import Foundation
import os.log

/// Fetches daily close prices from Coinbase Exchange API for a
/// `(symbol, fiat)` pair, applying the same alias/fallback chain
/// `CoinbasePriceService` uses for live spot prices:
///
/// 1. `WrappedAssetAliases` — WETH/WBTC/stETH price at ETH/BTC/ETH
///    historical close. The wrapper IS its underlying for pricing
///    purposes.
/// 2. `KnownStablecoins` — USDT-proxied stablecoins price at USDT's
///    historical close. AUSD/FRAX/USDe at $1-with-off-peg-risk.
/// 3. `EURPeggedStablecoins` — EURC at EUR's historical close.
/// 4. Direct fetch.
///
/// **The endpoint.** Coinbase Exchange API public market data:
/// `GET https://api.exchange.coinbase.com/products/{base}-{quote}/candles?granularity=86400`.
/// No auth required. Returns up to 300 candles per call as JSON
/// arrays `[time, low, high, open, close, volume]` sorted **newest
/// first**. We read `close` (index 4) and `time` (index 0 — Unix
/// epoch seconds) to build daily close data.
///
/// **Honesty (Rule #16 §A.7).** When Coinbase doesn't quote a
/// pair, this service returns an empty series. The chart treats
/// missing days as "no historical price — fall back to today's
/// spot" rather than "value at zero" (the prior bug).
struct CoinbaseHistoricalPriceService {

    /// One candle from the Exchange API.
    struct DailyClose: Sendable {
        let timestamp: Date
        let dayKey: Int
        let close: Decimal
    }

    private static let baseURL = URL(string: "https://api.exchange.coinbase.com")!

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "HistoricalPrice"
    )

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch up to 300 daily close prices for `symbol-fiat`, ending
    /// at `now`. Returns an empty array on any network failure or
    /// when Coinbase doesn't list the pair. Honors the alias /
    /// stablecoin / EUR-pegged fallbacks.
    ///
    /// The 300-candle limit covers ~10 months — plenty for the
    /// chart's `.all` range on a young wallet. If a longer span
    /// matters later, paginate with `start`/`end` query params.
    func fetchDailyCloses(
        symbol: String,
        fiat: String,
        endingAt now: Date = Date()
    ) async -> [DailyClose] {
        let upper = symbol.uppercased()
        // Apply the same alias chain as live spot pricing so the
        // chart speaks one consistent honesty about wrappers and
        // pegged stables.
        let aliased = WrappedAssetAliases.resolveSymbol(upper)
        if aliased != upper {
            return await fetchDirectCloses(base: aliased, quote: fiat.uppercased(), endingAt: now)
        }
        if EURPeggedStablecoins.needsEURFallback(symbol: upper) {
            return await fetchDirectCloses(
                base: EURPeggedStablecoins.fallbackSymbol,
                quote: fiat.uppercased(),
                endingAt: now
            )
        }
        if KnownStablecoins.needsUSDTFallback(symbol: upper) {
            return await fetchDirectCloses(
                base: KnownStablecoins.fallbackSymbol,
                quote: fiat.uppercased(),
                endingAt: now
            )
        }
        // Direct.
        return await fetchDirectCloses(base: upper, quote: fiat.uppercased(), endingAt: now)
    }

    /// Single network call against Coinbase Exchange. Returns empty
    /// on any non-2xx, decode failure, or empty array — these are
    /// all "unsupported pair / no history" outcomes treated alike.
    private func fetchDirectCloses(
        base: String,
        quote: String,
        endingAt now: Date
    ) async -> [DailyClose] {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("/products/\(base)-\(quote)/candles"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "granularity", value: "86400")
        ]
        guard let url = components.url else { return [] }

        let response: (Data, URLResponse)
        do {
            response = try await session.data(from: url)
        } catch {
            Self.log.error("Historical fetch network error for \(base, privacy: .public)-\(quote, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        guard
            let http = response.1 as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            return []
        }

        // Coinbase Exchange `/candles` returns a JSON array of arrays.
        // Each inner array is `[time, low, high, open, close, volume]`.
        // The mixed Number / Double values mean we decode through
        // `JSONSerialization` rather than `JSONDecoder` — the latter
        // can't express "array of arrays of mixed numeric types"
        // cleanly without a wrapper.
        guard let parsed = try? JSONSerialization.jsonObject(with: response.0) as? [[Any]] else {
            return []
        }

        var out: [DailyClose] = []
        out.reserveCapacity(parsed.count)
        for row in parsed {
            guard row.count >= 5,
                  let timeAny = row[0] as? Double,
                  let closeAny = row[4] as? Double
            else { continue }
            let date = Date(timeIntervalSince1970: timeAny)
            let close = Decimal(closeAny)
            out.append(DailyClose(
                timestamp: date,
                dayKey: DayKey.from(date: date),
                close: close
            ))
        }
        return out
    }
}
