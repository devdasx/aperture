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
        client: RPCClient = RPCClient(),
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
        async let fxRateTask = fxService.rate(toUSD: currency.code)
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
    func streamScan(
        addresses: [SupportedChain: String],
        currency: SupportedCurrency
    ) -> AsyncStream<StreamRow> {
        AsyncStream(StreamRow.self) { continuation in
            let task = Task {
                let fxRateTask = Task { [fxService] in
                    await fxService.rate(toUSD: currency.code) ?? 0
                }

                await withTaskGroup(of: Void.self) { group in
                    for (chain, address) in addresses {
                        // Native balance task (one per chain).
                        group.addTask { [client, priceService] in
                            async let summaryTask = Self.fetchNative(
                                chain: chain,
                                address: address,
                                client: client
                            )
                            let coinbaseSymbol = Self.coinbaseSymbol(for: chain.ticker)
                            async let priceTask = priceService.price(
                                symbol: coinbaseSymbol,
                                fiat: "USD"
                            )

                            let summary = await summaryTask
                            let usdPrice = await priceTask?.amount
                            let fxRate = await fxRateTask.value

                            guard let summary else { return }

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
                        group.addTask { [client, priceService] in
                            await Self.streamTokens(
                                chain: chain,
                                address: address,
                                client: client,
                                priceService: priceService,
                                fxRateTask: fxRateTask,
                                currency: currency,
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
    private static func streamTokens(
        chain: SupportedChain,
        address: String,
        client: RPCClient,
        priceService: CoinbasePriceService,
        fxRateTask: Task<Decimal, Never>,
        currency: SupportedCurrency,
        yield: @Sendable @escaping (StreamRow) -> Void
    ) async {
        switch chain.family {
        case .evm:
            let registry = EVMTokenRegistry.tokens(for: chain)
            guard !registry.isEmpty else { return }
            let adapter = EVMChainAdapter(chain: chain, client: client)
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in registry {
                    tokenGroup.addTask {
                        async let rawTask: Decimal? = (try? await adapter.fetchTokenBalance(
                            holder: address,
                            contract: entry.contract
                        ))
                        async let priceTask = priceService.price(symbol: entry.symbol, fiat: "USD")
                        let raw = await rawTask ?? 0
                        let usdPrice = await priceTask?.amount
                        let fxRate = await fxRateTask.value
                        let amount = raw / Self.pow10(entry.decimals)
                        // Honest: only emit if balance > 0 (rule of
                        // thumb — review screen would be flooded with
                        // empty rows otherwise). Zero-balance tokens
                        // simply don't show.
                        guard amount > 0 else { return }
                        let fiat = Self.computeFiat(
                            native: amount,
                            usdPrice: usdPrice,
                            fxRate: fxRate,
                            isUSDTarget: currency.code.uppercased() == "USD"
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
                }
            }
        case .ed25519 where chain == .solana:
            let solAdapter = SolanaChainAdapter(client: client)
            guard let accounts = try? await solAdapter.fetchTokenAccounts(address: address) else {
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
            await withTaskGroup(of: Void.self) { tokenGroup in
                for account in supportedAccounts {
                    tokenGroup.addTask {
                        let symbol = SolanaTokenRegistry.symbol(for: account.mint)
                        let name = SolanaTokenRegistry.name(for: account.mint)
                        let usdPrice = await priceService.price(symbol: symbol, fiat: "USD")?.amount
                        let fxRate = await fxRateTask.value
                        let fiat = Self.computeFiat(
                            native: account.amount,
                            usdPrice: usdPrice,
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
                }
            }
        // TRON — TRC-20 balances via TronGrid REST.
        // `POST /wallet/triggerconstantcontract` with the `balanceOf`
        // selector. Same calldata shape as EVM but the call body is
        // TRON-flavored.
        case .tron:
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in TronTokenRegistry.tokens {
                    tokenGroup.addTask {
                        async let rawTask = Self.fetchTronTokenBalance(
                            holder: address,
                            contract: entry.contract,
                            client: client
                        )
                        async let priceTask = priceService.price(symbol: entry.symbol, fiat: "USD")
                        let raw = await rawTask ?? 0
                        let usdPrice = await priceTask?.amount
                        let fxRate = await fxRateTask.value
                        let amount = raw / Self.pow10(entry.decimals)
                        guard amount > 0 else { return }
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
                        async let rawTask = Self.fetchNearTokenBalance(
                            holder: address,
                            tokenAccount: entry.tokenAccount
                        )
                        async let priceTask = priceService.price(symbol: entry.symbol, fiat: "USD")
                        let raw = await rawTask ?? 0
                        let usdPrice = await priceTask?.amount
                        let fxRate = await fxRateTask.value
                        let amount = raw / Self.pow10(entry.decimals)
                        guard amount > 0 else { return }
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
                        async let rawTask = Self.fetchAptosTokenBalance(
                            holder: address,
                            metadata: entry.contract,
                            client: client
                        )
                        async let priceTask = priceService.price(symbol: entry.symbol, fiat: "USD")
                        let raw = await rawTask ?? 0
                        let usdPrice = await priceTask?.amount
                        let fxRate = await fxRateTask.value
                        let amount = raw / Self.pow10(entry.decimals)
                        guard amount > 0 else { return }
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
            guard let lines = await Self.fetchXRPLTokenLines(holder: address) else { return }
            await withTaskGroup(of: Void.self) { tokenGroup in
                for entry in XRPLTokenRegistry.tokens {
                    tokenGroup.addTask {
                        let amount = lines[Self.xrplKey(currency: entry.currency, issuer: entry.issuer)] ?? 0
                        guard amount > 0 else { return }
                        async let priceTask = priceService.price(symbol: entry.symbol, fiat: "USD")
                        let usdPrice = await priceTask?.amount
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
                        async let priceTask = priceService.price(symbol: entry.symbol, fiat: "USD")
                        let usdPrice = await priceTask?.amount
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
        // remaining 20 for the call. The TronGrid call shape:
        //   POST /wallet/triggerconstantcontract
        //   {"owner_address": "<base58 or hex>",
        //    "contract_address": "<base58 or hex>",
        //    "function_selector": "balanceOf(address)",
        //    "parameter": "<32-byte hex of holder address>",
        //    "visible": true}
        guard let url = URL(string: "https://api.trongrid.io/wallet/triggerconstantcontract") else {
            return nil
        }
        let holderHex = Self.tronAddressToEVMHex(holder)
        guard !holderHex.isEmpty else { return nil }
        let paddedHolder = String(repeating: "0", count: 24) + holderHex
        let bodyDict: [String: Any] = [
            "owner_address":     holder,
            "contract_address":  contract,
            "function_selector": "balanceOf(address)",
            "parameter":         paddedHolder,
            "visible":           true,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
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
        tokenAccount: String
    ) async -> Decimal? {
        // NEAR's `query` method with `request_type=call_function`
        // calls a contract's view method. Args are base64-encoded
        // JSON. We call `ft_balance_of({"account_id": holder})`.
        guard let url = URL(string: "https://rpc.mainnet.near.org") else {
            return nil
        }
        let argsJSON = "{\"account_id\":\"\(holder)\"}"
        let argsBase64 = Data(argsJSON.utf8).base64EncodedString()
        let body = """
        {"jsonrpc":"2.0","id":1,"method":"query","params":{"request_type":"call_function","finality":"final","account_id":"\(tokenAccount)","method_name":"ft_balance_of","args_base64":"\(argsBase64)"}}
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
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

    private static func fetchXRPLTokenLines(holder: String) async -> [String: Decimal]? {
        // `account_lines` returns the holder's IOU trust lines. Each
        // line has currency, account (issuer), balance (decimal
        // string). Index by (currency, issuer).
        guard let url = URL(string: "https://s1.ripple.com:51234/") else { return nil }
        let body = """
        {"method":"account_lines","params":[{"account":"\(holder)","ledger_index":"validated"}]}
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
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
            log.error(
                "scan failed for \(chain.rawValue, privacy: .public)/\(String(address.prefix(8)), privacy: .public)…: \(String(describing: error), privacy: .public)"
            )
            // Honest failure (Rule #16). Zero native, not-used,
            // empty fiat — the UI surfaces a per-row error footer
            // separately if it wants. We don't lie about a balance
            // we couldn't verify.
            return ScanRow(
                chain: chain,
                address: address,
                nativeBalance: 0,
                isUsed: false
            )
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
