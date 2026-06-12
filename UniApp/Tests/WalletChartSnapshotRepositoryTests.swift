import Testing
import Foundation
import SwiftData
@testable import Aperture

/// `WalletChartSnapshotRepository` contract tests against an in-memory
/// SwiftData store:
///
/// 1. Capture throttle — at most one snapshot per (wallet, currency)
///    per 10 minutes.
/// 2. Series — ascending order, `from:` bound, and strict per-wallet /
///    per-currency isolation (wallet A's series never returns wallet
///    B's rows).
/// 3. `deleteAll(walletId:)` removes exactly one wallet's timeline.
/// 4. Pruning — daily decimation beyond 48h plus the hard row cap
///    (oldest-first eviction).
/// 5. `captureFromPersistedBalances` — sums the wallet's persisted
///    balance rows in the requested currency, with the
///    currency-mismatch honesty guard.
@Suite struct WalletChartSnapshotRepositoryTests {

    private func makeRepository() throws -> WalletChartSnapshotRepository {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: WalletChartSnapshotRecord.self,
            configurations: config
        )
        return WalletChartSnapshotRepository(modelContainer: container)
    }

    /// Container that also carries the wallet graph, for the
    /// `captureFromPersistedBalances` tests.
    private func makeWalletContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: WalletRecord.self,
            WalletAddressRecord.self,
            TransactionRecord.self,
            TokenBalanceRecord.self,
            WalletChartSnapshotRecord.self,
            configurations: config
        )
    }

    // MARK: - Capture throttle

    @Test("capture skips when a snapshot newer than 10 minutes exists")
    func captureThrottle() async throws {
        let repo = try makeRepository()
        let walletId = UUID()
        let t0 = Date()

        let first = try await repo.capture(
            walletId: walletId, currencyCode: "USD", fiatValue: 100, now: t0
        )
        let withinThrottle = try await repo.capture(
            walletId: walletId, currencyCode: "USD", fiatValue: 101, now: t0.addingTimeInterval(5 * 60)
        )
        let afterThrottle = try await repo.capture(
            walletId: walletId, currencyCode: "USD", fiatValue: 102, now: t0.addingTimeInterval(11 * 60)
        )

        #expect(first == true)
        #expect(withinThrottle == false)
        #expect(afterThrottle == true)

        let points = try await repo.series(walletId: walletId, currencyCode: "USD")
        #expect(points.count == 2)
        #expect(points.map(\.fiatValue) == [100, 102])
    }

    @Test("the throttle is per (wallet, currency) — another currency captures immediately")
    func throttleScopedToPair() async throws {
        let repo = try makeRepository()
        let walletId = UUID()
        let t0 = Date()

        try await repo.capture(walletId: walletId, currencyCode: "USD", fiatValue: 100, now: t0)
        let otherCurrency = try await repo.capture(
            walletId: walletId, currencyCode: "EUR", fiatValue: 90, now: t0.addingTimeInterval(60)
        )
        let otherWallet = try await repo.capture(
            walletId: UUID(), currencyCode: "USD", fiatValue: 50, now: t0.addingTimeInterval(60)
        )
        #expect(otherCurrency == true)
        #expect(otherWallet == true)
    }

    // MARK: - Series

    @Test("series returns points oldest-first regardless of insert order")
    func seriesOrderedAscending() async throws {
        let repo = try makeRepository()
        let walletId = UUID()
        let t0 = Date()
        // Insert deliberately out of chronological order via the
        // unthrottled primitive.
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 300, capturedAt: t0.addingTimeInterval(1200))
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 100, capturedAt: t0)
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 200, capturedAt: t0.addingTimeInterval(600))

        let points = try await repo.series(walletId: walletId, currencyCode: "USD")
        #expect(points.map(\.fiatValue) == [100, 200, 300])
    }

    @Test("series honors the from: lower bound (inclusive)")
    func seriesFromBound() async throws {
        let repo = try makeRepository()
        let walletId = UUID()
        let t0 = Date()
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 100, capturedAt: t0)
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 200, capturedAt: t0.addingTimeInterval(600))
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 300, capturedAt: t0.addingTimeInterval(1200))

        let points = try await repo.series(
            walletId: walletId, currencyCode: "USD", from: t0.addingTimeInterval(600)
        )
        #expect(points.map(\.fiatValue) == [200, 300])
    }

    @Test("per-wallet isolation: wallet A's series never returns wallet B's rows")
    func perWalletIsolation() async throws {
        let repo = try makeRepository()
        let walletA = UUID()
        let walletB = UUID()
        let t0 = Date()
        try await repo.record(walletId: walletA, currencyCode: "USD", fiatValue: 100, capturedAt: t0)
        try await repo.record(walletId: walletA, currencyCode: "USD", fiatValue: 110, capturedAt: t0.addingTimeInterval(600))
        try await repo.record(walletId: walletB, currencyCode: "USD", fiatValue: 999, capturedAt: t0)

        let seriesA = try await repo.series(walletId: walletA, currencyCode: "USD")
        let seriesB = try await repo.series(walletId: walletB, currencyCode: "USD")
        #expect(seriesA.count == 2)
        #expect(seriesA.allSatisfy { $0.fiatValue != 999 })
        #expect(seriesB.count == 1)
        #expect(seriesB.first?.fiatValue == 999)
    }

    @Test("per-currency isolation within one wallet")
    func perCurrencyIsolation() async throws {
        let repo = try makeRepository()
        let walletId = UUID()
        let t0 = Date()
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 100, capturedAt: t0)
        try await repo.record(walletId: walletId, currencyCode: "EUR", fiatValue: 90, capturedAt: t0)

        let usd = try await repo.series(walletId: walletId, currencyCode: "USD")
        let eur = try await repo.series(walletId: walletId, currencyCode: "EUR")
        #expect(usd.map(\.fiatValue) == [100])
        #expect(eur.map(\.fiatValue) == [90])
    }

    // MARK: - Delete

    @Test("deleteAll(walletId:) removes one wallet's timeline and nothing else")
    func deleteAllScopedToWallet() async throws {
        let repo = try makeRepository()
        let walletA = UUID()
        let walletB = UUID()
        let t0 = Date()
        try await repo.record(walletId: walletA, currencyCode: "USD", fiatValue: 100, capturedAt: t0)
        try await repo.record(walletId: walletA, currencyCode: "EUR", fiatValue: 90, capturedAt: t0)
        try await repo.record(walletId: walletB, currencyCode: "USD", fiatValue: 50, capturedAt: t0)

        try await repo.deleteAll(walletId: walletA)

        let aUSD = try await repo.series(walletId: walletA, currencyCode: "USD")
        let aEUR = try await repo.series(walletId: walletA, currencyCode: "EUR")
        let bUSD = try await repo.series(walletId: walletB, currencyCode: "USD")
        #expect(aUSD.isEmpty)
        #expect(aEUR.isEmpty)
        #expect(bUSD.count == 1)
    }

    // MARK: - Pruning

    @Test("prune decimates beyond 48h to the last snapshot of each day")
    func pruneDecimatesOldDays() async throws {
        let repo = try makeRepository()
        let walletId = UUID()
        let now = Date()
        let calendar = Calendar.current
        let oldDayStart = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -4, to: now) ?? now
        )
        for (hour, value) in [(9, Decimal(100)), (12, Decimal(105)), (15, Decimal(108))] {
            try await repo.record(
                walletId: walletId,
                currencyCode: "USD",
                fiatValue: value,
                capturedAt: oldDayStart.addingTimeInterval(TimeInterval(hour) * 3600)
            )
        }
        try await repo.record(walletId: walletId, currencyCode: "USD", fiatValue: 120, capturedAt: now)

        try await repo.prune(walletId: walletId, currencyCode: "USD", now: now)

        let points = try await repo.series(walletId: walletId, currencyCode: "USD")
        #expect(points.count == 2, "one decimated old-day row + the fresh row")
        #expect(points.first?.fiatValue == 108, "the LAST snapshot of the old day survives")
        #expect(points.last?.fiatValue == 120)
    }

    @Test("hard cap evicts oldest rows first")
    func hardCapEvictsOldest() async throws {
        let repo = try makeRepository()
        await repo._setHardCapForTesting(3)
        let walletId = UUID()
        let now = Date()
        let calendar = Calendar.current
        // Five snapshots on five distinct old days — daily decimation
        // keeps all five, then the cap of 3 must evict the oldest two.
        for dayOffset in 1...5 {
            let dayStart = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -(5 + dayOffset), to: now) ?? now
            )
            try await repo.record(
                walletId: walletId,
                currencyCode: "USD",
                fiatValue: Decimal(dayOffset * 10),
                capturedAt: dayStart.addingTimeInterval(12 * 3600)
            )
        }
        try await repo.prune(walletId: walletId, currencyCode: "USD", now: now)

        let points = try await repo.series(walletId: walletId, currencyCode: "USD")
        #expect(points.count == 3)
        // dayOffset 5 is the OLDEST day (now - 10d); offsets 1...3 are
        // the newest three and must be the survivors, oldest first.
        #expect(points.map(\.fiatValue) == [30, 20, 10])
    }

    // MARK: - captureFromPersistedBalances

    @Test("captureFromPersistedBalances sums the wallet's rows in the requested currency")
    func captureFromBalancesSums() async throws {
        let container = try makeWalletContainer()
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Test", kind: .watchOnly, mnemonicWordCount: nil,
            hasPassphrase: false, colorTag: "default", sortOrder: 0, requiresBackup: false
        )
        context.insert(wallet)
        let address = WalletAddressRecord(chainRaw: "ethereum", address: "0xabc")
        address.wallet = wallet
        context.insert(address)
        for (symbol, fiat, code) in [("ETH", Decimal(100), "USD"), ("USDC", Decimal(50), "USD"), ("ETH", Decimal(30), "EUR")] {
            let balance = TokenBalanceRecord(
                tokenSymbol: symbol, decimals: 6, rawBalance: "1",
                fiatValueCached: fiat, fiatCurrencyCode: code
            )
            balance.address = address
            balance.addressId = address.id
            context.insert(balance)
        }
        try context.save()

        let repo = WalletChartSnapshotRepository(modelContainer: container)
        let captured = try await repo.captureFromPersistedBalances(
            walletId: wallet.id, currencyCode: "USD", now: Date()
        )
        #expect(captured == true)
        let points = try await repo.series(walletId: wallet.id, currencyCode: "USD")
        #expect(points.map(\.fiatValue) == [150], "100 + 50 USD rows; the EUR row is excluded")
    }

    @Test("captureFromPersistedBalances skips when no row matches the currency — no fabricated 0")
    func captureFromBalancesCurrencyMismatchSkips() async throws {
        let container = try makeWalletContainer()
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Test", kind: .watchOnly, mnemonicWordCount: nil,
            hasPassphrase: false, colorTag: "default", sortOrder: 0, requiresBackup: false
        )
        context.insert(wallet)
        let address = WalletAddressRecord(chainRaw: "ethereum", address: "0xabc")
        address.wallet = wallet
        context.insert(address)
        let balance = TokenBalanceRecord(
            tokenSymbol: "ETH", decimals: 18, rawBalance: "1",
            fiatValueCached: 100, fiatCurrencyCode: "USD"
        )
        balance.address = address
        balance.addressId = address.id
        context.insert(balance)
        try context.save()

        let repo = WalletChartSnapshotRepository(modelContainer: container)
        let captured = try await repo.captureFromPersistedBalances(
            walletId: wallet.id, currencyCode: "JOD", now: Date()
        )
        #expect(captured == false)
        let points = try await repo.series(walletId: wallet.id, currencyCode: "JOD")
        #expect(points.isEmpty)
    }

    @Test("a wallet with no balance rows captures an honest zero")
    func captureFromBalancesEmptyWalletCapturesZero() async throws {
        let container = try makeWalletContainer()
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Empty", kind: .watchOnly, mnemonicWordCount: nil,
            hasPassphrase: false, colorTag: "default", sortOrder: 0, requiresBackup: false
        )
        context.insert(wallet)
        try context.save()

        let repo = WalletChartSnapshotRepository(modelContainer: container)
        let captured = try await repo.captureFromPersistedBalances(
            walletId: wallet.id, currencyCode: "USD", now: Date()
        )
        #expect(captured == true)
        let points = try await repo.series(walletId: wallet.id, currencyCode: "USD")
        #expect(points.map(\.fiatValue) == [0])
    }
}
