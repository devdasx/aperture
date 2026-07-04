import Foundation
import GRDB
@testable import Aperture

enum TestAppDatabaseFactory {
    static func makeDatabase(name: String = #function, seedSingletonRows: Bool = true) throws -> AppDatabase {
        let safeName = name
            .replacingOccurrences(of: "()", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-grdb-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("aperture.sqlite", isDirectory: false)
        return try AppDatabase(testStoreURL: url, seedSingletonRows: seedSingletonRows)
    }

    static func cleanup(_ database: AppDatabase) {
        try? database.pool.close()
        try? AppDatabase.resetStoreFiles(at: database.storeURL)
        try? FileManager.default.removeItem(at: database.storeURL.deletingLastPathComponent())
    }

    static func count(_ table: String, database: AppDatabase) throws -> Int {
        try database.tableCount(table)
    }

    static func scalarString(_ sql: String, arguments: StatementArguments = [], database: AppDatabase) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: sql, arguments: arguments)
        }
    }

    static func scalarInt(_ sql: String, arguments: StatementArguments = [], database: AppDatabase) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }
}
