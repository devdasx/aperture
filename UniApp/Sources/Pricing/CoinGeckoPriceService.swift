import Foundation
import OSLog

/// Secondary (fallback) spot-price provider backed by CoinGecko's
/// public `simple/price` endpoint — independent infrastructure from
/// Coinbase, no key required, plain `URLSession` REST (Rule #3).
///
/// **Position in the pricing ladder.** `TokenPricingEngine` consults
/// this service only AFTER Coinbase failed for a symbol AND no
/// per-currency cached price exists. It is the "second independent
/// API" rung — never the primary.
///
/// **One call for everything.** `simple/price` accepts many ids and
/// many vs_currencies in a single request, so a whole refresh's worth
/// of missed symbols costs exactly one HTTP round trip — the
/// batch-first discipline the Coinbase service achieves with bounded
/// chunking, CoinGecko gives us natively.
///
/// **Currency strategy.** Every request asks for `usd` plus the
/// user's currency (lowercased). CoinGecko supports ~60 vs_currencies
/// (most fiats, not all — JOD for example is absent); unsupported
/// currencies are silently omitted from the response rather than
/// erroring. The engine prefers the direct value when present and
/// falls back to `usd × FX` otherwise.
///
/// **Unknown-symbol skip.** Symbols without a confident CoinGecko id
/// in `coinGeckoIds` (after wrapped-asset alias + stablecoin-proxy
/// resolution) are skipped — no guessed ids, no fabricated prices
/// (Rule #2 §A.7). They fall through to the next ladder rung.
actor CoinGeckoPriceService {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "coingecko")

    /// One symbol's quote. `direct` is the price in the requested
    /// fiat when CoinGecko supports that vs_currency; `usd` is always
    /// requested so the engine can pivot through FX when `direct`
    /// is unavailable.
    struct Quote: Sendable {
        let direct: Decimal?
        let usd: Decimal?
    }

    /// Same restraint as `CoinbasePriceService.spotSession`: tiny JSON
    /// payloads, 8 s request timeout, ephemeral (no disk cache — the
    /// engine's persistent per-currency cache is the only disk layer
    /// we want).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 16
        return URLSession(configuration: config)
    }()

    /// Short in-memory TTL so back-to-back fallback batches (retry
    /// pass racing the first pass) don't double-hit the free-tier
    /// rate limit.
    private let cacheTTL: TimeInterval = 60

    private struct CacheKey: Hashable, Sendable {
        let symbol: String
        let fiat: String
    }

    private struct CachedQuote: Sendable {
        let quote: Quote
        let fetchedAt: Date
    }

    private var cache: [CacheKey: CachedQuote] = [:]

    // MARK: - Symbol → CoinGecko id map

    /// CoinGecko ids for the symbols Aperture can ever need to price:
    /// every `SupportedChain.ticker` plus every registry token
    /// (`EVMTokenRegistry`, `SolanaTokenRegistry`, `TronTokenRegistry`,
    /// `NearTokenRegistry`, `AptosTokenRegistry`, `XRPLTokenRegistry`,
    /// `KavaCosmosTokenRegistry`). Only confidently-verified ids are
    /// listed; long-tail stablecoins without one (USD1, USDai, USDf,
    /// DUSD, lisUSD) resolve through the USDT proxy in `id(for:)` —
    /// the same honesty bound as `KnownStablecoins`' Coinbase
    /// fallback.
    static let coinGeckoIds: [String: String] = [
        // Native chain coins (19 unique tickers across 26 chains).
        "BTC":   "bitcoin",
        "BCH":   "bitcoin-cash",
        "LTC":   "litecoin",
        "DOGE":  "dogecoin",
        "ETH":   "ethereum",
        "POL":   "polygon-ecosystem-token",
        "BNB":   "binancecoin",
        "AVAX":  "avalanche-2",
        "CELO":  "celo",
        "KAVA":  "kava",
        "APT":   "aptos",
        "NEAR":  "near",
        "DOT":   "polkadot",
        "XRP":   "ripple",
        "SOL":   "solana",
        "XLM":   "stellar",
        "SUI":   "sui",
        "TON":   "the-open-network",
        "TRX":   "tron",
        // Majors / wrapped (registry tokens).
        "USDT":  "tether",
        "USDC":  "usd-coin",
        "DAI":   "dai",
        "WETH":  "weth",
        "WBTC":  "wrapped-bitcoin",
        "STETH": "staked-ether",
        // Stablecoins with dedicated listings.
        "PYUSD": "paypal-usd",
        "TUSD":  "true-usd",
        "FRAX":  "frax",
        "GUSD":  "gemini-dollar",
        "USDP":  "paxos-standard",
        "FDUSD": "first-digital-usd",
        "USDD":  "usdd",
        "USDE":  "ethena-usde",
        "RLUSD": "ripple-usd",
        "EURC":  "euro-coin",
        "USDS":  "usds",
        "USDG":  "global-dollar",
        "USD0":  "usual-usd",
        "AUSD":  "agora-dollar",
    ]

    /// Resolve a registry symbol to the CoinGecko id to query.
    /// Resolution order mirrors the Coinbase service's fallback
    /// chain: direct id → wrapped-asset alias (WETH → ETH id) →
    /// USD-stable proxy (tether) → `nil` (skip — next ladder rung).
    static func id(for symbol: String) -> String? {
        let upper = symbol.uppercased()
        if let direct = coinGeckoIds[upper] { return direct }
        let aliased = WrappedAssetAliases.resolveSymbol(upper)
        if aliased != upper, let viaAlias = coinGeckoIds[aliased] { return viaAlias }
        if KnownStablecoins.needsUSDTFallback(symbol: upper) {
            return coinGeckoIds[KnownStablecoins.fallbackSymbol]
        }
        return nil
    }

    // MARK: - Batch fetch

    /// Quotes for `symbols` in `fiat` (plus USD pivot), one network
    /// round trip for every cold symbol. Symbols with no CoinGecko id
    /// are absent from the result (unknown-symbol skip). Network or
    /// decode failure returns whatever the TTL cache already held —
    /// typically `[:]` — and the engine moves to the next rung.
    func quotes(symbols: [String], fiat: String) async -> [String: Quote] {
        let fiatUpper = fiat.uppercased()
        var results: [String: Quote] = [:]
        var coldSymbols: [String] = []

        for symbol in Set(symbols.map { $0.uppercased() }) {
            let key = CacheKey(symbol: symbol, fiat: fiatUpper)
            if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
                results[symbol] = cached.quote
            } else if Self.id(for: symbol) != nil {
                coldSymbols.append(symbol)
            }
        }
        guard !coldSymbols.isEmpty else { return results }

        // Reverse map id → symbols so a shared proxy id (tether for
        // several $1 stables) fans back out to every requester.
        var symbolsByID: [String: [String]] = [:]
        for symbol in coldSymbols {
            guard let id = Self.id(for: symbol) else { continue }
            symbolsByID[id, default: []].append(symbol)
        }
        guard !symbolsByID.isEmpty else { return results }

        guard let payload = await fetchSimplePrice(
            ids: symbolsByID.keys.sorted(),
            fiat: fiatUpper
        ) else {
            return results
        }

        let fiatField = fiatUpper.lowercased()
        let now = Date()
        for (id, values) in payload {
            guard let requesters = symbolsByID[id] else { continue }
            let quote = Quote(
                direct: fiatField == "usd" ? values["usd"] : values[fiatField],
                usd: values["usd"]
            )
            for symbol in requesters {
                results[symbol] = quote
                cache[CacheKey(symbol: symbol, fiat: fiatUpper)] = CachedQuote(quote: quote, fetchedAt: now)
            }
        }
        return results
    }

    // MARK: - Network

    /// `GET /api/v3/simple/price?ids=…&vs_currencies=usd,<fiat>`.
    /// Returns `[id: [currencyField: price]]` or `nil` on any failure
    /// (the engine treats nil as "this rung didn't answer").
    /// Decimal decode goes through `NSDecimalNumber(string:)` — the
    /// same precision-preserving path `FXRateService` uses — never
    /// through a lossy `Double` round trip.
    private func fetchSimplePrice(ids: [String], fiat: String) async -> [String: [String: Decimal]]? {
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")
        let vsCurrencies = fiat.uppercased() == "USD" ? "usd" : "usd,\(fiat.lowercased())"
        components?.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "vs_currencies", value: vsCurrencies),
        ]
        guard let url = components?.url else { return nil }

        let response: (Data, URLResponse)
        do {
            response = try await Self.session.data(from: url)
        } catch {
            Self.log.error("simple/price request failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let http = response.1 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            // 429 = free-tier rate limit; any non-2xx → rung declines.
            Self.log.error("simple/price returned non-2xx")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any] else {
            Self.log.error("simple/price returned malformed JSON")
            return nil
        }

        var out: [String: [String: Decimal]] = [:]
        for (id, value) in json {
            guard let fields = value as? [String: Any] else { continue }
            var prices: [String: Decimal] = [:]
            for (field, raw) in fields {
                guard let num = raw as? NSNumber else { continue }
                let dec: Decimal
                if let exact = num as? NSDecimalNumber {
                    dec = exact.decimalValue
                } else {
                    dec = NSDecimalNumber(string: num.stringValue).decimalValue
                }
                if !dec.isNaN, dec > 0 {
                    prices[field.lowercased()] = dec
                }
            }
            if !prices.isEmpty {
                out[id] = prices
            }
        }
        return out
    }
}
