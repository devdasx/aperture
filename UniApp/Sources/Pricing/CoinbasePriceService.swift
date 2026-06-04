import Foundation

/// `PriceService` implementation backed by Coinbase's public spot-price API
/// (`https://api.coinbase.com/v2/prices/{symbol}-{fiat}/spot`). No
/// authentication required, no third-party SDK — just `URLSession` and
/// `JSONDecoder` (Rule #3).
///
/// Coverage probe (2026-06-04) against the 45 unique tickers in
/// `SUPPORTED_ASSETS.md`: **31 supported**, **14 unsupported** (mostly
/// long-tail stablecoins and stETH). See `docs/coinbase-coverage.txt`.
/// Unsupported symbols return `nil` from `price(symbol:fiat:)` — the UI
/// must handle "Price unavailable" gracefully.
///
/// Thread-safe via actor isolation. Includes a 60-second in-memory cache
/// keyed on `(symbol, fiat)` so back-to-back lookups don't hammer the API.
actor CoinbasePriceService: PriceService {

    // MARK: - Configuration

    /// Base URL for the spot-price endpoint.
    private static let baseURL = URL(string: "https://api.coinbase.com/v2/prices")!

    /// In-memory cache TTL. Coinbase spot prices update fast enough that a
    /// minute is honest for "as of now" displays without spamming the API.
    private let cacheTTL: TimeInterval

    /// Maximum parallel in-flight requests in a batch `prices(symbols:fiat:)`
    /// call. Coinbase doesn't publish a hard rate limit for the public
    /// endpoint but throttles aggressive concurrency; 8 is conservative.
    private let maxParallelism: Int

    private let session: URLSession

    init(
        session: URLSession = .shared,
        cacheTTL: TimeInterval = 60,
        maxParallelism: Int = 8
    ) {
        self.session = session
        self.cacheTTL = cacheTTL
        self.maxParallelism = maxParallelism
    }

    // MARK: - Cache

    private struct CacheKey: Hashable, Sendable {
        let symbol: String
        let fiat: String
    }

    private struct CachedEntry: Sendable {
        let price: TokenPrice?
        let fetchedAt: Date
    }

    private var cache: [CacheKey: CachedEntry] = [:]

    // MARK: - PriceService

    func price(symbol: String, fiat: String) async -> TokenPrice? {
        let key = CacheKey(symbol: symbol.uppercased(), fiat: fiat.uppercased())
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.price
        }

        let fetched = await fetchSpot(symbol: key.symbol, fiat: key.fiat)
        cache[key] = CachedEntry(price: fetched, fetchedAt: Date())
        return fetched
    }

    func prices(symbols: [String], fiat: String) async -> [String: TokenPrice] {
        let unique = Array(Set(symbols.map { $0.uppercased() }))
        var results: [String: TokenPrice] = [:]

        // Bounded parallelism via a chunked TaskGroup. Each chunk runs up to
        // `maxParallelism` concurrent fetches; chunks are processed in order.
        for chunk in unique.chunked(into: maxParallelism) {
            let chunkResults = await withTaskGroup(of: (String, TokenPrice?).self) { group in
                for symbol in chunk {
                    group.addTask { [self] in
                        let p = await self.price(symbol: symbol, fiat: fiat)
                        return (symbol, p)
                    }
                }
                var collected: [(String, TokenPrice?)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            for (symbol, price) in chunkResults {
                if let price { results[symbol] = price }
            }
        }
        return results
    }

    // MARK: - Network

    private struct SpotResponse: Decodable {
        struct DataPayload: Decodable {
            let base: String
            let currency: String
            let amount: String
        }
        let data: DataPayload
    }

    /// Single network round-trip. Returns `nil` for unsupported pairs
    /// (404 or missing `amount`). Returns `nil` for any error too —
    /// callers that need error reasons can switch to a `Result`-returning
    /// variant later; for "show a price or hide it" UI, `nil` is enough.
    private func fetchSpot(symbol: String, fiat: String) async -> TokenPrice? {
        let url = Self.baseURL.appendingPathComponent("\(symbol)-\(fiat)").appendingPathComponent("spot")

        let response: (Data, URLResponse)
        do {
            response = try await session.data(from: url)
        } catch {
            return nil // network error → treat as unavailable
        }

        guard
            let http = response.1 as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            return nil // non-2xx → unsupported pair (404) or server hiccup
        }

        guard
            let decoded = try? JSONDecoder().decode(SpotResponse.self, from: response.0),
            let amount = Decimal(string: decoded.data.amount)
        else {
            return nil
        }

        return TokenPrice(
            symbol: symbol,
            fiat: fiat,
            amount: amount,
            timestamp: Date()
        )
    }
}

// MARK: - Array chunking helper (local, not exposed)

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
