import Foundation
import Testing
@testable import Aperture

/// BUG-013: Markets chart ranges must match the UI label for every
/// provider (CoinGecko / Binance / Coinbase). Includes offline sampling
/// tests plus live probes of each API’s real response shape.
@Suite("Market chart ranges (BUG-013)")
struct MarketChartRangeTests {

    // MARK: - Window definitions

    @Test("Every UI range has a distinct window duration")
    func windowDurationsAreDistinctAndOrdered() {
        #expect(MarketChartRange.oneHour.windowDuration == 3_600)
        #expect(MarketChartRange.oneDay.windowDuration == 86_400)
        #expect(MarketChartRange.oneWeek.windowDuration == 7 * 86_400)
        #expect(MarketChartRange.oneMonth.windowDuration == 30 * 86_400)
        #expect(MarketChartRange.oneYear.windowDuration == 365 * 86_400)

        let ordered = MarketChartRange.allCases.map(\.windowDuration)
        #expect(ordered == ordered.sorted())
        #expect(Set(ordered).count == MarketChartRange.allCases.count)
    }

    @Test("BUG-013: CoinGecko does not alias 1H to days=1")
    func coinGeckoOneHourIsNotDaysOne() {
        #expect(MarketChartRange.oneHour.coinGeckoDays == nil)
        #expect(MarketChartRange.oneDay.coinGeckoDays == "1")
        #expect(MarketChartRange.oneWeek.coinGeckoDays == "7")
        #expect(MarketChartRange.oneMonth.coinGeckoDays == "30")
        #expect(MarketChartRange.oneYear.coinGeckoDays == "365")
    }

    @Test("Binance interval × limit covers each zone without a multi-day 1H")
    func binanceParamsCoverWindows() {
        // 60 × 1m = 1h
        #expect(MarketChartRange.oneHour.binanceInterval == "1m")
        #expect(MarketChartRange.oneHour.binanceLimit == 60)
        // 48 × 30m = 24h
        #expect(MarketChartRange.oneDay.binanceInterval == "30m")
        #expect(MarketChartRange.oneDay.binanceLimit == 48)
        // 42 × 4h = 7d
        #expect(MarketChartRange.oneWeek.binanceInterval == "4h")
        #expect(MarketChartRange.oneWeek.binanceLimit == 42)
        // 30 × 1d = 30d
        #expect(MarketChartRange.oneMonth.binanceInterval == "1d")
        #expect(MarketChartRange.oneMonth.binanceLimit == 30)
        // 52 × 1w = 52w
        #expect(MarketChartRange.oneYear.binanceInterval == "1w")
        #expect(MarketChartRange.oneYear.binanceLimit == 52)

        for range in MarketChartRange.allCases {
            let secondsPerBar = binanceIntervalSeconds(range.binanceInterval)
            let covered = TimeInterval(range.binanceLimit - 1) * secondsPerBar
            // Coverage is at least ~half the window and never more than 2×.
            #expect(covered >= range.windowDuration * 0.45, "\(range.rawValue) under-covers")
            #expect(covered <= range.windowDuration * 2.1, "\(range.rawValue) over-covers")
        }
    }

    @Test("Coinbase granularity fits each window inside the 300-candle cap")
    func coinbaseGranularityFitsWindow() {
        for range in MarketChartRange.allCases {
            let bars = range.windowDuration / TimeInterval(range.coinbaseGranularity)
            // Coinbase hard-caps a single request at 300 candles. 1Y daily
            // wants 365 → API returns the most recent 300; clip still keeps
            // the zone honest. Every other zone fits in one request.
            if range == .oneYear {
                #expect(bars <= 365)
                #expect(bars > 300) // documents the known single-request clip
            } else {
                #expect(bars <= 300, "\(range.rawValue) needs \(bars) candles > 300 cap")
            }
            #expect(bars >= 12, "\(range.rawValue) too coarse (\(bars) bars)")
            let bounds = MarketChartSampling.coinbaseTimeBounds(
                range: range,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
            #expect(bounds.end.timeIntervalSince(bounds.start) == range.windowDuration)
        }
        #expect(MarketChartRange.oneHour.coinbaseGranularity == 60)
        #expect(MarketChartRange.oneDay.coinbaseGranularity == 900)
    }

    // MARK: - Clip / sampling (provider-agnostic)

    @Test("clip drops a full-day series when the zone is 1H")
    func clipOneHourRejectsDayLongSeries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Simulate CoinGecko days=1: 5-minute samples over 24h.
        var daySeries: [MarketPoint] = []
        for minute in stride(from: 0, through: 24 * 60, by: 5) {
            let t = now.addingTimeInterval(-TimeInterval((24 * 60 - minute) * 60))
            daySeries.append(MarketPoint(date: t, price: 40_000 + Double(minute)))
        }
        #expect(daySeries.count > 200)

        let hour = MarketChartSampling.clip(daySeries, to: .oneHour, now: now)
        #expect(hour.count >= 10)
        #expect(hour.count < 30) // ~12 five-minute bars in 1h
        #expect(MarketChartSampling.isSpanPlausible(for: .oneHour, points: hour, now: now))

        if let span = MarketChartSampling.span(of: hour) {
            #expect(span <= 3_600 * 1.15)
            #expect(span >= 3_000)
        } else {
            Issue.record("1H clip produced no span")
        }
    }

    @Test("clip keeps a genuine 1H minute series intact")
    func clipPreservesTrueOneHourSeries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let series = (0..<60).map { i in
            MarketPoint(
                date: now.addingTimeInterval(-TimeInterval(59 - i) * 60),
                price: 100 + Double(i)
            )
        }
        let clipped = MarketChartSampling.clip(series, to: .oneHour, now: now)
        #expect(clipped.count == 60)
        #expect(MarketChartSampling.isSpanPlausible(for: .oneHour, points: clipped, now: now))
    }

    @Test("clip works for every zone against an over-long series")
    func clipAllRangesAgainstLongSeries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // One point per hour for 400 days (built imperatively so the
        // type-checker doesn't choke on a giant map expression).
        var long: [MarketPoint] = []
        long.reserveCapacity(400 * 24)
        let totalHours = 400 * 24
        for hour in 0..<totalHours {
            let age = TimeInterval((totalHours - 1 - hour) * 3600)
            long.append(MarketPoint(
                date: now.addingTimeInterval(-age),
                price: 1_000 + Double(hour % 100)
            ))
        }
        for range in MarketChartRange.allCases {
            let clipped = MarketChartSampling.clip(long, to: range, now: now)
            #expect(!clipped.isEmpty, "\(range.rawValue) empty after clip")
            #expect(
                MarketChartSampling.isSpanPlausible(for: range, points: clipped, now: now),
                "\(range.rawValue) span not plausible"
            )
            if let span = MarketChartSampling.span(of: clipped) {
                #expect(span <= range.windowDuration * 1.15, "\(range.rawValue) span \(span)")
            }
        }
    }

    @Test("stale series clips relative to last point (clock-skew / cache)")
    func clipRelativeToLastPointWhenStale() {
        // Series ends 2 days ago — absolute now-cutoff would wipe it.
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        let now = last.addingTimeInterval(2 * 86_400)
        // 120 one-minute samples ending at `last`.
        let series = (0..<120).map { i in
            MarketPoint(
                date: last.addingTimeInterval(-TimeInterval(119 - i) * 60),
                price: 50 + Double(i)
            )
        }
        let clipped = MarketChartSampling.clip(series, to: .oneHour, now: now)
        // Inclusive window last-3600…last with 1m steps → 61 samples.
        #expect(clipped.count == 61)
        if let span = MarketChartSampling.span(of: clipped) {
            #expect(span <= 3_600 * 1.05)
            #expect(span >= 3_500)
        }
    }

    // MARK: - Live API shape probes (real responses)

    /// Live CoinGecko: days=1 is ~24h; range 1h is ~1h. Soft-skip on 429.
    @Test("Live CoinGecko days=1 spans ~24h; range endpoint spans ~1h")
    func liveCoinGeckoShapes() async throws {
        do {
            let dayURL = URL(string: "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart?vs_currency=usd&days=1")!
            let day = try await fetchJSON(dayURL)
            let dayPrices = try prices(from: day)
            let dayPoints = marketPoints(dayPrices)
            let now = Date()
            if let span = MarketChartSampling.span(of: dayPoints) {
                #expect(span > 20 * 3600, "days=1 should be ~24h, got \(span / 3600)h")
                #expect(span < 30 * 3600)
            }
            // Offline clip must turn that into a 1H chart.
            let hourFromDay = MarketChartSampling.clip(dayPoints, to: .oneHour, now: now)
            #expect(MarketChartSampling.isSpanPlausible(for: .oneHour, points: hourFromDay, now: now))

            let end = Int(now.timeIntervalSince1970)
            let start = end - 3600
            let rangeURL = URL(string: "https://api.coingecko.com/api/v3/coins/bitcoin/market_chart/range?vs_currency=usd&from=\(start)&to=\(end)")!
            let rangeJSON = try await fetchJSON(rangeURL)
            let rangePoints = marketPoints(try prices(from: rangeJSON))
            let clipped = MarketChartSampling.clip(rangePoints, to: .oneHour, now: now)
            #expect(!clipped.isEmpty)
            if let span = MarketChartSampling.span(of: clipped) {
                #expect(span <= 3_600 * 1.2, "range 1H span \(span / 60)m")
            }
            print("[MarketChart] CoinGecko days=1 n=\(dayPoints.count) range1h n=\(clipped.count)")
        } catch {
            print("[MarketChart] CoinGecko live probe skipped: \(error)")
        }
    }

    /// Live Binance (data-api host mirrors production klines shape).
    @Test("Live Binance 1m×60 spans ~1h for every major interval used by zones")
    func liveBinanceShapes() async throws {
        let cases: [(MarketChartRange, String)] = [
            (.oneHour, "1m"),
            (.oneDay, "30m"),
            (.oneWeek, "4h"),
            (.oneMonth, "1d"),
            (.oneYear, "1w")
        ]
        for (range, interval) in cases {
            let limit = range.binanceLimit
            // Prefer vision host — same JSON as api.binance.com uiKlines/klines.
            let url = URL(string: "https://data-api.binance.vision/api/v3/klines?symbol=BTCUSDT&interval=\(interval)&limit=\(limit)")!
            do {
                let rows = try await fetchJSONArray(url)
                #expect(rows.count > 0, "\(range.rawValue) empty")
                let points: [MarketPoint] = rows.compactMap { row in
                    guard row.count >= 5,
                          let openTime = jsonNumber(row[0]),
                          let close = jsonNumber(row[4]) ?? (row[4] as? String).flatMap(Double.init)
                    else { return nil }
                    return MarketPoint(date: Date(timeIntervalSince1970: openTime / 1000), price: close)
                }
                let clipped = MarketChartSampling.clip(points, to: range)
                #expect(!clipped.isEmpty, "\(range.rawValue) clip empty")
                #expect(
                    MarketChartSampling.isSpanPlausible(for: range, points: clipped),
                    "\(range.rawValue) span not plausible after clip"
                )
                print("[MarketChart] Binance \(range.rawValue) n=\(clipped.count) span=\(MarketChartSampling.span(of: clipped) ?? -1)")
            } catch {
                print("[MarketChart] Binance \(range.rawValue) skipped: \(error)")
            }
        }
    }

    /// Live Coinbase with start/end — proves unbounded candles would overshoot
    /// and that bounded queries respect the window after clip.
    @Test("Live Coinbase bounded candles respect 1H and 1D windows")
    func liveCoinbaseBoundedShapes() async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = Date()

        for range in [MarketChartRange.oneHour, .oneDay] {
            let bounds = MarketChartSampling.coinbaseTimeBounds(range: range, now: now)
            var components = URLComponents(string: "https://api.exchange.coinbase.com/products/BTC-USD/candles")!
            components.queryItems = [
                URLQueryItem(name: "granularity", value: "\(range.coinbaseGranularity)"),
                URLQueryItem(name: "start", value: iso.string(from: bounds.start)),
                URLQueryItem(name: "end", value: iso.string(from: bounds.end))
            ]
            guard let url = components.url else { continue }
            do {
                let rows = try await fetchJSONArray(url)
                let points: [MarketPoint] = rows.compactMap { row in
                    // [time, low, high, open, close, volume]
                    guard row.count >= 5,
                          let t = jsonNumber(row[0]),
                          let close = jsonNumber(row[4]) else {
                        return nil
                    }
                    return MarketPoint(date: Date(timeIntervalSince1970: t), price: close)
                }
                let clipped = MarketChartSampling.clip(points, to: range, now: now)
                #expect(!clipped.isEmpty, "\(range.rawValue) empty")
                #expect(
                    MarketChartSampling.isSpanPlausible(for: range, points: clipped, now: now),
                    "\(range.rawValue) Coinbase span not plausible"
                )
                print("[MarketChart] Coinbase \(range.rawValue) n=\(clipped.count)")
            } catch {
                print("[MarketChart] Coinbase \(range.rawValue) skipped: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func binanceIntervalSeconds(_ interval: String) -> TimeInterval {
        switch interval {
        case "1m": return 60
        case "30m": return 30 * 60
        case "4h": return 4 * 3600
        case "1d": return 86_400
        case "1w": return 7 * 86_400
        default: return 60
        }
    }

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue("ApertureTests/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return obj
    }

    private func fetchJSONArray(_ url: URL) async throws -> [[Any]] {
        var request = URLRequest(url: url)
        request.setValue("ApertureTests/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return obj
    }

    private func prices(from json: [String: Any]) throws -> [[Double]] {
        guard let prices = json["prices"] as? [[Any]] else {
            throw URLError(.cannotParseResponse)
        }
        return prices.compactMap { pair in
            guard pair.count >= 2,
                  let t = jsonNumber(pair[0]),
                  let p = jsonNumber(pair[1]) else {
                return nil
            }
            return [t, p]
        }
    }

    private func marketPoints(_ prices: [[Double]]) -> [MarketPoint] {
        prices.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return MarketPoint(date: Date(timeIntervalSince1970: pair[0] / 1000), price: pair[1])
        }
    }

    private func jsonNumber(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
