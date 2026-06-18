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
        // Trigger label for the latency log — pull-to-refresh vs the
        // silent background/import/launch refresh.
        let triggerLabel = userInitiated ? "pull-to-refresh" : "background refresh"
        let task = await WalletRefreshRegistry.joinOrStart(
            walletId: walletId,
            cancelExisting: userInitiated
        ) {
            await self.performRefresh(
                walletId: walletId,
                fiatCode: fiatCode,
                triggerLabel: triggerLabel,
                liveCommit: userInitiated
            )
        }
        return await task.value
    }

    /// The actual refresh pipeline. Only ever entered through the
    /// registry above, so at most one instance runs per wallet at a
    /// time. Returns the chains whose balance scan yielded nothing
    /// even after the bounded retry pass below.
    ///
    /// `liveCommit` — only a USER-initiated pull-to-refresh streams balances
    /// to the UI per-chain (the user is watching the numbers tick). The silent
    /// background 30s auto-refresh sets this `false` so it accumulates every
    /// balance write and commits ONCE at the end: a user just reading the
    /// screen sees a single smooth update, not ~20 per-commit `@Query`
    /// re-renders mid-scan (the "laggy while idle" report, 2026-06-18).
    private func performRefresh(
        walletId: UUID,
        fiatCode: String,
        triggerLabel: String = "refresh",
        liveCommit: Bool = false
    ) async -> Set<SupportedChain> {
        // **Latency log (2026-06-17).** Reset + stamp the run here — the
        // single chokepoint every trigger (pull-to-refresh, open-wallet,
        // import, app-launch, periodic) funnels through — so the
        // diagnostics screen always reflects the most recent real pipeline.
        RefreshPerfLog.shared.beginRun(triggerLabel)
        let refreshGeneration = await MainActor.run {
            WalletRefreshState.shared.beginRefresh()
        }
        let txRepo = TransactionRepository(modelContainer: container)
        // 2026-06-17 — per-chain aggregate read-model (user direction "a
        // row for each chain, with all its details"). The same parallel
        // fan-out that fills the normalized balance / tx / UTXO rows feeds
        // this denormalized one-row-per-chain snapshot; the balance card
        // reads it so per-chain balances render live.
        let chainStateRepo = ChainStateRepository(modelContainer: container)

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
        // Stamp existing per-chain rows as syncing so the UI can show a
        // per-chain spinner until this refresh stamps each row's outcome.
        try? await chainStateRepo.markSyncing(walletId: walletId)

        // Resolve the user's currency code → struct once, so the
        // per-address tasks share an immutable Sendable value.
        // Falls back to USD if the stored code somehow isn't in our
        // supported list (Locale-bootstrap may have written an
        // unsupported code on first launch).
        let currency = CurrencyPreference.currency(for: fiatCode)
            ?? CurrencyPreference.currency(for: "USD")
            ?? CurrencyPreference.all[0]

        // Read the wallet's addresses into a one-shot Sendable snapshot
        // OFF the main thread (2026-06-14): this runs on the coordinator's
        // background executor via its OWN `ModelContext`, so a refresh
        // (incl. pull-to-refresh) never blocks scrolling/navigation. We
        // don't hold the context across await points — concurrency stays
        // clean and the snapshot is `Sendable`.
        let snapshotToken = RefreshPerfLog.shared.start()
        var snapshot = fetchAddressSnapshot(walletId: walletId)
        RefreshPerfLog.shared.end("db", "address snapshot (\(snapshot.count) addresses)", since: snapshotToken)

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
                snapshot = fetchAddressSnapshot(walletId: walletId)
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
            txRepo: txRepo,
            chainStateRepo: chainStateRepo,
            walletId: walletId,
            fiatCurrencyCode: currency.code
        )

        // 2026-06-17 — UTXO persistence + one-time encrypted-key population
        // run in parallel with the balance + history fan-out (the
        // `Promise.all` shape: independent `async let`s awaited before the
        // final per-chain rebuild). Both are best-effort — a failure here
        // never blocks the balances / history the user is waiting on.
        // Immutable copy of the chain→address map for the key task —
        // `chainAddresses` is a `var` read again by the balance retry pass,
        // so sending the `var` itself into the `async let` would risk a
        // data race (Swift 6 region isolation). The copy is value-typed and
        // owned solely by the task.
        let keyChainAddresses = chainAddresses
        async let utxoTask: Void = scanAndPersistUTXOs(
            walletId: walletId,
            snapshot: addressSnapshot,
            chainStateRepo: chainStateRepo
        )
        async let keyTask: Void = populateEncryptedKeys(
            walletId: walletId,
            chainAddresses: keyChainAddresses,
            chainStateRepo: chainStateRepo
        )

        // **2026-06-11 — shared RPCClient.** The client's rate
        // limiter and circuit breakers are instance state; a fresh
        // client per scan reset them to zero every time, so neither
        // mechanism ever actually accumulated. `RPCClient.shared`
        // makes both enforce their contracts across the whole app.
        // **2026-06-13 — price-scope.** Read the symbols the wallet
        // already HOLDS from the store so the scanner prices only those
        // (+ native + custom) instead of the full ~49-symbol registry
        // universe — faster fiat + lighter provider load. Empty on a
        // fresh wallet, which makes the scanner price the full universe
        // for the first scan (no regression). See
        // `RealRPCBalanceScanner.uniquePriceSymbols`.
        let heldSymbols: Set<String> =
            Set(fetchBalanceRowSnapshot(walletId: walletId).map { $0.symbol.uppercased() })

        let scanner = RealRPCBalanceScanner(client: RPCClient.shared)
        let stream = scanner.streamScan(
            addresses: chainAddresses,
            currency: currency,
            customTokens: customTokensByChain,
            priorityTokenSymbols: heldSymbols
        )

        // Track which chains yielded a native row so we can (a)
        // retry the ones that didn't and (b) mark the rest
        // scan-complete at the end (chains whose RPC failed
        // entirely still need their "Last synced" stamp refreshed
        // for honesty). The scanner yields a native row for every
        // chain it could READ — a genuine zero balance still
        // yields — so "no row" means the read failed, not that the
        // wallet is empty.
        let balancePassToken = RefreshPerfLog.shared.start()
        var nativeYieldedChains = await consumeBalanceStream(
            stream,
            chainSnapshots: chainSnapshots,
            txRepo: txRepo,
            chainStateRepo: chainStateRepo,
            walletId: walletId,
            fiatCurrencyCode: currency.code,
            liveCommit: liveCommit
        )
        RefreshPerfLog.shared.end("balance", "balance pass — \(nativeYieldedChains.count)/\(chainAddresses.count) chains landed", since: balancePassToken)

        let failedChains = Set(chainAddresses.keys).subtracting(nativeYieldedChains)

        // **2026-06-17 — retry pass removed for speed.** The old code slept
        // 3s and re-scanned failed chains in-pipeline, which kept the spinner
        // up for seconds *after* the fast chains were already done. Each chain
        // is now per-chain time-bounded (see `withTimeout` in the scanner), a
        // failed chain keeps its last-known persisted balance, and the next
        // refresh re-attempts it — the live per-chain commits + the @Query UI
        // mean the user sees what landed immediately, with no blocking wait.

        // Chains whose native row never landed — mark scan
        // complete with prior `isUsed` so the "Last synced" footer
        // updates and the UI doesn't lie about a stale read.
        // Skipped when the pipeline was cancelled (a user-initiated
        // replacement is running; stamping scans we never finished
        // would be dishonest).
        if !Task.isCancelled {
            for snap in addressSnapshot where !nativeYieldedChains.contains(snap.chain) {
                try? await txRepo.markScanComplete(addressId: snap.id, isUsed: snap.isUsed, save: false)
            }
        }

        // Commit the WHOLE balance pass in ONE main-context merge
        // (2026-06-14): every upsert above ran with `save: false`, so this
        // single flush replaces the dozens of per-record saves that fired a
        // @Query invalidation + main-thread body re-render each — the storm
        // that froze the UI during pull-to-refresh.
        try? await txRepo.flush()

        // Interim per-chain rebuild — balances have landed, so each chain
        // row lights up live (still `.syncing`) while transaction history
        // is in flight. The final rebuild below fills the tx counts + UTXOs.
        try? await chainStateRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: currency.code,
            interim: true
        )

        let historyPassToken = RefreshPerfLog.shared.start()
        await txHistoryTask
        RefreshPerfLog.shared.end("history", "history pass (all chains)", since: historyPassToken)
        // Transaction history pass ran to completion — stamp it synced
        // (the scanner swallows per-chain failures, so completion is the
        // freshness signal available here). Skipped if cancelled.
        // Flush the batched transaction writes in one merge (same fix).
        try? await txRepo.flush()
        if !Task.isCancelled {
            try? await syncRepo.markSynced(domain: .transactions, scopeId: syncScope)
        }

        // 2026-06-17 — FINAL per-chain rebuild. Ensure the parallel UTXO +
        // encrypted-key population finished, then recompute every chain row
        // from the now-complete balance + tx + UTXO state, stamping each
        // row `.synced` (or `.failed` for chains whose live read failed —
        // the row keeps its last-known balances). This is the snapshot the
        // balance card reads per chain.
        await utxoTask
        await keyTask
        let finalRebuildToken = RefreshPerfLog.shared.start()
        try? await chainStateRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: currency.code,
            failedChains: failedChains
        )
        RefreshPerfLog.shared.end("db", "final per-chain rebuild (all chains)", since: finalRebuildToken)

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
        RefreshPerfLog.shared.event("refresh", "failed chains: \(outcome.isEmpty ? "none" : outcome.map { $0.rawValue }.sorted().joined(separator: ", "))")
        RefreshPerfLog.shared.endRun()
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
        txRepo: TransactionRepository,
        chainStateRepo: ChainStateRepository,
        walletId: UUID,
        fiatCurrencyCode: String,
        liveCommit: Bool
    ) async -> Set<SupportedChain> {
        // **Live per-chain commit (2026-06-17, user direction).** Each
        // yielded row stages its upsert (`save: false`) and marks its chain
        // dirty; the committer below flushes + rebuilds dirty chains on a
        // ~120ms cadence, so a chain renders live the moment ITS balance RPC
        // lands — independent of every other chain — while the cadence
        // bounds @Query churn (the save-storm the old single-end-flush
        // guarded against). Fiat refines through the same path when the
        // shared price batch resolves.
        let channel = LiveCommitChannel()
        async let committer: Void = runLiveBalanceCommitter(
            channel: channel, txRepo: txRepo, chainStateRepo: chainStateRepo,
            walletId: walletId, fiatCurrencyCode: fiatCurrencyCode,
            liveCommit: liveCommit
        )

        var nativeYieldedChains: Set<SupportedChain> = []
        await withTaskGroup(of: Void.self) { upsertGroup in
            for await row in stream {
                switch row {
                case .native(let chainBalance):
                    guard let snap = chainSnapshots[chainBalance.chain] else { continue }
                    nativeYieldedChains.insert(chainBalance.chain)
                    let chain = chainBalance.chain
                    upsertGroup.addTask {
                        await self.upsertNativeBalance(
                            snap: snap,
                            chainBalance: chainBalance,
                            txRepo: txRepo
                        )
                        await channel.mark(chain)
                    }
                case .token(let tokenBalance):
                    guard let snap = chainSnapshots[tokenBalance.chain] else { continue }
                    let chain = tokenBalance.chain
                    upsertGroup.addTask {
                        await self.upsertTokenBalance(
                            snap: snap,
                            tokenBalance: tokenBalance,
                            txRepo: txRepo
                        )
                        await channel.mark(chain)
                    }
                }
            }
            // Wait for every queued upsert to finish before
            // proceeding to the post-stream cleanup
            // (`markScanComplete` for chains that didn't yield).
            await upsertGroup.waitForAll()
        }
        // Stream drained — let the committer make a final pass over any
        // chains still dirty, then exit.
        await channel.finish()
        await committer
        return nativeYieldedChains
    }

    /// Coalescing live committer for the balance stream. On a ~300ms
    /// cadence it drains the dirty-chain set, flushes the staged balance
    /// upserts in ONE main-context merge, then rebuilds just those chains'
    /// aggregate rows — so each chain goes live shortly after its balance
    /// lands while the cadence caps `@Query` invalidations. The cadence is
    /// the main lever against pull-to-refresh UI lag (2026-06-17): every
    /// commit triggers the home's `@Query` re-fetches + a display-row
    /// rebuild on the main actor, so coalescing more aggressively (300ms,
    /// up from 120ms) cuts that main-thread churn ~2.5× while still
    /// updating balances ~3×/second — imperceptibly less "live", far
    /// smoother. Exits after a final drain once `channel.finish()` fires.
    private func runLiveBalanceCommitter(
        channel: LiveCommitChannel,
        txRepo: TransactionRepository,
        chainStateRepo: ChainStateRepository,
        walletId: UUID,
        fiatCurrencyCode: String,
        liveCommit: Bool
    ) async {
        // **Background refresh commits ONCE (2026-06-18 lag fix).** A silent
        // 30s auto-refresh isn't being watched — streaming per-chain commits
        // just fires a `@Query` notification every interval, re-rendering /
        // recomputing whatever screen the user is reading (the wallet home,
        // an asset detail). So for a background run we DON'T commit mid-scan:
        // we wait for the stream to drain, then do the single final
        // `commitDirtyChains` below — one save, one re-render. A user pull
        // still streams live (they're watching the numbers land).
        if liveCommit {
            while !(await channel.isFinished) {
                try? await Task.sleep(for: .milliseconds(300))
                await commitDirtyChains(
                    channel: channel, txRepo: txRepo, chainStateRepo: chainStateRepo,
                    walletId: walletId, fiatCurrencyCode: fiatCurrencyCode
                )
            }
        } else {
            // Idle until the scan finishes; the staged upserts (save: false)
            // accumulate and land in the single final commit. Poll the
            // finished flag without committing so the UI stays still.
            while !(await channel.isFinished) {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Final drain — the live path's last delta, or the background path's
        // ONE and only commit for the whole scan.
        await commitDirtyChains(
            channel: channel, txRepo: txRepo, chainStateRepo: chainStateRepo,
            walletId: walletId, fiatCurrencyCode: fiatCurrencyCode
        )
    }

    /// Flush staged balance upserts and rebuild the dirty chains' aggregate
    /// rows (one coalesced commit). No-op when nothing is dirty.
    private func commitDirtyChains(
        channel: LiveCommitChannel,
        txRepo: TransactionRepository,
        chainStateRepo: ChainStateRepository,
        walletId: UUID,
        fiatCurrencyCode: String
    ) async {
        let dirty = await channel.drain()
        guard !dirty.isEmpty else { return }
        let token = RefreshPerfLog.shared.start()
        try? await txRepo.flush()
        try? await chainStateRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: fiatCurrencyCode,
            onlyChains: dirty,
            interim: true
        )
        RefreshPerfLog.shared.end("db", "live balance commit [\(dirty.map { $0.rawValue }.sorted().joined(separator: ","))]", since: token)
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
                fiatCurrencyCode: chainBalance.fiatCurrencyCode,
                save: false
            )
            try await txRepo.markScanComplete(
                addressId: snap.id,
                isUsed: chainBalance.isUsed,
                save: false
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
                fiatCurrencyCode: tokenBalance.fiatCurrencyCode,
                save: false
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
        txRepo: TransactionRepository,
        chainStateRepo: ChainStateRepository,
        walletId: UUID,
        fiatCurrencyCode: String
    ) async {
        // Shared client (2026-06-11) — limiter + breaker state must
        // accumulate across the fan-out, not reset per refresh.
        let rpcClient = RPCClient.shared

        // **Per-chain own-address set (2026-06-16, Rule #24).** Group the
        // wallet's full address snapshot by chain so every per-address
        // history scan knows ALL of the wallet's own addresses on that
        // chain. A transfer whose counterparty is one of these is a
        // self-transfer → the scanner relabels BOTH legs `.internal`
        // (the spend AND the receive), fixing the multi-address case the
        // per-address adapters can't see. Built once, shared (immutable)
        // across the fan-out.
        let ownAddressesByChain: [SupportedChain: Set<String>] = Dictionary(
            grouping: snapshot, by: { $0.chain }
        ).mapValues { Set($0.map { $0.address }) }

        // **Single per-chain history pass (2026-06-17 — in-pipeline retry
        // removed for speed).** Each scan is per-chain time-bounded (see
        // `withTimeout` in `scanTransactionHistory`); a chain that yields
        // nothing (genuinely empty OR timed out) keeps its persisted history
        // and is re-attempted on the NEXT refresh. The live per-chain commits
        // keep the activity feed current — no blocking 3s backoff + 2nd pass.
        await withTaskGroup(of: Void.self) { group in
            for snap in snapshot {
                let customContracts = customTokensByChain[snap.chain]?.map { $0.contract } ?? []
                let own = ownAddressesByChain[snap.chain] ?? [snap.address]
                group.addTask {
                    _ = await scanTransactionHistory(
                        address: snap,
                        client: rpcClient,
                        txRepo: txRepo,
                        chainStateRepo: chainStateRepo,
                        walletId: walletId,
                        fiatCurrencyCode: fiatCurrencyCode,
                        customContracts: customContracts,
                        ownAddresses: own
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
        let rows = fetchBalanceRowSnapshot(walletId: walletId)
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
                    fiatCurrencyCode: code,
                    save: false
                )
                repriced += 1
            } catch {
                Self.log.error("reprice upsert failed for \(row.symbol, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // One merge for the whole re-price pass (2026-06-14 batch fix).
        try? await txRepo.flush()
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

    /// Off-main (2026-06-14): creates its OWN `ModelContext` and returns
    /// a `Sendable` snapshot, so it runs on the coordinator's background
    /// executor without blocking the UI. No `@MainActor`.
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
        chainStateRepo: ChainStateRepository,
        walletId: UUID,
        fiatCurrencyCode: String,
        customContracts: [String] = [],
        ownAddresses: Set<String> = []
    ) async -> Int {
        let scanner = RealRPCTransactionScanner(client: client)
        let fetchToken = RefreshPerfLog.shared.start()
        let chainForScan = address.chain
        // Bound the per-chain history fetch — a slow chain is abandoned at the
        // deadline (keeps its persisted history) instead of holding the
        // refresh open. History runs AFTER balances and all chains scan
        // concurrently (see the `withTaskGroup` caller), so this bound is the
        // slowest single chain's ceiling, NOT a sum — it can be generous
        // without delaying the balance card. 8s (up from 2s, 2026-06-17): a
        // block-explorer history page for the slower chains (Dogecoin, BCH,
        // LTC) routinely needs >2s, and the tight bound was cancelling them
        // every refresh — so their activity never loaded and the console
        // filled with "… : cancelled". 8s lets one page (limit 25) land while
        // still abandoning a genuinely stuck chain.
        let events = await withTimeout(8.0) {
            await scanner.scan(
                addresses: [chainForScan: address.address],
                limit: 25,
                customContractsByChain: customContracts.isEmpty
                    ? [:]
                    : [chainForScan: customContracts],
                // Full per-chain own-address set so the scanner can relabel a
                // transfer to/from another of the wallet's own addresses as a
                // self-transfer (2026-06-16). Defaults to this one address when
                // the caller didn't supply the set.
                ownAddressesByChain: ownAddresses.isEmpty
                    ? [:]
                    : [chainForScan: ownAddresses]
            )
        } ?? []
        RefreshPerfLog.shared.end("history", "fetch \(address.chain.rawValue) — \(events.count) events", since: fetchToken)
        guard !events.isEmpty else { return 0 }
        for event in events {
            // **Self-transfer taxonomy (2026-06-16).** Pass an explicit
            // `.selfTransfer` kind for `.internal` events so the repository
            // upsert reclassifies BOTH a stored row's `directionRaw` AND
            // its `kindRaw` — correcting the stale pre-2026-06-12
            // `.outgoing`/`.transfer` leg of the user's BTC self-send on
            // the next scan. Non-internal events keep `nil` (direction-
            // derived) kind, unchanged from before.
            let explicitKind: TransactionKind? = event.direction == .internal ? .selfTransfer : nil
            do {
                try await txRepo.upsertTransaction(
                    addressId: address.id,
                    txHash: event.txHash,
                    direction: event.direction,
                    amountRaw: Self.decimalString(event.amount),
                    tokenSymbol: event.tokenSymbol,
                    tokenContract: event.tokenContract,
                    kind: explicitKind,
                    blockNumber: event.blockNumber,
                    occurredAt: event.occurredAt,
                    status: event.status,
                    counterparty: event.counterparty,
                    feeRaw: event.fee.map { Self.decimalString($0) },
                    save: false
                )
            } catch {
                Self.log.error("upsertTransaction failed for \(event.txHash, privacy: .public) on \(address.chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // **History persistence is coalesced (2026-06-18 perf fix).** This
        // per-address scan stages its legs with `save: false` (above) and no
        // longer flushes or rebuilds per chain. The old per-chain
        // `flush() + rebuild(onlyChains:)` fired ~2 SwiftData saves PER chain
        // (~48 per refresh tick across the ~24 chains), and every save
        // invalidated the wallet-home `@Query` graph and re-evaluated its
        // ~2,800-line body on the main thread — the dominant pull-to-refresh
        // /steady-state lag and heat. The staged legs are committed instead
        // by the balance committer's periodic flush (while the two passes
        // overlap) and, authoritatively, by `performRefresh`'s end-of-run
        // `txRepo.flush()` + all-chain `chainStateRepo.rebuild()`. History
        // therefore lands at refresh completion (within the same ~30s tick)
        // rather than streaming in chain-by-chain — the same data, far fewer
        // main-thread @Query invalidations. (`walletId` / `chainStateRepo` /
        // `fiatCurrencyCode` stay on the signature for the caller + the
        // staging path; the per-chain commit they fed is gone.)
        Self.log.info("Transaction history for \(address.chain.rawValue, privacy: .public)/\(address.address, privacy: .public): staged \(events.count, privacy: .public) events")
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
    /// `RemoteHistoricalPriceService` directly (Rule #27 §A.3 / §E) —
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

        let service = RemoteHistoricalPriceService()
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

    // MARK: - Per-chain aggregate population (2026-06-17)

    /// Fetch + persist the UTXO set for every Bitcoin-family address in the
    /// snapshot, in parallel (`UTXOService` reuses the shared `RPCClient`).
    /// Account-model chains have no UTXOs and are skipped. Best-effort: a
    /// per-chain fetch failure leaves that chain's last-persisted UTXOs
    /// untouched rather than blanking them.
    private func scanAndPersistUTXOs(
        walletId: UUID,
        snapshot: [AddressSnapshot],
        chainStateRepo: ChainStateRepository
    ) async {
        let utxoService = UTXOService(client: .shared)
        await withTaskGroup(of: Void.self) { group in
            for snap in snapshot where snap.chain.family == .bitcoin {
                if snap.address.hasPrefix(StubKeyImportService.stubAddressPrefix) { continue }
                group.addTask {
                    do {
                        let utxoToken = RefreshPerfLog.shared.start()
                        let utxos = try await utxoService.fetchUTXOs(address: snap.address, chain: snap.chain)
                        _ = try await chainStateRepo.replaceUTXOs(
                            walletId: walletId,
                            chain: snap.chain,
                            address: snap.address,
                            utxos: utxos
                        )
                        RefreshPerfLog.shared.end("utxo", "\(snap.chain.rawValue) — \(utxos.count) UTXOs", since: utxoToken)
                        Self.log.info("Persisted \(utxos.count, privacy: .public) UTXOs for \(snap.chain.rawValue, privacy: .public)")
                    } catch {
                        if Task.isCancelled { return }
                        Self.log.warning("UTXO fetch/persist failed for \(snap.chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    /// One-time per-chain private-key population: derive + AES-GCM seal each
    /// chain's key (only chains that don't already have a stored blob) and
    /// persist the ciphertext into the chain rows. Watch-only wallets (no
    /// key) are skipped. The derivation builds the `HDWallet` ONCE for all
    /// chains and runs on a detached background task (the BIP-39 PBKDF2
    /// stretch is CPU-bound) so it never blocks the balances / history.
    private func populateEncryptedKeys(
        walletId: UUID,
        chainAddresses: [SupportedChain: String],
        chainStateRepo: ChainStateRepository
    ) async {
        guard let descriptor = fetchWalletDescriptor(walletId: walletId),
              descriptor.kind != .watchOnly,
              !chainAddresses.isEmpty else { return }
        let candidates = Set(chainAddresses.keys)
        guard let missing = try? await chainStateRepo.chainsMissingKey(walletId: walletId, candidates: candidates),
              !missing.isEmpty else { return }
        let toDerive = chainAddresses.filter { missing.contains($0.key) }
        guard !toDerive.isEmpty else { return }

        let keyToken = RefreshPerfLog.shared.start()
        let blobs = await Task.detached(priority: .utility) {
            SigningKeyProvider.encryptedKeyBlobs(wallet: descriptor, chainAddresses: toDerive)
        }.value
        RefreshPerfLog.shared.end("key", "derive + seal \(blobs.count)/\(toDerive.count) chain keys (HDWallet/PBKDF2)", since: keyToken)
        guard !blobs.isEmpty else { return }
        do {
            try await chainStateRepo.storeEncryptedKeys(walletId: walletId, blobs: blobs)
            Self.log.info("Stored encrypted keys for \(blobs.count, privacy: .public) chain(s)")
        } catch {
            Self.log.warning("storeEncryptedKeys failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Off-main `WalletDescriptor` for the key-derivation path — reads the
    /// wallet's kind + passphrase flag from its own `ModelContext` and
    /// returns a `Sendable` value the detached derivation can capture.
    private func fetchWalletDescriptor(walletId: UUID) -> WalletDescriptor? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        descriptor.fetchLimit = 1
        guard let wallet = try? context.fetch(descriptor).first else { return nil }
        return WalletDescriptor(record: wallet)
    }

    // MARK: - Snapshot helpers

    private struct AddressSnapshot: Sendable {
        let id: UUID
        let address: String
        let chain: SupportedChain
        let isUsed: Bool
    }

    /// Off-main (2026-06-14): own `ModelContext`, `Sendable` output —
    /// runs on the coordinator's background executor, never the main
    /// thread, so a refresh never blocks scrolling/navigation.
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

// MARK: - Live commit channel

/// Thread-safe dirty-chain channel driving the balance stream's live
/// committer (2026-06-17). The stream consumer marks a chain dirty as its
/// rows land; the committer drains + commits on a fixed cadence. An actor
/// so the concurrent producer (per-row upsert tasks) and single consumer
/// (the committer loop) never race on the set.
private actor LiveCommitChannel {
    private var dirty: Set<SupportedChain> = []
    private var finished = false

    func mark(_ chain: SupportedChain) { dirty.insert(chain) }

    /// Return the currently-dirty chains and clear the set atomically.
    func drain() -> Set<SupportedChain> {
        defer { dirty.removeAll() }
        return dirty
    }

    func finish() { finished = true }
    var isFinished: Bool { finished }
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
enum WalletRefreshRegistry {
    private struct Entry {
        let token: UUID
        let startedAt: DispatchTime
        let task: Task<Set<SupportedChain>, Never>
    }

    private static var inFlight: [UUID: Entry] = [:]

    /// **Wedge threshold (2026-06-18 — "wait for the current run, don't run
    /// it twice").** A user pull replaces an in-flight run ONLY if that run
    /// has been going longer than this — i.e. only if it's genuinely stuck.
    /// Any in-flight refresh that's still within a normal completion window
    /// (a scene/on-appear/periodic scan, or another pull) is already
    /// fetching fresh balances + history, so a new request JOINS it and
    /// awaits its result instead of cancelling ~24 in-flight RPCs and
    /// re-running the whole scan (which is "running the same job twice" +
    /// the wasted-cancellation churn the user reported). Raised 6 → 90 s so
    /// even a slow-but-progressing fan-out (per-chain timeouts + bounded
    /// retries run in parallel, so a healthy run finishes well under this)
    /// is waited for, not duplicated; past 90 s the pipeline is treated as
    /// wedged and a pull may replace it. Backgrounding still cancels in-flight
    /// runs promptly via `cancelAll()` — this only governs foreground re-triggers.
    private static let wedgeThreshold: TimeInterval = 90

    /// Returns the already-running refresh task for `walletId` when
    /// one exists and is healthy; otherwise starts `operation` as a new
    /// task, registers it, and deregisters it on completion. With
    /// `cancelExisting`, an in-flight task is replaced ONLY if it looks
    /// wedged (older than `wedgeThreshold`); a younger one is joined.
    static func joinOrStart(
        walletId: UUID,
        cancelExisting: Bool = false,
        operation: @escaping @Sendable () async -> Set<SupportedChain>
    ) -> Task<Set<SupportedChain>, Never> {
        if let existing = inFlight[walletId] {
            let elapsed = Double(
                DispatchTime.now().uptimeNanoseconds &- existing.startedAt.uptimeNanoseconds
            ) / 1_000_000_000
            // Join unless the caller wants a replacement AND the in-flight run
            // looks wedged. This collapses a near-simultaneous background scan
            // + user pull into ONE pipeline instead of cancel-and-restart.
            if !cancelExisting || elapsed < wedgeThreshold {
                return existing.task
            }
            // Wedged pipeline — cancel it (propagates through the scan stream
            // and RPCClient as `RPCError.cancelled`) and stale-out its pending
            // state publication before the replacement runs.
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
        inFlight[walletId] = Entry(token: token, startedAt: DispatchTime.now(), task: task)
        return task
    }

    /// Cancel every in-flight refresh. Called from `UniAppApp` the moment
    /// the scene enters `.background` (2026-06-18 — the "hot in the
    /// background" fix). The auto-refresh LOOP already stops via its
    /// `scenePhase` gate, but each refresh runs inside an UNSTRUCTURED
    /// `Task` here, and `refreshWallet`'s `await task.value` does NOT
    /// propagate cancellation into it — so an in-flight ~24-chain scan
    /// would otherwise run to completion off-screen, draining the radio +
    /// CPU. Cancelling the task directly propagates through the structured
    /// fan-out + `RPCClient`/`URLSession` (every read honors
    /// `Task.isCancelled`), so the pipeline unwinds within roughly one RPC
    /// timeout instead of finishing the whole scan in the background.
    static func cancelAll() {
        for entry in inFlight.values {
            entry.task.cancel()
        }
        inFlight.removeAll()
        WalletRefreshState.shared.invalidate()
    }
}
