import Foundation
import Security
import CryptoKit
import OSLog

/// Keychain-backed encrypted storage for the **user-readable secret**
/// behind each wallet — the BIP-39 mnemonic for created / phrase-import
/// wallets, the original private-key string (hex or WIF) for key-import
/// wallets. Mirrors `SeedVault`'s shape (AES-GCM 256-bit cipher,
/// per-wallet symmetric key stored as a separate Keychain item, ACL
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`).
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
@MainActor
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
            return nil
        }
        guard let cipherData = try readItem(service: cipherService, account: account) else {
            return nil
        }
        let key = SymmetricKey(data: keyData)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: cipherData)
        } catch {
            log.error("AES-GCM box decode failed: \(String(describing: error), privacy: .public)")
            throw .decryptionFailed
        }
        do {
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard let secret = String(data: plaintext, encoding: .utf8) else {
                throw VaultError.decryptionFailed
            }
            return secret
        } catch {
            log.error("AES-GCM open failed: \(String(describing: error), privacy: .public)")
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("Keychain write failed status=\(status) service=\(service, privacy: .public)")
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
            throw .keychainDeleteFailed(status)
        }
    }
}
