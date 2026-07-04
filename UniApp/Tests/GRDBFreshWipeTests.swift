import Foundation
import Testing
@testable import Aperture

@Suite struct GRDBFreshWipeTests {
    @Test("one-time GRDB transition wipe removes old SQLite files and records a file marker")
    func transitionWipeDeletesLegacyStoreAndWritesMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-fresh-wipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("aperture.sqlite", isDirectory: false)
        let files = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-journal"),
            URL(fileURLWithPath: storeURL.path + "-SwiftDataMetadata")
        ]
        for file in files {
            FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3]))
        }

        let markerURL = directory.appendingPathComponent(".test-transition-marker", isDirectory: false)

        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            markerURL: markerURL
        )

        for file in files {
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) survived fresh wipe")
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        FileManager.default.createFile(atPath: storeURL.path, contents: Data([4, 5, 6]))
        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            markerURL: markerURL
        )
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
