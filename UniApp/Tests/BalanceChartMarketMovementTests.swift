import Testing
import Foundation
@testable import Aperture

/// **Part 4 — market-movement vectors for the balance chart (2026-06-19).**
///
/// Guards root cause #2 at the pure-function level (the reconstructor is
/// `nonisolated`, so these need no device/UI): a held position with no trades
/// in a MULTI-DAY window must follow the market (move with the daily historical
/// price), not draw a flat line. Sub-day ranges (1H/1D) intentionally stay flat
/// — daily-close data can't show intraday shape — and that is covered by the
/// existing `BalanceHistoryReconstructorTests`.
struct BalanceChartMarketMovementTests {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private func dayKey(_ y: Int, _ m: Int, _ d: Int) -> Int { y * 10_000 + m * 100 + d }

    private func incomingBTC(on date: Date) -> BalanceHistoryReconstructor.HistoryTx {
        BalanceHistoryReconstructor.HistoryTx(
            occurredAt: date, statusRaw: "confirmed",
            tokenSymbol: "BTC", tokenContract: nil, amountRaw: "1",
            directionRaw: "incoming", counterparty: "0xsomeone"
        )
    }
    private func btcBalance(fiat: Decimal) -> BalanceHistoryReconstructor.HistoryBalance {
        BalanceHistoryReconstructor.HistoryBalance(
            tokenSymbol: "BTC", tokenContract: nil, rawBalance: "1", decimals: 0, fiatValueCached: fiat
        )
    }

    /// Rising daily closes Nov 2025 → Jan 2026 (covers any 1-month window edge).
    private func risingBTCHistory() -> [String: [Int: Decimal]] {
        var h: [Int: Decimal] = [:]
        for d in 1...30 { h[dayKey(2025, 11, d)] = Decimal(60 + d) }
        for d in 1...31 { h[dayKey(2025, 12, d)] = Decimal(90 + d) }
        for d in 1...31 { h[dayKey(2026, 1, d)]  = Decimal(120 + d) }
        return ["BTC": h]
    }

    @Test("Held BTC, no trades in a 1M window, price rises → curve MOVES (root cause #2)")
    func marketMovementNoTrades() {
        let now = date(2026, 1, 31)
        let tx = incomingBTC(on: date(2025, 6, 1))   // well before the 1-month window
        let points = BalanceHistoryReconstructor.reconstruct(
            txSnapshots: [tx],
            balanceSnapshots: [btcBalance(fiat: 151)],
            priceCache: ["BTC": 151],
            priceHistory: risingBTCHistory(),
            range: .month, now: now
        )
        #expect(points.count > 2, "a multi-day no-trade window must be a dense market curve, not a flat 2-point line")
        let fiats = points.map { $0.fiat }
        #expect(Set(fiats).count > 1, "the curve must MOVE with the market, not be flat")
        #expect((fiats.max() ?? 0) > (fiats.min() ?? 0))
        for i in 1..<points.count { #expect(points[i].timestamp >= points[i - 1].timestamp) }
    }

    @Test("No historical prices → no-trade window stays flat (honest, no fabricated wiggle)")
    func noHistoryStaysFlat() {
        let now = date(2026, 1, 31)
        let tx = incomingBTC(on: date(2025, 6, 1))
        let points = BalanceHistoryReconstructor.reconstruct(
            txSnapshots: [tx],
            balanceSnapshots: [btcBalance(fiat: 120)],
            priceCache: ["BTC": 120],     // today's spot only — no daily closes
            priceHistory: [:],
            range: .month, now: now
        )
        #expect(Set(points.map { $0.fiat }).count == 1, "no historical data → flat, never fabricated movement")
    }

    @Test("Reconstruction is deterministic (timezone-invariant via the UTC day-key)")
    func deterministicUTC() {
        let now = date(2026, 1, 31)
        let tx = incomingBTC(on: date(2025, 6, 1))
        func run() -> [BalancePoint] {
            BalanceHistoryReconstructor.reconstruct(
                txSnapshots: [tx], balanceSnapshots: [btcBalance(fiat: 151)],
                priceCache: ["BTC": 151], priceHistory: risingBTCHistory(),
                range: .month, now: now
            )
        }
        // `DayKey.from` is UTC (Part 4.4), so the curve never depends on the
        // device timezone — two runs are byte-for-byte identical.
        #expect(run() == run())
    }

    @Test("sampleGrid is time-ordered, bounded, and spans [start, end]")
    func sampleGridShape() {
        let start = date(2025, 1, 1)
        let end = date(2026, 1, 1)   // ~365 days
        let grid = BalanceHistoryReconstructor.sampleGrid(from: start, to: end, range: .year)
        #expect(grid.count >= 2)
        #expect(grid.count <= 421)            // capped
        #expect(grid.first == start)
        #expect(grid.last == end)
        for i in 1..<grid.count { #expect(grid[i] > grid[i - 1]) }
    }
}
