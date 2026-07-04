import Foundation
import CryptoKit
import OSLog
import GRDB

/// GRDB-backed compatibility adapter for user-readable wallet secrets.
///
/// Older code called this type when mnemonic/private-key material lived in
/// Keychain. Storage is now SQLite-only: every method delegates to
/// `WalletSecretPersistence`, whose encrypted rows live in `wallet_secrets`.
enum MnemonicVault {
    enum VaultError: Error, Sendable, Equatable {
        case databaseWriteFailed(String)
        case databaseReadFailed(String)
        case databaseDeleteFailed(String)
        case noSuchWallet
        case decryptionFailed
        case encodingFailed
    }

    // MARK: - Public surface

    static func storeMnemonic(_ words: [String], for walletId: UUID) throws(VaultError) {
        do {
            try WalletSecretPersistence.upsertMnemonic(words, for: walletId)
        } catch {
            throw .databaseWriteFailed(String(describing: error))
        }
    }

    static func loadMnemonic(for walletId: UUID) throws(VaultError) -> [String]? {
        do {
            return try WalletSecretPersistence.loadMnemonic(for: walletId)
        } catch WalletSecretCrypto.CryptoError.openFailed {
            throw .decryptionFailed
        } catch {
            throw .databaseReadFailed(String(describing: error))
        }
    }

    static func hasMnemonic(for walletId: UUID) -> Bool {
        WalletSecretPersistence.hasSecret(kind: .mnemonic, for: walletId)
    }

    static func deleteMnemonic(for walletId: UUID) throws(VaultError) {
        do {
            try WalletSecretPersistence.deleteSecret(kind: .mnemonic, for: walletId)
        } catch {
            throw .databaseDeleteFailed(String(describing: error))
        }
    }

    // MARK: - Imported private-key strings

    static func storePrivateKey(_ keyString: String, for walletId: UUID) throws(VaultError) {
        do {
            try WalletSecretPersistence.upsertPrivateKey(keyString, for: walletId)
        } catch {
            throw .databaseWriteFailed(String(describing: error))
        }
    }

    static func loadPrivateKey(for walletId: UUID) throws(VaultError) -> String? {
        do {
            return try WalletSecretPersistence.loadPrivateKey(for: walletId)
        } catch WalletSecretCrypto.CryptoError.openFailed {
            throw .decryptionFailed
        } catch {
            throw .databaseReadFailed(String(describing: error))
        }
    }

    static func hasPrivateKey(for walletId: UUID) -> Bool {
        WalletSecretPersistence.hasSecret(kind: .privateKey, for: walletId)
    }

    static func deletePrivateKey(for walletId: UUID) throws(VaultError) {
        do {
            try WalletSecretPersistence.deleteSecret(kind: .privateKey, for: walletId)
        } catch {
            throw .databaseDeleteFailed(String(describing: error))
        }
    }
}

// MARK: - GRDB-backed encrypted wallet secrets

/// Device-local encryption for `WalletSecretRecord` rows.
///
/// The master key is an app-owned random 256-bit key stored in GRDB's
/// `local_secure_blobs` table. The wallet secret rows store only AES-GCM
/// ciphertext.
enum WalletSecretCrypto {
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "wallet-secret-crypto")
    nonisolated(unsafe) private static var cachedMasterKeyData: Data?

    enum CryptoError: Error, Sendable, Equatable {
        case invalidMasterKey
        case sealFailed
        case openFailed
    }

    static func seal(_ plaintext: Data, associatedData: Data) throws(CryptoError) -> Data {
        let key = try masterKey()
        do {
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
            guard let combined = box.combined else { throw CryptoError.sealFailed }
            return combined
        } catch let error as CryptoError {
            throw error
        } catch {
            log.error("Wallet secret seal failed: \(String(describing: error), privacy: .public)")
            throw .sealFailed
        }
    }

    static func open(_ ciphertext: Data, associatedData: Data) throws(CryptoError) -> Data {
        let key = try masterKey()
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch {
            log.error("Wallet secret open failed: \(String(describing: error), privacy: .public)")
            throw .openFailed
        }
    }

    static func configure(database: AppDatabase = .shared) {
        cachedMasterKeyData = try? database.write { db in
            try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.walletSecretMasterKey, db: db)
        }
    }

    static func clearMasterKey(database: AppDatabase = .shared) {
        try? database.write { db in
            try LocalSecureBlobStore.delete(LocalSecureBlobStore.walletSecretMasterKey, db: db)
            cachedMasterKeyData = try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.walletSecretMasterKey, db: db)
        }
    }

    private static func masterKey() throws(CryptoError) -> SymmetricKey {
        if let existing = cachedMasterKeyData {
            guard existing.count == 32 else { throw .invalidMasterKey }
            return SymmetricKey(data: existing)
        }
        guard let keyData = try? AppDatabase.shared.write({ db in
            try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.walletSecretMasterKey, db: db)
        }), keyData.count == 32 else {
            throw .invalidMasterKey
        }
        cachedMasterKeyData = keyData
        return SymmetricKey(data: keyData)
    }
}

enum WalletSecretPersistence {
    struct EncryptedSecretRow: Sendable {
        let key: String
        let walletId: UUID
        let kindRaw: String
        let cipherData: Data
    }

    enum StoreError: Error, Sendable, Equatable {
        case encodingFailed
        case decodingFailed
    }

    enum Availability: Sendable, Equatable {
        case available
        case encryptedRecordUnavailable
        case missing

        var canReveal: Bool {
            if case .available = self { return true }
            return false
        }
    }

    static func upsertSeed(
        _ seed: Data,
        for walletId: UUID,
        database: AppDatabase = .shared
    ) throws {
        try upsertSecretData(seed, kind: .seed, walletId: walletId, database: database)
    }

    static func upsertMnemonic(
        _ words: [String],
        for walletId: UUID,
        database: AppDatabase = .shared
    ) throws {
        let canonical = words.map { $0.lowercased() }.joined(separator: " ")
        try upsertSecret(canonical, kind: .mnemonic, walletId: walletId, database: database)
    }

    static func upsertPrivateKey(
        _ keyString: String,
        for walletId: UUID,
        database: AppDatabase = .shared
    ) throws {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
        try upsertSecret(trimmed, kind: .privateKey, walletId: walletId, database: database)
    }

    static func encryptedSeedRow(_ seed: Data, for walletId: UUID) throws -> EncryptedSecretRow {
        try encryptedSecretRow(seed, kind: .seed, walletId: walletId)
    }

    static func encryptedMnemonicRow(_ words: [String], for walletId: UUID) throws -> EncryptedSecretRow {
        let canonical = words.map { $0.lowercased() }.joined(separator: " ")
        return try encryptedSecretRow(canonical, kind: .mnemonic, walletId: walletId)
    }

    static func encryptedPrivateKeyRow(_ keyString: String, for walletId: UUID) throws -> EncryptedSecretRow {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
        return try encryptedSecretRow(trimmed, kind: .privateKey, walletId: walletId)
    }

    static func loadSeed(for walletId: UUID, database: AppDatabase = .shared) throws -> Data? {
        try loadSecretData(kind: .seed, walletId: walletId, database: database)
    }

    static func loadMnemonic(for walletId: UUID, database: AppDatabase = .shared) throws -> [String]? {
        guard let secret = try loadSecret(kind: .mnemonic, walletId: walletId, database: database) else {
            return nil
        }
        let words = secret.split(separator: " ").map(String.init)
        return words.isEmpty ? nil : words
    }

    static func loadPrivateKey(for walletId: UUID, database: AppDatabase = .shared) throws -> String? {
        try loadSecret(kind: .privateKey, walletId: walletId, database: database)
    }

    static func hasSecret(kind: WalletSecretKind, for walletId: UUID, database: AppDatabase = .shared) -> Bool {
        (try? existingRecord(kind: kind, walletId: walletId, database: database)) != nil
    }

    static func availability(kind: WalletSecretKind, for walletId: UUID, database: AppDatabase = .shared) -> Availability {
        do {
            guard try existingRecord(kind: kind, walletId: walletId, database: database) != nil else {
                return .missing
            }
            switch kind {
            case .seed:
                return ((try loadSeed(for: walletId, database: database)) ?? Data()).isEmpty ? .missing : .available
            case .mnemonic:
                return ((try loadMnemonic(for: walletId, database: database)) ?? []).isEmpty ? .missing : .available
            case .privateKey:
                return ((try loadPrivateKey(for: walletId, database: database)) ?? "").isEmpty ? .missing : .available
            }
        } catch {
            return .encryptedRecordUnavailable
        }
    }

    static func deleteSecret(kind: WalletSecretKind, for walletId: UUID, database: AppDatabase = .shared) throws {
        let storageKey = WalletSecretRecord.storageKey(walletId: walletId, kind: kind)
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallet_secrets WHERE key = ?", arguments: [storageKey])
        }
    }

    static func deleteAll(for walletId: UUID, database: AppDatabase = .shared) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallet_secrets WHERE wallet_id = ?", arguments: [walletId.uuidString])
        }
    }

    private static func upsertSecretData(
        _ data: Data,
        kind: WalletSecretKind,
        walletId: UUID,
        database: AppDatabase
    ) throws {
        let encrypted = try encryptedSecretRow(data, kind: kind, walletId: walletId)
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallet_secrets
                (key, wallet_id, kind_raw, cipher_data, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(wallet_id, kind_raw) DO UPDATE SET
                    cipher_data = excluded.cipher_data,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    encrypted.key,
                    encrypted.walletId.uuidString,
                    encrypted.kindRaw,
                    encrypted.cipherData,
                    now,
                    now
                ]
            )
        }
    }

    private static func upsertSecret(
        _ secret: String,
        kind: WalletSecretKind,
        walletId: UUID,
        database: AppDatabase
    ) throws {
        let encrypted = try encryptedSecretRow(secret, kind: kind, walletId: walletId)
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallet_secrets
                (key, wallet_id, kind_raw, cipher_data, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(wallet_id, kind_raw) DO UPDATE SET
                    cipher_data = excluded.cipher_data,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    encrypted.key,
                    encrypted.walletId.uuidString,
                    encrypted.kindRaw,
                    encrypted.cipherData,
                    now,
                    now
                ]
            )
        }
    }

    private static func encryptedSecretRow(
        _ secret: String,
        kind: WalletSecretKind,
        walletId: UUID
    ) throws -> EncryptedSecretRow {
        guard let plaintext = secret.data(using: .utf8) else { throw StoreError.encodingFailed }
        return try encryptedSecretRow(plaintext, kind: kind, walletId: walletId)
    }

    private static func encryptedSecretRow(
        _ plaintext: Data,
        kind: WalletSecretKind,
        walletId: UUID
    ) throws -> EncryptedSecretRow {
        let storageKey = WalletSecretRecord.storageKey(walletId: walletId, kind: kind)
        let associatedData = Data(storageKey.utf8)
        let ciphertext = try WalletSecretCrypto.seal(plaintext, associatedData: associatedData)
        return EncryptedSecretRow(
            key: storageKey,
            walletId: walletId,
            kindRaw: kind.rawValue,
            cipherData: ciphertext
        )
    }

    private static func loadSecretData(
        kind: WalletSecretKind,
        walletId: UUID,
        database: AppDatabase
    ) throws -> Data? {
        guard let record = try existingRecord(kind: kind, walletId: walletId, database: database) else {
            return nil
        }
        let associatedData = Data(record.key.utf8)
        return try WalletSecretCrypto.open(record.cipherData, associatedData: associatedData)
    }

    private static func loadSecret(
        kind: WalletSecretKind,
        walletId: UUID,
        database: AppDatabase
    ) throws -> String? {
        guard let plaintext = try loadSecretData(kind: kind, walletId: walletId, database: database) else { return nil }
        guard let secret = String(data: plaintext, encoding: .utf8) else {
            throw StoreError.decodingFailed
        }
        return secret
    }

    private static func existingRecord(
        kind: WalletSecretKind,
        walletId: UUID,
        database: AppDatabase
    ) throws -> WalletSecretRecord? {
        let storageKey = WalletSecretRecord.storageKey(walletId: walletId, kind: kind)
        return try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT key, wallet_id, kind_raw, cipher_data, created_at_ms, updated_at_ms FROM wallet_secrets WHERE key = ?",
                arguments: [storageKey]
            ), let walletId = UUID(uuidString: row["wallet_id"]) else {
                return nil
            }
            return WalletSecretRecord(
                walletId: walletId,
                kind: WalletSecretKind(rawValue: row["kind_raw"]) ?? kind,
                cipherData: row["cipher_data"],
                createdAt: Date(databaseMilliseconds: row["created_at_ms"]),
                updatedAt: Date(databaseMilliseconds: row["updated_at_ms"])
            )
        }
    }
}

@MainActor
final class WalletSecretRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func loadMnemonic(for walletId: UUID) throws -> [String]? {
        try WalletSecretPersistence.loadMnemonic(for: walletId, database: database)
    }

    func loadPrivateKey(for walletId: UUID) throws -> String? {
        try WalletSecretPersistence.loadPrivateKey(for: walletId, database: database)
    }

    func hasMnemonic(for walletId: UUID) -> Bool {
        if let words = try? WalletSecretPersistence.loadMnemonic(for: walletId, database: database),
           !words.isEmpty {
            return true
        }
        return false
    }

    func hasPrivateKey(for walletId: UUID) -> Bool {
        if let key = try? WalletSecretPersistence.loadPrivateKey(for: walletId, database: database),
           !key.isEmpty {
            return true
        }
        return false
    }

    func mnemonicAvailability(for walletId: UUID) -> WalletSecretPersistence.Availability {
        if hasMnemonic(for: walletId) {
            return .available
        }
        let availability = WalletSecretPersistence.availability(kind: .mnemonic, for: walletId, database: database)
        if availability == .encryptedRecordUnavailable {
            return .encryptedRecordUnavailable
        }
        return .missing
    }

    func privateKeyAvailability(for walletId: UUID) -> WalletSecretPersistence.Availability {
        if hasPrivateKey(for: walletId) {
            return .available
        }
        let availability = WalletSecretPersistence.availability(kind: .privateKey, for: walletId, database: database)
        if availability == .encryptedRecordUnavailable {
            return .encryptedRecordUnavailable
        }
        return .missing
    }
}
