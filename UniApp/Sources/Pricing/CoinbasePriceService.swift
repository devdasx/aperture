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

    /// How many `maxParallelism`-sized chunks a batch keeps in flight
    /// at once (2026-06-12). Strictly-sequential chunks meant one
    /// degraded chunk gated every chunk behind it — with ~49 symbols
    /// per refresh that was minutes of wall clock on a bad network.
    /// Three concurrent chunks cap peak concurrency at 24 requests,
    /// still polite for the public endpoint.
    private static let maxConcurrentChunks = 3

    /// Dedicated session for the spot endpoint (2026-06-12). The
    /// shared session's 60 s default request timeout let a single
    /// degraded round trip stall a whole price batch — and every
    /// `streamScan` row used to wait on that batch. Spot quotes are
    /// tiny JSON payloads; 8 s is generous. Ephemeral configuration:
    /// no disk cache for price data (the actor's TTL cache is the
    /// only cache layer we want).
    private static let spotSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 16
        return URLSession(configuration: config)
    }()

    private let session: URLSession

    init(
        session: URLSession? = nil,
        cacheTTL: TimeInterval = 60,
        maxParallelism: Int = 8
    ) {
        self.session = session ?? Self.spotSession
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

        // **2026-06-12 — wrapped-asset alias resolution.** A wrapped
        // or liquid-staked variant (WETH / WBTC / stETH) prices at
        // its underlying's spot since Coinbase doesn't quote the
        // wrappers directly. Same shape as the `KnownStablecoins`
        // USDT fallback but applied BEFORE the direct fetch so we
        // don't burn a guaranteed-miss round trip first. The cache
        // entry and returned `TokenPrice.symbol` carry the
        // **requested** symbol so callers see WETH rendered as WETH,
        // even though the price came from ETH spot.
        let resolvedSymbol = WrappedAssetAliases.resolveSymbol(key.symbol)
        if resolvedSymbol != key.symbol,
           let underlying = await fetchSpot(symbol: resolvedSymbol, fiat: key.fiat) {
            let proxied = TokenPrice(
                symbol: key.symbol,
                fiat: key.fiat,
                amount: underlying.amount,
                timestamp: underlying.timestamp
            )
            cache[key] = CachedEntry(price: proxied, fetchedAt: Date())
            return proxied
        }

        // First try the direct spot. Coinbase covers the majors
        // (BTC, ETH, SOL, …) and the well-known stablecoins (USDC,
        // USDT, DAI, GUSD, PYUSD, USD1, USDS, USDf).
        if let direct = await fetchSpot(symbol: key.symbol, fiat: key.fiat) {
            cache[key] = CachedEntry(price: direct, fetchedAt: Date())
            return direct
        }

        // Stablecoin fallback (per `docs/coinbase-coverage.txt`).
        // For known $1-pegged stablecoins Coinbase doesn't quote
        // directly (USD0, USDe, AUSD, FRAX, TUSD, RLUSD, FDUSD, …)
        // we proxy to USDT — the canonical "$1 with off-peg risk"
        // stand-in, same risk profile. We re-stamp the returned
        // `TokenPrice.symbol` to the **requested** symbol so the
        // caller (and the cache key) stays accurate.
        if KnownStablecoins.needsUSDTFallback(symbol: key.symbol),
           let usdt = await fetchSpot(symbol: KnownStablecoins.fallbackSymbol, fiat: key.fiat) {
            let proxied = TokenPrice(
                symbol: key.symbol,
                fiat: key.fiat,
                amount: usdt.amount,
                timestamp: usdt.timestamp
            )
            cache[key] = CachedEntry(price: proxied, fetchedAt: Date())
            return proxied
        }

        // **2026-06-12 — EUR-pegged fallback.** Mirrors the USDT
        // fallback above but for euro-pegged stables (EURC today).
        // Coinbase quotes `EUR-USD`, `EUR-GBP`, etc., so we ask for
        // `EUR-{fiat}` spot — the honest approximation of 1 EURC
        // worth of the user's fiat.
        if EURPeggedStablecoins.needsEURFallback(symbol: key.symbol),
           let eur = await fetchSpot(symbol: EURPeggedStablecoins.fallbackSymbol, fiat: key.fiat) {
            let proxied = TokenPrice(
                symbol: key.symbol,
                fiat: key.fiat,
                amount: eur.amount,
                timestamp: eur.timestamp
            )
            cache[key] = CachedEntry(price: proxied, fetchedAt: Date())
            return proxied
        }

        // Genuine miss — cache the negative so we don't refetch
        // for `cacheTTL` seconds. The UI surfaces this as
        // "Price unavailable" (Rule #16 §A.6 honesty).
        cache[key] = CachedEntry(price: nil, fetchedAt: Date())
        return nil
    }

    func prices(symbols: [String], fiat: String) async -> [String: TokenPrice] {
        let unique = Array(Set(symbols.map { $0.uppercased() }))
        var results: [String: TokenPrice] = [:]

        // Bounded two-level parallelism (2026-06-12). A sliding
        // window keeps up to `maxConcurrentChunks` chunks in flight,
        // each running up to `maxParallelism` concurrent fetches —
        // previously chunks ran strictly sequentially, so one slow
        // chunk stalled every chunk behind it.
        let chunks = unique.chunked(into: maxParallelism)
        await withTaskGroup(of: [(String, TokenPrice?)].self) { group in
            var pending = chunks.makeIterator()
            var inFlight = 0
            while inFlight < Self.maxConcurrentChunks, let chunk = pending.next() {
                group.addTask { [self] in
                    await self.fetchChunk(chunk, fiat: fiat)
                }
                inFlight += 1
            }
            while let chunkResults = await group.next() {
                for (symbol, price) in chunkResults {
                    if let price { results[symbol] = price }
                }
                if let chunk = pending.next() {
                    group.addTask { [self] in
                        await self.fetchChunk(chunk, fiat: fiat)
                    }
                }
            }
        }
        return results
    }

    /// One chunk's worth of concurrent single-symbol lookups.
    /// Factored out of `prices(symbols:fiat:)` so the batch path can
    /// keep several chunks in flight at once.
    private func fetchChunk(_ chunk: [String], fiat: String) async -> [(String, TokenPrice?)] {
        await withTaskGroup(of: (String, TokenPrice?).self) { group in
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
