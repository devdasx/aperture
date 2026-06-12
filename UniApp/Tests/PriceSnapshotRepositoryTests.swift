import Testing
import Foundation
import SwiftData
@testable import Aperture

/// `PriceSnapshotRepository` contract tests against an in-memory
/// SwiftData store:
///
/// 1. `record` appends observations; `latest` returns the newest.
/// 2. `change24h` math — absolute and percent against the ~24h-ago
///    reference, including the ±2 h window edges, the
///    nearest-neighbor selection, the tie rule, and the honest-nil
///    conditions (no reference, stale current, zero reference).
/// 3. `prune` keeps the 48 h raw window verbatim and decimates older
///    rows to the last observation per (symbol, currency, day).
@Suite struct PriceSnapshotRepositoryTests {

    /// Fresh repository over a fresh in-memory store per test —
    /// no shared state, no disk.
    private func makeRepository() throws -> PriceSnapshotRepository {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: PriceSnapshotRecord.self, configurations: config)
        return PriceSnapshotRepository(modelContainer: container)
    }

    // MARK: - Record / latest

    @Test("latest returns the newest observation, not the first")
    func latestReturnsNewest() async throws {
        let repo = try makeRepository()
        let now = Date()
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now.addingTimeInterval(-3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 110, source: "coinbase")],
            at: now
        )
        let latest = try await repo.latest(symbol: "BTC", currency: "USD")
        #expect(latest?.price == 110)
        #expect(latest?.fetchedAt == now)
    }

    @Test("latest is nil for a pair that was never recorded")
    func latestNilWhenEmpty() async throws {
        let repo = try makeRepository()
        let latest = try await repo.latest(symbol: "BTC", currency: "USD")
        #expect(latest == nil)
    }

    @Test("symbol and currency are case-normalized on write and read")
    func casingNormalized() async throws {
        let repo = try makeRepository()
        try await repo.record(
            [(symbol: "btc", currencyCode: "usd", price: 100, source: "coinbase")],
            at: Date()
        )
        let upper = try await repo.latest(symbol: "BTC", currency: "USD")
        let lower = try await repo.latest(symbol: "btc", currency: "usd")
        #expect(upper?.price == 100)
        #expect(lower?.price == 100)
    }

    @Test("currency series are independent — USD and EUR never mix")
    func currencyIsolation() async throws {
        let repo = try makeRepository()
        let now = Date()
        try await repo.record(
            [
                (symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase"),
                (symbol: "BTC", currencyCode: "EUR", price: 90, source: "coinbase")
            ],
            at: now
        )
        let usd = try await repo.latest(symbol: "BTC", currency: "USD")
        let eur = try await repo.latest(symbol: "BTC", currency: "EUR")
        #expect(usd?.price == 100)
        #expect(eur?.price == 90)
    }

    // MARK: - 24h change math

    @Test("change24h: 100 → 110 over 24h is +10 absolute, +10 percent")
    func change24hMath() async throws {
        let repo = try makeRepository()
        let now = Date()
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now.addingTimeInterval(-24 * 3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 110, source: "coinbase")],
            at: now
        )
        let change = try await repo.change24h(symbol: "BTC", currency: "USD", now: now)
        let unwrapped = try #require(change)
        #expect(unwrapped.absolute == 10)
        #expect(unwrapped.percent == 10)
        #expect(unwrapped.currentPrice == 110)
        #expect(unwrapped.referencePrice == 100)
    }

    @Test("change24h handles a price drop with negative absolute and percent")
    func change24hNegative() async throws {
        let repo = try makeRepository()
        let now = Date()
        try await repo.record(
            [(symbol: "ETH", currencyCode: "USD", price: 200, source: "coinbase")],
            at: now.addingTimeInterval(-24 * 3600)
        )
        try await repo.record(
            [(symbol: "ETH", currencyCode: "USD", price: 150, source: "coinbase")],
            at: now
        )
        let change = try await repo.change24h(symbol: "ETH", currency: "USD", now: now)
        let unwrapped = try #require(change)
        #expect(unwrapped.absolute == -50)
        #expect(unwrapped.percent == -25)
    }

    @Test("nearest-neighbor: the candidate closest to the -24h target wins")
    func nearestNeighborPicksClosest() async throws {
        let repo = try makeRepository()
        let now = Date()
        // 25h ago (1h from target) vs 23h30m ago (30m from target).
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 80, source: "coinbase")],
            at: now.addingTimeInterval(-25 * 3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 90, source: "coinbase")],
            at: now.addingTimeInterval(-23 * 3600 - 1800)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now
        )
        let change = try await repo.change24h(symbol: "BTC", currency: "USD", now: now)
        let unwrapped = try #require(change)
        #expect(unwrapped.referencePrice == 90)
    }

    @Test("nearest-neighbor tie resolves to the earlier snapshot")
    func nearestNeighborTieBreaksEarlier() async throws {
        let repo = try makeRepository()
        let now = Date()
        // Both exactly 1h from the -24h target.
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 80, source: "coinbase")],
            at: now.addingTimeInterval(-25 * 3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 90, source: "coinbase")],
            at: now.addingTimeInterval(-23 * 3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now
        )
        let change = try await repo.change24h(symbol: "BTC", currency: "USD", now: now)
        let unwrapped = try #require(change)
        #expect(unwrapped.referencePrice == 80)
    }

    // MARK: - 24h change window edges

    @Test("a reference just inside the 26h edge resolves")
    func referenceInsideWindowEdge() async throws {
        let repo = try makeRepository()
        let now = Date()
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now.addingTimeInterval(-26 * 3600 + 1)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 110, source: "coinbase")],
            at: now
        )
        let change = try await repo.change24h(symbol: "BTC", currency: "USD", now: now)
        #expect(change != nil)
    }

    @Test("a reference just outside the 26h edge returns nil — no honest 24h answer")
    func referenceOutsideWindowEdge() async throws {
        let repo = try makeRepository()
        let now = Date()
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now.addingTimeInterval(-26 * 3600 - 1)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 110, source: "coinbase")],
            at: now
        )
        let change = try await repo.change24h(symbol: "BTC", currency: "USD", now: now)
        #expect(change == nil)
    }

    @Test("a current price older than 22h returns nil — too stale to call 'now'")
    func staleCurrentReturnsNil() async throws {
        let repo = try makeRepository()
        let now = Date()
        // Only observation sits inside the reference window — it would
        // be both 'current' and 'reference'. The repository refuses.
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now.addingTimeInterval(-23 * 3600)
        )
        let change = try await repo.change24h(symbol: "BTC", currency: "USD", now: now)
        #expect(change == nil)
    }

    @Test("a zero reference price returns nil — never divide by zero")
    func zeroReferenceReturnsNil() async throws {
        let repo = try makeRepository()
        let now = Date()
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 0, source: "coinbase")],
            at: now.addingTimeInterval(-24 * 3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 110, source: "coinbase")],
            at: now
        )
        let change = try await repo.change24h(symbol: "BTC", currency: "USD", now: now)
        #expect(change == nil)
    }

    // MARK: - Pruning

    @Test("prune decimates rows older than 48h to the last observation per day")
    func pruneDecimatesOldDays() async throws {
        let repo = try makeRepository()
        let now = Date()
        let calendar = Calendar.current
        let oldDayStart = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -4, to: now) ?? now
        )
        // Three observations on one old day — only the 14:00 one (the
        // last of the day) must survive decimation.
        for (hour, price) in [(10, Decimal(100)), (12, Decimal(105)), (14, Decimal(108))] {
            try await repo.record(
                [(symbol: "BTC", currencyCode: "USD", price: price, source: "coinbase")],
                at: oldDayStart.addingTimeInterval(TimeInterval(hour) * 3600)
            )
        }
        // A fresh record triggers prune(now:) over the old rows.
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 110, source: "coinbase")],
            at: now
        )
        let rows = try await repo.observations(symbol: "BTC", currency: "USD")
        #expect(rows.count == 2, "one decimated old-day row + the fresh row")
        #expect(rows.first?.price == 108, "the LAST observation of the old day survives")
        #expect(rows.last?.price == 110)
    }

    @Test("prune keeps every row inside the 48h raw window")
    func pruneKeepsRawWindow() async throws {
        let repo = try makeRepository()
        let now = Date()
        // Two same-day-ish observations within 48h — both must survive
        // even though decimation would collapse them if they were old.
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase")],
            at: now.addingTimeInterval(-47 * 3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 105, source: "coinbase")],
            at: now.addingTimeInterval(-46 * 3600)
        )
        try await repo.record(
            [(symbol: "BTC", currencyCode: "USD", price: 110, source: "coinbase")],
            at: now
        )
        let rows = try await repo.observations(symbol: "BTC", currency: "USD")
        #expect(rows.count == 3)
    }

    @Test("deleteAll wipes the table")
    func deleteAllWipes() async throws {
        let repo = try makeRepository()
        try await repo.record(
            [
                (symbol: "BTC", currencyCode: "USD", price: 100, source: "coinbase"),
                (symbol: "ETH", currencyCode: "EUR", price: 90, source: "coingecko")
            ],
            at: Date()
        )
        try await repo.deleteAll()
        let btc = try await repo.latest(symbol: "BTC", currency: "USD")
        let eth = try await repo.latest(symbol: "ETH", currency: "EUR")
        #expect(btc == nil)
        #expect(eth == nil)
    }
}
