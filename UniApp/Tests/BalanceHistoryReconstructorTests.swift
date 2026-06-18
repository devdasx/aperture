import Testing
import Foundation
@testable import Aperture

/// Tests for `BalanceHistoryReconstructor` — the **2026-06-19 Mode B
/// rebuild** ("transaction-sourced, deterministic, real for every range").
///
/// Contract under test:
/// - **Holdings ledger** is a pure function of transactions: forward walk
///   oldest-first from ZERO, `+incoming / −outgoing / internal-no-op`,
///   negatives clamp to zero.
/// - **Valuation (Mode B)**: `y = Σ quantity × current spot`. Using a spot
///   of 1 makes the curve's fiat equal the quantity, so these tests assert
///   the ledger directly; a non-1 spot only rescales (determinism test).
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

    @Test("Four USDT receives (12,10,500,300) step 0→12→22→522→822; first event is a receive so it starts at 0")
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
        #expect(points.first?.fiat == 0, "first event is a receive → true pre-state is 0")
        #expect(points.last?.fiat == Decimal(822))
        #expect(Self.valueProgression(points) == [0, 12, 22, 522, 822])
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
        // 0 (pre-state) → 5 → 3 → 13 → 10.
        #expect(Self.valueProgression(points) == [0, 5, 3, 13, 10])
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
        #expect(Self.valueProgression(points) == [0, 4])
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
        #expect(Self.valueProgression(points) == [0, 3, 5])
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
        #expect(Self.valueProgression(points) == [0, 2000, 2100])
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

    // MARK: - Range distinctness (Bug 3 — 1M ≠ 1Y ≠ All)

    @Test("Young wallet (all activity in last 14 days): 1M, 1Y, All have DISTINCT window starts")
    @MainActor
    func youngWalletRangesDistinct() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [
            Self.makeTx(symbol: "ETH", contract: nil, amount: "5", direction: .incoming, at: now.addingTimeInterval(-10 * 86_400)),
            Self.makeTx(symbol: "ETH", contract: nil, amount: "5", direction: .incoming, at: now.addingTimeInterval(-3 * 86_400)),
        ]
        func start(_ r: BalanceHistoryRange) -> Date {
            BalanceHistoryReconstructor.reconstruct(transactions: txs, priceCache: Self.unitPrices, range: r, now: now).first!.timestamp
        }
        let month = start(.month), year = start(.year), all = start(.all)
        // The old `max(cutoff, firstTx)` clamp made all three equal (firstTx).
        // Now they are genuinely different windows.
        #expect(month != year && year != all && month != all, "1M/1Y/All windows must differ (got \(month), \(year), \(all))")
        // All anchors to the first transaction (10 days ago); 1Y/1M lead earlier.
        #expect(abs(all.timeIntervalSince(now.addingTimeInterval(-10 * 86_400))) < 1)
        #expect(year < month, "1Y starts before 1M")
        #expect(month < all, "1M starts before the first tx (flat-zero lead)")
    }

    @Test("Young wallet: a long range starts at a ZERO baseline (funded during the window)")
    @MainActor
    func youngWalletZeroBaseline() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let txs = [Self.makeTx(symbol: "ETH", contract: nil, amount: "8", direction: .incoming, at: now.addingTimeInterval(-3 * 86_400))]
        // 1Y / All both predate (or meet) the only transaction → baseline 0,
        // which drives the pill's percent-suppression (Bug 4).
        for r in [BalanceHistoryRange.year, .all] {
            let pts = BalanceHistoryReconstructor.reconstruct(transactions: txs, priceCache: Self.unitPrices, range: r, now: now)
            #expect(pts.first?.fiat == 0, "\(r) on a young wallet must start at a zero baseline")
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
