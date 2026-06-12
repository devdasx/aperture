import Testing
import Foundation
import SwiftData
@testable import Aperture

/// Wallet-removal cleanup contract (2026-06-13): deleting a wallet
/// through the canonical repository path
/// (`WalletRepository.deleteWalletAndActivateNext(walletId:)`) must
/// leave ZERO `WalletChartSnapshotRecord` rows for that wallet — the
/// timeline table is keyed by primitive `walletId` with no
/// relationship, so SwiftData's cascade rules never touch it and the
/// repository must delete it explicitly (atomically, in the same save
/// as the record delete).
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

    @Test("deleting wallet A removes A's chart snapshots and leaves B's intact")
    func deleteWalletRemovesItsChartSnapshotsOnly() async throws {
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
            hasPassphrase: false, colorTag: "default", requiresBackup: false
        )
        try await repo.insertCreatedWallet(
            id: walletB, name: "B", mnemonicWordCount: 12,
            hasPassphrase: false, colorTag: "default", requiresBackup: false
        )

        // Timelines: A in two currencies, B in one — the deletion must
        // be scoped by wallet, not by currency.
        let t0 = Date()
        try await chartRepo.record(walletId: walletA, currencyCode: "USD", fiatValue: 100, capturedAt: t0)
        try await chartRepo.record(walletId: walletA, currencyCode: "EUR", fiatValue: 90, capturedAt: t0)
        try await chartRepo.record(walletId: walletA, currencyCode: "USD", fiatValue: 110, capturedAt: t0.addingTimeInterval(700))
        try await chartRepo.record(walletId: walletB, currencyCode: "USD", fiatValue: 50, capturedAt: t0)

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

        // Orphaned timeline: snapshots exist for a wallet id that has
        // no record (the crash-between-save-and-cleanup shape).
        let ghost = UUID()
        try await chartRepo.record(walletId: ghost, currencyCode: "USD", fiatValue: 42, capturedAt: Date())
        #expect(try await chartRepo.series(walletId: ghost, currencyCode: "USD").count == 1)

        // The idempotent early-return path must still sweep them.
        _ = try await repo.deleteWalletAndActivateNext(walletId: ghost)
        let after = try await chartRepo.series(walletId: ghost, currencyCode: "USD")
        #expect(after.isEmpty, "orphaned chart snapshots must be swept by the idempotent delete path")
    }

    @Test("deleteAllWallets wipes every chart snapshot alongside the wallet rows")
    func deleteAllWalletsWipesAllChartSnapshots() async throws {
        let store = try makeTempStore()
        defer { store.destroy() }

        let repo = WalletRepository(modelContainer: store.container)
        let chartRepo = WalletChartSnapshotRepository(modelContainer: store.container)

        let walletA = UUID()
        try await repo.insertCreatedWallet(
            id: walletA, name: "A", mnemonicWordCount: 12,
            hasPassphrase: false, colorTag: "default", requiresBackup: false
        )
        try await chartRepo.record(walletId: walletA, currencyCode: "USD", fiatValue: 1, capturedAt: Date())
        // Plus an orphan for a wallet with no record — the full reset
        // must not leave even those behind.
        let ghost = UUID()
        try await chartRepo.record(walletId: ghost, currencyCode: "USD", fiatValue: 2, capturedAt: Date())

        try await repo.deleteAllWallets()

        #expect(try await repo.allWalletIds().isEmpty)
        #expect(try await chartRepo.series(walletId: walletA, currencyCode: "USD").isEmpty)
        #expect(try await chartRepo.series(walletId: ghost, currencyCode: "USD").isEmpty)
    }
}
