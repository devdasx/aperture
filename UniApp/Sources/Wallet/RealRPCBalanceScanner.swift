import Foundation
import OSLog

/// Production `BalanceScanner` that reads real on-chain balances via
/// the `RPCClient` actor and the per-chain adapters
/// (`EVMChainAdapter`, `BitcoinFamilyAdapter`, `SolanaChainAdapter`,
/// long-tail adapters in `LongTailAdapters.swift`).
///
/// **Honesty contract (Rule #16 §A.5).**
/// - Real addresses (Solana, NEAR today) hit the real RPC and report
///   the on-chain balance — zero is a real zero, not a stub.
/// - Stub addresses (every other chain, prefix `[STUB]` or shape-fake)
///   are detected and short-circuited to zero / not-used so we never
///   pretend a placeholder has on-chain activity.
/// - Fiat conversion goes through `TokenPricingEngine` (Coinbase →
///   per-currency cache → CoinGecko ladder; no auth, no third-party
///   SDK) and is denominated in the **active currency** end-to-end —
///   `fiatValueCached` is always written in the currency the user
///   currently has selected. Symbols no ladder rung can price yield
///   no fiat — the UI must show "Price unavailable" rather than a
///   wrong number.
///
/// **Rule #3 compliance.** Pure native plumbing: `RPCClient` actor,
/// `URLSession`, `JSONSerialization`. No SPM dependency.
struct RealRPCBalanceScanner: BalanceScanner {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "scanner")

    let client: RPCClient
    let pricing: TokenPricingEngine

    init(
        client: RPCClient = RPCClient.shared,
        pricing: TokenPricingEngine = .shared
    ) {
        self.client = client
        self.pricing = pricing
    }

    func scan(
        addresses: [SupportedChain: String],
        currency: SupportedCurrency
    ) async throws -> [ChainBalance] {
        // EVM data fetching is disabled app-wide (2026-06-21 user direction):
        // drop every EVM address up front so no EVM balance/token RPC is ever
        // fired, no matter which caller invoked the scan.
        let addresses = addresses.filter { $0.key.family != .evm }
        // Phase 1 — fetch on-chain summaries in parallel. Bounded by
        // each endpoint's `RateLimiter`; the `TaskGroup` is honest
        // about concurrency without flooding any single provider
        // (each chain has its own bucket).
        let nativeBalances = await withTaskGroup(of: ScanRow?.self) { group in
            for (chain, address) in addresses {
                group.addTask { [client] in
                    await Self.fetchNative(
                        chain: chain,
                        address: address,
                        client: client
                    )
                }
            }
            var collected: [ScanRow] = []
            for await row in group {
                if let row { collected.append(row) }
            }
            return collected
        }

        // Phase 2 — resolve fiat per row via `TokenPricingEngine`'s
        // ladder (Coinbase USD×FX → per-currency cache → CoinGecko).
        // The engine prices directly in the active currency, so the
        // returned `ChainBalance.fiatBalance` is already denominated
        // in what the user has selected.
        let uniqueTickers = Array(Set(nativeBalances.map { Self.coinbaseSymbol(for: $0.chain.ticker) }))
        let prices = await pricing.unitPrices(symbols: uniqueTickers, currencyCode: currency.code)

        let now = Date()
        return nativeBalances.map { row in
            let symbol = Self.coinbaseSymbol(for: row.chain.ticker)
            let fiat: Decimal? = Self.computeFiat(
                native: row.nativeBalance,
                unitPrice: prices[symbol]?.amount
            )
            return ChainBalance(
                chain: row.chain,
                address: row.address,
                nativeBalance: row.nativeBalance,
                fiatBalance: fiat,
                fiatCurrencyCode: currency.code,
                isUsed: row.isUsed,
                lastUpdated: now
            )
        }
    }

    /// Streaming scan emits two row types — native chain balances
    /// AND fungible token balances (ERC-20 / SPL today; TRC-20 / TON
    /// jettons / Cosmos IBC follow when their adapters ship).
    /// Consumers pattern-match on the case to render row-by-row.
    enum StreamRow: Sendable {
        case native(ChainBalance)
        case token(TokenBalance)
    }

    /// Streaming scan: kicks off one task per chain, yielding the
    /// native row plus any token rows as soon as each lands.
    /// Independent per chain — a slow / failing chain doesn't block
    /// the others.
    ///
    /// `customTokens` is an optional per-chain map of user-added
    /// `CustomTokenRecord` snapshots. The scanner runs the same
    /// balance-fetch path on these as it does for static registry
    /// entries, so user-added tokens surface alongside the curated
    /// set without a separate code path. Empty / missing entries
    /// are skipped — chains without custom tokens behave exactly
    /// as before.
    /// `priorityTokenSymbols` (2026-06-13 price-scope) — the token
    /// symbols the wallet already HOLDS, read from the DB by the caller.
    /// When non-empty the shared price batch is scoped to just these
    /// (plus native + custom), instead of the full registry universe —
    /// faster fiat + lighter provider load. Empty (a fresh wallet's
    /// first scan) prices the full universe. See `uniquePriceSymbols`.
    func streamScan(
        addresses: [SupportedChain: String],
        currency: SupportedCurrency,
        customTokens: [SupportedChain: [CustomTokenSnapshot]] = [:],
        priorityTokenSymbols: Set<String> = []
    ) -> AsyncStream<StreamRow> {
        // EVM data fetching is disabled app-wide (2026-06-21 user direction):
        // drop EVM addresses (and any EVM custom tokens) so the stream never
        // scans an EVM chain — every caller skips EVM through this one point.
        let addresses = addresses.filter { $0.key.family != .evm }
        let customTokens = customTokens.filter { $0.key.family != .evm }
        return AsyncStream(StreamRow.self) { continuation in
            // **One deduplicated price batch per refresh** (2026-06-12)
            // — every token on every chain reads from this single
            // shared result instead of firing its own price call
            // (USDC alone used to be requested ~14× per refresh).
            // The scan's symbol universe is fully known up front
            // (chain tickers + per-chain registries + custom tokens).
            // **Rows are NOT hostage to the batch**: each row yields
            // with `fiatBalance: nil` the moment its balance lands,
            // then re-yields with fiat once this task resolves — a
            // slow or down provider delays prices, never balances.
            //
            // The batch resolves through `TokenPricingEngine`'s
            // ladder (Coinbase USD×FX → per-currency cache →
            // CoinGecko) in the **active currency**, so every fiat
            // this stream yields is denominated in what the user has
            // currently selected (the 2026-06-13 currency-change
            // contract).
            let pricesTask = Task { [pricing] in
                let symbols = Self.uniquePriceSymbols(
                    addresses: addresses,
                    customTokens: customTokens,
                    priorityTokenSymbols: priorityTokenSymbols
                )
                let result = await pricing.unitPrices(
                    symbols: symbols,
                    currencyCode: currency.code
                )
                return result
            }
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for (chain, address) in addresses {
                        // Native balance task (one per chain).
                        group.addTask { [client] in
                            // Bound the per-chain native read so one slow chain
                            // can't stall the whole stream (and the spinner).
                            let summary = await withTimeout(2.0) {
                                await Self.fetchNative(chain: chain, address: address, client: client)
                            } ?? nil
                            // Scan failure → no row; the refresh
                            // coordinator preserves the persisted
                            // balance via its markScanComplete path.
                            guard let summary else { return }

                            // **2026-06-12 — balance first, fiat
                            // second.** The shared price batch covers
                            // ~49 symbols and can take minutes on a
                            // degraded network; awaiting it BEFORE
                            // the first yield held every row hostage
                            // (a fresh wallet rendered nothing until
                            // Coinbase answered). Yield the on-chain
                            // balance the moment it lands with
                            // `fiatBalance: nil`, then re-yield with
                            // fiat once the batch + FX rate resolve.
                            // Every consumer upserts idempotently by
                            // chain identity, so the refined row
                            // replaces the pending one.
                            func nativeRow(fiat: Decimal?) -> StreamRow {
                                .native(ChainBalance(
                                    chain: chain,
                                    address: summary.address,
                                    nativeBalance: summary.nativeBalance,
                                    fiatBalance: fiat,
                                    fiatCurrencyCode: currency.code,
                                    isUsed: summary.isUsed,
                                    lastUpdated: Date()
                                ))
                            }
                            continuation.yield(nativeRow(fiat: nil))

                            let coinbaseSymbol = Self.coinbaseSymbol(for: chain.ticker)
                            let unitPrice = await pricesTask.value[coinbaseSymbol]?.amount

                            guard let fiat = Self.computeFiat(
                                native: summary.nativeBalance,
                                unitPrice: unitPrice
                            ) else { return }
                            continuation.yield(nativeRow(fiat: fiat))
                        }

                        // Token scan task (one per chain). Skip stub
                        // addresses entirely — no point hitting RPC for
                        // a placeholder.
                        if address.hasPrefix(StubKeyImportService.stubAddressPrefix) {
                            continue
                        }
                        let customForChain = customTokens[chain] ?? []
                        group.addTask { [client] in
                            // Bound the per-chain token sweep too — rows yielded
                            // before the deadline are kept; a slow chain is
                            // abandoned instead of holding the stream open.
                            _ = await withTimeout(2.0) {
                                await Self.streamTokens(
                                    chain: chain,
                                    address: address,
                                    client: client,
                                    pricesTask: pricesTask,
                                    currency: currency,
                                    customTokens: customForChain,
                                    yield: { row in continuation.yield(row) }
                                )
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                pricesTask.cancel()
            }
        }
    }

    /// Per-chain token discovery + pricing. Each token yields its
    /// row independently — `USDC` on Ethereum doesn't wait on `DAI`.
    ///
    /// `customTokens` is the user's per-chain `CustomTokenSnapshot`
    /// set (see Custom Tokens feature). After the static-registry
    /// pass for the chain completes, the same balance-fetch path
    /// runs against each custom token's contract / mint — the user's
    /// adds surface alongside the curated set without a separate
    /// code path.
    private static func streamTokens(
        chain: SupportedChain,
        address: String,
        client: RPCClient,
        pricesTask: Task<[String: TokenPricingEngine.ResolvedPrice], Never>,
        currency: SupportedCurrency,
        customTokens: [CustomTokenSnapshot],
        yield: @Sendable @escaping (StreamRow) -> Void
    ) async {
        // Run static-registry tokens first, then custom tokens. Both
        // passes use the same family-specific balance fetcher.
        await streamRegistryTokens(
            chain: chain,
            address: address,
            client: client,
            pricesTask: pricesTask,
            currency: currency,
            yield: yield
        )
        await streamCustomTokens(
            chain: chain,
            address: address,
            client: client,
            pricesTask: pricesTask,
            currency: currency,
            customTokens: customTokens,
            yield: yield
        )
    }

    /// Static-registry token pass — now routed through the chain's
    /// `ChainConnector` (the fleet design). The connector owns the
    /// chain's curated registry + its own balance-fetch shape (EVM
    /// Multicall3, Solana both-program SPL query, TRON/NEAR/Aptos/XRPL
    /// reads, …), ported verbatim from the adapters. It returns the
    /// positive-balance `[TokenBalance]` rows directly (`fiatBalance:
    /// nil`); the scanner converts each to a `DiscoveredToken` and runs
    /// the SAME two-phase deferred-fiat yield as before, so pricing +
    /// the idempotent upsert downstream are unchanged. `customContracts:
    /// []` here — the registry pass; the custom pass runs separately
    /// (`streamCustomTokens`) so it can re-stamp the user's chosen
    /// symbol/name. Chains without a token layer (Bitcoin family,
    /// Stellar, Sui, TON, Polkadot) return `[]` from their connector,
    /// yielding nothing — the old `default: return` behavior, now owned
    /// by each connector.
    private static func streamRegistryTokens(
        chain: SupportedChain,
        address: String,
        client: RPCClient,
        pricesTask: Task<[String: TokenPricingEngine.ResolvedPrice], Never>,
        currency: SupportedCurrency,
        yield: @Sendable @escaping (StreamRow) -> Void
    ) async {
        let connector = ChainConnectorRegistry.connector(for: chain)
        let rows = await connector.fetchTokenBalances(address: address, customContracts: [])
        guard !rows.isEmpty else { return }
        let discovered = rows.map { row in
            DiscoveredToken(
                contract: row.contract,
                symbol: row.symbol,
                name: row.name,
                decimals: row.decimals,
                amount: row.amount
            )
        }
        await yieldTokensWithDeferredFiat(
            discovered,
            chain: chain,
            address: address,
            pricesTask: pricesTask,
            currency: currency,
            yield: yield
        )
    }


    // MARK: - Custom tokens

    /// User-added token pass — now routed through the chain's
    /// `ChainConnector` (the fleet design). The connector's
    /// `fetchTokenBalances(address:customContracts:)` reads the custom
    /// contracts/mints alongside its registry set in the chain's own
    /// balance-fetch shape (EVM Multicall3, Solana both-program SPL
    /// query, …). The scanner keeps the custom pass distinct from the
    /// registry pass so it can RE-STAMP each returned row with the user's
    /// chosen `symbol` / `name` / `decimals` from the
    /// `CustomTokenSnapshot` — the connector returns generic metadata for
    /// contracts it doesn't recognize, but the user's labels are the
    /// source of truth on the wallet home.
    ///
    /// Per Rule #2 §A.7 honesty: zero balances are NOT yielded (the
    /// connector already drops zero rows). The custom token still shows
    /// in the Custom Tokens management screen, but isn't surfaced on the
    /// wallet home until it carries a positive balance — same rule the
    /// registry pass uses. Chains whose connector has no token layer
    /// return `[]`, yielding nothing (the old `default: return`).
    private static func streamCustomTokens(
        chain: SupportedChain,
        address: String,
        client: RPCClient,
        pricesTask: Task<[String: TokenPricingEngine.ResolvedPrice], Never>,
        currency: SupportedCurrency,
        customTokens: [CustomTokenSnapshot],
        yield: @Sendable @escaping (StreamRow) -> Void
    ) async {
        guard !customTokens.isEmpty else { return }

        // Lookup from the user's custom contracts/mints → their snapshot,
        // keyed case-insensitively (EVM checksum casing). The connector
        // returns rows for its registry too; we keep ONLY the custom ones
        // and re-stamp them with the user's chosen labels.
        let snapByContract: [String: CustomTokenSnapshot] = Dictionary(
            customTokens.map { ($0.contract.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let customContracts = customTokens.map { $0.contract }
        let rows = await ChainConnectorRegistry
            .connector(for: chain)
            .fetchTokenBalances(address: address, customContracts: customContracts)

        let discovered: [DiscoveredToken] = rows.compactMap { row in
            guard let snap = snapByContract[row.contract.lowercased()] else { return nil }
            // Re-stamp the user's chosen symbol/name/decimals AND re-scale
            // the amount to the snapshot's decimals. A connector decodes a
            // contract it doesn't recognize with a family-default decimals
            // (EVM custom contracts use 18); the user's snapshot is the
            // authoritative decimals. Re-scaling by the decimals ratio
            // recovers the canonical amount the old per-family path
            // computed (`raw / 10^snap.decimals`): for EVM,
            // `row.amount × 10^18 / 10^snap.decimals`; for Solana, where
            // the connector already returns the authoritative on-chain
            // decimals, `row.decimals == snap.decimals` so the ratio is 1
            // and the amount is unchanged.
            let amount = row.decimals == snap.decimals
                ? row.amount
                : row.amount * Self.pow10(row.decimals) / Self.pow10(snap.decimals)
            return DiscoveredToken(
                contract: snap.contract,
                symbol: snap.symbol,
                name: snap.name,
                decimals: snap.decimals,
                amount: amount
            )
        }
        guard !discovered.isEmpty else { return }
        await Self.yieldTokensWithDeferredFiat(
            discovered,
            chain: chain,
            address: address,
            pricesTask: pricesTask,
            currency: currency,
            yield: yield
        )
    }

    // MARK: - Retry policy (2026-06-12)

    /// Retries after the initial attempt — 3 attempts total per
    /// failed fetch. Bounded so a hard-down chain doesn't pin the
    /// stream open indefinitely.
    private static let scanRetryLimit = 2

    /// Sleep before retry `attempt` (1-based): ~2 s before the
    /// first retry, ~5 s before the second. A `.rateLimited`
    /// failure honors the provider's `retryAfter` when it's longer
    /// (floored at 5 s, capped at 30 s so one throttled provider
    /// can't hold the scan open for minutes). Returns `false` when
    /// the sleep was cancelled — the caller stops retrying.
    private static func backoffBeforeRetry(
        attempt: Int,
        lastError: RPCError?
    ) async -> Bool {
        var delay: TimeInterval = attempt <= 1 ? 2 : 5
        if case .rateLimited(let retryAfter) = lastError {
            delay = min(max(delay, retryAfter.timeIntervalSinceNow, 5), 30)
        }
        do {
            try await Task.sleep(for: .seconds(delay))
            return true
        } catch {
            return false // cancelled mid-backoff — stop retrying
        }
    }

    /// Bounded retry for a typed-throws RPC fetch (native summaries,
    /// EVM Multicall3 batches). `.cancelled` propagates immediately
    /// and is never retried; every other `RPCError` gets up to
    /// `scanRetryLimit` more attempts with `backoffBeforeRetry`'s
    /// ladder. Each per-chain task calls this inside its OWN task,
    /// so one chain's retries never block another chain's rows.
    private static func withRetry<T>(
        _ operation: () async throws(RPCError) -> T
    ) async throws(RPCError) -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                if case .cancelled = error { throw error }
                attempt += 1
                guard attempt <= scanRetryLimit,
                      await backoffBeforeRetry(attempt: attempt, lastError: error) else {
                    throw error
                }
            }
        }
    }

    /// Bounded retry for the optional-returning per-chain / per-token
    /// fetch helpers (TRON, NEAR, Aptos, XRPL, Kava, Solana token
    /// accounts). Those paths swallow their error kind via `try?`,
    /// so the fixed 2 s / 5 s ladder applies. A cancelled task stops
    /// retrying immediately — `Task.sleep` throws on cancellation.
    private static func withNilRetry<T>(
        _ operation: () async -> T?
    ) async -> T? {
        var attempt = 0
        while true {
            if let value = await operation() { return value }
            attempt += 1
            guard attempt <= scanRetryLimit,
                  await backoffBeforeRetry(attempt: attempt, lastError: nil) else {
                return nil
            }
        }
    }

    // MARK: - Deferred-fiat token yield (2026-06-12)

    /// One discovered positive-balance token row, pre-fiat.
    private struct DiscoveredToken: Sendable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
        let amount: Decimal
    }

    /// Two-phase token yield — the price-batch decoupling. Phase 1
    /// emits every discovered row immediately with `fiatBalance: nil`
    /// so balances render even when the price providers are slow or
    /// down. Phase 2 awaits the shared active-currency price batch
    /// (`TokenPricingEngine` ladder) and re-yields the rows that
    /// priced. Consumers upsert idempotently by
    /// `(chain, contract)` identity — the coordinator's compound
    /// unique key, the review screens' replace-by-contract — so the
    /// refined row simply replaces the pending one.
    private static func yieldTokensWithDeferredFiat(
        _ discovered: [DiscoveredToken],
        chain: SupportedChain,
        address: String,
        pricesTask: Task<[String: TokenPricingEngine.ResolvedPrice], Never>,
        currency: SupportedCurrency,
        yield: @Sendable (StreamRow) -> Void
    ) async {
        guard !discovered.isEmpty else { return }
        func tokenRow(_ d: DiscoveredToken, fiat: Decimal?) -> StreamRow {
            .token(TokenBalance(
                chain: chain,
                address: address,
                contract: d.contract,
                symbol: d.symbol,
                name: d.name,
                decimals: d.decimals,
                amount: d.amount,
                fiatBalance: fiat,
                fiatCurrencyCode: currency.code,
                lastUpdated: Date()
            ))
        }
        for d in discovered {
            yield(tokenRow(d, fiat: nil))
        }
        let prices = await pricesTask.value
        for d in discovered {
            guard let fiat = computeFiat(
                native: d.amount,
                unitPrice: prices[d.symbol.uppercased()]?.amount
            ) else { continue }
            yield(tokenRow(d, fiat: fiat))
        }
    }

    // MARK: - Solana SPL token accounts (both token programs)

    /// Legacy SPL Token program + Token-2022. `getTokenAccountsByOwner`
    /// hard-filters on ONE `programId`, so a single query can never
    /// see accounts owned by the other program — Token-2022 mints
    /// (PYUSD, AUSD, DUSD, USDG in `SolanaTokenRegistry`, plus any
    /// user-added `.splToken2022` custom mint) were invisible to the
    /// scan until 2026-06-12. Two queries, merged; a token account is
    /// owned by exactly one program, so the union has no duplicates.
    private static let solanaTokenProgramIds: [String] = [
        "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",   // SPL Token (legacy) — 43 chars, decodes to 32 bytes
        "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",   // Token-2022 — 43 chars, decodes to 32 bytes (mainnet-verified 2026-06-12)
    ]

    /// Token accounts across BOTH SPL programs. Returns `nil` only
    /// when every program query failed (scan failure — the caller
    /// emits no rows, preserving persisted balances); a partial
    /// result is returned honestly when one program answered.
    /// Each program's query retries independently (2026-06-12) —
    /// the failed part is retried, the answered part isn't refetched.
    private static func fetchAllSolanaTokenAccounts(
        address: String,
        client: RPCClient
    ) async -> [SolanaChainAdapter.SPLTokenAccount]? {
        var merged: [SolanaChainAdapter.SPLTokenAccount] = []
        var anyProgramAnswered = false
        for programId in solanaTokenProgramIds {
            guard let accounts = await withNilRetry({
                await fetchSolanaTokenAccounts(
                    address: address,
                    programId: programId,
                    client: client
                )
            }) else { continue }
            anyProgramAnswered = true
            merged.append(contentsOf: accounts)
        }
        return anyProgramAnswered ? merged : nil
    }

    /// One `getTokenAccountsByOwner` query against a single token
    /// program. Decode mirrors `SolanaChainAdapter.fetchTokenAccounts`
    /// (jsonParsed encoding; zero-balance rent-exempt accounts
    /// dropped). Lives in the scanner so the scan's query path owns
    /// its per-program fan-out.
    private static func fetchSolanaTokenAccounts(
        address: String,
        programId: String,
        client: RPCClient
    ) async -> [SolanaChainAdapter.SPLTokenAccount]? {
        let filter: [String: Sendable] = ["programId": programId]
        let opts: [String: Sendable] = ["encoding": "jsonParsed"]
        guard let data = try? await client.callJSONResultData(
            chain: .solana,
            method: "getTokenAccountsByOwner",
            params: [address, filter, opts]
        ),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = dict["value"] as? [[String: Any]] else {
            return nil
        }
        return value.compactMap { item in
            guard let account = item["account"] as? [String: Any],
                  let acctData = account["data"] as? [String: Any],
                  let parsed = acctData["parsed"] as? [String: Any],
                  let info = parsed["info"] as? [String: Any],
                  let mint = info["mint"] as? String,
                  let tokenAmount = info["tokenAmount"] as? [String: Any],
                  let amountStr = tokenAmount["amount"] as? String,
                  let raw = Decimal(string: amountStr) else {
                return nil
            }
            let decimals = (tokenAmount["decimals"] as? NSNumber)?.intValue ?? 0
            let amount = decimals == 0 ? raw : raw / Self.pow10(decimals)
            // Filter out zero-balance accounts — Solana keeps
            // closed-but-rent-exempt token accounts hanging around.
            guard amount > 0 else { return nil }
            return SolanaChainAdapter.SPLTokenAccount(mint: mint, amount: amount, decimals: decimals)
        }
    }

    // MARK: - TRON TRC-20

    private static func fetchTronTokenBalance(
        holder: String,
        contract: String,
        client: RPCClient
    ) async -> Decimal? {
        // TronGrid's `triggerconstantcontract` returns
        // `{"constant_result": ["<32-byte hex>"]}` for read-only
        // calls. Build the calldata for `balanceOf(address)` —
        // selector `0x70a08231` + 32-byte left-padded TRON address.
        // TRON's base58 addresses decode to 21 bytes (1 prefix +
        // 20 EVM-style); we strip the prefix byte and use the
        // remaining 20 for the call. The call shape:
        //   POST /wallet/triggerconstantcontract
        //   {"owner_address": "<base58 or hex>",
        //    "contract_address": "<base58 or hex>",
        //    "function_selector": "balanceOf(address)",
        //    "parameter": "<32-byte hex of holder address>",
        //    "visible": true}
        //
        // **2026-06-12 — routed through `RPCClient`.** Previously a
        // raw `URLSession.shared` POST against a hardcoded TronGrid
        // URL: no rate limiter (6 concurrent unthrottled requests per
        // refresh against TronGrid's free tier), no fallback to
        // tronstack, no circuit breaker, and the 60 s default timeout
        // could stall the whole stream. `callRESTPost` inherits the
        // 10 s timeout, the per-endpoint token bucket, and the
        // trongrid → tronstack rotation registered in `RPCRegistry`.
        let holderHex = Self.tronAddressToEVMHex(holder)
        guard !holderHex.isEmpty else { return nil }
        let paddedHolder = String(repeating: "0", count: 24) + holderHex
        let body: [String: Sendable] = [
            "owner_address":     holder,
            "contract_address":  contract,
            "function_selector": "balanceOf(address)",
            "parameter":         paddedHolder,
            "visible":           true,
        ]
        guard let data = try? await client.callRESTPost(
            chain: .tron,
            path: "wallet/triggerconstantcontract",
            body: body
        ),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["constant_result"] as? [String],
              let hex = results.first else {
            return nil
        }
        return Self.decimalFromHex(hex)
    }

    /// Parse a hex string (with or without `0x` prefix) into a
    /// `Decimal`. Local copy so RealRPCBalanceScanner doesn't
    /// depend on EVMChainAdapter's fileprivate extension.
    private static func decimalFromHex(_ hexString: String) -> Decimal? {
        var hex = hexString
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") {
            hex.removeFirst(2)
        }
        if hex.isEmpty { return .zero }
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for char in hex {
            guard let digit = char.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        return result
    }

    /// TRON addresses are 34-char base58check. The decoded payload
    /// is `<prefix-0x41><20-byte-EVM-style-address><4-byte-checksum>`.
    /// We return the 20-byte hex (no prefix) for use in `balanceOf`
    /// calldata. If decode fails returns empty.
    private static func tronAddressToEVMHex(_ address: String) -> String {
        guard let bytes = Base58.decodeBytes(address), bytes.count >= 25 else {
            return ""
        }
        // bytes[0] = 0x41 (prefix), bytes[1..21] = address body
        let body = bytes[1..<21]
        return body.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - NEAR NEP-141

    private static func fetchNearTokenBalance(
        holder: String,
        tokenAccount: String,
        client: RPCClient
    ) async -> Decimal? {
        // NEAR's `query` method with `request_type=call_function`
        // calls a contract's view method. Args are base64-encoded
        // JSON. We call `ft_balance_of({"account_id": holder})`.
        //
        // **2026-06-12 — routed through `RPCClient`.** Previously a
        // raw `URLSession.shared` POST against a hardcoded
        // rpc.mainnet.near.org URL (60 s default timeout, no fallback,
        // no rate limit). NEAR's `query` requires named-object params
        // — the `callJSONResultData(paramsObject:)` variant exists for
        // exactly this shape and inherits the 10 s timeout plus the
        // near-mainnet → near-lava rotation registered in
        // `RPCRegistry`. The client strips the JSON-RPC envelope, so
        // the returned data IS the inner result object.
        let argsJSON = "{\"account_id\":\"\(holder)\"}"
        let argsBase64 = Data(argsJSON.utf8).base64EncodedString()
        let params: [String: Sendable] = [
            "request_type": "call_function",
            "finality":     "final",
            "account_id":   tokenAccount,
            "method_name":  "ft_balance_of",
            "args_base64":  argsBase64,
        ]
        guard let data = try? await client.callJSONResultData(
            chain: .near,
            method: "query",
            paramsObject: params
        ),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultBytes = result["result"] as? [Int] else {
            return nil
        }
        // NEAR returns the raw view-call return as a byte array.
        // ft_balance_of returns a JSON string of the balance. Decode
        // bytes → UTF-8 → strip outer quotes → Decimal.
        let bytes = resultBytes.compactMap { UInt8(exactly: $0) }
        guard let raw = String(data: Data(bytes), encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return Decimal(string: trimmed)
    }

    // MARK: - Aptos primary fungible store

    private static func fetchAptosTokenBalance(
        holder: String,
        metadata: String,
        client: RPCClient
    ) async -> Decimal? {
        // `0x1::primary_fungible_store::balance<0x1::object::Object<0x1::fungible_asset::Metadata>>(address, Object<Metadata>)`.
        // Aptos's view API accepts `arguments: [holder, metadata]`
        // and resolves the generic from `type_arguments`.
        do {
            let body: [String: Sendable] = [
                "function": "0x1::primary_fungible_store::balance",
                "type_arguments": ["0x1::fungible_asset::Metadata"],
                "arguments": [holder, metadata],
            ]
            let data = try await client.callRESTPost(
                chain: .aptos, path: "view", body: body
            )
            guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
                  let valueStr = arr.first as? String,
                  let raw = Decimal(string: valueStr) else {
                return nil
            }
            return raw
        } catch {
            return nil
        }
    }

    // MARK: - XRP Ledger IOU lines

    private static func xrplKey(currency: String, issuer: String) -> String {
        "\(currency.uppercased()).\(issuer)"
    }

    private static func fetchXRPLTokenLines(
        holder: String,
        client: RPCClient
    ) async -> [String: Decimal]? {
        // `account_lines` returns the holder's IOU trust lines. Each
        // line has currency, account (issuer), balance (decimal
        // string). Index by (currency, issuer).
        //
        // **2026-06-12 — routed through `RPCClient`.** Previously a
        // raw `URLSession.shared` POST against a hardcoded
        // s1.ripple.com URL (60 s default timeout, no fallback, no
        // rate limit). Goes through the s1 → s2 → xrplcluster rotation
        // registered in `RPCRegistry` with the 10 s timeout. rippled
        // never echoes the JSON-RPC `id`, so id-echo validation is
        // off (`validatesIDEcho: false` — see the RPCClient docs).
        // The client strips the envelope; the returned data IS the
        // `result` object containing `lines`.
        guard let data = try? await client.callJSONResultData(
            chain: .ripple,
            method: "account_lines",
            params: [["account": holder, "ledger_index": "validated"]],
            validatesIDEcho: false
        ),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = result["lines"] as? [[String: Any]] else {
            return nil
        }
        var out: [String: Decimal] = [:]
        for line in lines {
            guard let currency = line["currency"] as? String,
                  let account = line["account"] as? String,
                  let balanceStr = line["balance"] as? String,
                  let balance = Decimal(string: balanceStr) else { continue }
            out[xrplKey(currency: currency, issuer: account)] = balance
        }
        return out
    }

    /// 10^n as a `Decimal` — used for token decimal scaling
    /// (e.g. raw USDC base units / 10^6 = canonical USDC amount).
    private static func pow10(_ n: Int) -> Decimal {
        var r = Decimal(1)
        for _ in 0..<n { r *= 10 }
        return r
    }

    /// Compute the fiat-balance result honestly. Returns `nil` when
    /// no ladder rung could price the asset in the active currency
    /// (`TokenPricingEngine` omitted the symbol). Returns a real
    /// `Decimal` (including `0` for an actual zero balance × known
    /// price) otherwise. The unit price is already denominated in
    /// the active currency — no FX math here.
    private static func computeFiat(
        native: Decimal,
        unitPrice: Decimal?
    ) -> Decimal? {
        guard let unitPrice else { return nil }
        return native * unitPrice
    }

    /// Some tickers in `SupportedChain.ticker` don't match the symbol
    /// Coinbase Spot publishes — Polygon's 2024 rebrand from MATIC to
    /// POL is the canonical case. The pricing pipeline asks Coinbase
    /// for the alias it actually quotes, so the user sees a real fiat
    /// value instead of "Price unavailable".
    private static func coinbaseSymbol(for ticker: String) -> String {
        switch ticker.uppercased() {
        case "POL": return "POL"  // Coinbase added POL pairs alongside MATIC
        default:    return ticker.uppercased()
        }
    }

    /// Every symbol one `streamScan` could possibly need to price —
    /// the scanned chains' native tickers, their registry tokens,
    /// and the user's custom tokens. Known fully up front, so the
    /// whole scan shares ONE `TokenPricingEngine.unitPrices` batch
    /// instead of firing a duplicated request per row (2026-06-12 —
    /// see the comment at the `pricesTask` creation site in
    /// `streamScan`). Mirrors the per-family dispatch in
    /// `streamRegistryTokens`; families that aren't token-scanned yet
    /// (TON jettons, Polkadot Asset Hub) contribute only their native
    /// ticker.
    /// **2026-06-13 — price-scope optimization (user direction "make
    /// syncing maximum faster").** The price batch always covers the
    /// scanned chains' native tickers + the user's custom tokens. For
    /// the registry TOKEN universe it splits on `priorityTokenSymbols`
    /// (the symbols the wallet already HOLDS, read from the DB by the
    /// coordinator):
    ///
    /// - **`priorityTokenSymbols` non-empty (steady state):** price ONLY
    ///   those held tokens — not the full ~49-symbol registry universe.
    ///   Fewer Coinbase calls per cycle → fiat lands faster AND less
    ///   provider pressure (fewer "Price unavailable" under the 10 s
    ///   poll). A token received since the last scan shows its balance
    ///   immediately and its fiat next cycle (once it's persisted into
    ///   the held set), never "Price unavailable" for a HELD token.
    /// - **`priorityTokenSymbols` empty (a fresh wallet's first scan, or
    ///   a wallet that holds nothing):** price the full registry universe
    ///   so any token discovered on the very first scan prices the same
    ///   cycle — no regression for a fresh import.
    static func uniquePriceSymbols(
        addresses: [SupportedChain: String],
        customTokens: [SupportedChain: [CustomTokenSnapshot]],
        priorityTokenSymbols: Set<String> = []
    ) -> [String] {
        var symbols: Set<String> = []
        // Native tickers — always shown (the coin rows).
        for chain in addresses.keys {
            symbols.insert(coinbaseSymbol(for: chain.ticker))
        }
        // The user's custom tokens — always priced.
        for snaps in customTokens.values {
            for snap in snaps {
                symbols.insert(snap.symbol.uppercased())
            }
        }

        if priorityTokenSymbols.isEmpty {
            // Fresh / empty wallet — full registry universe so the first
            // scan prices everything it discovers.
            for chain in addresses.keys {
                switch chain.family {
                case .evm:
                    for entry in EVMTokenRegistry.tokens(for: chain) {
                        symbols.insert(entry.symbol.uppercased())
                    }
                case .ed25519 where chain == .solana:
                    for entry in SolanaTokenRegistry.mints.values {
                        symbols.insert(entry.symbol.uppercased())
                    }
                case .tron:
                    for entry in TronTokenRegistry.tokens {
                        symbols.insert(entry.symbol.uppercased())
                    }
                case .near:
                    for entry in NearTokenRegistry.tokens {
                        symbols.insert(entry.symbol.uppercased())
                    }
                case .aptos:
                    for entry in AptosTokenRegistry.tokens {
                        symbols.insert(entry.symbol.uppercased())
                    }
                case .ripple:
                    for entry in XRPLTokenRegistry.tokens {
                        symbols.insert(entry.symbol.uppercased())
                    }
                default:
                    break
                }
            }
        } else {
            // Steady state — price only the held tokens (the DB knows
            // them). The scoped batch is the speed + reliability win.
            symbols.formUnion(priorityTokenSymbols.map { $0.uppercased() })
        }
        return Array(symbols)
    }

    // MARK: - Per-row fetch

    /// One row's worth of on-chain data. The route mirrors
    /// `WalletRefreshCoordinator.fetchSummary` — same family adapters,
    /// same Sendable boundary via `ChainAccountSummary`.
    private struct ScanRow: Sendable {
        let chain: SupportedChain
        let address: String
        let nativeBalance: Decimal
        let isUsed: Bool
    }

    private static func fetchNative(
        chain: SupportedChain,
        address: String,
        client: RPCClient
    ) async -> ScanRow? {
        // Honesty short-circuit: stub addresses don't go on-chain.
        // The `[STUB]` prefix is the marker the import flow puts on
        // any address it couldn't derive for real. We could also let
        // the RPC return zero, but that wastes a real network call
        // (and a rate-limit token) for no information.
        if address.hasPrefix(StubKeyImportService.stubAddressPrefix) || address.isEmpty {
            return ScanRow(
                chain: chain,
                address: address,
                nativeBalance: 0,
                isUsed: false
            )
        }

        do {
            // **2026-06-12 — bounded retry.** A transient per-chain
            // failure (flaky public RPC, brief throttle) gets up to
            // 2 more attempts (2 s / 5 s backoff, rate-limit aware)
            // before the chain gives up for this refresh. Runs
            // inside the chain's own task, so retries never block
            // other chains' rows. `.cancelled` stops immediately.
            let summary = try await withRetry { () async throws(RPCError) -> ChainAccountSummary in
                try await dispatch(chain: chain, address: address, client: client)
            }
            return ScanRow(
                chain: chain,
                address: address,
                nativeBalance: summary.nativeBalance,
                isUsed: summary.isUsed
            )
        } catch {
            // Cancellation (user navigated away mid-refresh) is not
            // a scan failure — stay silent, emit no row, no error log.
            if case .cancelled = error { return nil }
            log.error(
                "scan failed for \(chain.rawValue, privacy: .public)/\(String(address.prefix(8)), privacy: .public)…: \(String(describing: error), privacy: .public)"
            )
            // **2026-06-12 — honest failure means NO row, never a
            // fabricated zero.** Neither `ScanRow` nor `ChainBalance`
            // carries an error flag, so a zero row here was
            // indistinguishable from a real on-chain zero — the
            // refresh coordinator upserted it over the user's
            // persisted REAL balance, wiping it to 0 whenever a
            // chain's RPCs were down / throttled / offline. Returning
            // nil instead: `streamScan` yields nothing for the chain,
            // the coordinator's `nativeYieldedChains` cleanup calls
            // `markScanComplete` (preserving the stored balance and
            // honestly refreshing the "Last synced" stamp), and the
            // bulk `scan()` review path drops the row rather than
            // render a fake "0".
            return nil
        }
    }

    /// Native-balance read, now routed through the per-chain
    /// `ChainConnector` (the fleet design). Each chain's connector owns
    /// its own `fetchNativeBalance` — same endpoints / parsing / decimals
    /// the family adapters used, ported verbatim into the connector — and
    /// dispatches through the shared `RPCClient` actor. The registry's
    /// exhaustive switch replaces the per-family switch that used to live
    /// here; the scanner stays decoupled from the wallet/DB layer (the
    /// review screen runs before any wallet exists in SwiftData).
    private static func dispatch(
        chain: SupportedChain,
        address: String,
        client: RPCClient
    ) async throws(RPCError) -> ChainAccountSummary {
        let connector = ChainConnectorRegistry.connector(for: chain)
        return try await connector.fetchNativeBalance(address: address)
    }
}
