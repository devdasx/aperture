import Foundation
import Security
import CryptoKit
import OSLog

/// Keychain-backed encrypted storage for BIP-39 64-byte seeds. One
/// Keychain item per wallet, keyed by the wallet's UUID. The cleartext
/// seed never lives in SwiftData — `WalletRecord` only holds the UUID,
/// `SeedVault` holds the ciphertext + key reference in Keychain.
///
/// **Cipher.** AES-GCM (CryptoKit). 256-bit key generated fresh per
/// wallet via `SymmetricKey(size: .bits256)`. Key material stored as a
/// dedicated Keychain item alongside the ciphertext so a Keychain dump
/// without the device passcode does not reveal the seed.
///
/// **ACL.** `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` on both
/// items — Aperture requires the device to have a passcode set and
/// items don't sync to iCloud Keychain (per Rule #16 — self-custody,
/// device-local). The `ThisDeviceOnly` suffix is what blocks iCloud
/// sync; the `WhenPasscodeSet` prefix means the items become
/// inaccessible if the user removes their device passcode.
///
/// **Per-wallet key separation.** A future feature can attach an
/// additional `SecAccessControl` with `.biometryCurrentSet` for
/// per-wallet biometric gating; the schema here doesn't preclude it.
/// For v1 we keep the unlock simple: app-level PIN/biometric gates the
/// wallet UI, individual seed reads succeed as long as the device is
/// unlocked.
@MainActor
enum SeedVault {
    /// Keychain service name for ciphertext items.
    private static let cipherService = "com.thuglife.aperture.seed.cipher"
    /// Keychain service name for per-wallet symmetric key items.
    private static let keyService = "com.thuglife.aperture.seed.key"

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "seed-vault")

    /// Errors surfaced by `SeedVault`. Typed throws per Swift 6
    /// guidance — callers can pattern-match without inspecting an
    /// untyped `Error`.
    enum VaultError: Error, Sendable, Equatable {
        case keychainWriteFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case keychainDeleteFailed(OSStatus)
        case noSuchWallet
        case decryptionFailed
        case invalidSeedLength
    }

    // MARK: - Public surface

    /// Encrypt the 64-byte BIP-39 seed and write both ciphertext and
    /// the per-wallet symmetric key to Keychain. Idempotent — if items
    /// already exist for `walletId`, they're overwritten.
    ///
    /// - parameter seed: the 64-byte BIP-39 seed from
    ///   `BIP39.deriveSeed(words:passphrase:)`.
    /// - parameter walletId: stable UUID also written to `WalletRecord.id`.
    /// - throws: `VaultError.invalidSeedLength` if `seed.count != 64`;
    ///   `VaultError.keychainWriteFailed` if Keychain refuses the write.
    static func storeSeed(_ seed: Data, for walletId: UUID) throws(VaultError) {
        guard seed.count == 64 else { throw .invalidSeedLength }

        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(seed, using: key, nonce: nonce)
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

    /// Read the ciphertext for `walletId` and return the decrypted
    /// 64-byte BIP-39 seed. Caller is responsible for zeroizing the
    /// returned buffer when done.
    ///
    /// - throws: `VaultError.noSuchWallet` if either Keychain item is
    ///   missing; `VaultError.decryptionFailed` if the ciphertext was
    ///   tampered with (AES-GCM authentication tag check fails).
    static func loadSeed(for walletId: UUID) throws(VaultError) -> Data {
        guard let keyData = try readItem(service: keyService, account: walletId.uuidString) else {
            throw .noSuchWallet
        }
        guard let cipherData = try readItem(service: cipherService, account: walletId.uuidString) else {
            throw .noSuchWallet
        }
        let key = SymmetricKey(data: keyData)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: cipherData)
        } catch {
            log.error("AES-GCM sealed-box decode failed: \(String(describing: error), privacy: .public)")
            throw .decryptionFailed
        }
        do {
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard plaintext.count == 64 else { throw VaultError.invalidSeedLength }
            return plaintext
        } catch {
            log.error("AES-GCM open failed: \(String(describing: error), privacy: .public)")
            throw .decryptionFailed
        }
    }

    /// `true` if Keychain holds a seed for `walletId`. Cheap — does not
    /// decrypt.
    static func hasSeed(for walletId: UUID) -> Bool {
        (try? readItem(service: cipherService, account: walletId.uuidString)) != nil
    }

    /// Delete both ciphertext and key for `walletId`. Idempotent —
    /// missing items are not an error.
    static func deleteSeed(for walletId: UUID) throws(VaultError) {
        try deleteItem(service: cipherService, account: walletId.uuidString)
        try deleteItem(service: keyService, account: walletId.uuidString)
    }

    // MARK: - Keychain primitives

    private static func writeItem(service: String, account: String, data: Data) throws(VaultError) {
        // Delete first (matches the pattern in `PinCodeStorage`): if a
        // prior item exists for this service+account, overwrite rather
        // than merge. Keychain's `SecItemUpdate` is more code for the
        // same outcome.
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
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
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
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            log.error("Keychain delete failed status=\(status) service=\(service, privacy: .public)")
            throw .keychainDeleteFailed(status)
        }
    }
}
