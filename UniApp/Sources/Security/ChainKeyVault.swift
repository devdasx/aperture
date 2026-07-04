import Foundation
import CryptoKit
import OSLog

/// AES-GCM encryption for per-chain private keys stored in GRDB.
///
/// The encrypted key blobs live on `chain_states.encrypted_private_key`. The
/// app-wide AES master key also lives in GRDB's `local_secure_blobs` table so
/// chain signing no longer depends on Keychain compatibility state.
enum ChainKeyVault {
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "chain-key-vault")
    nonisolated(unsafe) private static var cachedMasterKeyData: Data?

    static let scheme = "aesgcm256-grdb-v2"

    enum VaultError: Error, Sendable, Equatable {
        case invalidMasterKey
        case cryptoFailed
    }

    static func configure(database: AppDatabase = .shared) {
        cachedMasterKeyData = try? database.write { db in
            try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.chainKeyMasterKey, db: db)
        }
    }

    static func seal(_ plaintext: Data) throws(VaultError) -> Data {
        let key = try masterKey()
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw VaultError.cryptoFailed }
            return combined
        } catch let error as VaultError {
            throw error
        } catch {
            log.error("AES-GCM seal failed: \(String(describing: error), privacy: .public)")
            throw .cryptoFailed
        }
    }

    static func open(_ combined: Data) throws(VaultError) -> Data {
        let key = try masterKey()
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            log.error("AES-GCM open failed: \(String(describing: error), privacy: .public)")
            throw .cryptoFailed
        }
    }

    static func clear(database: AppDatabase = .shared) {
        try? database.write { db in
            try LocalSecureBlobStore.delete(LocalSecureBlobStore.chainKeyMasterKey, db: db)
            cachedMasterKeyData = try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.chainKeyMasterKey, db: db)
        }
    }

    private static func masterKey() throws(VaultError) -> SymmetricKey {
        if let existing = cachedMasterKeyData {
            guard existing.count == 32 else { throw .invalidMasterKey }
            return SymmetricKey(data: existing)
        }
        guard let keyData = try? AppDatabase.shared.write({ db in
            try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.chainKeyMasterKey, db: db)
        }), keyData.count == 32 else {
            throw .invalidMasterKey
        }
        cachedMasterKeyData = keyData
        return SymmetricKey(data: keyData)
    }
}
