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
/// - Fiat conversion uses `CoinbasePriceService` (no auth, no
///   third-party SDK). Symbols Coinbase doesn't cover return zero
///   fiat — the UI must show "Price unavailable" rather than a wrong
///   number.
///
/// **Rule #3 compliance.** Pure native plumbing: `RPCClient` actor,
/// `URLSession`, `JSONSerialization`. No SPM dependency.
struct RealRPCBalanceScanner: BalanceScanner {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "scanner")

    let client: RPCClient
    let priceService: CoinbasePriceService
    let fxService: FXRateService

    init(
        client: RPCClient = RPCClient.shared,
        priceService: CoinbasePriceService = CoinbasePriceService(),
        fxService: FXRateService = FXRateService()
    ) {
        self.client = client
        self.priceService = priceService
        self.fxService = fxService
    }

    func scan(
        addresses: [SupportedChain: String],
        currency: SupportedCurrency
    ) async throws -> [ChainBalance] {
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

        // Phase 2 — resolve fiat per row via the **USD-pivot**
        // pricing pipeline. Coinbase Spot reliably covers ticker→USD
        // for nearly every crypto we ship; long-tail fiats like JOD,
        // EGP, NGN are then resolved via the ECB+open-er FX service.
        // Both halves run concurrently — the user's wall-clock cost
        // is roughly the slower of (Coinbase USD round-trip,
        // FX rates round-trip).
        let uniqueTickers = Array(Set(nativeBalances.map { Self.coinbaseSymbol(for: $0.chain.ticker) }))
        async let usdPricesTask = priceService.prices(symbols: uniqueTickers, fiat: "USD")
        async let fxRateTask = fxService.rate(fromUSDTo: currency.code)
        let usdPrices = await usdPricesTask
        let fxRate = await fxRateTask ?? 0

        let now = Date()
        return nativeBalances.map { row in
            let symbol = Self.coinbaseSymbol(for: row.chain.ticker).uppercased()
            let usdPrice = usdPrices[symbol]?.amount
            let fiat: Decimal? = Self.computeFiat(
                native: row.nativeBalance,
                usdPrice: usdPrice,
                fxRate: fxRate,
                isUSDTarget: currency.code.uppercased() == "USD"
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
    func streamScan(
        addresses: [SupportedChain: String],
        currency: SupportedCurrency,
        customTokens: [SupportedChain: [CustomTokenSnapshot]] = [:]
    ) -> AsyncStream<StreamRow> {
        AsyncStream(StreamRow.self) { continuation in
            let task = Task {
                let fxRateTask = Task { [fxService] in
                    await fxService.rate(fromUSDTo: currency.code) ?? 0
                }

                // **2026-06-12 — one deduplicated price fetch per
                // refresh.** Previously every token on every chain
                // fired its own `priceService.price(...)` call, all
                // concurrently — USDC alone was requested ~14× per
                // refresh (once per EVM chain + Solana + Tron), and
                // the actor's 60 s TTL cache can't help while all
                // callers race the SAME cold miss (actor reentrancy:
                // each checks the cache before the first response
                // lands). The scan's symbol universe is fully known
                // up front (chain tickers + per-chain registries +
                // custom tokens), so we fetch each unique symbol
                // exactly once via the bounded `prices(symbols:fiat:)`
                // batch API (max 8 in flight) and let every row task
                // read from the shared result.
                let usdPricesTask = Task { [priceService] in
                    await priceService.prices(
                        symbols: Self.uniquePriceSymbols(
                            addresses: addresses,
                            customTokens: customTokens
                        ),
                        fiat: "USD"
                    )
                }

                await withTaskGroup(of: Void.self) { group in
                    for (chain, address) in addresses {
                        // Native balance task (one per chain).
                        group.addTask { [client] in
                            let summary = await Self.fetchNative(
                                chain: chain,
                                address: address,
                                client: client
                            )
                            // Scan failure → no row; the refresh
                            // coordinator preserves the persisted
                            // balance via its markScanComplete path.
                            guard let summary else { return }

                            let coinbaseSymbol = Self.coinbaseSymbol(for: chain.ticker)
                            let usdPrice = await usdPricesTask.value[coinbaseSymbol]?.amount
                            let fxRate = await fxRateTask.value

                            let fiat = Self.computeFiat(
                                native: summary.nativeBalance,
                                usdPrice: usdPrice,
                                fxRate: fxRate,
                                isUSDTarget: currency.code.uppercased() == "USD"
                            )
                            continuation.yield(.native(ChainBalance(
                                chain: chain,
                                address: summary.address,
                                nativeBalance: summary.nativeBalance,
                                fiatBalance: fiat,
                                fiatCurrencyCode: currency.code,
                                isUsed: summary.isUsed,
                                lastUpdated: Date()
                            )))
                        }

                        // Token scan task (one per chain). Skip stub
                        // addresses entirely — no point hitting RPC for
                        // a placeholder.
                        if address.hasPrefix(StubKeyImportService.stubAddressPrefix) {
                            continue
                        }
                        let customForChain = customTokens[chain] ?? []
                        group.addTask { [client] in
                            await Self.streamTokens(
                                chain: chain,
                                address: address,
                                client: client,
                                usdPricesTask: usdPricesTask,
                                fxRateTask: fxRateTask,
                                currency: currency,
                                customTokens: customForChain,
                                yield: { row in continuation.yield(row) }
                            )
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
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
        usdPricesTask: Task<[String: TokenPrice], Never>,
        fxRateTask: Task<Decimal, Never>,
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
            usdPricesTask: usdPricesTask,
            fxRateTask: fxRateTask,
            currency: currency,
            yield: yield
        )
        await streamCustomTokens(
            chain: chain,
            address: address,
            client: client,
            usdPricesTask: usdPricesTask,
            fxRateTask: fxRateTask,
            currency: currency,
            customTokens: customTokens,
            yield: yield
        )
    }

    /// Static-registry token pass. The original `streamTokens` body —
    /// extracted unchanged so the custom-token pass can run in the
    /// same shape.
    private static func streamRegistryTokens(
        chain: SupportedChain,
        address: String,
        client: RPCClient,
        usdPricesTask: Task<[String: TokenPrice], Never>,
        fxRateTask: Task<Decimal, Never>,
        currency: SupportedCurrency,
        yield: @Sendable @escaping (StreamRow) -> Void
    ) async {
        switch chain.family {
        case .evm:
            let registry = EVMTokenRegistry.tokens(for: chain)
            guard !registry.isEmpty else { return }
            let adapter = EVMChainAdapter(chain: chain, client: client)

            // **2026-06-09 — Multicall3 batched balance fetch.**
            // Previously each token fired its own `eth_call`
            // (N parallel requests rate-limited by the endpoint).
            // Now one `eth_call` reads ALL token balances at once
            // via the `aggregate3(...)` call on the universal
            // Multicall3 contract (deployed at the same address on
            // every major EVM chain). Result: 1 round trip instead
            // of N — typically a 20–25× reduction in RPC requests
            // per chain for the token-scan phase.
            //
            // **2026-06-12 — honest failure.** The batched fetch now
            // THROWS on transport-level failure (offline, throttled,
            // every endpoint down) instead of returning all-zeros.
            // A thrown error skips the chain entirely — emitting
            // rows would fabricate "0" balances that overwrite the
            // user's persisted real values. Per-token `nil` entries
            // (individually-failed tokens) stay treated as 0-and-
            // skipped, which never yields a row either.
            let contracts = registry.map { $0.contract }
            var rawBalances: [Decimal?]
            do {
                rawBalances = try await adapter.fetchTokenBalancesBatched(
                    holder: address,
                    contracts: contracts
                )
            } catch {
                if case .cancelled = error { return }
                log.error(
                    "token scan failed for \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            // Defensive (2026-06-10): a malformed / truncated
            // Multicall3 response can decode to FEWER entries than
            // `contracts.count`. Indexing `rawBalances[i]` past the
            // short array crashed the scan task; pad with `nil`
            // (unknown balance → treated as 0 and skipped) so every
            // registry index is addressable.
            if rawBalances.count < contracts.count {
                rawBalances.append(
                    contentsOf: [Decimal?](repeating: nil, count: contracts.count - rawBalances.count)
                )
            }
            let usdPrices = await usdPricesTask.value
            let fxRate = await fxRateTask.value
            let isUSDTarget = currency.code.uppercased() == "USD"

            for (i, entry) in registry.enumerated() {
                let raw = rawBalances[i] ?? 0
                let amount = raw / Self.pow10(entry.decimals)
                // Honest: only emit if balance > 0 — see prior comment.
                guard amount > 0 else { continue }
                let fiat = Self.computeFiat(
                    native: amount,
                    usdPrice: usdPrices[entry.symbol.uppercased()]?.amount,
                    fxRate: fxRate,
                    isUSDTarget: isUSDTarget
                )
                yield(.token(TokenBalance(
                    chain: chain,
                    address: address,
                    contract: entry.contract,
                    symbol: entry.symbol,
                    name: entry.name,
                    decimals: entry.decimals,
                    amount: amount,
                    fiatBalance: fiat,
                    fiatCurrencyCode: currency.code,
                    lastUpdated: Date()
                )))
            }
        case .ed25519 where chain == .solana:
            // **2026-06-12 — query BOTH SPL token programs.** The
            // previous single `getTokenAccountsByOwner` call was
            // hard-filtered to the legacy SPL Token program, so
            // accounts owned by Token-2022 were never returned —
            // the registry's `.splToken2022` mints (PYUSD, AUSD,
            // DUSD, USDG) silently scanned as absent. See
            // `fetchAllSolanaTokenAccounts`.
            guard let accounts = await fetchAllSolanaTokenAccounts(
                address: address,
                client: client
            ) else {
                return
            }
            // Symmetry with EVM: only emit tokens that are in the
            // curated `SolanaTokenRegistry`. `getTokenAccountsByOwner`
            // returns EVERY mint the address has ever interacted with
            // (dust airdrops, expired LP positions, scam tokens, …)
            // — surfacing all of them would flood the UI with rows
            // the user didn't choose to hold (Rule #2 §A.7 honesty
            // about which tokens we actually support).
            let supportedAccounts = accounts.filter {
                SolanaTokenRegistry.mints[$0.mint] != nil
            }
            let usdPrices = await usdPricesTask.value
            let fxRate = await fxRateTask.value
            for account in supportedAccounts {
                let symbol = SolanaTokenRegistry.symbol(for: account.mint)
                let name = SolanaTokenRegistry.name(for: account.mint)
                let fiat = Self.computeFiat(
                    native: account.amount,
                    usdPrice: usdPrices[symbol.uppercased()]?.amount,
                    fxRate: fxRate,
                    isUSDTarget: currency.code.uppercased() == "USD"
                )
                yield(.token(TokenBalance(
                    chain: chain,
                    address: address,
                    contract: account.mint,
                    symbol: symbol,
                    name: name,
                    decimals: account.decimals,
                    amount: account.amount,
                    fiatBalance: fiat,
                    fiatCurrencyCode: currency.code,
                    lastUpdated: Date()
                )))
            }
        // TRON — TRC-20 balances via TronGrid REST.
        // `POST /wallet/triggerconstantcontract` with the `balanceOf`
        // selector. Same calldata shape as EVM but the call body is
        // TRON-flavored.
        case .tron:
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in TronTokenRegistry.tokens {
                    tokenGroup.addTask {
                        let raw = await Self.fetchTronTokenBalance(
                            holder: address,
                            contract: entry.contract,
                            client: client
                        ) ?? 0
                        let amount = raw / Self.pow10(entry.decimals)
                        guard amount > 0 else { return }
                        let usdPrice = await usdPricesTask.value[entry.symbol.uppercased()]?.amount
                        let fxRate = await fxRateTask.value
                        let fiat = Self.computeFiat(
                            native: amount,
                            usdPrice: usdPrice,
                            fxRate: fxRate,
                            isUSDTarget: currency.code.uppercased() == "USD"
                        )
                        yield(.token(TokenBalance(
                            chain: chain, address: address,
                            contract: entry.contract, symbol: entry.symbol,
                            name: entry.name, decimals: entry.decimals,
                            amount: amount, fiatBalance: fiat,
                            fiatCurrencyCode: currency.code,
                            lastUpdated: Date()
                        )))
                    }
                }
            }

        // NEAR — NEP-141 `ft_balance_of` via `query` JSON-RPC with
        // `request_type=call_function`. Args are base64-encoded JSON.
        case .near:
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in NearTokenRegistry.tokens {
                    tokenGroup.addTask {
                        let raw = await Self.fetchNearTokenBalance(
                            holder: address,
                            tokenAccount: entry.tokenAccount,
                            client: client
                        ) ?? 0
                        let amount = raw / Self.pow10(entry.decimals)
                        guard amount > 0 else { return }
                        let usdPrice = await usdPricesTask.value[entry.symbol.uppercased()]?.amount
                        let fxRate = await fxRateTask.value
                        let fiat = Self.computeFiat(
                            native: amount, usdPrice: usdPrice,
                            fxRate: fxRate,
                            isUSDTarget: currency.code.uppercased() == "USD"
                        )
                        yield(.token(TokenBalance(
                            chain: chain, address: address,
                            contract: entry.tokenAccount, symbol: entry.symbol,
                            name: entry.name, decimals: entry.decimals,
                            amount: amount, fiatBalance: fiat,
                            fiatCurrencyCode: currency.code,
                            lastUpdated: Date()
                        )))
                    }
                }
            }

        // Aptos — view function `0x1::primary_fungible_store::balance`.
        case .aptos:
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in AptosTokenRegistry.tokens {
                    tokenGroup.addTask {
                        let raw = await Self.fetchAptosTokenBalance(
                            holder: address,
                            metadata: entry.contract,
                            client: client
                        ) ?? 0
                        let amount = raw / Self.pow10(entry.decimals)
                        guard amount > 0 else { return }
                        let usdPrice = await usdPricesTask.value[entry.symbol.uppercased()]?.amount
                        let fxRate = await fxRateTask.value
                        let fiat = Self.computeFiat(
                            native: amount, usdPrice: usdPrice,
                            fxRate: fxRate,
                            isUSDTarget: currency.code.uppercased() == "USD"
                        )
                        yield(.token(TokenBalance(
                            chain: chain, address: address,
                            contract: entry.contract, symbol: entry.symbol,
                            name: entry.name, decimals: entry.decimals,
                            amount: amount, fiatBalance: fiat,
                            fiatCurrencyCode: currency.code,
                            lastUpdated: Date()
                        )))
                    }
                }
            }

        // XRPL — `account_lines` JSON-RPC returns all IOU lines.
        case .ripple:
            guard let lines = await Self.fetchXRPLTokenLines(holder: address, client: client) else { return }
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in XRPLTokenRegistry.tokens {
                    tokenGroup.addTask {
                        let amount = lines[Self.xrplKey(currency: entry.currency, issuer: entry.issuer)] ?? 0
                        guard amount > 0 else { return }
                        let usdPrice = await usdPricesTask.value[entry.symbol.uppercased()]?.amount
                        let fxRate = await fxRateTask.value
                        let fiat = Self.computeFiat(
                            native: amount, usdPrice: usdPrice,
                            fxRate: fxRate,
                            isUSDTarget: currency.code.uppercased() == "USD"
                        )
                        yield(.token(TokenBalance(
                            chain: chain, address: address,
                            contract: "\(entry.currency).\(entry.issuer)",
                            symbol: entry.symbol, name: entry.name,
                            decimals: entry.decimals, amount: amount,
                            fiatBalance: fiat, fiatCurrencyCode: currency.code,
                            lastUpdated: Date()
                        )))
                    }
                }
            }

        // Kava (Cosmos) — bank balance filtered by IBC denom.
        case .cosmos where chain == .kava:
            guard let balances = await Self.fetchKavaCosmosBalances(holder: address, client: client) else { return }
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in KavaCosmosTokenRegistry.tokens {
                    tokenGroup.addTask {
                        let raw = balances[entry.denom] ?? 0
                        guard raw > 0 else { return }
                        let amount = raw / Self.pow10(entry.decimals)
                        let usdPrice = await usdPricesTask.value[entry.symbol.uppercased()]?.amount
                        let fxRate = await fxRateTask.value
                        let fiat = Self.computeFiat(
                            native: amount, usdPrice: usdPrice,
                            fxRate: fxRate,
                            isUSDTarget: currency.code.uppercased() == "USD"
                        )
                        yield(.token(TokenBalance(
                            chain: chain, address: address,
                            contract: entry.denom, symbol: entry.symbol,
                            name: entry.name, decimals: entry.decimals,
                            amount: amount, fiatBalance: fiat,
                            fiatCurrencyCode: currency.code,
                            lastUpdated: Date()
                        )))
                    }
                }
            }

        // TON jettons + Polkadot Asset Hub — registries ship in
        // this turn so the Receive screen surfaces the tokens, but
        // balance scanning requires per-chain RPC adapters that are
        // significant plumbing (jetton wallet derivation for TON,
        // Asset Hub endpoint registration for Polkadot). Surface
        // honestly in SHIPPED.md per Rule #21.
        default:
            return
        }
    }

    // MARK: - Custom tokens

    /// User-added token pass. Runs the same balance-fetch path as the
    /// static registry — EVM via `EVMChainAdapter.fetchTokenBalance`,
    /// Solana via `getTokenAccountsByOwner` filtered to the user's
    /// mints. Only EVM and Solana custom tokens are supported today
    /// (matches the `AddCustomTokenSheet` chain picker); other
    /// families return early.
    ///
    /// Per Rule #2 §A.7 honesty: zero balances are NOT yielded — the
    /// custom token still shows in the Custom Tokens management
    /// screen, but isn't surfaced on the wallet home until it carries
    /// a positive balance. Same rule registry tokens use.
    private static func streamCustomTokens(
        chain: SupportedChain,
        address: String,
        client: RPCClient,
        usdPricesTask: Task<[String: TokenPrice], Never>,
        fxRateTask: Task<Decimal, Never>,
        currency: SupportedCurrency,
        customTokens: [CustomTokenSnapshot],
        yield: @Sendable @escaping (StreamRow) -> Void
    ) async {
        guard !customTokens.isEmpty else { return }

        switch chain.family {
        case .evm:
            // **2026-06-12 — Multicall3 batched custom-token fetch.**
            // Previously each custom token fired its own `eth_call`
            // sequentially through `withTaskGroup`, which gave the
            // rate limiter no opportunity to batch. The static
            // registry path has been on `fetchTokenBalancesBatched`
            // since 2026-06-09 (one round trip for all tokens) —
            // user-added custom tokens deserved the same path, and
            // the only reason they didn't have it was history. Same
            // honest-failure contract as the registry: a thrown
            // batched-fetch error skips emit (preserves persisted
            // balances) rather than fabricating zeros.
            let adapter = EVMChainAdapter(chain: chain, client: client)
            let contracts = customTokens.map { $0.contract }
            var rawBalances: [Decimal?]
            do {
                rawBalances = try await adapter.fetchTokenBalancesBatched(
                    holder: address,
                    contracts: contracts
                )
            } catch {
                if case .cancelled = error { return }
                log.error(
                    "custom-token scan failed for \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            // Defensive — same shape as the registry path: a
            // malformed Multicall3 response can decode short; pad
            // with nil so per-index reads stay in-bounds.
            if rawBalances.count < contracts.count {
                rawBalances.append(
                    contentsOf: [Decimal?](repeating: nil, count: contracts.count - rawBalances.count)
                )
            }
            let usdPrices = await usdPricesTask.value
            let fxRate = await fxRateTask.value
            let isUSDTarget = currency.code.uppercased() == "USD"
            for (i, snap) in customTokens.enumerated() {
                let raw = rawBalances[i] ?? 0
                let amount = raw / Self.pow10(snap.decimals)
                guard amount > 0 else { continue }
                let fiat = Self.computeFiat(
                    native: amount,
                    usdPrice: usdPrices[snap.symbol.uppercased()]?.amount,
                    fxRate: fxRate,
                    isUSDTarget: isUSDTarget
                )
                yield(.token(TokenBalance(
                    chain: chain,
                    address: address,
                    contract: snap.contract,
                    symbol: snap.symbol,
                    name: snap.name,
                    decimals: snap.decimals,
                    amount: amount,
                    fiatBalance: fiat,
                    fiatCurrencyCode: currency.code,
                    lastUpdated: Date()
                )))
            }

        case .ed25519 where chain == .solana:
            // The `getTokenAccountsByOwner` queries already return
            // every mint the address holds; the custom-token pass
            // filters the accounts by the user's added mints rather
            // than the static registry. **2026-06-12:** uses the same
            // both-programs fetch as the registry pass — a user-added
            // Token-2022 mint (AddCustomTokenSheet supports
            // `.splToken2022`) is owned by the Token-2022 program and
            // was invisible to the legacy-only query.
            guard let accounts = await fetchAllSolanaTokenAccounts(
                address: address,
                client: client
            ) else {
                return
            }
            // Build a lookup from custom-token mints → snapshot so we
            // can preserve the user's chosen symbol+name+iconURL.
            let mintLookup: [String: CustomTokenSnapshot] = Dictionary(
                uniqueKeysWithValues: customTokens.map { ($0.contract, $0) }
            )
            let matchedAccounts = accounts.filter { mintLookup[$0.mint] != nil }
            let usdPrices = await usdPricesTask.value
            let fxRate = await fxRateTask.value
            for account in matchedAccounts {
                guard let snap = mintLookup[account.mint] else { continue }
                let fiat = Self.computeFiat(
                    native: account.amount,
                    usdPrice: usdPrices[snap.symbol.uppercased()]?.amount,
                    fxRate: fxRate,
                    isUSDTarget: currency.code.uppercased() == "USD"
                )
                yield(.token(TokenBalance(
                    chain: chain,
                    address: address,
                    contract: snap.contract,
                    symbol: snap.symbol,
                    name: snap.name,
                    decimals: snap.decimals,
                    amount: account.amount,
                    fiatBalance: fiat,
                    fiatCurrencyCode: currency.code,
                    lastUpdated: Date()
                )))
            }

        default:
            // Custom tokens are EVM + Solana only for this turn —
            // mirrors the AddCustomTokenSheet's chain picker.
            return
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
    private static func fetchAllSolanaTokenAccounts(
        address: String,
        client: RPCClient
    ) async -> [SolanaChainAdapter.SPLTokenAccount]? {
        var merged: [SolanaChainAdapter.SPLTokenAccount] = []
        var anyProgramAnswered = false
        for programId in solanaTokenProgramIds {
            guard let accounts = await fetchSolanaTokenAccounts(
                address: address,
                programId: programId,
                client: client
            ) else { continue }
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

    // MARK: - Kava (Cosmos) bank balances

    private static func fetchKavaCosmosBalances(
        holder: String,
        client: RPCClient
    ) async -> [String: Decimal]? {
        // `GET /cosmos/bank/v1beta1/balances/{address}` returns
        // every denom the holder has. Index by denom.
        do {
            let data = try await client.callREST(
                chain: .kava,
                path: "cosmos/bank/v1beta1/balances/\(holder)"
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["balances"] as? [[String: Any]] else {
                return nil
            }
            var out: [String: Decimal] = [:]
            for entry in arr {
                guard let denom = entry["denom"] as? String,
                      let amountStr = entry["amount"] as? String,
                      let amount = Decimal(string: amountStr) else { continue }
                out[denom] = amount
            }
            return out
        } catch {
            return nil
        }
    }

    /// 10^n as a `Decimal` — used for token decimal scaling
    /// (e.g. raw USDC base units / 10^6 = canonical USDC amount).
    private static func pow10(_ n: Int) -> Decimal {
        var r = Decimal(1)
        for _ in 0..<n { r *= 10 }
        return r
    }

    /// Compute the fiat-balance result honestly. Returns `nil` when
    /// we truly cannot price the asset (no USD price or no FX rate
    /// to the user's currency). Returns a real `Decimal` (including
    /// `0` for an actual zero balance × known price) otherwise.
    private static func computeFiat(
        native: Decimal,
        usdPrice: Decimal?,
        fxRate: Decimal,
        isUSDTarget: Bool
    ) -> Decimal? {
        guard let usdPrice else { return nil }
        if isUSDTarget {
            return native * usdPrice
        }
        guard fxRate > 0 else { return nil }
        return native * usdPrice * fxRate
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

    /// Every Coinbase symbol one `streamScan` could possibly need to
    /// price — the scanned chains' native tickers, their registry
    /// tokens, and the user's custom tokens. Known fully up front, so
    /// the whole scan shares ONE bounded `prices(symbols:fiat:)`
    /// batch instead of firing a duplicated request per row
    /// (2026-06-12 — see the comment at the `usdPricesTask` creation
    /// site in `streamScan`). Mirrors the per-family dispatch in
    /// `streamRegistryTokens`; families that aren't token-scanned yet
    /// (TON jettons, Polkadot Asset Hub) contribute only their native
    /// ticker.
    private static func uniquePriceSymbols(
        addresses: [SupportedChain: String],
        customTokens: [SupportedChain: [CustomTokenSnapshot]]
    ) -> [String] {
        var symbols: Set<String> = []
        for chain in addresses.keys {
            symbols.insert(coinbaseSymbol(for: chain.ticker))
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
            case .cosmos where chain == .kava:
                for entry in KavaCosmosTokenRegistry.tokens {
                    symbols.insert(entry.symbol.uppercased())
                }
            default:
                break
            }
        }
        for snaps in customTokens.values {
            for snap in snaps {
                symbols.insert(snap.symbol.uppercased())
            }
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
            let summary = try await dispatch(chain: chain, address: address, client: client)
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

    /// Same per-chain switch as `WalletRefreshCoordinator.fetchSummary`.
    /// Kept inline here (instead of factored into a shared helper) so
    /// the scanner has zero dependency on the wallet/database layer —
    /// the review screen runs before any wallet exists in SwiftData.
    private static func dispatch(
        chain: SupportedChain,
        address: String,
        client: RPCClient
    ) async throws(RPCError) -> ChainAccountSummary {
        switch chain {
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
            let adapter = EVMChainAdapter(chain: chain, client: client)
            let s = try await adapter.fetchAccountSummary(address: address)
            return ChainAccountSummary(nativeBalance: s.nativeBalance, isUsed: s.isUsed)
        case .bitcoin, .bitcoinCash, .litecoin, .dogecoin:
            let adapter = BitcoinFamilyAdapter(chain: chain, client: client)
            let s = try await adapter.fetchAccountSummary(address: address)
            return ChainAccountSummary(nativeBalance: s.nativeBalance, isUsed: s.isUsed)
        case .solana:
            return try await SolanaChainAdapter(client: client).fetchAccountSummary(address: address)
        case .ripple:
            return try await XRPChainAdapter(client: client).fetchAccountSummary(address: address)
        case .stellar:
            return try await StellarChainAdapter(client: client).fetchAccountSummary(address: address)
        case .near:
            return try await NEARChainAdapter(client: client).fetchAccountSummary(address: address)
        case .ton:
            return try await TONChainAdapter(client: client).fetchAccountSummary(address: address)
        case .tron:
            return try await TRONChainAdapter(client: client).fetchAccountSummary(address: address)
        case .polkadot:
            return try await PolkadotChainAdapter(client: client).fetchAccountSummary(address: address)
        case .aptos:
            return try await AptosChainAdapter(client: client).fetchAccountSummary(address: address)
        case .sui:
            return try await SuiChainAdapter(client: client).fetchAccountSummary(address: address)
        case .kava:
            return try await CosmosKavaAdapter(client: client).fetchAccountSummary(address: address)
        }
    }
}
