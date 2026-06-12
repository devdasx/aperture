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
        status: TransactionStatus = .confirmed
    ) -> TransactionRecord {
        TransactionRecord(
            txHash: UUID().uuidString,
            direction: direction,
            amountRaw: amount,
            tokenSymbol: symbol,
            tokenContract: contract,
            occurredAt: at,
            status: status,
            counterparty: "0xcounterparty"
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
        // Trailing anchor at now, at the cumulative-transaction total.
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
}
