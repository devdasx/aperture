import Foundation
import Security
import CryptoKit
import OSLog
import GRDB

/// Keychain-backed encrypted storage for the **user-readable secret**
/// behind each wallet — the BIP-39 mnemonic for created / phrase-import
/// wallets, the original private-key string (hex or WIF) for key-import
/// wallets. Mirrors `SeedVault`'s shape (AES-GCM 256-bit cipher,
/// per-wallet symmetric key stored as a separate Keychain item, ACL
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
///
/// **Why this exists.** Seed/key derivation is one-way: the 64-byte
/// `SeedVault` slot cannot be reversed to the original mnemonic or the
/// exact key string the user typed. Anything the user entrusts to
/// Aperture — generated phrase, imported phrase, imported key — must
/// remain viewable from Settings → Wallets on this device. The current
/// contract (per the user's 2026-06-13 direction: "anything user import
/// via app should be saved in the app locally"):
///
/// 1. **Created wallet:** mnemonic stored here at persist time, always.
/// 2. **Imported wallet (mnemonic):** the typed phrase stored here at
///    import time, always.
/// 3. **Imported wallet (private key / WIF):** the typed key string
///    stored here at import time, always (separate Keychain services —
///    see `storePrivateKey`).
/// 4. **Watch-only wallet:** no secret exists. Vault is NOT used.
///
/// Entries are deleted ONLY by wallet deletion
/// (`WalletDetailView.deleteWallet`, `WalletRepository.deleteWallet`),
/// Reset Aperture (`AdvancedSettingsView`), and the fresh-install purge
/// (`FreshInstallGuard`). Per Rule #16 §A.7, this transparency is the
/// difference between "wallet that helps the user" and "wallet that
/// pretends not to know the phrase while having it."
/// **Concurrency (2026-06-14, Rule #28).** No longer `@MainActor`: every
/// method is pure, thread-safe Keychain I/O (`SecItem*`) + AES-GCM
/// (CryptoKit value types) + logging, with zero main-actor state. The
/// annotation was an over-restriction that forced the decrypt onto the
/// main thread (blocking the reveal/backup sheets on present). Now
/// `nonisolated`, so callers can run it off-main via `Task.detached`;
/// existing synchronous main-actor callers are unaffected (nonisolated
/// static funcs are callable from any isolation). Actor isolation is not
/// a security boundary — the Keychain ACLs (`kSecAttr…`) are.
enum MnemonicVault {
    private static let cipherService = "com.thuglife.aperture.mnemonic.cipher"
    private static let keyService = "com.thuglife.aperture.mnemonic.key"
    /// Separate services for imported private-key strings so a key
    /// entry can never be confused with (or shadow) a phrase entry
    /// for the same wallet id. Both are listed in
    /// `FreshInstallGuard.knownServices`.
    private static let privateKeyCipherService = "com.thuglife.aperture.privatekey.cipher"
    private static let privateKeyKeyService = "com.thuglife.aperture.privatekey.key"

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "mnemonic-vault")

    enum VaultError: Error, Sendable, Equatable {
        case keychainWriteFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case keychainDeleteFailed(OSStatus)
        case noSuchWallet
        case decryptionFailed
        case encodingFailed
    }

    // MARK: - Public surface

    /// Encrypt and store the mnemonic for `walletId`. Mnemonic is
    /// joined with single-space separators (matches the
    /// `BIP39.deriveSeed` input shape) and stored as UTF-8 bytes.
    static func storeMnemonic(_ words: [String], for walletId: UUID) throws(VaultError) {
        try storeSecret(
            words.joined(separator: " "),
            cipherService: cipherService,
            keyService: keyService,
            account: walletId.uuidString
        )
    }

    /// Decrypt and return the mnemonic words for `walletId`. Returns
    /// `nil` if no mnemonic is stored for this wallet (imported-key /
    /// watch-only kinds, or wallets persisted before the always-store
    /// policy shipped).
    static func loadMnemonic(for walletId: UUID) throws(VaultError) -> [String]? {
        guard let joined = try loadSecret(
            cipherService: cipherService,
            keyService: keyService,
            account: walletId.uuidString
        ) else { return nil }
        return joined.split(separator: " ").map(String.init)
    }

    /// `true` if Keychain holds a mnemonic for `walletId`. Cheap —
    /// does not decrypt.
    static func hasMnemonic(for walletId: UUID) -> Bool {
        (try? readItem(service: cipherService, account: walletId.uuidString)) != nil
    }

    /// Delete both ciphertext and key for `walletId`. Called by wallet
    /// deletion / Reset Aperture. Idempotent.
    static func deleteMnemonic(for walletId: UUID) throws(VaultError) {
        try deleteItem(service: cipherService, account: walletId.uuidString)
        try deleteItem(service: keyService, account: walletId.uuidString)
    }

    // MARK: - Imported private-key strings

    /// Encrypt and store the original private-key string the user
    /// imported (hex or WIF, exactly as typed after trimming) for
    /// `walletId`. `SeedVault` holds only the decoded raw bytes, which
    /// can't be rendered back to the WIF/base58 form the user expects
    /// to see — this slot preserves the displayable original.
    static func storePrivateKey(_ keyString: String, for walletId: UUID) throws(VaultError) {
        try storeSecret(
            keyString,
            cipherService: privateKeyCipherService,
            keyService: privateKeyKeyService,
            account: walletId.uuidString
        )
    }

    /// Decrypt and return the imported private-key string for
    /// `walletId`. Returns `nil` if none is stored (non-key kinds, or
    /// key wallets imported before the always-store policy shipped).
    static func loadPrivateKey(for walletId: UUID) throws(VaultError) -> String? {
        try loadSecret(
            cipherService: privateKeyCipherService,
            keyService: privateKeyKeyService,
            account: walletId.uuidString
        )
    }

    /// `true` if Keychain holds an imported private-key string for
    /// `walletId`. Cheap — does not decrypt.
    static func hasPrivateKey(for walletId: UUID) -> Bool {
        (try? readItem(service: privateKeyCipherService, account: walletId.uuidString)) != nil
    }

    /// Delete the stored private-key string for `walletId`. Called by
    /// wallet deletion / Reset Aperture. Idempotent.
    static func deletePrivateKey(for walletId: UUID) throws(VaultError) {
        try deleteItem(service: privateKeyCipherService, account: walletId.uuidString)
        try deleteItem(service: privateKeyKeyService, account: walletId.uuidString)
    }

    // MARK: - Shared seal/open

    /// Seal `secret` with a fresh AES-GCM 256-bit key and write both
    /// items to Keychain under the given services.
    private static func storeSecret(
        _ secret: String,
        cipherService: String,
        keyService: String,
        account: String
    ) throws(VaultError) {
        guard let plaintext = secret.data(using: .utf8) else { throw .encodingFailed }

        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        } catch {
            log.error("AES-GCM seal failed: \(String(describing: error), privacy: .public)")
            throw .keychainWriteFailed(errSecParam)
        }
        guard let ciphertextBlob = sealed.combined else {
            throw .keychainWriteFailed(errSecParam)
        }

        let keyData = key.withUnsafeBytes { Data($0) }
        try writeItem(service: keyService, account: account, data: keyData)
        try writeItem(service: cipherService, account: account, data: ciphertextBlob)
    }

    /// Read + open the sealed secret under the given services. Returns
    /// `nil` when either item is absent.
    private static func loadSecret(
        cipherService: String,
        keyService: String,
        account: String
    ) throws(VaultError) -> String? {
        guard let keyData = try readItem(service: keyService, account: account) else {
            recordSecretEvent(
                .debug,
                message: "Wallet secret key item missing",
                cipherService: cipherService,
                keyService: keyService,
                account: account
            )
            return nil
        }
        guard let cipherData = try readItem(service: cipherService, account: account) else {
            recordSecretEvent(
                .debug,
                message: "Wallet secret cipher item missing",
                cipherService: cipherService,
                keyService: keyService,
                account: account,
                metadata: ["keyBytes": "\(keyData.count)"]
            )
            return nil
        }
        let key = SymmetricKey(data: keyData)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: cipherData)
        } catch {
            log.error("AES-GCM box decode failed: \(String(describing: error), privacy: .public)")
            recordSecretEvent(
                .error,
                message: "Wallet secret sealed-box decode failed",
                cipherService: cipherService,
                keyService: keyService,
                account: account,
                metadata: [
                    "keyBytes": "\(keyData.count)",
                    "cipherBytes": "\(cipherData.count)",
                    "error": String(describing: error)
                ]
            )
            throw .decryptionFailed
        }
        do {
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard let secret = String(data: plaintext, encoding: .utf8) else {
                recordSecretEvent(
                    .error,
                    message: "Wallet secret UTF-8 decode failed",
                    cipherService: cipherService,
                    keyService: keyService,
                    account: account,
                    metadata: [
                        "keyBytes": "\(keyData.count)",
                        "cipherBytes": "\(cipherData.count)",
                        "plainBytes": "\(plaintext.count)"
                    ]
                )
                throw VaultError.decryptionFailed
            }
            recordSecretEvent(
                .debug,
                message: "Wallet secret opened",
                cipherService: cipherService,
                keyService: keyService,
                account: account,
                metadata: [
                    "keyBytes": "\(keyData.count)",
                    "cipherBytes": "\(cipherData.count)"
                ]
            )
            return secret
        } catch {
            log.error("AES-GCM open failed: \(String(describing: error), privacy: .public)")
            let errorText = String(describing: error)
            let reason = errorText.contains("authenticationFailure")
                ? "authenticationFailure"
                : errorText
            recordSecretEvent(
                .error,
                message: "Wallet secret open failed: \(reason)",
                cipherService: cipherService,
                keyService: keyService,
                account: account,
                metadata: [
                    "keyBytes": "\(keyData.count)",
                    "cipherBytes": "\(cipherData.count)",
                    "error": errorText
                ]
            )
            throw .decryptionFailed
        }
    }

    // MARK: - Keychain primitives (parallel to SeedVault)

    private static func writeItem(service: String, account: String, data: Data) throws(VaultError) {
        try? deleteItem(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("Keychain write failed status=\(status) service=\(service, privacy: .public)")
            DiagnosticsLogStore.shared.record(
                .error,
                category: "wallet-secret",
                message: "Wallet secret Keychain write failed",
                metadata: [
                    "service": service,
                    "account": account,
                    "status": "\(status)",
                    "bytes": "\(data.count)"
                ]
            )
            throw .keychainWriteFailed(status)
        }
    }

    private static func readItem(service: String, account: String) throws(VaultError) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:    return result as? Data
        case errSecItemNotFound: return nil
        default:
            log.error("Keychain read failed status=\(status) service=\(service, privacy: .public)")
            DiagnosticsLogStore.shared.record(
                .error,
                category: "wallet-secret",
                message: "Wallet secret Keychain read failed",
                metadata: [
                    "service": service,
                    "account": account,
                    "status": "\(status)"
                ]
            )
            throw .keychainReadFailed(status)
        }
    }

    private static func deleteItem(service: String, account: String) throws(VaultError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        default:
            log.error("Keychain delete failed status=\(status) service=\(service, privacy: .public)")
            DiagnosticsLogStore.shared.record(
                .error,
                category: "wallet-secret",
                message: "Wallet secret Keychain delete failed",
                metadata: [
                    "service": service,
                    "account": account,
                    "status": "\(status)"
                ]
            )
            throw .keychainDeleteFailed(status)
        }
    }

    private static func recordSecretEvent(
        _ level: DiagnosticsLogLevel,
        message: String,
        cipherService: String,
        keyService: String,
        account: String,
        metadata: [String: String] = [:]
    ) {
        var metadata = metadata
        metadata["account"] = account
        metadata["kind"] = secretKind(cipherService: cipherService)
        metadata["cipherService"] = cipherService
        metadata["keyService"] = keyService
        DiagnosticsLogStore.shared.record(
            level,
            category: "wallet-secret",
            message: message,
            metadata: metadata
        )
    }

    private static func secretKind(cipherService: String) -> String {
        switch cipherService {
        case Self.cipherService:
            return "mnemonic"
        case Self.privateKeyCipherService:
            return "privateKey"
        default:
            return "unknown"
        }
    }
}

// MARK: - GRDB-backed encrypted wallet secrets

/// Device-local encryption for `WalletSecretRecord` rows.
///
/// The master key is an app-owned random 256-bit key stored in Keychain with
/// `AfterFirstUnlockThisDeviceOnly`. It is not derived from the app passcode
/// or Face ID, so turning those app locks off cannot make manual backup
/// unable to read a phrase. The GRDB row stores only AES-GCM ciphertext.
enum WalletSecretCrypto {
    private static let masterKeyService = "com.thuglife.aperture.wallet-secret.master-key"
    private static let masterKeyAccount = "v1"
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "wallet-secret-crypto")

    enum CryptoError: Error, Sendable, Equatable {
        case randomFailed(OSStatus)
        case keychainWriteFailed(OSStatus)
        case keychainReadFailed(OSStatus)
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

    static func clearMasterKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: masterKeyService,
            kSecAttrAccount as String: masterKeyAccount
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    private static func masterKey() throws(CryptoError) -> SymmetricKey {
        if let existing = try readMasterKeyData() {
            guard existing.count == 32 else { throw .invalidMasterKey }
            return SymmetricKey(data: existing)
        }
        let keyData = try randomBytes(count: 32)
        try writeMasterKeyData(keyData)
        return SymmetricKey(data: keyData)
    }

    private static func randomBytes(count: Int) throws(CryptoError) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else { throw .randomFailed(status) }
        return data
    }

    private static func readMasterKeyData() throws(CryptoError) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: masterKeyService,
            kSecAttrAccount as String: masterKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw .keychainReadFailed(status)
        }
    }

    private static func writeMasterKeyData(_ data: Data) throws(CryptoError) {
        clearMasterKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: masterKeyService,
            kSecAttrAccount as String: masterKeyAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychainWriteFailed(status) }
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

    static func encryptedMnemonicRow(_ words: [String], for walletId: UUID) throws -> EncryptedSecretRow {
        let canonical = words.map { $0.lowercased() }.joined(separator: " ")
        return try encryptedSecretRow(canonical, kind: .mnemonic, walletId: walletId)
    }

    static func encryptedPrivateKeyRow(_ keyString: String, for walletId: UUID) throws -> EncryptedSecretRow {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
        return try encryptedSecretRow(trimmed, kind: .privateKey, walletId: walletId)
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

    private static func loadSecret(
        kind: WalletSecretKind,
        walletId: UUID,
        database: AppDatabase
    ) throws -> String? {
        guard let record = try existingRecord(kind: kind, walletId: walletId, database: database) else {
            return nil
        }
        let associatedData = Data(record.key.utf8)
        let plaintext = try WalletSecretCrypto.open(record.cipherData, associatedData: associatedData)
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
        let dbError: Error?
        do {
            if let words = try WalletSecretPersistence.loadMnemonic(for: walletId, database: database) {
                return words
            }
            dbError = nil
        } catch {
            dbError = error
        }

        if let words = try MnemonicVault.loadMnemonic(for: walletId), !words.isEmpty {
            try? WalletSecretPersistence.upsertMnemonic(words, for: walletId, database: database)
            return words
        }

        if let dbError {
            throw dbError
        }
        return nil
    }

    func loadPrivateKey(for walletId: UUID) throws -> String? {
        let dbError: Error?
        do {
            if let key = try WalletSecretPersistence.loadPrivateKey(for: walletId, database: database) {
                return key
            }
            dbError = nil
        } catch {
            dbError = error
        }

        if let key = try MnemonicVault.loadPrivateKey(for: walletId), !key.isEmpty {
            try? WalletSecretPersistence.upsertPrivateKey(key, for: walletId, database: database)
            return key
        }

        if let dbError {
            throw dbError
        }
        return nil
    }

    func hasMnemonic(for walletId: UUID) -> Bool {
        if let words = try? WalletSecretPersistence.loadMnemonic(for: walletId, database: database),
           !words.isEmpty {
            return true
        }
        return MnemonicVault.hasMnemonic(for: walletId)
    }

    func hasPrivateKey(for walletId: UUID) -> Bool {
        if let key = try? WalletSecretPersistence.loadPrivateKey(for: walletId, database: database),
           !key.isEmpty {
            return true
        }
        return MnemonicVault.hasPrivateKey(for: walletId)
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
