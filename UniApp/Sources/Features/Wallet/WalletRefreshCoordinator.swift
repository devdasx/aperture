import Foundation
import Observation
import SwiftData
import OSLog

/// Orchestrates a wallet-home refresh cycle: fan out balance scans
/// across the active wallet's addresses, fetch any missing prices,
/// upsert results into the local store via the repository actors.
///
/// Called from `WalletHomeView.refreshable { await ... }` and from
/// the future `BGTaskScheduler` background refresh (T-041 / T-044).
///
/// **Honest current state.** Wired against `StubBalanceScanner` for
/// v1; per-chain real scanners land as T-037..T-040. The wallet-home
/// "Last synced …" footer surfaces the truth either way — the row is
/// the same regardless of whether the data came from stubs or chain.
struct WalletRefreshCoordinator: Sendable {
    let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "wallet-refresh")

    /// Refresh balances + prices for the given wallet. Catches and
    /// logs individual address-level failures so a single failing
    /// chain doesn't kill the whole refresh. Returns when all
    /// addresses have been touched (either with new balances or with
    /// a `markScanComplete` so the "last synced" footer reflects the
    /// attempt).
    ///
    /// **In-flight deduplication (2026-06-10).** Concurrent calls for
    /// the same wallet (pull-to-refresh racing a scene-phase refresh)
    /// previously ran two full scan pipelines that raced each other's
    /// SwiftData upserts and doubled every RPC fetch. The first caller
    /// now registers its task in `WalletRefreshRegistry`; every
    /// concurrent caller for the same `walletId` awaits that same task
    /// instead of starting a second pipeline.
    ///
    /// **User-initiated escape hatch (2026-06-12).** Joining the
    /// in-flight task meant a pull-to-refresh against a WEDGED
    /// pipeline (a stalled RPC read) silently absorbed the pull —
    /// "refresh did nothing" was guaranteed for the duration of the
    /// stall. When `userInitiated` is `true` and a pipeline is
    /// already in flight, the existing task is CANCELLED (the
    /// cancellation propagates through the scan stream and
    /// `RPCClient` as `RPCError.cancelled`) and a fresh pipeline
    /// starts in its place. Background / auto refreshes keep the
    /// join semantics — they have no user waiting on them.
    ///
    /// Returns the set of chains whose balance scan yielded nothing
    /// even after the bounded retry pass (empty = every chain
    /// reported). The same outcome is published on
    /// `WalletRefreshState.shared` for observers that don't own the
    /// call site.
    @discardableResult
    func refreshWallet(
        walletId: UUID,
        fiatCode: String,
        userInitiated: Bool = false
    ) async -> Set<SupportedChain> {
        let task = await WalletRefreshRegistry.joinOrStart(
            walletId: walletId,
            cancelExisting: userInitiated
        ) {
            await self.performRefresh(walletId: walletId, fiatCode: fiatCode)
        }
        return await task.value
    }

    /// The actual refresh pipeline. Only ever entered through the
    /// registry above, so at most one instance runs per wallet at a
    /// time. Returns the chains whose balance scan yielded nothing
    /// even after the bounded retry pass below.
    private func performRefresh(walletId: UUID, fiatCode: String) async -> Set<SupportedChain> {
        let refreshGeneration = await MainActor.run {
            WalletRefreshState.shared.beginRefresh()
        }
        let txRepo = TransactionRepository(modelContainer: container)

        // **Local-first freshness ledger (Rule #27 §B).** Stamp this
        // wallet's balance + transaction domains as syncing now; mark
        // synced / failed at the end. The wallet-home footer reads these
        // `SyncStatusRecord` rows via `@Query` to show an honest
        // "Updated 14:31 · Syncing…" instead of pretending a cached
        // value is live. Stamps never block the refresh (try?).
        let syncRepo = SyncStatusRepository(modelContainer: container)
        let syncScope = walletId.uuidString
        try? await syncRepo.markSyncing(domain: .balances, scopeId: syncScope)
        try? await syncRepo.markSyncing(domain: .transactions, scopeId: syncScope)

        // Resolve the user's currency code → struct once, so the
        // per-address tasks share an immutable Sendable value.
        // Falls back to USD if the stored code somehow isn't in our
        // supported list (Locale-bootstrap may have written an
        // unsupported code on first launch).
        let currency = CurrencyPreference.currency(for: fiatCode)
            ?? CurrencyPreference.currency(for: "USD")
            ?? CurrencyPreference.all[0]

        // Read the wallet's addresses on the main actor for a one-shot
        // snapshot. We don't hold the context across await points to
        // keep concurrency clean.
        var snapshot = await MainActor.run { fetchAddressSnapshot(walletId: walletId) }

        // **2026-06-12 — empty-snapshot backoff.** A refresh fired in
        // the import-completion window can land before the freshly
        // imported wallet's rows are visible to a new context (the
        // repository actor's save commits a beat before cross-context
        // visibility is guaranteed). An empty snapshot used to
        // silently no-op the entire refresh — the wallet then showed
        // $0.00 until the next manual pull or relaunch. Re-ask the
        // store a few times before declaring the no-op.
        if snapshot.isEmpty {
            for attempt in 1...3 where !Task.isCancelled {
                Self.log.info("Empty address snapshot for wallet \(walletId.uuidString, privacy: .public) — retry \(attempt, privacy: .public)/3 after backoff")
                try? await Task.sleep(for: .milliseconds(500))
                snapshot = await MainActor.run { fetchAddressSnapshot(walletId: walletId) }
                if !snapshot.isEmpty { break }
            }
            if snapshot.isEmpty {
                Self.log.error("Address snapshot still empty for wallet \(walletId.uuidString, privacy: .public) — balance refresh has nothing to scan")
            }
        }

        // Immutable rebind after the backoff loop — `async let` below
        // sends the value across an isolation region, which Swift 6
        // (correctly) refuses for a still-mutable `var`.
        let addressSnapshot = snapshot

        // 2026-06-09 — **switched the main-screen refresh to the
        // same `RealRPCBalanceScanner.streamScan` the Import flow
        // uses.** Previously the wallet-home only fetched the
        // chain's native coin balance (via the per-address
        // `scanViaRealRPC` path); tokens (ERC-20 / SPL / TRC-20 /
        // jettons / IBC) were never refreshed after import, so
        // their rows showed stale or zero amounts forever. The
        // import scanner already does it right — discover native
        // + every supported token per chain in a single streamed
        // pass. Reuse that path here for parity.
        //
        // **Chain → address snapshot map.** `streamScan` takes one
        // address per chain (HD wallet shape). Multi-address-per-
        // chain wallets (xpub watch-only) lose the duplicates here,
        // matching the Import flow's contract.
        var chainAddresses: [SupportedChain: String] = [:]
        var chainSnapshots: [SupportedChain: AddressSnapshot] = [:]
        for snap in addressSnapshot {
            chainAddresses[snap.chain] = snap.address
            chainSnapshots[snap.chain] = snap
        }

        // Load user-added custom tokens grouped by chain so the
        // scanner can run the same balance-fetch path against them
        // as it does for the static registry, AND so the
        // transaction-history allowlist (Rule #16 — drop unsolicited
        // airdrops) admits the user's tokens. Empty when the user
        // hasn't added any — the scanner short-circuits per chain
        // in that case.
        let customTokensByChain: [SupportedChain: [CustomTokenSnapshot]] = await {
            let repo = CustomTokenRepository(modelContainer: container)
            guard let all = try? await repo.fetchAll(chain: nil) else { return [:] }
            return Dictionary(grouping: all, by: { $0.chain })
        }()

        // Transaction-history fetch runs in parallel — independent
        // pipeline (different adapters), so we kick it off before
        // the balance stream and let it complete in the
        // background. The `customTokensByChain` map seeds the
        // adapter's allowlist so EVM token history only includes
        // registry + user-added contracts (no spam airdrops).
        async let txHistoryTask: Void = scanAllTransactionHistory(
            snapshot: addressSnapshot,
            customTokensByChain: customTokensByChain,
            txRepo: txRepo
        )

        // **2026-06-11 — shared RPCClient.** The client's rate
        // limiter and circuit breakers are instance state; a fresh
        // client per scan reset them to zero every time, so neither
        // mechanism ever actually accumulated. `RPCClient.shared`
        // makes both enforce their contracts across the whole app.
        let scanner = RealRPCBalanceScanner(client: RPCClient.shared)
        let stream = scanner.streamScan(
            addresses: chainAddresses,
            currency: currency,
            customTokens: customTokensByChain
        )

        // Track which chains yielded a native row so we can (a)
        // retry the ones that didn't and (b) mark the rest
        // scan-complete at the end (chains whose RPC failed
        // entirely still need their "Last synced" stamp refreshed
        // for honesty). The scanner yields a native row for every
        // chain it could READ — a genuine zero balance still
        // yields — so "no row" means the read failed, not that the
        // wallet is empty.
        var nativeYieldedChains = await consumeBalanceStream(
            stream,
            chainSnapshots: chainSnapshots,
            txRepo: txRepo
        )

        var failedChains = Set(chainAddresses.keys).subtracting(nativeYieldedChains)

        // **2026-06-12 — one bounded coordinator-level retry pass.**
        // A fresh import has nothing persisted; if a chain's first
        // read fails, the user would see a silent $0.00 row forever
        // (honest-failure semantics yield no row, and nothing was
        // ever stored). Give every failed chain exactly one more
        // attempt after a short backoff — transient provider blips
        // (rate-limit bursts, cold circuit breakers) usually clear
        // within seconds. Chains that fail twice are reported via
        // the returned set + `WalletRefreshState` so the UI can be
        // honest instead of rendering all-zeros.
        if !failedChains.isEmpty, !Task.isCancelled {
            Self.log.info("Balance scan retry for \(failedChains.count, privacy: .public) failed chain(s) after backoff")
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                let retryAddresses = chainAddresses.filter { failedChains.contains($0.key) }
                let retryCustomTokens = customTokensByChain.filter { failedChains.contains($0.key) }
                let retryStream = scanner.streamScan(
                    addresses: retryAddresses,
                    currency: currency,
                    customTokens: retryCustomTokens
                )
                let retriedChains = await consumeBalanceStream(
                    retryStream,
                    chainSnapshots: chainSnapshots,
                    txRepo: txRepo
                )
                nativeYieldedChains.formUnion(retriedChains)
                failedChains = Set(chainAddresses.keys).subtracting(nativeYieldedChains)
            }
        }

        // Chains whose native row never landed — mark scan
        // complete with prior `isUsed` so the "Last synced" footer
        // updates and the UI doesn't lie about a stale read.
        // Skipped when the pipeline was cancelled (a user-initiated
        // replacement is running; stamping scans we never finished
        // would be dishonest).
        if !Task.isCancelled {
            for snap in addressSnapshot where !nativeYieldedChains.contains(snap.chain) {
                try? await txRepo.markScanComplete(addressId: snap.id, isUsed: snap.isUsed)
            }
        }

        await txHistoryTask
        // Transaction history pass ran to completion — stamp it synced
        // (the scanner swallows per-chain failures, so completion is the
        // freshness signal available here). Skipped if cancelled.
        if !Task.isCancelled {
            try? await syncRepo.markSynced(domain: .transactions, scopeId: syncScope)
        }

        // 2026-06-13 — persist this wallet's portfolio-value timeline.
        // The repository sums the freshly-upserted balance rows in the
        // active currency and appends one `WalletChartSnapshotRecord`
        // (throttled to 10 min per wallet+currency, pruned per its
        // growth bound). Failed chains keep their last-known persisted
        // rows, so a partial refresh still records an honest
        // last-known total. Skipped when cancelled — a replaced
        // pipeline must not stamp a point its replacement will also
        // stamp.
        if !Task.isCancelled {
            let chartRepo = WalletChartSnapshotRepository(modelContainer: container)
            do {
                try await chartRepo.captureFromPersistedBalances(
                    walletId: walletId,
                    currencyCode: currency.code
                )
            } catch {
                Self.log.error("chart snapshot capture failed for \(walletId.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // Stamp the balance + price freshness ledger (Rule #27 §B).
        // Balances are "synced" unless EVERY chain failed — a partial
        // success still means the store holds fresh data for the chains
        // that answered. The shared price batch ran as part of the
        // balance stream, so a balance success implies prices synced.
        // Skipped when cancelled (a replacement pipeline owns the stamp).
        if !Task.isCancelled {
            let everyChainFailed = !chainAddresses.isEmpty
                && failedChains == Set(chainAddresses.keys)
            if everyChainFailed {
                try? await syncRepo.markFailed(
                    domain: .balances,
                    scopeId: syncScope,
                    error: "All \(failedChains.count) chains failed to sync"
                )
            } else {
                try? await syncRepo.markSynced(domain: .balances, scopeId: syncScope)
                try? await syncRepo.markSynced(domain: .prices, scopeId: SyncDomain.globalScope)
                try? await syncRepo.markSynced(domain: .chart, scopeId: syncScope)
            }
        }

        // Publish the outcome. The generation guard inside
        // `endRefresh` discards stale completions — a cancelled
        // pipeline that limps to this line after its replacement
        // began cannot clobber the replacement's state.
        let outcome = failedChains
        await MainActor.run {
            WalletRefreshState.shared.endRefresh(
                walletId: walletId,
                failedChains: outcome,
                generation: refreshGeneration
            )
        }
        return outcome
    }

    /// Consume one balance stream: queue every yielded row's upsert
    /// onto a task group and return the set of chains whose NATIVE
    /// row landed. Shared by the first pass and the retry pass of
    /// `performRefresh`.
    ///
    /// **2026-06-09 — parallel upserts.** Previously each yielded
    /// row blocked the stream consumer on a sequential `await
    /// upsertNativeBalance/upsertTokenBalance(...)` call.
    /// SwiftData's `@ModelActor` serializes writes internally
    /// anyway, but the actor hop overhead per row added up
    /// across dozens of rows per refresh. The `withTaskGroup`
    /// shape lets each upsert run on the actor's queue WITHOUT
    /// blocking the stream consumer — we keep pulling rows from
    /// the network stream while writes happen in parallel.
    private func consumeBalanceStream(
        _ stream: AsyncStream<RealRPCBalanceScanner.StreamRow>,
        chainSnapshots: [SupportedChain: AddressSnapshot],
        txRepo: TransactionRepository
    ) async -> Set<SupportedChain> {
        var nativeYieldedChains: Set<SupportedChain> = []
        await withTaskGroup(of: Void.self) { upsertGroup in
            for await row in stream {
                switch row {
                case .native(let chainBalance):
                    guard let snap = chainSnapshots[chainBalance.chain] else { continue }
                    nativeYieldedChains.insert(chainBalance.chain)
                    upsertGroup.addTask {
                        await self.upsertNativeBalance(
                            snap: snap,
                            chainBalance: chainBalance,
                            txRepo: txRepo
                        )
                    }
                case .token(let tokenBalance):
                    guard let snap = chainSnapshots[tokenBalance.chain] else { continue }
                    upsertGroup.addTask {
                        await self.upsertTokenBalance(
                            snap: snap,
                            tokenBalance: tokenBalance,
                            txRepo: txRepo
                        )
                    }
                }
            }
            // Wait for every queued upsert to finish before
            // proceeding to the post-stream cleanup
            // (`markScanComplete` for chains that didn't yield).
            await upsertGroup.waitForAll()
        }
        return nativeYieldedChains
    }

    /// 2026-06-09 — Upsert a streamScan-yielded native chain
    /// balance for a specific address snapshot. Honest fiat: the
    /// stream's `ChainBalance.fiatBalance` is `Decimal?` — `nil`
    /// means the price is unavailable RIGHT NOW (the shared price
    /// batch hasn't resolved this symbol yet, or was cancelled). We
    /// forward that `nil` to `upsertBalance`, which PRESERVES the
    /// row's last-known price instead of stomping it to 0 (the
    /// 2026-06-13 BTC/ETH "Price unavailable" fix — see
    /// `TransactionRepository.upsertBalance`). The first, balance-only
    /// yield therefore never blanks a good price; the second, priced
    /// yield updates it for real.
    private func upsertNativeBalance(
        snap: AddressSnapshot,
        chainBalance: ChainBalance,
        txRepo: TransactionRepository
    ) async {
        do {
            try await txRepo.upsertBalance(
                addressId: snap.id,
                tokenSymbol: snap.chain.ticker,
                tokenContract: nil,
                decimals: 0,
                rawBalance: Self.decimalString(chainBalance.nativeBalance),
                fiatValueCached: chainBalance.fiatBalance,
                fiatCurrencyCode: chainBalance.fiatCurrencyCode
            )
            try await txRepo.markScanComplete(
                addressId: snap.id,
                isUsed: chainBalance.isUsed
            )
            Self.log.info("Native balance for \(snap.chain.rawValue, privacy: .public)/\(snap.address, privacy: .public): \(String(describing: chainBalance.nativeBalance), privacy: .public)")
        } catch {
            Self.log.error("upsertBalance (native) failed for \(snap.address, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// 2026-06-09 — Upsert a streamScan-yielded fungible token
    /// balance. `tokenContract` carries the chain's contract /
    /// mint / asset id (ERC-20 contract, SPL mint, TRC-20 contract,
    /// jetton master, IBC denom). The repository's compound unique
    /// key is `(addressId, tokenSymbol, tokenContract)` so re-runs
    /// idempotently update the same row.
    private func upsertTokenBalance(
        snap: AddressSnapshot,
        tokenBalance: TokenBalance,
        txRepo: TransactionRepository
    ) async {
        // **2026-06-09 — decimals bug fix.** `TokenBalance.amount`
        // is ALREADY decimal-decoded by `RealRPCBalanceScanner`
        // (e.g. `20.0` for 20 USDT). The storage schema's contract
        // is `rawBalance` = raw on-chain INTEGER (e.g. `"20000000"`)
        // + `decimals` = the token's decimals (e.g. `6`); the UI
        // formatter (`WalletFormatting.decimalAmount(...)`) divides
        // by `10^decimals`. The previous code stored the decoded
        // amount AND the decimals — so the UI divided 20.0 by 10⁶
        // again, displaying `0.00002 USDT` for a 20 USDT holding.
        //
        // Fix: convert the decoded amount back to the raw integer
        // by multiplying by `10^decimals` before persisting. The
        // schema contract is now honored on both write and read.
        let rawInteger = tokenBalance.amount * Self.pow10(tokenBalance.decimals)
        let rawString = Self.integerString(from: rawInteger)
        do {
            try await txRepo.upsertBalance(
                addressId: snap.id,
                tokenSymbol: tokenBalance.symbol,
                tokenContract: tokenBalance.contract,
                decimals: tokenBalance.decimals,
                rawBalance: rawString,
                // `nil` (price unknown) preserves the row's last-known
                // price; only a real quote overwrites it — same
                // 2026-06-13 fix as the native path above.
                fiatValueCached: tokenBalance.fiatBalance,
                fiatCurrencyCode: tokenBalance.fiatCurrencyCode
            )
            Self.log.info("Token balance for \(snap.chain.rawValue, privacy: .public)/\(tokenBalance.symbol, privacy: .public): \(String(describing: tokenBalance.amount), privacy: .public) (raw \(rawString, privacy: .public))")
        } catch {
            Self.log.error("upsertBalance (token) failed for \(tokenBalance.symbol, privacy: .public) on \(snap.address, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// 10^exponent as a `Decimal`. Pure exponentiation, no
    /// floating-point — `Decimal` carries arbitrary precision up
    /// to 38 significant digits, plenty for any token's 6–24
    /// decimal scale.
    private static func pow10(_ exponent: Int) -> Decimal {
        guard exponent > 0 else { return Decimal(1) }
        var result = Decimal(1)
        var base = Decimal(10)
        var n = exponent
        while n > 0 {
            if n & 1 == 1 { result *= base }
            n >>= 1
            if n > 0 { base *= base }
        }
        return result
    }

    /// `Decimal` → integer-form string, suppressing any fractional
    /// remainder (which `tokenBalance.amount * pow10(decimals)`
    /// shouldn't produce, but defensive). Without this guard a
    /// scientific-notation render like "2e+7" could leak through.
    private static func integerString(from value: Decimal) -> String {
        var rounded = Decimal()
        var input = value
        NSDecimalRound(&rounded, &input, 0, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    /// `Decimal` → plain decimal string for persistence (2026-06-10).
    /// `String(describing:)` on a `Decimal` can emit scientific
    /// notation (`"2e-07"`), which `Decimal(string:)` mis-parses on
    /// read-back — it stops at the exponent marker, so stored
    /// balances and amounts silently collapse to wrong values.
    /// `NSDecimalNumber.stringValue` always renders plain notation
    /// that round-trips through `Decimal(string:)` losslessly.
    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// 2026-06-09 — Fan-out transaction-history scan across every
    /// address in the wallet snapshot. Independent of the balance
    /// stream; uses the unified `RealRPCTransactionScanner`'s
    /// per-family adapters. Failures per-chain are swallowed by
    /// the scanner; this function never throws.
    ///
    /// **2026-06-12 — bounded retry pass.** The scanner returns an
    /// empty array for BOTH "the endpoint errored" and "this address
    /// genuinely has no history" — an empty yield is the only
    /// failure signal available at this level. Addresses that
    /// yielded nothing get exactly one more attempt after a short
    /// backoff (mirroring the balance pipeline's retry). The cost of
    /// re-asking a genuinely-empty-but-healthy chain is one cheap
    /// RPC round-trip per refresh; the gain is that a fresh import
    /// whose history fetch hit a transient blip still gets its
    /// activity feed this refresh instead of never.
    private func scanAllTransactionHistory(
        snapshot: [AddressSnapshot],
        customTokensByChain: [SupportedChain: [CustomTokenSnapshot]],
        txRepo: TransactionRepository
    ) async {
        // Shared client (2026-06-11) — limiter + breaker state must
        // accumulate across the fan-out, not reset per refresh.
        let rpcClient = RPCClient.shared

        // First pass — collect the addresses that yielded nothing.
        var pendingRetry: [AddressSnapshot] = []
        await withTaskGroup(of: AddressSnapshot?.self) { group in
            for snap in snapshot {
                let customContracts = customTokensByChain[snap.chain]?.map { $0.contract } ?? []
                group.addTask {
                    let persisted = await scanTransactionHistory(
                        address: snap,
                        client: rpcClient,
                        txRepo: txRepo,
                        customContracts: customContracts
                    )
                    return persisted == 0 ? snap : nil
                }
            }
            for await emptyYield in group {
                if let emptyYield { pendingRetry.append(emptyYield) }
            }
        }

        // Stub addresses short-circuit inside the scanner — retrying
        // them is a guaranteed second no-op, so drop them here.
        pendingRetry.removeAll { $0.address.hasPrefix(StubKeyImportService.stubAddressPrefix) }
        guard !pendingRetry.isEmpty, !Task.isCancelled else { return }

        Self.log.info("Transaction-history retry for \(pendingRetry.count, privacy: .public) address(es) after backoff")
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }

        // Second (final) pass — same fetch, same persistence path.
        // Still-empty results stay empty; the scanner's honesty
        // contract means we never fabricate rows for a chain that
        // won't answer.
        await withTaskGroup(of: Void.self) { group in
            for snap in pendingRetry {
                let customContracts = customTokensByChain[snap.chain]?.map { $0.contract } ?? []
                group.addTask {
                    _ = await scanTransactionHistory(
                        address: snap,
                        client: rpcClient,
                        txRepo: txRepo,
                        customContracts: customContracts
                    )
                }
            }
        }
    }

    // MARK: - Currency re-price (2026-06-13)

    /// Fast re-price of the wallet's **persisted** balances into
    /// `fiatCode` — no on-chain rescan. This is the currency-change
    /// fast path: the user flips JOD → USD in Settings, every
    /// existing `TokenBalanceRecord` gets its `fiatValueCached`
    /// re-valued in the new currency within one price batch, and the
    /// caller then kicks a normal `refreshWallet` for live balances.
    ///
    /// Per-row resolution follows the `TokenPricingEngine` ladder
    /// (Coinbase → per-currency cache → CoinGecko); rows whose symbol
    /// no fetch rung can price fall to the **balance-derived** rung:
    /// the row's own cached fiat re-denominated via the FX cross rate
    /// (old currency → new currency). Rows that even that cannot
    /// convert are left untouched — they keep their old
    /// `fiatCurrencyCode`, so the UI keeps showing the old currency
    /// symbol next to the old value (honest pairing) instead of a
    /// wrong number under a new symbol.
    func repriceWallet(walletId: UUID, fiatCode: String) async {
        let code = (CurrencyPreference.currency(for: fiatCode)?.code ?? CurrencyPreference.defaultCode).uppercased()
        let rows = await MainActor.run { fetchBalanceRowSnapshot(walletId: walletId) }
        guard !rows.isEmpty else { return }

        let engine = TokenPricingEngine.shared
        let symbols = Array(Set(rows.map { $0.symbol.uppercased() }))
        let prices = await engine.unitPrices(symbols: symbols, currencyCode: code)
        guard !Task.isCancelled else { return }

        let txRepo = TransactionRepository(modelContainer: container)
        var repriced = 0
        for row in rows {
            let amount = WalletFormatting.decimalAmount(
                rawBalance: row.rawBalance,
                decimals: row.decimals
            )
            var newFiat: Decimal?
            if let price = prices[row.symbol.uppercased()] {
                newFiat = amount * price.amount
            } else if row.fiatCurrencyCode.uppercased() != code,
                      row.fiatValueCached > 0,
                      let cross = await engine.crossRate(from: row.fiatCurrencyCode, to: code) {
                // Balance-derived rung: per-unit price implied by the
                // row's own cached fiat, re-denominated via FX.
                newFiat = row.fiatValueCached * cross
            }
            guard let newFiat else { continue }  // omit — row stays honest in its old currency
            do {
                try await txRepo.upsertBalance(
                    addressId: row.addressId,
                    tokenSymbol: row.symbol,
                    tokenContract: row.contract,
                    decimals: row.decimals,
                    rawBalance: row.rawBalance,
                    fiatValueCached: newFiat,
                    fiatCurrencyCode: code
                )
                repriced += 1
            } catch {
                Self.log.error("reprice upsert failed for \(row.symbol, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        Self.log.info("Repriced \(repriced, privacy: .public)/\(rows.count, privacy: .public) balance rows into \(code, privacy: .public)")
    }

    /// One persisted balance row, flattened for the re-price pass.
    private struct BalanceRowSnapshot: Sendable {
        let addressId: UUID
        let symbol: String
        let contract: String?
        let decimals: Int
        let rawBalance: String
        let fiatValueCached: Decimal
        let fiatCurrencyCode: String
    }

    @MainActor
    private func fetchBalanceRowSnapshot(walletId: UUID) -> [BalanceRowSnapshot] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        descriptor.fetchLimit = 1
        guard let wallet = try? context.fetch(descriptor).first else { return [] }
        var rows: [BalanceRowSnapshot] = []
        for address in wallet.addresses {
            for balance in address.balances where !balance.rawBalance.isEmpty {
                rows.append(BalanceRowSnapshot(
                    addressId: address.id,
                    symbol: balance.tokenSymbol,
                    contract: balance.tokenContract,
                    decimals: balance.decimals,
                    rawBalance: balance.rawBalance,
                    fiatValueCached: balance.fiatValueCached,
                    fiatCurrencyCode: balance.fiatCurrencyCode
                ))
            }
        }
        return rows
    }

    /// Drives the unified `RealRPCTransactionScanner` for one
    /// address and upserts every event into SwiftData via
    /// `TransactionRepository`. Same scanner powers the
    /// `WalletHomeView` test-mode feed; this path is the
    /// production sink that persists history for the user's real
    /// wallet.
    ///
    /// Returns the number of events the scanner yielded (0 = either
    /// the endpoint failed or the address genuinely has no history —
    /// the scanner swallows the distinction). The retry pass in
    /// `scanAllTransactionHistory` keys off this count.
    @discardableResult
    private func scanTransactionHistory(
        address: AddressSnapshot,
        client: RPCClient,
        txRepo: TransactionRepository,
        customContracts: [String] = []
    ) async -> Int {
        let scanner = RealRPCTransactionScanner(client: client)
        let events = await scanner.scan(
            addresses: [address.chain: address.address],
            limit: 25,
            customContractsByChain: customContracts.isEmpty
                ? [:]
                : [address.chain: customContracts]
        )
        guard !events.isEmpty else { return 0 }
        for event in events {
            do {
                try await txRepo.upsertTransaction(
                    addressId: address.id,
                    txHash: event.txHash,
                    direction: event.direction,
                    amountRaw: Self.decimalString(event.amount),
                    tokenSymbol: event.tokenSymbol,
                    tokenContract: event.tokenContract,
                    blockNumber: event.blockNumber,
                    occurredAt: event.occurredAt,
                    status: event.status,
                    counterparty: event.counterparty,
                    feeRaw: event.fee.map { Self.decimalString($0) }
                )
            } catch {
                Self.log.error("upsertTransaction failed for \(event.txHash, privacy: .public) on \(address.chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        Self.log.info("Transaction history for \(address.chain.rawValue, privacy: .public)/\(address.address, privacy: .public): persisted \(events.count, privacy: .public) events")
        return events.count
    }

    // (2026-06-13 — the dead per-address `scan` / `scanViaRealRPC` /
    // `fetchSummary` / `fiatValueFor` / `refreshPrice` legacy path
    // was removed. It had no callers since the 2026-06-09 switch to
    // `streamScan`, and its contract — "the persistence layer always
    // stores USD" — contradicted the active-currency pricing ladder
    // that `TokenPricingEngine` now owns.)

    // MARK: - Historical daily closes (Rule #27 §A — sync layer owns the wire)

    /// The sync layer's sole owner of historical daily-close fetching.
    /// Feature views (`WalletHomeView`, `AssetDetailView`) must NOT call
    /// `CoinbaseHistoricalPriceService` directly (Rule #27 §A.3 / §E) —
    /// they read `HistoricalPriceRecord` from the store and call this to
    /// fill gaps. `symbols` is the desired set (from held balances + tx
    /// history, all DB-derived); `alreadyHave` is the symbols the store
    /// already covers for `fiat` (also DB-derived) — so the view passes
    /// only store state, never touches the network. Fetches just the
    /// missing symbols, writes them to the store, and stamps
    /// `.historical` freshness. Bounded to 4 concurrent fetches.
    func syncHistoricalCloses(
        symbols: [String],
        fiat: String,
        alreadyHave: Set<String>
    ) async {
        let wanted = Set(symbols.map { $0.uppercased() })
        let have = Set(alreadyHave.map { $0.uppercased() })
        let missing = wanted.subtracting(have)
        guard !missing.isEmpty else { return }

        let syncRepo = SyncStatusRepository(modelContainer: container)
        try? await syncRepo.markSyncing(domain: .historical, scopeId: SyncDomain.globalScope)

        let service = CoinbaseHistoricalPriceService()
        let repo = HistoricalPriceRepository(modelContainer: container)
        let fiatCode = fiat

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for symbol in missing {
                if inFlight >= 4 {
                    await group.next()
                    inFlight -= 1
                }
                inFlight += 1
                group.addTask {
                    let candles = await service.fetchDailyCloses(symbol: symbol, fiat: fiatCode)
                    guard !candles.isEmpty else { return }
                    let entries = candles.map {
                        (symbol: symbol, fiat: fiatCode, dayKey: $0.dayKey, price: $0.close)
                    }
                    do {
                        try await repo.upsertMany(entries)
                    } catch {
                        Self.log.error("historical upsert failed for \(symbol, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }

        try? await syncRepo.markSynced(domain: .historical, scopeId: SyncDomain.globalScope)
    }

    // MARK: - Snapshot helpers

    private struct AddressSnapshot: Sendable {
        let id: UUID
        let address: String
        let chain: SupportedChain
        let isUsed: Bool
    }

    @MainActor
    private func fetchAddressSnapshot(walletId: UUID) -> [AddressSnapshot] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        descriptor.fetchLimit = 1
        guard let wallet = try? context.fetch(descriptor).first else { return [] }
        return wallet.addresses.compactMap { row in
            guard let chain = SupportedChain(rawValue: row.chainRaw) else { return nil }
            return AddressSnapshot(
                id: row.id,
                address: row.address,
                chain: chain,
                isUsed: row.isUsed
            )
        }
    }
}

// MARK: - Observable refresh state

/// Shared observable surface for the most recent refresh outcome.
/// The coordinator itself is a transient value (one per
/// `runRefresh()` call in `WalletHomeView`), so the outcome lives
/// here instead — the wallet home reads `lastRefreshFailedChains`
/// to decide between the silent all-supported $0.00 list (dishonest
/// for a fresh import whose every chain failed) and the explicit
/// "Couldn't reach the network" state.
@MainActor
@Observable
final class WalletRefreshState {
    static let shared = WalletRefreshState()

    /// `true` while a refresh pipeline is in flight (for any wallet).
    private(set) var isRefreshing: Bool = false
    /// Chains whose balance scan yielded nothing in the most recent
    /// COMPLETED refresh — after the bounded retry pass. Empty when
    /// every chain reported, or when no refresh has finished yet.
    private(set) var lastRefreshFailedChains: Set<SupportedChain> = []
    /// The wallet `lastRefreshFailedChains` belongs to. Readers must
    /// compare against their active wallet before acting — a stale
    /// outcome for wallet A says nothing about wallet B.
    private(set) var lastRefreshWalletId: UUID?

    /// Monotonic run counter. A cancelled pipeline's late completion
    /// (or its replacement racing it onto the main actor) must never
    /// clobber the newest run's published state.
    private var generation: Int = 0

    fileprivate func beginRefresh() -> Int {
        generation += 1
        isRefreshing = true
        return generation
    }

    /// Invalidate any in-flight run's pending `endRefresh` — called
    /// by the registry the moment a user-initiated refresh cancels
    /// an existing pipeline, so the doomed run's completion is
    /// guaranteed stale regardless of main-actor scheduling order.
    fileprivate func invalidate() {
        generation += 1
    }

    fileprivate func endRefresh(
        walletId: UUID,
        failedChains: Set<SupportedChain>,
        generation: Int
    ) {
        guard generation == self.generation else { return }
        isRefreshing = false
        lastRefreshFailedChains = failedChains
        lastRefreshWalletId = walletId
    }
}

// MARK: - In-flight refresh registry

/// Per-wallet refresh deduplication (2026-06-10). SwiftData upserts
/// are idempotent per row, but two pipelines racing each other still
/// double every network fetch and interleave `markScanComplete`
/// stamps against the same records. The registry keys exactly one
/// in-flight task per `walletId`; concurrent `refreshWallet` calls
/// join the existing task instead of starting a second pipeline.
/// `@MainActor` serializes all dictionary access — no lock needed.
///
/// **2026-06-12 — user-initiated cancellation.** `cancelExisting`
/// lets a pull-to-refresh replace a wedged pipeline instead of
/// joining it. The deregistration is token-guarded so a cancelled
/// task's late completion can't clobber its replacement's
/// registration.
@MainActor
private enum WalletRefreshRegistry {
    private struct Entry {
        let token: UUID
        let task: Task<Set<SupportedChain>, Never>
    }

    private static var inFlight: [UUID: Entry] = [:]

    /// Returns the already-running refresh task for `walletId` when
    /// one exists (and `cancelExisting` is `false`); otherwise starts
    /// `operation` as a new task, registers it, and deregisters it on
    /// completion. With `cancelExisting`, any in-flight task is
    /// cancelled first and a fresh pipeline starts in its place.
    static func joinOrStart(
        walletId: UUID,
        cancelExisting: Bool = false,
        operation: @escaping @Sendable () async -> Set<SupportedChain>
    ) -> Task<Set<SupportedChain>, Never> {
        if let existing = inFlight[walletId] {
            guard cancelExisting else { return existing.task }
            // User pulled against a (possibly wedged) pipeline —
            // cancel it (propagates through the scan stream and
            // RPCClient as `RPCError.cancelled`) and stale-out its
            // pending state publication before the replacement runs.
            existing.task.cancel()
            WalletRefreshState.shared.invalidate()
        }
        let token = UUID()
        let task = Task {
            let failedChains = await operation()
            // Deregister only if this task is still the registered
            // one — a cancelled task finishing late must not remove
            // its replacement's registration.
            if inFlight[walletId]?.token == token {
                inFlight[walletId] = nil
            }
            return failedChains
        }
        inFlight[walletId] = Entry(token: token, task: task)
        return task
    }
}
