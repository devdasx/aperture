import Foundation
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

    /// Fiat-to-fiat exchange-rate service used for the USD-pivot
    /// pricing pipeline. Crypto prices are quoted in USD by
    /// Coinbase (reliable, near-universal coverage); long-tail
    /// fiats like JOD / EGP / NGN are then converted via this
    /// service. Shared across all per-address scan tasks so the
    /// 12-hour rates cache is hit once per session.
    let fxService: FXRateService

    init(container: ModelContainer, fxService: FXRateService = FXRateService()) {
        self.container = container
        self.fxService = fxService
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
    /// instead of starting a second pipeline. Public API unchanged.
    func refreshWallet(walletId: UUID, fiatCode: String) async {
        let task = await WalletRefreshRegistry.joinOrStart(walletId: walletId) {
            await self.performRefresh(walletId: walletId, fiatCode: fiatCode)
        }
        await task.value
    }

    /// The actual refresh pipeline. Only ever entered through the
    /// registry above, so at most one instance runs per wallet at a
    /// time.
    private func performRefresh(walletId: UUID, fiatCode: String) async {
        let txRepo = TransactionRepository(modelContainer: container)

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
        let snapshot = await MainActor.run { fetchAddressSnapshot(walletId: walletId) }

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
        for snap in snapshot {
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
            snapshot: snapshot,
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

        // Track which chains yielded a native row so we can mark
        // the rest scan-complete at the end (chains whose RPC
        // failed entirely still need their "Last synced" stamp
        // refreshed for honesty).
        var nativeYieldedChains: Set<SupportedChain> = []

        // **2026-06-09 — parallel upserts.** Previously each yielded
        // row blocked the stream consumer on a sequential `await
        // upsertNativeBalance/upsertTokenBalance(...)` call.
        // SwiftData's `@ModelActor` serializes writes internally
        // anyway, but the actor hop overhead per row added up
        // across dozens of rows per refresh. The `withTaskGroup`
        // shape lets each upsert run on the actor's queue WITHOUT
        // blocking the stream consumer — we keep pulling rows from
        // the network stream while writes happen in parallel.
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

        // Chains whose native row never landed — mark scan
        // complete with prior `isUsed` so the "Last synced" footer
        // updates and the UI doesn't lie about a stale read.
        for snap in snapshot where !nativeYieldedChains.contains(snap.chain) {
            try? await txRepo.markScanComplete(addressId: snap.id, isUsed: snap.isUsed)
        }

        await txHistoryTask
    }

    /// 2026-06-09 — Upsert a streamScan-yielded native chain
    /// balance for a specific address snapshot. Honest fiat: the
    /// stream's `ChainBalance.fiatBalance` is `Decimal?` — `nil`
    /// means the price was unavailable. We store `0` in that case
    /// (the schema's column is non-optional) and let the UI
    /// distinguish via the price-unavailable row check.
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
                fiatValueCached: chainBalance.fiatBalance ?? 0,
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
                fiatValueCached: tokenBalance.fiatBalance ?? 0,
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
    private func scanAllTransactionHistory(
        snapshot: [AddressSnapshot],
        customTokensByChain: [SupportedChain: [CustomTokenSnapshot]],
        txRepo: TransactionRepository
    ) async {
        // Shared client (2026-06-11) — limiter + breaker state must
        // accumulate across the fan-out, not reset per refresh.
        let rpcClient = RPCClient.shared
        await withTaskGroup(of: Void.self) { group in
            for snap in snapshot {
                let customContracts = customTokensByChain[snap.chain]?.map { $0.contract } ?? []
                group.addTask {
                    await scanTransactionHistory(
                        address: snap,
                        client: rpcClient,
                        txRepo: txRepo,
                        customContracts: customContracts
                    )
                }
            }
        }
    }

    // MARK: - Per-address scan

    private func scan(
        address: AddressSnapshot,
        txRepo: TransactionRepository,
        priceRepo: PriceCacheRepository,
        fiatCurrency: SupportedCurrency
    ) async {
        // Phase 1-5 (T-053..T-056): every chain uses the real RPC
        // path. The stub `BalanceScanner` injection point was removed
        // 2026-06-10 — the parameter was dead (`_ = scanner`) and had
        // no remaining callers anywhere in the codebase; a future test
        // fixture can reintroduce injection at the initializer level
        // where it belongs.
        await scanViaRealRPC(
            address: address,
            txRepo: txRepo,
            priceRepo: priceRepo,
            fiatCurrency: fiatCurrency
        )
    }

    // MARK: - Real RPC path (Phase 1 — Ethereum)

    /// Phase 1 real-RPC scan: dispatches the `EVMChainAdapter` against
    /// the address, fetches the live native balance + nonce, refreshes
    /// the price, upserts both into the database. Errors fall back to
    /// `markScanComplete(isUsed: prior)` so the "Last synced" footer
    /// stays honest about the attempt even when the read failed.
    ///
    /// This is the reference impl per `docs/RPC-ARCHITECTURE.md` §3.1.
    /// The other 11 EVM chains land in T-053 by adding their
    /// registry entries; the adapter is already chain-parameterized
    /// and works for all of them once the endpoints register.
    private func scanViaRealRPC(
        address: AddressSnapshot,
        txRepo: TransactionRepository,
        priceRepo: PriceCacheRepository,
        fiatCurrency: SupportedCurrency
    ) async {
        // **2026-06-11 — shared RPCClient.** Previously a fresh
        // `RPCClient()` per address scan: every instance started
        // with a full token-bucket burst against the same provider
        // (N × the documented per-endpoint quota) and zeroed
        // circuit-breaker state, so a dead endpoint was re-probed
        // (10 s timeout each) by every single scan. The shared
        // instance is what makes the rate limiter and circuit
        // breaker actually enforce their contracts.
        let rpcClient = RPCClient.shared

        // Dispatch to the family-appropriate adapter. Phase 1-5
        // coverage per `docs/RPC-ARCHITECTURE.md` §3: EVM, Bitcoin,
        // Solana, XRP, Stellar, NEAR, TON, TRON, Polkadot, Aptos,
        // Sui, Cosmos (Kava). One unified `ChainAccountSummary`
        // shape; the adapter does the chain-specific decoding.
        // Parallel: balance summary + price refresh dispatch
        // concurrently. The summary read goes to the chain's RPC;
        // the price read goes to Coinbase. Different hosts, different
        // rate-limit buckets — no contention, just wall-clock saved.
        async let summaryTask: ChainAccountSummary? = try? await fetchSummary(
            chain: address.chain,
            address: address.address,
            client: rpcClient
        )
        async let priceTask: Void = refreshPrice(
            symbol: address.chain.ticker,
            fiat: fiatCurrency.code,
            priceRepo: priceRepo
        )
        let maybeSummary = await summaryTask
        await priceTask

        // Transaction-history fetch runs exactly once per address,
        // and regardless of whether the balance scan succeeded — an
        // address can have outgoing transactions on a chain where the
        // current balance lookup happens to time out, and the user
        // still deserves to see those rows in their activity feed.
        // (2026-06-10: a second post-upsert call used to live at the
        // bottom of this function, doubling every network fetch and
        // upsert per address; `upsertTransaction` keys on the full leg
        // identity `(txHash, addressId, tokenContract, tokenSymbol,
        // directionRaw)` and the address row already exists
        // before this function runs, so one call here is sufficient.)
        await scanTransactionHistory(
            address: address,
            client: rpcClient,
            txRepo: txRepo
        )

        guard let summary = maybeSummary else {
            Self.log.error("Real RPC scan failed for \(address.address, privacy: .public)")
            try? await txRepo.markScanComplete(addressId: address.id, isUsed: address.isUsed)
            return
        }

        let fiatValue = await fiatValueFor(
            symbol: address.chain.ticker,
            amount: summary.nativeBalance,
            fiatCode: fiatCurrency.code,
            priceRepo: priceRepo
        )
        do {
            try await txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: address.chain.ticker,
                tokenContract: nil,
                decimals: 0,
                rawBalance: Self.decimalString(summary.nativeBalance),
                fiatValueCached: fiatValue,
                fiatCurrencyCode: fiatCurrency.code
            )
            try await txRepo.markScanComplete(
                addressId: address.id,
                isUsed: summary.isUsed
            )
            Self.log.info("Real RPC scan for \(address.chain.rawValue, privacy: .public)/\(address.address, privacy: .public): balance=\(String(describing: summary.nativeBalance), privacy: .public) isUsed=\(summary.isUsed, privacy: .public)")
        } catch {
            Self.log.error("upsertBalance failed for \(address.address, privacy: .public): \(String(describing: error), privacy: .public)")
            try? await txRepo.markScanComplete(addressId: address.id, isUsed: summary.isUsed)
        }
    }

    /// Drives the unified `RealRPCTransactionScanner` for one
    /// address and upserts every event into SwiftData via
    /// `TransactionRepository`. Same scanner powers the
    /// `WalletHomeView` test-mode feed; this path is the
    /// production sink that persists history for the user's real
    /// wallet.
    private func scanTransactionHistory(
        address: AddressSnapshot,
        client: RPCClient,
        txRepo: TransactionRepository,
        customContracts: [String] = []
    ) async {
        let scanner = RealRPCTransactionScanner(client: client)
        let events = await scanner.scan(
            addresses: [address.chain: address.address],
            limit: 25,
            customContractsByChain: customContracts.isEmpty
                ? [:]
                : [address.chain: customContracts]
        )
        guard !events.isEmpty else { return }
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
    }

    /// Dispatcher: pick the family adapter for the chain and call
    /// its `fetchAccountSummary(address)`. Every adapter returns
    /// the same `ChainAccountSummary` shape so the coordinator
    /// doesn't care about the per-chain JSON shape.
    private func fetchSummary(
        chain: SupportedChain,
        address: String,
        client: RPCClient
    ) async throws(RPCError) -> ChainAccountSummary {
        switch chain {
        // EVM (12 chains via one adapter)
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
            let adapter = EVMChainAdapter(chain: chain, client: client)
            let s = try await adapter.fetchAccountSummary(address: address)
            return ChainAccountSummary(nativeBalance: s.nativeBalance, isUsed: s.isUsed)
        // Bitcoin family (4)
        case .bitcoin, .bitcoinCash, .litecoin, .dogecoin:
            let adapter = BitcoinFamilyAdapter(chain: chain, client: client)
            let s = try await adapter.fetchAccountSummary(address: address)
            return ChainAccountSummary(nativeBalance: s.nativeBalance, isUsed: s.isUsed)
        // Solana
        case .solana:
            return try await SolanaChainAdapter(client: client).fetchAccountSummary(address: address)
        // XRP
        case .ripple:
            return try await XRPChainAdapter(client: client).fetchAccountSummary(address: address)
        // Stellar
        case .stellar:
            return try await StellarChainAdapter(client: client).fetchAccountSummary(address: address)
        // NEAR
        case .near:
            return try await NEARChainAdapter(client: client).fetchAccountSummary(address: address)
        // TON
        case .ton:
            return try await TONChainAdapter(client: client).fetchAccountSummary(address: address)
        // TRON
        case .tron:
            return try await TRONChainAdapter(client: client).fetchAccountSummary(address: address)
        // Polkadot (placeholder — SCALE codec pending)
        case .polkadot:
            return try await PolkadotChainAdapter(client: client).fetchAccountSummary(address: address)
        // Aptos
        case .aptos:
            return try await AptosChainAdapter(client: client).fetchAccountSummary(address: address)
        // Sui
        case .sui:
            return try await SuiChainAdapter(client: client).fetchAccountSummary(address: address)
        // Kava (Cosmos)
        case .kava:
            return try await CosmosKavaAdapter(client: client).fetchAccountSummary(address: address)
        }
    }

    /// Resolve `fiat = amount × price(symbol)` from the price cache.
    /// Returns `0` if the price isn't cached yet — the UI then shows
    /// "Price unavailable" rather than a wrong dollar figure.
    ///
    /// Uses the **USD-pivot** pipeline: read the cached USD price,
    /// multiply by the live FX rate (USD → target). Coinbase Spot
    /// reliably covers ticker→USD; the FX service (open.er-api.com)
    /// covers USD→long-tail-fiats Coinbase doesn't quote directly
    /// (JOD, EGP, NGN, KZT, etc.). The persistence layer always
    /// stores USD so a fiat change in Settings is free.
    private func fiatValueFor(
        symbol: String,
        amount: Decimal,
        fiatCode: String,
        priceRepo: PriceCacheRepository
    ) async -> Decimal {
        do {
            // Always read USD from cache — it's the canonical pricing
            // currency (see `refreshPrice` below for the matching
            // upsert path).
            guard let cachedUSD = try await priceRepo.price(symbol: symbol, fiat: "USD") else {
                return 0
            }
            if fiatCode.uppercased() == "USD" {
                return amount * cachedUSD.price
            }
            guard let fxRate = await fxService.rate(fromUSDTo: fiatCode) else {
                return 0  // honest: no FX rate available
            }
            return amount * cachedUSD.price * fxRate
        } catch {
            return 0
        }
    }

    private func refreshPrice(symbol: String, fiat: String, priceRepo: PriceCacheRepository) async {
        _ = fiat  // pricing is canonically in USD; per-currency
                  // conversion happens in `fiatValueFor` via the FX
                  // service. The parameter is kept for source compat.
        let coinbase = CoinbasePriceService()
        guard let live = await coinbase.price(symbol: symbol, fiat: "USD") else { return }
        do {
            try await priceRepo.upsert(
                symbol: symbol,
                fiat: "USD",
                price: live.amount,
                source: "coinbase"
            )
        } catch {
            Self.log.error("price upsert failed for \(symbol, privacy: .public)/USD: \(String(describing: error), privacy: .public)")
        }
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

// MARK: - In-flight refresh registry

/// Per-wallet refresh deduplication (2026-06-10). SwiftData upserts
/// are idempotent per row, but two pipelines racing each other still
/// double every network fetch and interleave `markScanComplete`
/// stamps against the same records. The registry keys exactly one
/// in-flight task per `walletId`; concurrent `refreshWallet` calls
/// join the existing task instead of starting a second pipeline.
/// `@MainActor` serializes all dictionary access — no lock needed.
@MainActor
private enum WalletRefreshRegistry {
    private static var inFlight: [UUID: Task<Void, Never>] = [:]

    /// Returns the already-running refresh task for `walletId` when
    /// one exists; otherwise starts `operation` as a new task,
    /// registers it, and deregisters it on completion.
    static func joinOrStart(
        walletId: UUID,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        if let existing = inFlight[walletId] {
            return existing
        }
        let task = Task {
            await operation()
            inFlight[walletId] = nil
        }
        inFlight[walletId] = task
        return task
    }
}
