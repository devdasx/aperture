import Foundation
import SwiftData

/// The one pricing front door. Every consumer that needs "unit price of
/// SYMBOL in the user's currency" calls `unitPrices(symbols:currencyCode:)`
/// or `crossRate(from:to:)`.
///
/// Wallet balance/history fetching is disabled elsewhere. This actor remains
/// intentionally live because market prices, token fiat estimates, currency
/// conversion, and FX are still part of the app.
actor TokenPricingEngine {
    static let shared = TokenPricingEngine()

    struct ResolvedPrice: Sendable {
        let amount: Decimal
        let source: String
        let isStale: Bool
    }

    private struct Descriptor: Sendable {
        let symbol: String
        let coinGeckoId: String?
        let coinbaseProduct: String?
        let binanceSymbol: String?
    }

    private struct CachedPrice: Sendable {
        let price: ResolvedPrice
        let fetchedAt: Date
    }

    private struct FXRate: Sendable {
        let rate: Decimal
        let source: String
        let fetchedAt: Date
    }

    private let injectedContainer: ModelContainer?
    private var configuredContainer: ModelContainer?
    private var priceMemory: [String: CachedPrice] = [:]
    private var fxMemory: [String: FXRate] = [:]
    private let priceTTL: TimeInterval = 60
    private let fxTTL: TimeInterval = 10 * 60

    init(container: ModelContainer? = nil) {
        self.injectedContainer = container
    }

    // MARK: - Public API

    func configure(container: ModelContainer) {
        configuredContainer = container
    }

    func unitPrices(symbols: [String], currencyCode: String) async -> [String: ResolvedPrice] {
        let requested = Array(Set(symbols.map { $0.uppercased() }.filter { !$0.isEmpty })).sorted()
        guard !requested.isEmpty else { return [:] }

        let currency = currencyCode.uppercased()
        let now = Date()
        var resolved: [String: ResolvedPrice] = [:]
        var missing: [String] = []

        for symbol in requested {
            let key = cacheKey(symbol: symbol, currency: currency)
            if let cached = priceMemory[key], now.timeIntervalSince(cached.fetchedAt) < priceTTL {
                resolved[symbol] = cached.price
            } else {
                missing.append(symbol)
            }
        }
        guard !missing.isEmpty else { return resolved }

        let diskFallbacks = await diskCachedPrices(symbols: missing, currency: currency)
        let convertedFallbacks = await diskConvertedPrices(symbols: missing, currency: currency)
        let usdRate = await usdRate(to: currency) ?? (currency == "USD" ? FXRate(rate: 1, source: "USD", fetchedAt: now) : nil)
        guard let usdRate else {
            resolved.merge(diskFallbacks) { current, _ in current }
            resolved.merge(convertedFallbacks) { current, _ in current }
            return resolved
        }

        var underlyingByRequested: [String: String] = [:]
        for symbol in missing {
            if EURPeggedStablecoins.needsEURFallback(symbol: symbol) {
                continue
            }
            underlyingByRequested[symbol] = WrappedAssetAliases.resolveSymbol(symbol)
        }

        let underlyingSymbols = Array(Set(underlyingByRequested.values)).sorted()
        var usdPrices: [String: (price: Decimal, source: String)] = [:]

        async let coingeckoTask = fetchCoinGeckoUSDPrices(symbols: underlyingSymbols)
        async let binanceTask = fetchBinanceUSDPrices(symbols: underlyingSymbols)
        async let coinbaseTask = fetchCoinbaseUSDPrices(symbols: underlyingSymbols)
        let coingecko = await coingeckoTask
        let binance = await binanceTask
        let coinbase = await coinbaseTask
        usdPrices.merge(coingecko) { current, _ in current }
        usdPrices.merge(binance) { current, _ in current }
        usdPrices.merge(coinbase) { current, _ in current }

        var liveResolved: [String: ResolvedPrice] = [:]
        for symbol in missing {
            var price: ResolvedPrice?

            if EURPeggedStablecoins.needsEURFallback(symbol: symbol),
               let cross = await crossRate(from: "EUR", to: currency) {
                price = ResolvedPrice(amount: cross, source: "FX", isStale: false)
            } else if let underlying = underlyingByRequested[symbol],
                      let usd = usdPrices[underlying] {
                price = ResolvedPrice(
                    amount: usd.price * usdRate.rate,
                    source: usd.source + " · " + usdRate.source,
                    isStale: false
                )
            } else if KnownStablecoins.all.contains(symbol) {
                price = ResolvedPrice(
                    amount: usdRate.rate,
                    source: "USD stablecoin · " + usdRate.source,
                    isStale: false
                )
            }

            if price == nil {
                price = diskFallbacks[symbol] ?? convertedFallbacks[symbol]
            }

            if let price {
                resolved[symbol] = price
                priceMemory[cacheKey(symbol: symbol, currency: currency)] = CachedPrice(price: price, fetchedAt: now)
                if !price.isStale {
                    liveResolved[symbol] = price
                }
            }
        }

        await persistLivePrices(liveResolved, currency: currency, now: now)
        return resolved
    }

    func crossRate(from sourceCode: String, to targetCode: String) async -> Decimal? {
        let source = sourceCode.uppercased()
        let target = targetCode.uppercased()
        guard source != target else { return 1 }

        if source == "USD" {
            return await usdRate(to: target)?.rate
        }
        if target == "USD" {
            guard let sourceUSD = await usdRate(to: source)?.rate, sourceUSD > 0 else { return nil }
            return 1 / sourceUSD
        }
        guard
            let sourceUSD = await usdRate(to: source)?.rate,
            let targetUSD = await usdRate(to: target)?.rate,
            sourceUSD > 0
        else { return nil }
        return targetUSD / sourceUSD
    }

    // MARK: - Token prices

    private func fetchCoinGeckoUSDPrices(symbols: [String]) async -> [String: (price: Decimal, source: String)] {
        let descriptors = symbols.compactMap { descriptor(for: $0) }.filter { $0.coinGeckoId != nil }
        guard !descriptors.isEmpty else { return [:] }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.coingecko.com"
        components.path = "/api/v3/simple/price"
        components.queryItems = [
            URLQueryItem(name: "ids", value: descriptors.compactMap(\.coinGeckoId).joined(separator: ",")),
            URLQueryItem(name: "vs_currencies", value: "usd")
        ]
        guard let url = components.url else { return [:] }

        do {
            let rows = try await decode([String: [String: Double]].self, from: url, timeout: 10)
            var output: [String: (Decimal, String)] = [:]
            for descriptor in descriptors {
                guard
                    let id = descriptor.coinGeckoId,
                    let value = rows[id]?["usd"],
                    let decimal = decimal(value),
                    decimal > 0
                else { continue }
                output[descriptor.symbol] = (decimal, "CoinGecko")
            }
            return output
        } catch {
            return [:]
        }
    }

    private func fetchBinanceUSDPrices(symbols: [String]) async -> [String: (price: Decimal, source: String)] {
        let descriptors = symbols.compactMap { descriptor(for: $0) }.filter { $0.binanceSymbol != nil }
        guard !descriptors.isEmpty else { return [:] }

        let symbolsJSON = "[" + descriptors.compactMap(\.binanceSymbol).map { "\"\($0)\"" }.joined(separator: ",") + "]"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.binance.com"
        components.path = "/api/v3/ticker/price"
        components.queryItems = [URLQueryItem(name: "symbols", value: symbolsJSON)]
        guard let url = components.url else { return [:] }

        do {
            let rows = try await decode([BinanceTicker].self, from: url, timeout: 10)
            let byPair = Dictionary(uniqueKeysWithValues: rows.map { ($0.symbol, $0.price) })
            var output: [String: (Decimal, String)] = [:]
            for descriptor in descriptors {
                guard
                    let pair = descriptor.binanceSymbol,
                    let string = byPair[pair],
                    let price = Decimal(string: string),
                    price > 0
                else { continue }
                output[descriptor.symbol] = (price, "Binance")
            }
            return output
        } catch {
            return [:]
        }
    }

    private func fetchCoinbaseUSDPrice(symbol: String) async -> (price: Decimal, source: String)? {
        guard let product = descriptor(for: symbol)?.coinbaseProduct else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.exchange.coinbase.com"
        components.path = "/products/\(product)/ticker"
        guard let url = components.url else { return nil }

        do {
            let row = try await decode(CoinbaseTicker.self, from: url, timeout: 10)
            guard let price = Decimal(string: row.price), price > 0 else { return nil }
            return (price, "Coinbase")
        } catch {
            return nil
        }
    }

    private func fetchCoinbaseUSDPrices(symbols: [String]) async -> [String: (price: Decimal, source: String)] {
        var output: [String: (Decimal, String)] = [:]
        await withTaskGroup(of: (String, (price: Decimal, source: String)?).self) { group in
            for symbol in symbols {
                group.addTask {
                    (symbol, await self.fetchCoinbaseUSDPrice(symbol: symbol))
                }
            }
            for await result in group {
                if let price = result.1 {
                    output[result.0] = price
                }
            }
        }
        return output
    }

    // MARK: - FX

    private func usdRate(to currencyCode: String) async -> FXRate? {
        let code = currencyCode.uppercased()
        let now = Date()
        guard code != "USD" else {
            return FXRate(rate: 1, source: "USD", fetchedAt: now)
        }
        if let cached = fxMemory[code], now.timeIntervalSince(cached.fetchedAt) < fxTTL {
            return cached
        }

        async let coinbaseTask = fetchCoinbaseFX(to: code)
        async let exchangeRateTask = fetchExchangeRateAPIFX(to: code)
        async let frankfurterTask = fetchFrankfurterFX(to: code)
        let coinbaseRate = await coinbaseTask
        let exchangeRate = await exchangeRateTask
        let frankfurterRate = await frankfurterTask
        let rate = coinbaseRate ?? exchangeRate ?? frankfurterRate
        if let rate {
            fxMemory[code] = rate
        }
        return rate
    }

    // MARK: - Persistence

    private var persistenceContainer: ModelContainer? {
        injectedContainer ?? configuredContainer
    }

    private func diskCachedPrices(symbols: [String], currency: String) async -> [String: ResolvedPrice] {
        guard let container = persistenceContainer else { return [:] }
        let upperCurrency = currency.uppercased()
        let upperSymbols = symbols.map { $0.uppercased() }
        guard let rows = try? await PriceCacheRepository(modelContainer: container)
            .prices(symbols: upperSymbols, fiat: upperCurrency) else { return [:] }
        return rows.reduce(into: [:]) { output, entry in
            output[entry.key.uppercased()] = ResolvedPrice(
                amount: entry.value.price,
                source: "Local price cache",
                isStale: true
            )
        }
    }

    private func diskConvertedPrices(symbols: [String], currency: String) async -> [String: ResolvedPrice] {
        guard let container = persistenceContainer else { return [:] }
        let upperCurrency = currency.uppercased()
        let upperSymbols = symbols.map { $0.uppercased() }
        guard let rows = try? await PriceCacheRepository(modelContainer: container)
            .latestPriceAnyCurrency(symbols: upperSymbols) else { return [:] }

        var output: [String: ResolvedPrice] = [:]
        for entry in rows {
            let from = entry.value.fiat.uppercased()
            if from == upperCurrency {
                output[entry.key.uppercased()] = ResolvedPrice(
                    amount: entry.value.price,
                    source: "Local price cache",
                    isStale: true
                )
            } else if let cross = await crossRate(from: from, to: upperCurrency) {
                output[entry.key.uppercased()] = ResolvedPrice(
                    amount: entry.value.price * cross,
                    source: "Local price cache · FX",
                    isStale: true
                )
            }
        }
        return output
    }

    private func persistLivePrices(
        _ prices: [String: ResolvedPrice],
        currency: String,
        now: Date
    ) async {
        guard let container = persistenceContainer, !prices.isEmpty else { return }
        let entries = prices
            .filter { !$0.value.isStale && $0.value.amount > 0 }
            .map {
                (
                    symbol: $0.key.uppercased(),
                    fiat: currency.uppercased(),
                    price: $0.value.amount,
                    source: $0.value.source
                )
            }
        guard !entries.isEmpty else { return }
        try? await PriceCacheRepository(modelContainer: container).upsertMany(entries)
        try? await PriceSnapshotRepository(modelContainer: container).record(
            entries.map {
                (
                    symbol: $0.symbol,
                    currencyCode: $0.fiat,
                    price: $0.price,
                    source: $0.source
                )
            },
            at: now
        )
        try? await SyncStatusRepository(modelContainer: container)
            .markSynced(domain: .prices, scopeId: SyncDomain.globalScope)
    }

    private func fetchCoinbaseFX(to currencyCode: String) async -> FXRate? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.coinbase.com"
        components.path = "/v2/exchange-rates"
        components.queryItems = [URLQueryItem(name: "currency", value: "USD")]
        guard let url = components.url else { return nil }

        do {
            let row = try await decode(CoinbaseExchangeRates.self, from: url, timeout: 10)
            guard let string = row.data.rates[currencyCode], let rate = Decimal(string: string), rate > 0 else { return nil }
            return FXRate(rate: rate, source: "Coinbase FX", fetchedAt: Date())
        } catch {
            return nil
        }
    }

    private func fetchExchangeRateAPIFX(to currencyCode: String) async -> FXRate? {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return nil }
        do {
            let row = try await decode(ExchangeRateAPIResponse.self, from: url, timeout: 10)
            guard
                row.result == "success",
                let value = row.rates[currencyCode],
                let rate = decimal(value),
                rate > 0
            else { return nil }
            return FXRate(rate: rate, source: "ExchangeRate-API FX", fetchedAt: Date())
        } catch {
            return nil
        }
    }

    private func fetchFrankfurterFX(to currencyCode: String) async -> FXRate? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.frankfurter.dev"
        components.path = "/v1/latest"
        components.queryItems = [
            URLQueryItem(name: "from", value: "USD"),
            URLQueryItem(name: "to", value: currencyCode)
        ]
        guard let url = components.url else { return nil }

        do {
            let row = try await decode(FrankfurterResponse.self, from: url, timeout: 10)
            guard let value = row.rates[currencyCode], let rate = decimal(value), rate > 0 else { return nil }
            return FXRate(rate: rate, source: "Frankfurter FX", fetchedAt: Date())
        } catch {
            return nil
        }
    }

    // MARK: - Networking

    private func decode<T: Decodable>(_ type: T.Type, from url: URL, timeout: TimeInterval) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.apertureData(
            for: request,
            family: apiFamily(for: url),
            operation: apiOperation(for: url),
            metadata: ["source": "TokenPricingEngine"]
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func apiFamily(for url: URL) -> String {
        let path = url.path.lowercased()
        if path.contains("exchange-rates") || path.contains("latest") {
            return "fx"
        }
        return "prices"
    }

    private func apiOperation(for url: URL) -> String {
        let host = url.host ?? "api"
        switch host {
        case _ where host.contains("coingecko"):
            return "CoinGecko \(url.path)"
        case _ where host.contains("binance"):
            return "Binance \(url.path)"
        case _ where host.contains("coinbase"):
            return "Coinbase \(url.path)"
        case _ where host.contains("er-api"):
            return "ExchangeRate-API \(url.path)"
        case _ where host.contains("frankfurter"):
            return "Frankfurter \(url.path)"
        default:
            return "\(host) \(url.path)"
        }
    }

    // MARK: - Descriptors

    private func descriptor(for symbol: String) -> Descriptor? {
        Self.descriptorsBySymbol[symbol.uppercased()]
    }

    private static let descriptors: [Descriptor] = [
        .init(symbol: "BTC", coinGeckoId: "bitcoin", coinbaseProduct: "BTC-USD", binanceSymbol: "BTCUSDT"),
        .init(symbol: "ETH", coinGeckoId: "ethereum", coinbaseProduct: "ETH-USD", binanceSymbol: "ETHUSDT"),
        .init(symbol: "SOL", coinGeckoId: "solana", coinbaseProduct: "SOL-USD", binanceSymbol: "SOLUSDT"),
        .init(symbol: "BNB", coinGeckoId: "binancecoin", coinbaseProduct: nil, binanceSymbol: "BNBUSDT"),
        .init(symbol: "XRP", coinGeckoId: "ripple", coinbaseProduct: "XRP-USD", binanceSymbol: "XRPUSDT"),
        .init(symbol: "DOGE", coinGeckoId: "dogecoin", coinbaseProduct: "DOGE-USD", binanceSymbol: "DOGEUSDT"),
        .init(symbol: "TON", coinGeckoId: "the-open-network", coinbaseProduct: nil, binanceSymbol: "TONUSDT"),
        .init(symbol: "AVAX", coinGeckoId: "avalanche-2", coinbaseProduct: "AVAX-USD", binanceSymbol: "AVAXUSDT"),
        .init(symbol: "LTC", coinGeckoId: "litecoin", coinbaseProduct: "LTC-USD", binanceSymbol: "LTCUSDT"),
        .init(symbol: "DOT", coinGeckoId: "polkadot", coinbaseProduct: "DOT-USD", binanceSymbol: "DOTUSDT"),
        .init(symbol: "SUI", coinGeckoId: "sui", coinbaseProduct: "SUI-USD", binanceSymbol: "SUIUSDT"),
        .init(symbol: "NEAR", coinGeckoId: "near", coinbaseProduct: "NEAR-USD", binanceSymbol: "NEARUSDT"),
        .init(symbol: "BCH", coinGeckoId: "bitcoin-cash", coinbaseProduct: "BCH-USD", binanceSymbol: "BCHUSDT"),
        .init(symbol: "TRX", coinGeckoId: "tron", coinbaseProduct: nil, binanceSymbol: "TRXUSDT"),
        .init(symbol: "APT", coinGeckoId: "aptos", coinbaseProduct: "APT-USD", binanceSymbol: "APTUSDT"),
        .init(symbol: "XLM", coinGeckoId: "stellar", coinbaseProduct: "XLM-USD", binanceSymbol: "XLMUSDT"),
        .init(symbol: "POL", coinGeckoId: "polygon-ecosystem-token", coinbaseProduct: "POL-USD", binanceSymbol: "POLUSDT"),
        .init(symbol: "CELO", coinGeckoId: "celo", coinbaseProduct: "CELO-USD", binanceSymbol: "CELOUSDT"),
        .init(symbol: "USDC", coinGeckoId: "usd-coin", coinbaseProduct: "USDC-USD", binanceSymbol: "USDCUSDT"),
        .init(symbol: "USDT", coinGeckoId: "tether", coinbaseProduct: nil, binanceSymbol: nil),
        .init(symbol: "DAI", coinGeckoId: "dai", coinbaseProduct: "DAI-USD", binanceSymbol: "DAIUSDT")
    ]

    private static let descriptorsBySymbol = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.symbol, $0) })

    private func cacheKey(symbol: String, currency: String) -> String {
        "\(symbol.uppercased())|\(currency.uppercased())"
    }

    private func decimal(_ value: Double) -> Decimal? {
        Decimal(string: String(value))
    }
}

private struct BinanceTicker: Decodable {
    let symbol: String
    let price: String
}

private struct CoinbaseTicker: Decodable {
    let price: String
}

private struct CoinbaseExchangeRates: Decodable {
    let data: Payload
    struct Payload: Decodable {
        let rates: [String: String]
    }
}

private struct ExchangeRateAPIResponse: Decodable {
    let result: String?
    let rates: [String: Double]
}

private struct FrankfurterResponse: Decodable {
    let rates: [String: Double]
}
