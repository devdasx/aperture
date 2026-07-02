import Testing
import Foundation
import SwiftData
@testable import Aperture

/// Wallet-removal cleanup contract (2026-06-13): deleting a wallet
/// through the canonical repository path
/// (`WalletRepository.deleteWalletAndActivateNext(walletId:)`) must
/// leave ZERO wallet-scoped snapshot rows for that wallet — chart and
/// balance-card snapshot tables are keyed by primitive `walletId` with
/// no relationship, so SwiftData's cascade rules never touch them and
/// the repository must delete them explicitly (atomically, in the same
/// save as the record delete).
///
/// **Why an on-disk temp store, not in-memory.** The repository's
/// custody mutations (`ensureDurableStore()`) deliberately REFUSE
/// in-memory containers — an in-memory delete would desync Keychain
/// state from a store that vanishes at exit. So these tests run
/// against a throwaway SQLite file in `temporaryDirectory`, removed
/// (with its -wal/-shm sidecars) after each test.
///
/// **Honest side-effect boundary.** The repository path is the REAL
/// custody path: it syncs the Keychain wallet manifest from the test
/// store, moves the `activeWalletId` pointer in
/// `UserDefaults.standard`, and issues (no-op) vault deletes for the
/// test wallet ids. Each test snapshots + restores the pointer and
/// finishes with `deleteAllWallets()` so the manifest ends cleared —
/// the same posture `FreshInstallGuardTests` already takes about
/// touching host-process state. Keychain emptiness itself is not
/// asserted here (shared host Keychain — see the boundary note in
/// `ResetCompletenessTests`).
@Suite struct WalletRemovalCleanupTests {

    // MARK: - Temp on-disk container

    private struct TempStore {
        let container: ModelContainer
        let url: URL

        func destroy() {
            let fm = FileManager.default
            for path in [url.path, url.path + "-wal", url.path + "-shm"] {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private func makeTempStore() throws -> TempStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WalletRemovalCleanupTests-\(UUID().uuidString).sqlite",
                isDirectory: false
            )
        let schema = Schema(ApertureSchemaV1.models)
        let config = ModelConfiguration(
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        return TempStore(container: container, url: url)
    }

    // MARK: - The cleanup contract

    @Test("deleting wallet A removes A's snapshots and leaves B's intact")
    func deleteWalletRemovesItsSnapshotsOnly() async throws {
        let store = try makeTempStore()
        defer { store.destroy() }
        let priorPointer = await MainActor.run { ActiveWalletPointer.rawValue }
        defer {
            Task { @MainActor in ActiveWalletPointer.setRaw(priorPointer) }
        }

        let repo = WalletRepository(modelContainer: store.container)
        let chartRepo = WalletChartSnapshotRepository(modelContainer: store.container)

        let walletA = UUID()
        let walletB = UUID()
        try await repo.insertCreatedWallet(
            id: walletA, name: "A", mnemonicWordCount: 12,
            hasPassphrase: false, colorTag: "default", requiresBackup: false,
            mnemonicWords: ["abandon", "ability", "able"]
        )
        try await repo.insertCreatedWallet(
            id: walletB, name: "B", mnemonicWordCount: 12,
            hasPassphrase: false, colorTag: "default", requiresBackup: false,
            mnemonicWords: ["about", "above", "absent"]
        )

        // Timelines: A in two currencies, B in one — the deletion must
        // be scoped by wallet, not by currency.
        let t0 = Date()
        try await chartRepo.record(walletId: walletA, currencyCode: "USD", fiatValue: 100, capturedAt: t0)
        try await chartRepo.record(walletId: walletA, currencyCode: "EUR", fiatValue: 90, capturedAt: t0)
        try await chartRepo.record(walletId: walletA, currencyCode: "USD", fiatValue: 110, capturedAt: t0.addingTimeInterval(700))
        try await chartRepo.record(walletId: walletB, currencyCode: "USD", fiatValue: 50, capturedAt: t0)
        let snapshotContext = ModelContext(store.container)
        snapshotContext.insert(balanceCardSnapshot(walletId: walletA, currencyCode: "USD", totalFiat: 100, capturedAt: t0))
        snapshotContext.insert(balanceCardSnapshot(walletId: walletA, currencyCode: "EUR", totalFiat: 90, capturedAt: t0))
        snapshotContext.insert(balanceCardSnapshot(walletId: walletB, currencyCode: "USD", totalFiat: 50, capturedAt: t0))
        try snapshotContext.save()

        // Delete A through the canonical removal path.
        _ = try await repo.deleteWalletAndActivateNext(walletId: walletA)

        // A's record is gone; B's survives.
        #expect(try await repo.allWalletIds() == [walletB])

        // A's timeline is gone in EVERY currency; B's is intact.
        let aUSD = try await chartRepo.series(walletId: walletA, currencyCode: "USD")
        let aEUR = try await chartRepo.series(walletId: walletA, currencyCode: "EUR")
        let bUSD = try await chartRepo.series(walletId: walletB, currencyCode: "USD")
        #expect(aUSD.isEmpty, "wallet A's USD chart snapshots must not survive its deletion")
        #expect(aEUR.isEmpty, "wallet A's EUR chart snapshots must not survive its deletion")
        #expect(bUSD.count == 1, "wallet B's timeline must be untouched by A's deletion")
        #expect(bUSD.first?.fiatValue == 50)
        #expect(
            try balanceCardSnapshotCount(walletId: walletA, in: store.container) == 0,
            "wallet A's balance-card snapshots must not survive its deletion"
        )
        #expect(
            try balanceCardSnapshotCount(walletId: walletB, in: store.container) == 1,
            "wallet B's balance-card snapshot must be untouched by A's deletion"
        )
        let secretContext = ModelContext(store.container)
        let walletASecretKey = WalletSecretRecord.storageKey(walletId: walletA, kind: .mnemonic)
        let walletBSecretKey = WalletSecretRecord.storageKey(walletId: walletB, kind: .mnemonic)
        let walletASecrets = try secretContext.fetch(FetchDescriptor<WalletSecretRecord>(
            predicate: #Predicate { $0.key == walletASecretKey }
        ))
        let walletBSecrets = try secretContext.fetch(FetchDescriptor<WalletSecretRecord>(
            predicate: #Predicate { $0.key == walletBSecretKey }
        ))
        #expect(walletASecrets.isEmpty, "wallet A's encrypted phrase row must not survive its deletion")
        #expect(walletBSecrets.count == 1, "wallet B's encrypted phrase row must be untouched by A's deletion")

        // Cleanup: empty the store so the manifest sync ends cleared.
        try await repo.deleteAllWallets()
    }

    @Test("deleting an already-deleted wallet sweeps orphaned snapshots (idempotent path)")
    func idempotentDeleteSweepsOrphanedSnapshots() async throws {
        let store = try makeTempStore()
        defer { store.destroy() }
        let priorPointer = await MainActor.run { ActiveWalletPointer.rawValue }
        defer {
            Task { @MainActor in ActiveWalletPointer.setRaw(priorPointer) }
        }

        let repo = WalletRepository(modelContainer: store.container)
        let chartRepo = WalletChartSnapshotRepository(modelContainer: store.container)

        // Orphaned snapshots: records exist for a wallet id that has no
        // wallet record (the crash-between-save-and-cleanup shape).
        let ghost = UUID()
        try await chartRepo.record(walletId: ghost, currencyCode: "USD", fiatValue: 42, capturedAt: Date())
        let snapshotContext = ModelContext(store.container)
        snapshotContext.insert(balanceCardSnapshot(walletId: ghost, currencyCode: "USD", totalFiat: 42, capturedAt: Date()))
        try snapshotContext.save()
        #expect(try await chartRepo.series(walletId: ghost, currencyCode: "USD").count == 1)
        #expect(try balanceCardSnapshotCount(walletId: ghost, in: store.container) == 1)

        // The idempotent early-return path must still sweep them.
        _ = try await repo.deleteWalletAndActivateNext(walletId: ghost)
        let after = try await chartRepo.series(walletId: ghost, currencyCode: "USD")
        #expect(after.isEmpty, "orphaned chart snapshots must be swept by the idempotent delete path")
        #expect(
            try balanceCardSnapshotCount(walletId: ghost, in: store.container) == 0,
            "orphaned balance-card snapshots must be swept by the idempotent delete path"
        )
    }

    @Test("deleteAllWallets wipes every snapshot alongside the wallet rows")
    func deleteAllWalletsWipesAllSnapshots() async throws {
        let store = try makeTempStore()
        defer { store.destroy() }

        let repo = WalletRepository(modelContainer: store.container)
        let chartRepo = WalletChartSnapshotRepository(modelContainer: store.container)

        let walletA = UUID()
        try await repo.insertCreatedWallet(
            id: walletA, name: "A", mnemonicWordCount: 12,
            hasPassphrase: false, colorTag: "default", requiresBackup: false,
            mnemonicWords: ["abandon", "ability", "able"]
        )
        try await chartRepo.record(walletId: walletA, currencyCode: "USD", fiatValue: 1, capturedAt: Date())
        let snapshotContext = ModelContext(store.container)
        snapshotContext.insert(balanceCardSnapshot(walletId: walletA, currencyCode: "USD", totalFiat: 1, capturedAt: Date()))
        // Plus an orphan for a wallet with no record — the full reset
        // must not leave even those behind.
        let ghost = UUID()
        try await chartRepo.record(walletId: ghost, currencyCode: "USD", fiatValue: 2, capturedAt: Date())
        snapshotContext.insert(balanceCardSnapshot(walletId: ghost, currencyCode: "USD", totalFiat: 2, capturedAt: Date()))
        try snapshotContext.save()

        try await repo.deleteAllWallets()

        #expect(try await repo.allWalletIds().isEmpty)
        #expect(try await chartRepo.series(walletId: walletA, currencyCode: "USD").isEmpty)
        #expect(try await chartRepo.series(walletId: ghost, currencyCode: "USD").isEmpty)
        #expect(try balanceCardSnapshotCount(walletId: walletA, in: store.container) == 0)
        #expect(try balanceCardSnapshotCount(walletId: ghost, in: store.container) == 0)
        let secretContext = ModelContext(store.container)
        #expect(try secretContext.fetchCount(FetchDescriptor<WalletSecretRecord>()) == 0)
    }

    private func balanceCardSnapshot(
        walletId: UUID,
        currencyCode: String,
        totalFiat: Decimal,
        capturedAt: Date
    ) -> WalletBalanceCardSnapshotRecord {
        WalletBalanceCardSnapshotRecord(
            walletId: walletId,
            currencyCode: currencyCode,
            totalFiat: totalFiat,
            lastUpdatedAt: capturedAt,
            selectedRangeRaw: BalanceHistoryRange.all.rawValue,
            isBalanceHidden: false,
            ranges: [
                WalletBalanceCardRangeSnapshot(
                    rangeRaw: BalanceHistoryRange.all.rawValue,
                    points: [WalletBalanceCardPointSnapshot(timestamp: capturedAt, fiat: totalFiat)],
                    xFractions: [0],
                    minValue: NSDecimalNumber(decimal: totalFiat).doubleValue,
                    maxValue: NSDecimalNumber(decimal: totalFiat).doubleValue,
                    baselineFiat: totalFiat,
                    changeFiat: 0,
                    changePercent: 0,
                    signRaw: "flat"
                )
            ],
            updatedAt: capturedAt
        )
    }

    private func balanceCardSnapshotCount(walletId: UUID, in container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        return try context.fetchCount(FetchDescriptor<WalletBalanceCardSnapshotRecord>(
            predicate: #Predicate { $0.walletId == walletId }
        ))
    }
}
