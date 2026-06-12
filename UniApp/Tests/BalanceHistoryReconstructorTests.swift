import Testing
import Foundation
@testable import Aperture

/// Tests for `BalanceHistoryReconstructor` — particularly the
/// **2026-06-12 cashed-out fallback** that fixed the USDT-flat-chart
/// bug reported by the user.
///
/// The bug: a user received 747 USDT then sent every unit. Current
/// balance for USDT was 0 → no row in `currentBalances` →
/// `fiatPerUnit` had no entry for USDT → the historical receive
/// (which the reverse-walk correctly built up to 747 in `running`)
/// contributed zero fiat to the chart point. Result: flat-zero line
/// for an asset with real activity.
///
/// The fix: a `priceCache` parameter keyed by uppercased symbol.
/// When a token appears in `transactions` but not in
/// `currentBalances`, the reconstructor pulls a current spot price
/// from the cache and values past holdings against it.
struct BalanceHistoryReconstructorTests {

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
        at: Date
    ) -> TransactionRecord {
        TransactionRecord(
            txHash: UUID().uuidString,
            direction: direction,
            amountRaw: amount,
            tokenSymbol: symbol,
            tokenContract: contract,
            occurredAt: at,
            status: .confirmed,
            counterparty: "0xcounterparty"
        )
    }

    // MARK: - The bug case: USDT received then fully sent

    @Test("Cashed-out USDT renders non-zero historical fiat when priceCache supplied")
    @MainActor
    func cashedOutUSDTWithPriceCache() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        // Wallet currently holds 0 USDT (cashed out).
        let currentBalances: [TokenBalanceRecord] = []

        // History: received 747 then sent 747.
        let usdtContract = "0xdac17f958d2ee523a2206206994597c13d831ec7"
        let received = Self.makeTx(
            symbol: "USDT", contract: usdtContract, amount: "747.650991",
            direction: .incoming, at: twoDaysAgo
        )
        let sent = Self.makeTx(
            symbol: "USDT", contract: usdtContract, amount: "747.650991",
            direction: .outgoing, at: oneDayAgo
        )

        let priceCache: [String: Decimal] = ["USDT": Decimal(1.0)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: [received, sent],
            currentBalances: currentBalances,
            priceCache: priceCache,
            range: .all,
            now: now
        )

        let maxFiat = points.map(\.fiat).max() ?? .zero
        #expect(
            maxFiat > 0,
            "Cashed-out USDT chart should have non-zero historical fiat (received 747 USDT). Got points: \(points)"
        )

        // The receive moment should value at ~747 USDT × 1.0 USD = 747.
        #expect(
            maxFiat >= Decimal(700),
            "Maximum fiat should be ~$747 (747 USDT × $1.0), got \(maxFiat)"
        )
    }

    @Test("Without priceCache, cashed-out token reproduces the original flat-zero bug — regression guard")
    @MainActor
    func cashedOutUSDTWithoutPriceCacheReproducesBug() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        let received = Self.makeTx(symbol: "USDT", contract: "0xdac17f958d2ee523a2206206994597c13d831ec7",
                                   amount: "747", direction: .incoming, at: twoDaysAgo)
        let sent = Self.makeTx(symbol: "USDT", contract: "0xdac17f958d2ee523a2206206994597c13d831ec7",
                               amount: "747", direction: .outgoing, at: oneDayAgo)

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: [received, sent],
            currentBalances: [],
            priceCache: [:],  // empty — old behavior
            range: .all,
            now: now
        )

        let maxFiat = points.map(\.fiat).max() ?? .zero
        #expect(
            maxFiat == 0,
            "Without priceCache, all points should be zero — confirms the bug shape exists when fallback is empty. Got max \(maxFiat)"
        )
    }

    // MARK: - Mixed held + cashed-out

    @Test("Currently-held token + cashed-out token both contribute to history")
    @MainActor
    func mixedHeldAndCashedOut() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let oneDayAgo = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        // Holding 1 ETH currently, fiat $3,000.
        let ethBalance = Self.makeBalance(
            symbol: "ETH",
            rawBalance: "1000000000000000000",  // 1 ETH in wei
            decimals: 18,
            fiatCached: Decimal(3000)
        )

        // Past USDT activity, 0 held now.
        let usdtSent = Self.makeTx(symbol: "USDT", contract: "0xdac17f958d2ee523a2206206994597c13d831ec7",
                                   amount: "500", direction: .outgoing, at: oneDayAgo)

        let priceCache: [String: Decimal] = ["USDT": Decimal(1.0), "ETH": Decimal(3000)]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: [usdtSent],
            currentBalances: [ethBalance],
            priceCache: priceCache,
            range: .all,
            now: now
        )

        let last = points.last
        #expect(last != nil, "Should have at least one point")
        // Trailing edge = ETH × $3,000 = $3,000 (USDT now zero).
        #expect(
            last?.fiat == Decimal(3000),
            "Trailing edge should equal current holdings — got \(String(describing: last?.fiat))"
        )

        // Earlier point should be higher because user had 500 USDT then.
        let maxFiat = points.map(\.fiat).max() ?? .zero
        #expect(
            maxFiat >= Decimal(3400),
            "Historical max should reflect both ETH and USDT (~$3,500). Got \(maxFiat)"
        )
    }

    // MARK: - The user's $4000 → $50 case

    @Test("Historical-price reconstruction shows past peak at then-price, not today's price")
    @MainActor
    func historicalPeakRendersAtThenPrice() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let cal = Calendar(identifier: .gregorian)
        let yearAgo = cal.date(byAdding: .month, value: -12, to: now)!
        let yearAgoDayKey = DayKey.from(date: yearAgo, calendar: cal)

        // User received 1000 tokens 1 year ago.
        let receivedTx = Self.makeTx(
            symbol: "FOO",
            contract: "0xfeeed",
            amount: "1000",
            direction: .incoming,
            at: yearAgo
        )

        // Still holding all 1000 today — but they crashed to $0.05/each.
        let currentBalance = Self.makeBalance(
            symbol: "FOO",
            contract: "0xfeeed",
            rawBalance: "1000000000000000000000",  // 1000 in wei18
            decimals: 18,
            fiatCached: Decimal(50)   // 1000 × $0.05 = $50
        )

        // Today's spot in priceCache.
        let priceCache: [String: Decimal] = ["FOO": Decimal(0.05)]
        // Historical: 1 year ago FOO was $4.
        let priceHistory: [String: [Int: Decimal]] = [
            "FOO": [yearAgoDayKey: Decimal(4)]
        ]

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: [receivedTx],
            currentBalances: [currentBalance],
            priceCache: priceCache,
            priceHistory: priceHistory,
            range: .all,
            now: now
        )

        let maxFiat = points.map(\.fiat).max() ?? .zero
        let lastFiat = points.last?.fiat ?? .zero

        // Trailing edge: 1000 × $0.05 = $50 (current cached fiat).
        #expect(
            lastFiat == Decimal(50),
            "Trailing edge should equal today's $50, got \(lastFiat)"
        )

        // Past peak: 1000 × $4 = $4000 at the receive moment.
        // (Without historical pricing, this would be $50.)
        #expect(
            maxFiat >= Decimal(3500),
            "Past peak should be ~$4000 using historical $4 price. Got \(maxFiat). Points: \(points)"
        )
    }

    @Test("Without priceHistory, chart values everything at today's price (regression guard for the $4000 bug)")
    @MainActor
    func withoutPriceHistoryFlattensToToday() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let cal = Calendar(identifier: .gregorian)
        let yearAgo = cal.date(byAdding: .month, value: -12, to: now)!

        let receivedTx = Self.makeTx(
            symbol: "FOO", contract: "0xfeeed", amount: "1000",
            direction: .incoming, at: yearAgo
        )
        let currentBalance = Self.makeBalance(
            symbol: "FOO", contract: "0xfeeed",
            rawBalance: "1000000000000000000000",
            decimals: 18,
            fiatCached: Decimal(50)
        )

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: [receivedTx],
            currentBalances: [currentBalance],
            priceCache: [:],
            priceHistory: [:],
            range: .all,
            now: now
        )

        let maxFiat = points.map(\.fiat).max() ?? .zero
        // With no historical pricing, all points value at the
        // balance-derived per-unit ($50 / 1000 = $0.05) — so peak
        // = $50, not $4000. Confirms the bug shape without the fix.
        #expect(
            maxFiat <= Decimal(50),
            "Without priceHistory, peak should be capped at today's $50. Got \(maxFiat)"
        )
    }

    @Test("Default empty priceCache preserves prior behavior for held-only wallets")
    @MainActor
    func defaultPriceCacheNoBreakingChange() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        let ethBalance = Self.makeBalance(
            symbol: "ETH", rawBalance: "1000000000000000000",
            decimals: 18, fiatCached: Decimal(3000)
        )

        let points = BalanceHistoryReconstructor.reconstruct(
            transactions: [],
            currentBalances: [ethBalance],
            range: .week,
            now: now
        )

        #expect(points.count >= 2, "Should have a flat-line shape (leading anchor + now)")
        for p in points {
            #expect(p.fiat == Decimal(3000), "Flat-line point should be $3,000 — got \(p.fiat)")
        }
    }
}
