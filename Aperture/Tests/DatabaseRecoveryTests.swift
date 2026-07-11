import Foundation
import Testing
@testable import Aperture

/// BUG-020 / P0-001: corrupt DB recovery must never be silent, and ephemeral
/// stores must refuse user writes.
@Suite("Database recovery (BUG-020 / P0-001)")
struct DatabaseRecoveryTests {

    @Test("User writes are refused on ephemeral stores")
    func ephemeralRefusesWrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-recovery-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ephemeral.sqlite")

        let database = try AppDatabase(ephemeralTestStoreURL: url)
        defer {
            try? database.pool.close()
        }
        #expect(database.isInMemoryFallback)
        #expect(!database.allowsUserWrites)

        #expect(throws: AppDatabaseError.writesDisabledEphemeralStore) {
            try database.write { db in
                try db.execute(sql: "SELECT 1")
            }
        }

        // Reads still work so recovery UI / diagnostics can load.
        let one = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
        #expect(one == 1)
    }

    @Test("Normal test store still allows writes")
    func normalStoreAllowsWrites() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        #expect(!database.isInMemoryFallback)
        #expect(database.allowsUserWrites)
        try database.write { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    @Test("Recovery incident encodes and requires acknowledgement")
    func incidentPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-recovery-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let quarantine = directory.appendingPathComponent("CorruptStore-1", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let reasonURL = quarantine.appendingPathComponent("reason.txt")
        try "integrity failed".write(to: reasonURL, atomically: true, encoding: .utf8)

        DatabaseRecoveryIncident.record(
            kind: .quarantinedAndReplaced,
            reason: "integrityCheckFailed(quick_check)",
            quarantineDirectory: quarantine,
            storeURL: directory.appendingPathComponent("aperture.sqlite")
        )

        let loaded = DatabaseRecoveryIncident.loadPending(storeDirectory: directory)
        #expect(loaded != nil)
        #expect(loaded?.needsUserAcknowledgement == true)
        #expect(loaded?.kind == .quarantinedAndReplaced)
        #expect(loaded?.reason.contains("quick_check") == true)
        #expect(DatabaseRecoveryIncident.needsBlockingUI(storeDirectory: directory))

        let files = DatabaseRecoveryIncident.exportableFiles(in: quarantine)
        #expect(files.contains { $0.lastPathComponent == "reason.txt" })

        if let incident = loaded {
            DatabaseRecoveryIncident.acknowledge(incident)
        }
        // After acknowledge of quarantinedAndReplaced, markers are cleared.
        #expect(DatabaseRecoveryIncident.loadPending(storeDirectory: directory) == nil
                || DatabaseRecoveryIncident.loadPending(storeDirectory: directory)?.needsUserAcknowledgement == false)
    }

    @Test("AppDatabaseError user messages are honest")
    func errorCopy() {
        #expect(!AppDatabaseError.writesDisabledEphemeralStore.userMessage.isEmpty)
        #expect(AppDatabaseError.writesDisabledEphemeralStore.userMessage.contains("cannot save"))
    }

    @Test("Latest CorruptStore discovery picks newest folder")
    func latestQuarantine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-corrupt-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let older = directory.appendingPathComponent("CorruptStore-1000", isDirectory: true)
        let newer = directory.appendingPathComponent("CorruptStore-2000", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)

        let store = directory.appendingPathComponent("aperture.sqlite")
        let found = DatabaseRecoveryIncident.latestQuarantineDirectory(near: store)
        #expect(found?.lastPathComponent == "CorruptStore-2000")
    }
}
