import Foundation
import Testing
@testable import Aperture

@Suite("GRDB transition wipe (P1-011)")
struct GRDBFreshWipeTests {

    // MARK: - Pure policy

    @Test("Marker present is always a no-op")
    func markerPresentNoop() {
        #expect(AppDatabase.grdbTransitionAction(markerExists: true, primaryStoreExists: true) == .noop)
        #expect(AppDatabase.grdbTransitionAction(markerExists: true, primaryStoreExists: false) == .noop)
    }

    @Test("Marker missing with live store heals marker only — never wipe")
    func missingMarkerLiveStoreHeals() {
        #expect(
            AppDatabase.grdbTransitionAction(markerExists: false, primaryStoreExists: true)
                == .healMarkerPreserveStore
        )
    }

    @Test("Marker missing and no store is empty-install marker write")
    func missingMarkerNoStore() {
        #expect(
            AppDatabase.grdbTransitionAction(markerExists: false, primaryStoreExists: false)
                == .writeMarkerEmptyInstall
        )
    }

    // MARK: - File-system integration

    @Test("P1-011: deleting marker while sqlite remains does not destroy the live DB")
    func missingMarkerPreservesLiveDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-p1-011-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("aperture.sqlite", isDirectory: false)
        let markerURL = directory.appendingPathComponent(".aperture-grdb-transition-v1", isDirectory: false)

        // Live wallet DB contents (sentinel bytes must survive).
        let livePayload = Data("LIVE-WALLET-DB-P1-011".utf8)
        FileManager.default.createFile(atPath: storeURL.path, contents: livePayload)
        FileManager.default.createFile(atPath: storeURL.path + "-wal", contents: Data([0x0A, 0x0B]))

        // Marker intentionally absent (user deleted / iCloud restore quirk).
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            markerURL: markerURL
        )

        // Live store preserved.
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
        #expect(try Data(contentsOf: storeURL) == livePayload)
        #expect(FileManager.default.fileExists(atPath: storeURL.path + "-wal"))
        // Marker healed so next launch is a no-op.
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        // Second call with marker present must still preserve the store.
        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            markerURL: markerURL
        )
        #expect(try Data(contentsOf: storeURL) == livePayload)
    }

    @Test("Empty install writes marker without inventing a store file")
    func emptyInstallWritesMarkerOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-p1-011-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("aperture.sqlite", isDirectory: false)
        let markerURL = directory.appendingPathComponent(".test-transition-marker", isDirectory: false)

        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            markerURL: markerURL
        )

        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("Empty install cleans orphan sidecars but not after a primary exists")
    func orphanSidecarsCleanedWhenNoPrimary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-p1-011-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("aperture.sqlite", isDirectory: false)
        let markerURL = directory.appendingPathComponent(".test-transition-marker", isDirectory: false)
        let orphanJournal = URL(fileURLWithPath: storeURL.path + "-journal")
        let orphanMeta = URL(fileURLWithPath: storeURL.path + "-SwiftDataMetadata")
        FileManager.default.createFile(atPath: orphanJournal.path, contents: Data([1]))
        FileManager.default.createFile(atPath: orphanMeta.path, contents: Data([2]))

        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            markerURL: markerURL
        )

        #expect(!FileManager.default.fileExists(atPath: orphanJournal.path))
        #expect(!FileManager.default.fileExists(atPath: orphanMeta.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test("primaryStoreFilesExist detects sqlite and wal")
    func primaryStoreDetection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-p1-011-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("aperture.sqlite", isDirectory: false)
        #expect(AppDatabase.primaryStoreFilesExist(at: storeURL) == false)

        FileManager.default.createFile(atPath: storeURL.path + "-wal", contents: Data([1]))
        #expect(AppDatabase.primaryStoreFilesExist(at: storeURL) == true)

        try FileManager.default.removeItem(atPath: storeURL.path + "-wal")
        FileManager.default.createFile(atPath: storeURL.path, contents: Data([1]))
        #expect(AppDatabase.primaryStoreFilesExist(at: storeURL) == true)
    }
}
