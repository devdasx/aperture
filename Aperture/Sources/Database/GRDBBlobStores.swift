import Foundation
import GRDB
import Security
import UIKit

enum LocalSecureBlobStore {
    static let walletSecretMasterKey = "wallet-secret.master-key.v1"
    static let chainKeyMasterKey = "chain-key.master-key.v1"

    static func read(_ key: String, database: AppDatabase = .shared) throws -> Data? {
        try database.read { db in
            try read(key, db: db)
        }
    }

    static func read(_ key: String, db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT blob FROM local_secure_blobs WHERE key = ?", arguments: [key])
    }

    @discardableResult
    static func upsert(_ data: Data, forKey key: String, database: AppDatabase = .shared) throws -> Bool {
        try database.write { db in
            try upsert(data, forKey: key, db: db)
            return true
        }
    }

    static func upsert(_ data: Data, forKey key: String, db: Database) throws {
        let now = Date.databaseMilliseconds
        try db.execute(
            sql: """
            INSERT INTO local_secure_blobs (key, blob, created_at_ms, updated_at_ms)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                blob = excluded.blob,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [key, data, now, now]
        )
    }

    static func delete(_ key: String, database: AppDatabase = .shared) {
        try? database.write { db in
            try delete(key, db: db)
        }
    }

    static func delete(_ key: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM local_secure_blobs WHERE key = ?", arguments: [key])
    }

    static func ensureRandomKey(_ key: String, byteCount: Int = 32, db: Database) throws -> Data {
        if let existing = try read(key, db: db), existing.count == byteCount {
            return existing
        }
        let data = secureRandomBytes(count: byteCount)
        try upsert(data, forKey: key, db: db)
        return data
    }

    static func ensureSecurityKeys(db: Database) throws {
        _ = try ensureRandomKey(walletSecretMasterKey, db: db)
        _ = try ensureRandomKey(chainKeyMasterKey, db: db)
    }

    private static func secureRandomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return data
    }
}

enum AssetLogoCacheStore {
    static func image(for url: URL, database: AppDatabase = .shared) -> UIImage? {
        guard let data = try? database.read({ db in
            try Data.fetchOne(
                db,
                sql: "SELECT png_data FROM asset_logo_cache WHERE source_url = ?",
                arguments: [url.absoluteString]
            )
        }) else { return nil }
        return UIImage(data: data)
    }

    static func store(_ image: UIImage, for url: URL, database: AppDatabase = .shared) {
        guard let data = image.pngData() else { return }
        Task.detached(priority: .utility) {
            try? database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO asset_logo_cache (cache_key, source_url, png_data, updated_at_ms)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(source_url) DO UPDATE SET
                        png_data = excluded.png_data,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [cacheKey(for: url), url.absoluteString, data, Date.databaseMilliseconds]
                )
            }
        }
    }

    private static func cacheKey(for url: URL) -> String {
        let hash = url.absoluteString.utf8.reduce(into: UInt64(5381)) { result, byte in
            result = result &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }
}

enum WalletAvatarRasterCacheStore {
    static func image(walletId: UUID, database: AppDatabase = .shared) -> UIImage? {
        guard let data = try? database.read({ db in
            try Data.fetchOne(
                db,
                sql: "SELECT png_data FROM wallet_avatar_raster_cache WHERE wallet_id = ?",
                arguments: [walletId.uuidString]
            )
        }) else { return nil }
        return UIImage(data: data)
    }

    static func store(_ image: UIImage, walletId: UUID, database: AppDatabase = .shared) throws {
        guard let data = image.pngData() else {
            throw NSError(
                domain: "WalletAvatarRasterCacheStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Image had no PNG representation"]
            )
        }
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallet_avatar_raster_cache (wallet_id, png_data, updated_at_ms)
                VALUES (?, ?, ?)
                ON CONFLICT(wallet_id) DO UPDATE SET
                    png_data = excluded.png_data,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [walletId.uuidString, data, Date.databaseMilliseconds]
            )
        }
    }

    static func invalidate(walletId: UUID, database: AppDatabase = .shared) {
        try? database.write { db in
            try db.execute(sql: "DELETE FROM wallet_avatar_raster_cache WHERE wallet_id = ?", arguments: [walletId.uuidString])
        }
    }
}

enum GeneratedDocumentStore {
    enum Kind: String {
        case activityStatement
        case transactionReceipt
    }

    static func storePDF(
        _ data: Data,
        fileName: String,
        kind: Kind,
        database: AppDatabase = .shared
    ) -> URL? {
        let id = UUID()
        do {
            try database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO generated_documents
                    (id, kind_raw, file_name, mime_type, data, created_at_ms)
                    VALUES (?, ?, ?, 'application/pdf', ?, ?)
                    """,
                    arguments: [id.uuidString, kind.rawValue, fileName, data, Date.databaseMilliseconds]
                )
            }
            return try exportTempFile(id: id, database: database)
        } catch {
            return nil
        }
    }

    private static func exportTempFile(id: UUID, database: AppDatabase) throws -> URL? {
        let row = try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT file_name, data FROM generated_documents WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        guard let row,
              let fileName = row["file_name"] as String?,
              let data = row["data"] as Data? else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        try data.write(to: url, options: .atomic)
        return url
    }
}

enum CloudKitBackupCacheStore {
    static func upsert(_ blob: WalletBackupBlob, encoded: Data, database: AppDatabase = .shared) {
        try? database.write { db in
            try db.execute(
                sql: """
                INSERT INTO cloudkit_backup_cache
                (wallet_id, version, encoded_blob, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(wallet_id) DO UPDATE SET
                    version = excluded.version,
                    encoded_blob = excluded.encoded_blob,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    blob.walletId.uuidString,
                    blob.version,
                    encoded,
                    blob.createdAt.databaseMilliseconds,
                    Date.databaseMilliseconds
                ]
            )
        }
    }

    static func delete(walletId: UUID, database: AppDatabase = .shared) {
        try? database.write { db in
            try db.execute(sql: "DELETE FROM cloudkit_backup_cache WHERE wallet_id = ?", arguments: [walletId.uuidString])
        }
    }
}
