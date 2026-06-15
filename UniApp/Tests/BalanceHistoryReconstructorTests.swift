import Testing
import Foundation
@testable import Aperture

/// Tests for `BalanceHistoryReconstructor` — the **2026-06-13 forward
/// cumulative walk** rebuild ("transactions as the only truth source").
///
/// The user's repro that drove the rebuild: received 12 USDT, then
/// 10, then 500, then 300 — and NONE of those movements appeared in
/// the chart. Two compounding causes:
///
/// 1. **Key casing mismatch** — `EVMTransactionAdapter` writes
///    `tokenContract` verbatim from the explorer (lowercased), the
///    balance scanner writes the registry's EIP-55 checksummed form.
///    The old un-normalized `(symbol, contract)` key split the same
///    token into two buckets: the walk's quantity deltas landed on an
///    unpriceable key and contributed zero → flat line.
/// 2. **Reverse-walk anchoring** — the old math derived the shape
///    backwards from `currentBalances`, so any key mismatch silently
///    froze the curve at the current total.
///
/// New contract under test:
/// - Forward walk oldest-first from ZERO; +incoming / −outgoing /
///   internal no-op; negatives clamp to zero.
/// - Per range `[cutoff, now]`: leading anchor at cutoff carrying the
///   pre-window cumulative state; a before/after step pair (1 ms
///   backstep) for EVERY in-window transaction; trailing anchor at
///   `now` with the final cumulative state. `.all` leads with the
///   oldest transaction's before-step (state zero).
/// - Valuation ladder per point: priceHistory[symbol][dayKey] →
///   priceCache[symbol] → balance-derived fiatPerUnit — all lookups
///   through normalized keys (symbol uppercased, contract lowercased).
/// - Preserved edges: no txs + no balances → empty; no txs + balances
///   → flat plateau at the cached fiat total; no in-window txs but
///   accumulated state → flat line at that state's value.
struct BalanceHistoryReconstructorTests {

    /// Checksummed (registry / balance-scanner) form of the Ethereum
    /// USDT contract.
    static let usdtChecksummed = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
    /// Lowercased (explorer / transaction-adapter) form of the same
    /// contract.
    static let usdtLowercased = "0xdac17f958d2ee523a2206206994597c13d831ec7"

    @MainActor
    static func makeBalance(
        symbol: String,
        contract: String? = nil,
        rawBalance: String,
        decimals: Int,
        fiatCached: Decimal
    ) -> TokenBalanceRecord {
        TokenBalanceRecord(
            tokenSymbol: symbol,
            tokenContract: contract,
            decimals: decimals,
            rawBalance: rawBalance,
            fiatValueCached: fiatCached
        )
    }

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

    // MARK: - (a) The user's exact repro: four USDT receives step up

    @Test("Four USDT receives (12, 10, 500, 300) step the series 0→12→22→522→822 with a before/after pair per tx")
    @MainActor
    func fourReceivesProduceCumulativeSteps() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-4 * 3_600)
        let t2 = now.addingTimeInterval(-3 * 3_600)
        let t3 = now.addingTimeInterval(-2 * 3_600)
        let t4 = now.addingTimeInterval(-1 * 3_600)

        // Transactions carry the explorer's lowercased contract; the
        // held balance row carries the registry's checksummed form —
        // exactly the on-device divergence.
        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "12", direction: .incoming, at: t1),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "10", direction: .incoming, at: t2),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "500", direction: .incoming, at: t3),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "300", direction: .incoming, at: t4),
        ]
        let balances = [
            Self.makeBalance(
                symbol: "USDT", contract: Self.usdtChecksummed,
                rawBalance: "822000000", decimals: 6, fiatCached: Decimal(822)
            )
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: balances,
            priceCache: priceCache,
            range: .all,
            now: now
        )

        // .all: before/after pair per tx (8) + trailing anchor (1).
        #expect(points.count == 9, "Expected 9 points, got \(points.count): \(points)")

        let fiats = points.map(\.fiat)
        let expected: [Decimal] = [0, 12, 12, 22, 22, 522, 522, 822, 822]
        #expect(
            fiats == expected,
            "Series must step 0→12→22→522→822 with before/after pairs. Got \(fiats)"
        )

        // The step pairs sit at (t − 1 ms, t) per transaction.
        #expect(points[0].timestamp == t1.addingTimeInterval(-0.001))
        #expect(points[1].timestamp == t1)
        #expect(points[7].timestamp == t4)
        // Trailing anchor at now — reconciled to the real current balance
        // ($822), which here equals the cumulative-transaction total ($822).
        #expect(points[8].timestamp == now)
        #expect(points[8].fiat == Decimal(822))
    }

    // MARK: - (b) Range windowing

    @Test("A tx 3 days ago appears in 1W but not 1D; 1D's leading anchor carries the pre-window cumulative value")
    @MainActor
    func rangeWindowingHonorsCutoffAndPreWindowState() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!

        let txs = [
            Self.makeTx(symbol: "FOO", contract: "0xfeed", amount: "100", direction: .incoming, at: threeDaysAgo)
        ]
        let priceCache: [String: Decimal] = ["FOO": Decimal(1)]

        // 1W — the receive is in-window: leading anchor at zero, then
        // the 0→100 step, then the trailing anchor at 100.
        let week = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            range: .week,
            now: now
        )
        #expect(week.count == 4, "1W: anchor + step pair + trailing. Got \(week)")
        #expect(week.map(\.fiat) == [0, 0, 100, 100], "1W series must show the up-step. Got \(week.map(\.fiat))")
        #expect(week.first?.timestamp == BalanceHistoryRange.week.cutoff(from: now))

        // 1D — the receive is BEFORE the window: flat line at the
        // pre-window cumulative value (100) across the whole day.
        let day = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            range: .day,
            now: now
        )
        #expect(day.count == 2, "1D: leading + trailing anchors only. Got \(day)")
        #expect(
            day.map(\.fiat) == [100, 100],
            "1D's leading anchor must carry the pre-window cumulative value. Got \(day.map(\.fiat))"
        )
        #expect(day.first?.timestamp == BalanceHistoryRange.day.cutoff(from: now))
        #expect(day.last?.timestamp == now)
    }

    // MARK: - (c) Outgoing steps go down

    @Test("An outgoing transaction steps the series DOWN")
    @MainActor
    func outgoingStepsDown() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-2 * 3_600)
        let t2 = now.addingTimeInterval(-1 * 3_600)

        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: t1),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "40", direction: .outgoing, at: t2),
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            range: .all,
            now: now
        )

        let fiats = points.map(\.fiat)
        #expect(
            fiats == [0, 100, 100, 60, 60],
            "Send of 40 must step 100 down to 60. Got \(fiats)"
        )
    }

    // MARK: - (d) Key normalization across writer casings

    @Test("Checksummed tx contract vs lowercased balance row still prices via the balance-derived rung")
    @MainActor
    func keyNormalizationBridgesContractCasing() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-3_600)

        // Inverted casing vs test (a): the TX carries the checksummed
        // form, the balance row the lowercased one. No priceCache and
        // no priceHistory — the ONLY price source is the balance-
        // derived fiatPerUnit (100 units ÷ $100 = $1/unit), which is
        // reachable only if the normalized keys match. Symbol casing
        // diverges too (usdt vs USDT).
        let txs = [
            Self.makeTx(symbol: "usdt", contract: Self.usdtChecksummed, amount: "100", direction: .incoming, at: t1)
        ]
        let balances = [
            Self.makeBalance(
                symbol: "USDT", contract: Self.usdtLowercased,
                rawBalance: "100000000", decimals: 6, fiatCached: Decimal(100)
            )
        ]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: balances,
            priceCache: [:],
            priceHistory: [:],
            range: .all,
            now: now
        )

        let fiats = points.map(\.fiat)
        #expect(
            fiats == [0, 100, 100],
            "Casing-mismatched keys must still price the step (the invisible-USDT bug). Got \(fiats)"
        )
    }

    // MARK: - (e) Zero-transaction behaviors

    @Test("Zero transactions + non-zero balances renders a flat plateau at the cached fiat total")
    @MainActor
    func zeroTxFlatLineAtBalanceTotal() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ethBalance = Self.makeBalance(
            symbol: "ETH", rawBalance: "1000000000000000000",
            decimals: 18, fiatCached: Decimal(3000)
        )

        for range in BalanceHistoryRange.allCases {
            let points = BalanceHistoryReconstructor.reconstruct(
                transactions: [],
                currentBalances: [ethBalance],
                range: range,
                now: now
            )
            #expect(points.count == 2, "\(range): flat plateau is exactly 2 anchors. Got \(points)")
            #expect(
                points.allSatisfy { $0.fiat == Decimal(3000) },
                "\(range): plateau must sit at the cached $3,000. Got \(points.map(\.fiat))"
            )
            #expect(points.last?.timestamp == now)
        }
    }

    @Test("Zero transactions + zero balances returns the empty state")
    @MainActor
    func zeroEverythingIsEmpty() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: [],
            currentBalances: [],
            range: .all,
            now: now
        )
        #expect(points.isEmpty, "No history + no balances → empty (caller draws the zero baseline). Got \(points)")
    }

    // MARK: - Supporting behaviors

    @Test("Failed transactions never shape the curve")
    @MainActor
    func failedTransactionsAreIgnored() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-2 * 3_600)
        let t2 = now.addingTimeInterval(-1 * 3_600)

        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: t1),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "999", direction: .incoming, at: t2, status: .failed),
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            range: .all,
            now: now
        )
        #expect(
            points.map(\.fiat) == [0, 100, 100],
            "The failed 999 receive must not appear. Got \(points.map(\.fiat))"
        )
    }

    @Test("Historical closes value past points at their then-price")
    @MainActor
    func priceHistoryValuesPointsAtThenPrice() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let cal = Calendar(identifier: .gregorian)
        let yearAgo = cal.date(byAdding: .month, value: -12, to: now)!
        let yearAgoDayKey = DayKey.from(date: yearAgo)
        let todayDayKey = DayKey.from(date: now)

        // Received 1000 FOO a year ago at $4; today FOO trades at $0.05.
        let txs = [
            Self.makeTx(symbol: "FOO", contract: "0xfeed", amount: "1000", direction: .incoming, at: yearAgo)
        ]
        let priceHistory: [String: [Int: Decimal]] = [
            "FOO": [yearAgoDayKey: Decimal(4), todayDayKey: Decimal(string: "0.05")!]
        ]
        let priceCache: [String: Decimal] = ["FOO": Decimal(string: "0.05")!]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            priceHistory: priceHistory,
            range: .all,
            now: now
        )

        // Step pair at the receive values at the THEN-price ($4000);
        // the trailing anchor values at today's price ($50).
        let maxFiat = points.map(\.fiat).max() ?? .zero
        #expect(maxFiat == Decimal(4000), "Receive moment must value at the $4 then-price. Got \(maxFiat)")
        #expect(points.last?.fiat == Decimal(50), "Trailing anchor must value at today's $0.05. Got \(String(describing: points.last?.fiat))")
    }

    @Test("Negative residue clamps to zero — a send larger than recorded history never draws below zero")
    @MainActor
    func negativeResidueClampsToZero() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-2 * 3_600)
        let t2 = now.addingTimeInterval(-1 * 3_600)

        // History only captured 50 in, but 80 went out (pre-import
        // activity the explorer never reported).
        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "50", direction: .incoming, at: t1),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "80", direction: .outgoing, at: t2),
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            range: .all,
            now: now
        )
        #expect(
            points.map(\.fiat) == [0, 50, 50, 0, 0],
            "Over-send must clamp to zero, never negative. Got \(points.map(\.fiat))"
        )
        #expect(points.allSatisfy { $0.fiat >= 0 })
    }

    @Test("Internal transfers appear as flat step pairs — no quantity change")
    @MainActor
    func internalTransfersAreFlat() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-2 * 3_600)
        let t2 = now.addingTimeInterval(-1 * 3_600)

        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: t1),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .internal, at: t2),
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            range: .all,
            now: now
        )
        #expect(
            points.map(\.fiat) == [0, 100, 100, 100, 100],
            "Internal shuffle is a wallet-wide no-op. Got \(points.map(\.fiat))"
        )
    }

    // MARK: - (f) Self-transfers via the ownAddresses filter (2026-06-16)

    @Test("A send to / receive from one of the wallet's OWN addresses moves nothing on any range")
    @MainActor
    func selfTransferToOwnAddressMovesNothing() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-3 * 3_600)
        let t2 = now.addingTimeInterval(-2 * 3_600)
        let t3 = now.addingTimeInterval(-1 * 3_600)

        let ownB = "0xOWNADDRESSB"
        // A genuine receive (real third party), then a self-shuffle out to
        // the wallet's own address B, then a matching receive at B from the
        // same own address. The two self legs must drop entirely — the
        // curve must read identically to "only the 100 receive happened".
        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: t1),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "40", direction: .outgoing, at: t2, counterparty: ownB),
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "40", direction: .incoming, at: t3, counterparty: ownB),
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]
        let own: Set<String> = [ownB.lowercased()]

        for range in BalanceHistoryRange.allCases where range != .hour {
            let points = BalanceHistoryReconstructor.reconstruct(
                transactions: txs,
                currentBalances: [],
                priceCache: priceCache,
                ownAddresses: own,
                range: range,
                now: now
            )
            // Only the genuine 100 receive shapes the curve; both self legs
            // are filtered out, so the peak is 100 and the trailing edge
            // (no real balance ⇒ tx-state fallback) is 100, never 60 or 140.
            #expect(
                points.last?.fiat == Decimal(100),
                "\(range): self-transfer legs must not move the trailing edge. Got \(String(describing: points.last?.fiat))"
            )
            #expect(
                points.allSatisfy { $0.fiat == 0 || $0.fiat == 100 },
                "\(range): the curve must only ever be 0 or 100 — the self legs vanish. Got \(points.map(\.fiat))"
            )
        }
    }

    @Test("A classified-.internal self-send (empty counterparty) moves nothing — both exclusion mechanisms agree")
    @MainActor
    func internalSelfSendWithEmptyCounterpartyMovesNothing() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-2 * 3_600)
        let t2 = now.addingTimeInterval(-1 * 3_600)

        // This is the shape the BTC adapter writes for the user's
        // d258f57f… self-send: direction = .internal, counterparty = "".
        // The empty counterparty passes the ownAddresses filter, and the
        // .internal direction makes `apply` a no-op — so the curve is flat.
        let txs = [
            Self.makeTx(symbol: "BTC", contract: nil, amount: "1", direction: .incoming, at: t1),
            Self.makeTx(symbol: "BTC", contract: nil, amount: "1", direction: .internal, at: t2, counterparty: ""),
        ]
        let priceCache: [String: Decimal] = ["BTC": Decimal(60_000)]
        // ownAddresses present but irrelevant — counterparty is empty.
        let own: Set<String> = ["bc1qexample"]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            ownAddresses: own,
            range: .all,
            now: now
        )
        #expect(
            points.map(\.fiat) == [0, 60_000, 60_000, 60_000, 60_000],
            "The .internal self-send must not dip or spike the curve. Got \(points.map(\.fiat))"
        )
    }

    // MARK: - (g) 1H is a real 1-hour window (2026-06-16)

    @Test("1H windows the last hour: a tx 2 hours ago is pre-window; a tx 30 min ago is in-window")
    @MainActor
    func hourRangeIsRealOneHourWindow() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let twoHoursAgo = now.addingTimeInterval(-2 * 3_600)
        let halfHourAgo = now.addingTimeInterval(-30 * 60)

        let txs = [
            // Pre-window: a 100 receive two hours ago (before the 1H cutoff).
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: twoHoursAgo),
            // In-window: a 25 receive half an hour ago.
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "25", direction: .incoming, at: halfHourAgo),
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: [],
            priceCache: priceCache,
            range: .hour,
            now: now
        )
        // 1H: leading anchor at cutoff carrying the pre-window 100, then the
        // 100→125 step pair for the in-window receive, then trailing at 125.
        #expect(points.map(\.fiat) == [100, 100, 125, 125], "1H must window the last hour. Got \(points.map(\.fiat))")
        #expect(points.first?.timestamp == BalanceHistoryRange.hour.cutoff(from: now))
        #expect(points.last?.timestamp == now)
        // The cutoff is exactly 3600 s before now.
        #expect(BalanceHistoryRange.hour.cutoff(from: now) == now.addingTimeInterval(-3_600))
    }

    @Test("1H with no transactions in the last hour draws a FLAT line at the current balance with 0% change")
    @MainActor
    func hourRangeFlatWhenNoRecentActivity() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let yesterday = now.addingTimeInterval(-26 * 3_600)

        // The only activity is a receive 26 hours ago — nothing in the last
        // hour. The honest result is a flat line at the real current balance.
        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "500", direction: .incoming, at: yesterday)
        ]
        let balances = [
            Self.makeBalance(
                symbol: "USDT", contract: Self.usdtChecksummed,
                rawBalance: "500000000", decimals: 6, fiatCached: Decimal(500)
            )
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: balances,
            priceCache: priceCache,
            range: .hour,
            now: now
        )
        #expect(points.count == 2, "1H flat case is exactly 2 anchors. Got \(points)")
        #expect(points.map(\.fiat) == [500, 500], "Flat at the current balance, 0% change. Got \(points.map(\.fiat))")
        #expect(points.first?.timestamp == BalanceHistoryRange.hour.cutoff(from: now))
        #expect(points.last?.timestamp == now)
    }

    // MARK: - (h) Trailing edge is reconciled to the real current balance

    @Test("points.last equals the real current balance fiat (hero) even when tx history is incomplete")
    @MainActor
    func trailingEdgeReconcilesToHeroBalance() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let t1 = now.addingTimeInterval(-3 * 3_600)

        // Transactions only captured a 100 receive (pre-import activity left
        // the wallet holding MORE than the recorded history implies). The
        // real balance scan says the wallet is worth $300. The chart's right
        // edge must equal $300 (the hero), NOT the $100 tx-cumulative total.
        let txs = [
            Self.makeTx(symbol: "USDT", contract: Self.usdtLowercased, amount: "100", direction: .incoming, at: t1)
        ]
        let balances = [
            Self.makeBalance(
                symbol: "USDT", contract: Self.usdtChecksummed,
                rawBalance: "300000000", decimals: 6, fiatCached: Decimal(300)
            )
        ]
        let priceCache: [String: Decimal] = ["USDT": Decimal(1)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: txs,
            currentBalances: balances,
            priceCache: priceCache,
            range: .all,
            now: now
        )
        #expect(
            points.last?.fiat == Decimal(300),
            "Trailing edge must equal the real $300 hero balance, not the $100 tx total. Got \(String(describing: points.last?.fiat))"
        )
        // The interior shape is still transaction-driven: the receive step
        // is present at $100 before the final reconciliation jump.
        let fiats = points.map(\.fiat)
        #expect(fiats.contains(Decimal(100)), "The interior 100 receive step must still be present. Got \(fiats)")
    }
}
