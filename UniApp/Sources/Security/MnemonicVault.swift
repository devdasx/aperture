import Foundation
import Security
import CryptoKit
import OSLog

/// Keychain-backed encrypted storage for BIP-39 mnemonics on **unbacked
/// wallets only**. Mirrors `SeedVault`'s shape (AES-GCM 256-bit cipher,
/// per-wallet symmetric key stored as a separate Keychain item, ACL
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`) but with a
/// short-lived contract: the mnemonic is stored ONLY for wallets the
/// user skipped backup on, and is deleted as soon as the user completes
/// the backup verification.
///
/// **Why this exists.** BIP-39 derivation is one-way: a stored seed
/// cannot be reversed to the original mnemonic. So once the user
/// completes backup verification, the mnemonic is genuinely gone from
/// the device — only the derived seed remains. For users who *skipped*
/// backup, they expect to be able to back up later via Settings →
/// Wallets → "Back up your recovery phrase." That UX requires the
/// mnemonic to be retrievable. This vault solves that, honestly:
///
/// 1. Created wallet, **user backs up at create**: mnemonic is NEVER
///    stored in this vault (the user wrote it down; that's the only
///    copy).
/// 2. Created wallet, **user skips backup at create**: mnemonic IS
///    stored here, encrypted. The skip-backup warning copy is
///    updated to name this honestly ("Your phrase is stored encrypted
///    on this iPhone until you back it up — once you back it up, the
///    local copy is deleted").
/// 3. Imported wallet (mnemonic): user already has the phrase by
///    definition. Vault is NOT used.
/// 4. Imported wallet (private key or watch-only): no mnemonic exists.
///    Vault is NOT used.
///
/// Per Rule #16 §A.7, this transparency is the difference between
/// "wallet that helps the user" and "wallet that pretends not to know
/// the phrase while having it."
@MainActor
enum MnemonicVault {
    private static let cipherService = "com.thuglife.aperture.mnemonic.cipher"
    private static let keyService = "com.thuglife.aperture.mnemonic.key"

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
        let joined = words.joined(separator: " ")
        guard let plaintext = joined.data(using: .utf8) else { throw .encodingFailed }

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
        try writeItem(service: keyService, account: walletId.uuidString, data: keyData)
        try writeItem(service: cipherService, account: walletId.uuidString, data: ciphertextBlob)
    }

    /// Decrypt and return the mnemonic words for `walletId`. Returns
    /// `nil` if no mnemonic is stored for this wallet (typical for
    /// backed-up wallets — by design they have only the seed).
    static func loadMnemonic(for walletId: UUID) throws(VaultError) -> [String]? {
        guard let keyData = try readItem(service: keyService, account: walletId.uuidString) else {
            return nil
        }
        guard let cipherData = try readItem(service: cipherService, account: walletId.uuidString) else {
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
            guard let joined = String(data: plaintext, encoding: .utf8) else {
                throw VaultError.decryptionFailed
            }
            return joined.split(separator: " ").map(String.init)
        } catch {
            log.error("AES-GCM open failed: \(String(describing: error), privacy: .public)")
            throw .decryptionFailed
        }
    }

    /// `true` if Keychain holds a mnemonic for `walletId`. Cheap —
    /// does not decrypt.
    static func hasMnemonic(for walletId: UUID) -> Bool {
        (try? readItem(service: cipherService, account: walletId.uuidString)) != nil
    }

    /// Delete both ciphertext and key for `walletId`. Called after
    /// the user completes backup verification — the local copy is no
    /// longer needed because the user has the phrase. Idempotent.
    static func deleteMnemonic(for walletId: UUID) throws(VaultError) {
        try deleteItem(service: cipherService, account: walletId.uuidString)
        try deleteItem(service: keyService, account: walletId.uuidString)
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
