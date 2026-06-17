import Foundation

/// **The wallet's sole price source (2026-06-17, user direction).**
///
/// Reads token prices + FX from the independent Aperture price server
/// (`aperture-price-server` on Render, backed by neon.tech). The app no
/// longer calls Coinbase/CoinGecko/FX directly — the server fetches USD
/// prices from several providers WITH fallback, fetches FX for ~160
/// currencies, refreshes every 2 minutes, and computes any currency on
/// read (a brand-new currency is fetched on demand server-side and saved
/// for future users). The app's local price cache
/// (`PriceCacheRepository`) is the only offline fallback — when this
/// server is unreachable, the last-known prices stand.
///
/// Endpoints:
///  - `GET /api/prices/:currency` → `{ currency, prices: { SYM: number }, fxRate, asOf }`
///  - `GET /api/fx/:currency`     → `{ currency, rate }`
struct RemotePriceService: Sendable {

    /// The deployed Render service. Public URL (not a secret).
    static let baseURL = "https://aperture-price-server.onrender.com"

    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.httpMaximumConnectionsPerHost = 4
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    /// All token prices already denominated in `currency`.
    struct Quote: Sendable {
        let currency: String
        let prices: [String: Decimal]   // SYMBOL (uppercased) → price in `currency`
        let fxRate: Decimal?
    }

    /// `GET /api/prices/:currency`. Returns `nil` on any transport/parse
    /// failure (the caller falls back to its local cache).
    ///
    /// When `symbols` is non-empty, the request asks the server for those
    /// specific tickers on demand (`?symbols=BTC,ETH,…`) — this is how
    /// custom/user-added tokens outside the server's default universe get
    /// priced. When empty (the default), the server returns its full
    /// universe, preserving the original no-arg behavior exactly.
    func prices(currency: String, symbols: [String] = []) async -> Quote? {
        let code = currency.uppercased()
        var urlString = "\(Self.baseURL)/api/prices/\(code)"
        if !symbols.isEmpty {
            let joined = symbols.map { $0.uppercased() }.joined(separator: ",")
            let allowed = CharacterSet.urlQueryAllowed
            if let encoded = joined.addingPercentEncoding(withAllowedCharacters: allowed) {
                urlString += "?symbols=\(encoded)"
            }
        }
        guard let url = URL(string: urlString),
              let data = try? await get(url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pricesObj = root["prices"] as? [String: Any]
        else { return nil }

        var prices: [String: Decimal] = [:]
        prices.reserveCapacity(pricesObj.count)
        for (symbol, value) in pricesObj {
            if let number = value as? NSNumber {
                prices[symbol.uppercased()] = number.decimalValue
            } else if let double = value as? Double {
                prices[symbol.uppercased()] = Decimal(double)
            }
        }
        let fx = (root["fxRate"] as? NSNumber)?.decimalValue
        return Quote(currency: code, prices: prices, fxRate: fx)
    }

    /// `GET /api/fx/:currency` → 1 USD = rate `currency`. `nil` on failure.
    func fxRate(currency: String) async -> Decimal? {
        let code = currency.uppercased()
        if code == "USD" { return 1 }
        guard let url = URL(string: "\(Self.baseURL)/api/fx/\(code)"),
              let data = try? await get(url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let number = root["rate"] as? NSNumber { return number.decimalValue }
        if let double = root["rate"] as? Double { return Decimal(double) }
        return nil
    }

    // MARK: - HTTP

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
