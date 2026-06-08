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
    func refreshWallet(walletId: UUID, fiatCode: String) async {
        let txRepo = TransactionRepository(modelContainer: container)
        let priceRepo = PriceCacheRepository(modelContainer: container)

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

        // Scan each address in parallel via the stub scanner. Real
        // implementations (T-037..T-040) will replace `StubBalanceScanner`
        // with per-family services dispatched from this same loop.
        let scanner = StubBalanceScanner()
        await withTaskGroup(of: Void.self) { group in
            for addr in snapshot {
                group.addTask {
                    await scan(
                        address: addr,
                        scanner: scanner,
                        txRepo: txRepo,
                        priceRepo: priceRepo,
                        fiatCurrency: currency
                    )
                }
            }
        }
    }

    // MARK: - Per-address scan

    private func scan(
        address: AddressSnapshot,
        scanner: any BalanceScanner,
        txRepo: TransactionRepository,
        priceRepo: PriceCacheRepository,
        fiatCurrency: SupportedCurrency
    ) async {
        // Phase 1-5 (T-053..T-056): every chain uses the real RPC
        // path. The stub `BalanceScanner.scan` is no longer reached;
        // the scanner param is left in the signature for backward
        // compat with any future test fixture that wants to inject
        // mock data.
        _ = scanner
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
        let rpcClient = RPCClient()

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

        // Transaction-history fetch runs regardless of whether the
        // balance scan succeeded — an address can have outgoing
        // transactions on a chain where the current balance lookup
        // happens to time out, and the user still deserves to see
        // those rows in their activity feed.
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
                rawBalance: String(describing: summary.nativeBalance),
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

        // Transaction history fetch (2026-06-08). Runs after the
        // balance upsert so the addressId is guaranteed present in
        // SwiftData. Uses the unified `RealRPCTransactionScanner`
        // which dispatches to the right family adapter per chain.
        // Each event is `upsertTransaction`'d to the repository —
        // idempotent on `(txHash, addressId)` so repeated refreshes
        // don't duplicate rows. The scanner swallows per-chain
        // adapter errors silently and returns the empty array, so a
        // failing chain doesn't take down the rest of the refresh.
        await scanTransactionHistory(
            address: address,
            client: rpcClient,
            txRepo: txRepo
        )
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
        txRepo: TransactionRepository
    ) async {
        let scanner = RealRPCTransactionScanner(client: client)
        let events = await scanner.scan(
            addresses: [address.chain: address.address],
            limit: 25
        )
        guard !events.isEmpty else { return }
        for event in events {
            do {
                try await txRepo.upsertTransaction(
                    addressId: address.id,
                    txHash: event.txHash,
                    direction: event.direction,
                    amountRaw: String(describing: event.amount),
                    tokenSymbol: event.tokenSymbol,
                    tokenContract: event.tokenContract,
                    blockNumber: event.blockNumber,
                    occurredAt: event.occurredAt,
                    status: event.status,
                    counterparty: event.counterparty,
                    feeRaw: event.fee.map { String(describing: $0) }
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
            guard let fxRate = await fxService.rate(toUSD: fiatCode) else {
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
