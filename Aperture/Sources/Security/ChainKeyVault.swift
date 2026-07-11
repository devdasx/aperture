import Foundation
import CryptoKit
import OSLog
import os

/// AES-GCM encryption for per-chain private keys stored in GRDB.
///
/// The encrypted key blobs live on `chain_states.encrypted_private_key`. The
/// app-wide AES master key also lives in GRDB's `local_secure_blobs` table so
/// chain signing no longer depends on Keychain compatibility state.
enum ChainKeyVault {
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "chain-key-vault")
    /// P3-004: unfair lock instead of `nonisolated(unsafe)` bare cache.
    private static let cache = OSAllocatedUnfairLock<Data?>(initialState: nil)

    static let scheme = "aesgcm256-grdb-v2"

    enum VaultError: Error, Sendable, Equatable {
        case invalidMasterKey
        case cryptoFailed
    }

    static func configure(database: AppDatabase = .shared) {
        let keyData = try? database.write { db in
            try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.chainKeyMasterKey, db: db)
        }
        cache.withLock { $0 = keyData }
    }

    /// P2-016: bind ciphertext to chain-key purpose AAD so a swapped DB
    /// blob cannot decrypt as a different secret class (parity with
    /// `WalletSecretCrypto` associated data). Existing v2 blobs without
    /// AAD still open via legacy path for one migration window.
    private static let sealAAD = Data("aperture.chain-key.v2".utf8)

    static func seal(_ plaintext: Data) throws(VaultError) -> Data {
        let key = try masterKey()
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: sealAAD)
            guard let combined = sealed.combined else { throw VaultError.cryptoFailed }
            return combined
        } catch let error as VaultError {
            throw error
        } catch {
            // P3-016: type only in public log metadata.
            log.error("AES-GCM seal failed: \(String(describing: type(of: error)), privacy: .public)")
            throw .cryptoFailed
        }
    }

    static func open(_ combined: Data) throws(VaultError) -> Data {
        let key = try masterKey()
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            // Prefer AAD-bound open (new seals).
            if let opened = try? AES.GCM.open(box, using: key, authenticating: sealAAD) {
                return opened
            }
            // Legacy no-AAD seals written before P2-016.
            return try AES.GCM.open(box, using: key)
        } catch {
            log.error("AES-GCM open failed: \(String(describing: type(of: error)), privacy: .public)")
            throw .cryptoFailed
        }
    }

    static func clear(database: AppDatabase = .shared) {
        try? database.write { db in
            try LocalSecureBlobStore.delete(LocalSecureBlobStore.chainKeyMasterKey, db: db)
            let next = try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.chainKeyMasterKey, db: db)
            cache.withLock { $0 = next }
        }
    }

    private static func masterKey() throws(VaultError) -> SymmetricKey {
        if let existing = cache.withLock({ $0 }), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        guard let keyData = try? AppDatabase.shared.write({ db in
            try LocalSecureBlobStore.ensureRandomKey(LocalSecureBlobStore.chainKeyMasterKey, db: db)
        }), keyData.count == 32 else {
            throw .invalidMasterKey
        }
        cache.withLock { $0 = keyData }
        return SymmetricKey(data: keyData)
    }
}
