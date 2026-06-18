import Foundation
import os.log

/// **The wallet's sole source of historical daily closes (2026-06-17,
/// user direction).** Server-backed replacement for the in-app
/// `CoinbaseHistoricalPriceService`.
///
/// Reads daily-close candles from the independent Aperture price server
/// (`aperture-price-server` on Render). The app no longer calls Coinbase
/// (or any external price API) directly — the server resolves wrapped
/// assets (WBTC→BTC), pegged USD stables (flat 1), and EUR stables, and
/// returns the close series. This client therefore passes the **raw**
/// symbol straight through and applies no alias logic of its own.
///
/// Endpoint:
///  - `GET /api/history/:symbol/:fiat?days=N`
///    → `{ closes: [ { t: epochSeconds, day: "yyyy-mm-dd", close: number } ] }`
///
/// **Honesty (Rule #16 §A.7).** When the server has no history for a
/// pair, this service returns an empty series. The chart treats missing
/// days as "no historical price — fall back to today's spot" rather than
/// "value at zero" — never a fabricated number, never a crash.
struct RemoteHistoricalPriceService: Sendable {

    /// One daily close. Same shape `CoinbaseHistoricalPriceService.DailyClose`
    /// used, so `WalletRefreshCoordinator.syncHistoricalCloses` is unchanged.
    struct DailyClose: Sendable {
        let timestamp: Date
        let dayKey: Int
        let close: Decimal
    }

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "HistoricalPrice"
    )

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

    /// `GET /api/history/:symbol/:fiat?days=N`. Returns an empty array on
    /// any non-2xx, transport, or parse failure — all "no history"
    /// outcomes treated alike. Any element order is fine; the repo keys
    /// by `dayKey`. Symbols/fiat are ASCII; we still percent-encode.
    func fetchDailyCloses(
        symbol: String,
        fiat: String,
        days: Int = 400
    ) async -> [DailyClose] {
        let sym = symbol.uppercased()
        let quote = fiat.uppercased()
        let allowed = CharacterSet.urlPathAllowed
        guard
            let symEnc = sym.addingPercentEncoding(withAllowedCharacters: allowed),
            let quoteEnc = quote.addingPercentEncoding(withAllowedCharacters: allowed),
            let url = URL(string: "\(RemotePriceService.baseURL)/api/history/\(symEnc)/\(quoteEnc)?days=\(days)")
        else { return [] }

        let response: (Data, URLResponse)
        do {
            response = try await session.data(from: url)
        } catch {
            Self.log.error("History fetch network error for \(sym, privacy: .public)-\(quote, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        guard
            let http = response.1 as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let root = (try? JSONSerialization.jsonObject(with: response.0)) as? [String: Any],
            let closesArray = root["closes"] as? [[String: Any]]
        else {
            return []
        }

        var out: [DailyClose] = []
        out.reserveCapacity(closesArray.count)
        for element in closesArray {
            guard let timeValue = element["t"] else { continue }
            let epoch: Double
            if let number = timeValue as? NSNumber {
                epoch = number.doubleValue
            } else if let double = timeValue as? Double {
                epoch = double
            } else {
                continue
            }

            guard let closeValue = element["close"] else { continue }
            let close: Decimal
            if let number = closeValue as? NSNumber {
                close = number.decimalValue
            } else if let double = closeValue as? Double {
                close = Decimal(double)
            } else {
                continue
            }

            let date = Date(timeIntervalSince1970: epoch)
            // Prefer the server's authoritative `day` string ("yyyy-mm-dd") so
            // the stored key can never drift with the device timezone; fall back
            // to the UTC epoch→day computation only when `day` is absent
            // (2026-06-18 — root cause #3 fix; previously this recomputed with
            // the LOCAL calendar and ignored `day`, mis-bucketing every candle).
            let dayKey = (element["day"] as? String).flatMap(DayKey.from(dayString:))
                ?? DayKey.from(date: date)
            out.append(DailyClose(
                timestamp: date,
                dayKey: dayKey,
                close: close
            ))
        }
        return out
    }
}
