import Testing
import Foundation
@testable import Aperture

/// Tests for `BalanceHistoryReconstructor` — the **2026-06-19 Mode C
/// rebuild** ("transaction-sourced holdings, historical-price valuation,
/// real and alive for every range").
///
/// Contract under test:
/// - **Holdings ledger** is a pure function of transactions: forward walk
///   oldest-first from ZERO, `+incoming / −outgoing / internal-no-op`,
///   negatives clamp to zero.
/// - **Valuation (Mode C)**: each instant is `Σ quantity × historical
///   close(token, UTCday)` with carry-forward on gaps; the `now` tip uses
///   current spot. The ledger tests below pass NO `priceHistory`, so
///   valuation falls back to spot — `Σ quantity × spot` — and a spot of 1
///   makes the curve's fiat equal the quantity (asserting the ledger
///   directly). The dedicated Mode C section exercises the historical
///   valuation (market movement, step-on-top, carry-forward, tip=spot).
/// - **Curve**: leading point at `effectiveCutoff` (pre-window value), a
///   before/after step pair per in-window transaction, trailing point at
///   `now` = the latest transaction-derived value (never a snapshot).
/// - **Edges**: no tx → empty; no in-window tx → flat at the pre-window
///   level; a window whose first event is a receive starts at 0;
///   self-transfers net out; failed excluded, pending included.
struct BalanceHistoryReconstructorTests {

    static let usdtChecksummed = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
    static let usdtLowercased = "0xdac17f958d2ee523a2206206994597c13d831ec7"

    /// Spot of 1.0 for every test symbol → fiat == quantity, so assertions
    /// read as the holdings ledger.
    static let unitPrices: [String: Decimal] = ["USDT": 1, "ETH": 1, "BTC": 1]

    @MainActor
    static func makeTx(
        symbol: String,
        contract: String?,
        amount: String,
        direction: TransactionDirection,
        at: Date,
        status: TransactionStatus = .confirmed,
        counterparty: String = "0xcounterparty"
    ) -> TransactionRecord {
        TransactionRecord(
            txHash: UUID().uuidString,
            direction: direction,
            amountRaw: amount,
            tokenSymbol: symbol,
            tokenContract: contract,
            occurredAt: at,
            status: status,
            counterparty: counterparty
        )
    }

    /// The distinct value progression of a curve (collapses the flat runs a
    /// step function emits), so a test can assert the ledger's shape without
    /// pinning the exact ±1 ms point count.
    static func valueProgression(_ points: [BalancePoint]) -> [Decimal] {
        var out: [Decimal] = []
        for p in points where out.last != p.fiat { out.append(p.fiat) }
        return out
    }

    // MARK: - Quantity correctness (ledger)

    @Test("Four USDT receives (12,10,500,300) step 12→22→522→822; trimmed to the first tx, starts at the first held balance")
    @MainActor
    func fourReceivesStepUp() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "12", direction: .incoming, at: now.addingTimeInterval(-4 * 3_600)),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "10", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "500", direction: .incoming, at: now.addingTimeInterval(-2 * 3_600)),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "300", direction: .incoming, at: now.addingTimeInterval(-1 * 3_600)),
        ]
        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .all, now: now
        )
        // FIX 2 trims to the first transaction; FIX 1a samples holdings as-of
        // each instant — so the curve starts at the first held balance (12).
        #expect(points.first?.fiat == Decimal(12), "trimmed to first tx → starts at the first held balance")
        #expect(points.last?.fiat == Decimal(822))
        #expect(Self.valueProgression(points) == [12, 22, 522, 822])
    }

    @Test("Mixed in/out steps the running balance exactly")
    @MainActor
    func mixedInOut() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "5", direction: .incoming, at: now.addingTimeInterval(-5 * 3_600)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "2", direction: .outgoing, at: now.addingTimeInterval(-4 * 3_600)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "10", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "3", direction: .outgoing, at: now.addingTimeInterval(-2 * 3_600)),
        ]
        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .all, now: now
        )
        // Trimmed to the first tx → starts at the first held balance: 5 → 3 → 13 → 10.
        #expect(Self.valueProgression(points) == [5, 3, 13, 10])
        #expect(points.last?.fiat == Decimal(10))
    }

    @Test("Outgoing below zero clamps to zero (unrecorded pre-history)")
    @MainActor
    func clampNegative() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "1", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "5", direction: .outgoing, at: now.addingTimeInterval(-2 * 3_600)),
        ]
        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .all, now: now
        )
        #expect(points.allSatisfy { $0.fiat >= 0 })
        #expect(points.last?.fiat == Decimal(0))
    }

    // MARK: - Self-transfers net out; failed excluded; pending included

    @Test("A self-transfer (counterparty is an own address) moves nothing")
    @MainActor
    func selfTransferNetsOut() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let own = "0xMyOtherAddress"
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "4", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            // Self-send to another of the wallet's own addresses — excluded.
            Self.makeTx(symbol: "ETH", contract: nil, amount: "4", direction: .outgoing, at: now.addingTimeInterval(-2 * 3_600), counterparty: own),
        ]
        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices,
            ownAddresses: [own.lowercased()], range: .all, now: now
        )
        // Only the receive counts → flat at 4 across the self-send.
        #expect(points.last?.fiat == Decimal(4))
        #expect(Self.valueProgression(points) == [4])
    }

    @Test("Failed transactions are excluded; pending are included")
    @MainActor
    func failedExcludedPendingIncluded() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "3", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "99", direction: .incoming, at: now.addingTimeInterval(-2 * 3_600), status: .failed),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "2", direction: .incoming, at: now.addingTimeInterval(-1 * 3_600), status: .pending),
        ]
        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .all, now: now
        )
        // 3 (confirmed) + 2 (pending) = 5; the failed 99 never moved anything.
        #expect(points.last?.fiat == Decimal(5))
        #expect(Self.valueProgression(points) == [3, 5])
    }

    // MARK: - Multi-asset total (main-screen Mode B)

    @Test("Multi-asset total sums every token at its spot")
    @MainActor
    func multiAssetTotal() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "2", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: now.addingTimeInterval(-2 * 3_600)),
        ]
        // ETH spot 1000, USDT spot 1 → after both: 2*1000 + 100 = 2100.
        let prices: [String: Decimal] = ["ETH": 1000, "USDT": 1]
        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: prices, range: .all, now: now
        )
        #expect(Self.valueProgression(points) == [2000, 2100])
        #expect(points.last?.fiat == Decimal(2100))
    }

    // MARK: - Range correctness + the pre-window leading anchor

    @Test("Older holdings: a 1H window with no in-window tx is flat at the pre-window held value")
    @MainActor
    func noInWindowFlatAtPreWindow() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // One receive a week ago; nothing in the last hour.
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "7", direction: .incoming, at: now.addingTimeInterval(-7 * 86_400)),
        ]
        let hour = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .hour, now: now
        )
        #expect(hour.count == 2, "no in-window tx → a flat 2-point line")
        #expect(hour.first?.fiat == Decimal(7))
        #expect(hour.last?.fiat == Decimal(7))
        // The flat line spans the trailing hour.
        #expect(abs(hour.first!.timestamp.timeIntervalSince(now.addingTimeInterval(-3_600))) < 1)
        #expect(abs(hour.last!.timestamp.timeIntervalSince(now)) < 1)
    }

    @Test("Older wallet's 1W window leads with the genuine pre-window balance, then steps")
    @MainActor
    func windowLeadsWithPreWindowBalance() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            // Held before the window: 10 from a month ago.
            Self.makeTx(symbol: "ETH", contract: nil, amount: "10", direction: .incoming, at: now.addingTimeInterval(-30 * 86_400)),
            // In-window (this week): +5 three days ago.
            Self.makeTx(symbol: "ETH", contract: nil, amount: "5", direction: .incoming, at: now.addingTimeInterval(-3 * 86_400)),
        ]
        let week = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .week, now: now
        )
        // Leading anchor at the cutoff carries the pre-window 10, then steps to 15.
        #expect(week.first?.fiat == Decimal(10), "1W leads at the real one-week-ago balance")
        #expect(week.last?.fiat == Decimal(15))
        #expect(Self.valueProgression(week) == [10, 15])
        // Leading point sits at the 1-week cutoff (clamped, not the month-ago tx).
        let weekCutoff = now.addingTimeInterval(-7 * 86_400)
        #expect(abs(week.first!.timestamp.timeIntervalSince(weekCutoff)) < 1)
    }

    @Test("Every range produces a window bounded by [effectiveCutoff, now] with the right edge at now")
    @MainActor
    func everyRangeBounds() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Activity spread over a year+: monthly receives.
        var txs: [TransactionRecord] = []
        for m in 1...14 {
            txs.append(Self.makeTx(symbol: "ETH", contract: nil, amount: "1", direction: .incoming, at: now.addingTimeInterval(-Double(m) * 30 * 86_400)))
        }
        for range in BalanceHistoryRange.allCases {
            let pts = BalanceHistoryReconstructor.reconstruct(
                transactions: txs, priceCache: Self.unitPrices, range: range, now: now
            )
            #expect(pts.count >= 2, "\(range) should yield a drawable curve")
            // Right edge is at `now`.
            #expect(abs(pts.last!.timestamp.timeIntervalSince(now)) < 1, "\(range) right edge must be now")
            // No point precedes the effective cutoff.
            let cutoff = max(range.cutoff(from: now), txs.map(\.occurredAt).min()!)
            #expect(pts.first!.timestamp >= cutoff.addingTimeInterval(-1), "\(range) must not lead before its cutoff")
            // Monotonic non-decreasing timestamps.
            #expect(zip(pts, pts.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }, "\(range) timestamps must be ordered")
        }
    }

    // MARK: - Time-proportional spacing

    @Test("Point timestamps are real time — a year gap and an hour gap space proportionally")
    @MainActor
    func timeProportionalSpacing() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // tx A a year before tx B; tx B an hour before now.
        let a = now.addingTimeInterval(-365 * 86_400)
        let b = now.addingTimeInterval(-3_600)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "1", direction: .incoming, at: a),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "1", direction: .incoming, at: b),
        ]
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .all, now: now
        )
        // Renderer fraction = (t − first)/(last − first). The A→B gap must be
        // far wider than the B→now gap (≈365 days vs ≈1 hour).
        let first = pts.first!.timestamp
        let span = pts.last!.timestamp.timeIntervalSince(first)
        let fracB = b.timeIntervalSince(first) / span
        #expect(fracB > 0.99, "the B step should sit far to the right — the year gap dominates the width (got \(fracB))")
    }

    // MARK: - Determinism / right edge

    @Test("Determinism: a spot-price change only rescales the curve, never reshapes it")
    @MainActor
    func priceOnlyRescales() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "2", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "1", direction: .outgoing, at: now.addingTimeInterval(-2 * 3_600)),
        ]
        let p1 = BalanceHistoryReconstructor.reconstruct(transactions: txs, priceCache: ["ETH": 1], range: .all, now: now)
        let p2 = BalanceHistoryReconstructor.reconstruct(transactions: txs, priceCache: ["ETH": 2], range: .all, now: now)
        // Same timestamps (identical shape).
        #expect(p1.map(\.timestamp) == p2.map(\.timestamp))
        // Values are exactly 2× — a pure rescale.
        #expect(zip(p1, p2).allSatisfy { $1.fiat == $0.fiat * 2 })
    }

    @Test("Right edge equals the transaction-derived latest balance")
    @MainActor
    func rightEdgeIsTransactionDerived() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "9", direction: .incoming, at: now.addingTimeInterval(-2 * 3_600)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "4", direction: .outgoing, at: now.addingTimeInterval(-1 * 3_600)),
        ]
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .all, now: now
        )
        // 9 − 4 = 5, valued at spot 1 → 5. No snapshot input exists to snap to.
        #expect(pts.last?.fiat == Decimal(5))
    }

    // MARK: - Empty state

    @Test("No transactions → empty (caller draws the zero baseline)")
    @MainActor
    func noTransactionsEmpty() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for range in BalanceHistoryRange.allCases {
            let pts = BalanceHistoryReconstructor.reconstruct(
                transactions: [], priceCache: Self.unitPrices, range: range, now: now
            )
            #expect(pts.isEmpty, "\(range): no transactions → empty")
        }
    }

    // MARK: - Window trim (FIX 2 — fill the width, converge when history is short)

    @Test("Young wallet (all activity in last 10 days): 1M/1Y/All trim to the first tx and CONVERGE")
    @MainActor
    func youngWalletRangesConverge() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let firstTx = now.addingTimeInterval(-10 * 86_400)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "5", direction: .incoming, at: firstTx),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "5", direction: .incoming, at: now.addingTimeInterval(-3 * 86_400)),
        ]
        func start(_ r: BalanceHistoryRange) -> Date {
            BalanceHistoryReconstructor.reconstruct(transactions: txs, priceCache: Self.unitPrices, range: r, now: now).first!.timestamp
        }
        let month = start(.month), year = start(.year), all = start(.all)
        // FIX 2: a range longer than the wallet's history trims to the first tx
        // and fills the width — so all three start at the first transaction.
        #expect(abs(month.timeIntervalSince(firstTx)) < 1, "1M trims to first tx")
        #expect(abs(year.timeIntervalSince(firstTx)) < 1, "1Y trims to first tx")
        #expect(abs(all.timeIntervalSince(firstTx)) < 1, "All anchors at first tx")
    }

    @Test("Young wallet: a trimmed long range starts at the first HELD balance (not an empty zero lead)")
    @MainActor
    func youngWalletStartsAtFirstHeldBalance() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [Self.makeTx(symbol: "ETH", contract: nil, amount: "8", direction: .incoming, at: now.addingTimeInterval(-3 * 86_400))]
        // 1Y / All trim to the only transaction → no empty lead; the curve
        // starts at the first held balance (8), not a flat-zero stretch.
        for r in [BalanceHistoryRange.year, .all] {
            let pts = BalanceHistoryReconstructor.reconstruct(transactions: txs, priceCache: Self.unitPrices, range: r, now: now)
            #expect(pts.first?.fiat == Decimal(8), "\(r) trims to first tx → starts at the first held balance")
            #expect(pts.last?.fiat == Decimal(8))
        }
    }

    @Test("Older wallet: 1M vs 1Y measure from DIFFERENT baselines → different windowed changes")
    @MainActor
    func olderWalletPerRangeChange() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "100", direction: .incoming, at: now.addingTimeInterval(-2 * 365 * 86_400)), // 2y ago
            Self.makeTx(symbol: "ETH", contract: nil, amount: "200", direction: .incoming, at: now.addingTimeInterval(-180 * 86_400)),      // 6mo ago (in 1Y, pre 1M)
            Self.makeTx(symbol: "ETH", contract: nil, amount: "50", direction: .incoming, at: now.addingTimeInterval(-14 * 86_400)),        // 2w ago (in both)
        ]
        func curve(_ r: BalanceHistoryRange) -> [BalancePoint] {
            BalanceHistoryReconstructor.reconstruct(transactions: txs, priceCache: Self.unitPrices, range: r, now: now)
        }
        let month = curve(.month), year = curve(.year)
        // 1M leads at 300 (100+200 held a month ago) → ends 350: +50.
        #expect(month.first?.fiat == Decimal(300), "1M baseline = pre-month holdings 300")
        #expect(month.last?.fiat == Decimal(350))
        // 1Y leads at 100 (only the 2y-ago receive precedes a year ago) → ends 350: +250.
        #expect(year.first?.fiat == Decimal(100), "1Y baseline = pre-year holdings 100")
        #expect(year.last?.fiat == Decimal(350))
        // The windowed change genuinely differs per range.
        let monthChange = month.last!.fiat - month.first!.fiat
        let yearChange = year.last!.fiat - year.first!.fiat
        #expect(monthChange == Decimal(50) && yearChange == Decimal(250) && monthChange != yearChange)
    }

    // MARK: - Mode C (historical-price valuation)

    /// Build a daily historical-close series for `symbol` spanning `daysBack`
    /// days before `now`, with a per-day value from `close(dayIndex)`.
    static func dailyHistory(symbol: String, now: Date, daysBack: Int, close: (Int) -> Decimal) -> [String: [Int: Decimal]] {
        var series: [Int: Decimal] = [:]
        for d in 0...daysBack {
            let date = now.addingTimeInterval(-Double(d) * 86_400)
            series[DayKey.from(date: date)] = close(d)
        }
        return [symbol: series]
    }

    @Test("Mode C: constant holdings + a varying historical price → the curve MOVES (not flat)")
    @MainActor
    func marketMovementVaries() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // 1 BTC acquired 60 days ago — held constant across the whole 1M window.
        let txs = [Self.makeTx(symbol: "BTC", contract: nil, amount: "1", direction: .incoming, at: now.addingTimeInterval(-60 * 86_400))]
        let history = Self.dailyHistory(symbol: "BTC", now: now, daysBack: 40) { Decimal(100 + $0) } // 100…140
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: ["BTC": 100], priceHistory: history, range: .month, now: now
        )
        let fiats = pts.map(\.fiat)
        #expect(fiats.count >= 3, "1M should sample a daily grid, got \(fiats.count)")
        // The whole point of Mode C: no transactions in the window, yet the
        // value changes day to day with the market.
        #expect(Set(fiats).count > 1, "constant holdings must still move with the market: \(fiats)")
        #expect(fiats.allSatisfy { $0 > 0 })
    }

    @Test("Mode C: a mid-window buy is a visible step ON TOP of the moving curve")
    @MainActor
    func stepOnTopOfCurve() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "BTC", contract: nil, amount: "1", direction: .incoming, at: now.addingTimeInterval(-60 * 86_400)), // pre-window 1 BTC
            Self.makeTx(symbol: "BTC", contract: nil, amount: "1", direction: .incoming, at: now.addingTimeInterval(-15 * 86_400)), // buy → 2 BTC
        ]
        let history = Self.dailyHistory(symbol: "BTC", now: now, daysBack: 40) { Decimal(100 + $0) }
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: ["BTC": 100], priceHistory: history, range: .month, now: now
        )
        // Before the buy holdings are 1 BTC (~100–115); after, 2 BTC (~200–230).
        // The doubling shows as a clear jump in the max vs min positive value.
        let positives = pts.map(\.fiat).filter { $0 > 0 }
        let maxFiat = positives.max() ?? 0
        let minFiat = positives.min() ?? 0
        #expect(maxFiat >= minFiat * Decimal(string: "1.8")!, "the buy must roughly double the curve: min \(minFiat), max \(maxFiat)")
    }

    @Test("Mode C: a missing daily close carries the prior close forward (no zero dip)")
    @MainActor
    func carryForwardNoZeroDip() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [Self.makeTx(symbol: "BTC", contract: nil, amount: "1", direction: .incoming, at: now.addingTimeInterval(-60 * 86_400))]
        // ONE close, 40 days ago (before the 1M window) — the window itself has
        // no closes, so every in-window instant must carry the 500 forward.
        let history = ["BTC": [DayKey.from(date: now.addingTimeInterval(-40 * 86_400)): Decimal(500)]]
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: ["BTC": 999], priceHistory: history, range: .month, now: now
        )
        // Every non-tip point carries 500 (1 BTC × 500); none dip to zero.
        let nonTip = pts.dropLast()
        #expect(!nonTip.isEmpty)
        #expect(nonTip.allSatisfy { $0.fiat == Decimal(500) }, "carry-forward should hold 500: \(nonTip.map(\.fiat))")
        // The tip uses the live spot, not the stale close.
        #expect(pts.last?.fiat == Decimal(999))
    }

    @Test("Mode C: the now tip equals the current spot-valued holdings (matches the hero)")
    @MainActor
    func tipEqualsSpot() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [Self.makeTx(symbol: "ETH", contract: nil, amount: "3", direction: .incoming, at: now.addingTimeInterval(-5 * 86_400))]
        let history = Self.dailyHistory(symbol: "ETH", now: now, daysBack: 10) { _ in Decimal(1500) } // historical 1500
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: ["ETH": 2000], priceHistory: history, range: .week, now: now
        )
        // 3 ETH × 2000 spot = 6000 at the tip, even though history closes were 1500.
        #expect(pts.last?.fiat == Decimal(6000))
    }

    @Test("Mode C: with no historical series, valuation falls back to spot (degrades to Mode B)")
    @MainActor
    func fallbackToSpotWhenNoHistory() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [Self.makeTx(symbol: "ETH", contract: nil, amount: "2", direction: .incoming, at: now.addingTimeInterval(-3 * 86_400))]
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: ["ETH": 1000], priceHistory: [:], range: .week, now: now
        )
        // No history → every point values 2 ETH at spot 1000 → flat at 2000.
        #expect(pts.last?.fiat == Decimal(2000))
        #expect(pts.allSatisfy { $0.fiat == 0 || $0.fiat == Decimal(2000) })
    }

    // MARK: - Key normalization

    @Test("Case-divergent contracts fold to one running quantity")
    @MainActor
    func contractCaseFolds() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Same token, different cased contracts — must not split the ledger.
        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: now.addingTimeInterval(-3 * 3_600)),
            Self.makeTx(symbol: "usdt", contract: Self.usdtChecksummed, amount: "50", direction: .outgoing, at: now.addingTimeInterval(-2 * 3_600)),
        ]
        let pts = BalanceHistoryReconstructor.reconstruct(
            transactions: txs, priceCache: Self.unitPrices, range: .all, now: now
        )
        // 100 − 50 = 50; if the keys had split, the −50 would clamp a separate
        // bucket to 0 and the total would read 100.
        #expect(pts.last?.fiat == Decimal(50))
    }
}
