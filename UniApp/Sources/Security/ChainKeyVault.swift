import Foundation
import Security
import CryptoKit
import OSLog

/// **AES-GCM encryption for per-chain private keys stored in SwiftData.**
///
/// User direction (2026-06-17): each chain's private key is stored as an
/// encrypted blob in the local DB (`ChainStateRecord.encryptedPrivateKey`).
/// This vault owns the cipher. It mirrors `SeedVault`'s posture — AES-GCM
/// (CryptoKit) under a 256-bit symmetric key held in the Keychain — but
/// with two differences suited to its job:
///
/// 1. **One app-wide key, not per-wallet.** The blobs live in the DB keyed
///    by `(walletId, chain)`; a single master symmetric key in the
///    Keychain seals all of them. A Keychain dump without the device
///    passcode still cannot read any chain key (the master key carries the
///    same `WhenPasscodeSetThisDeviceOnly` ACL `SeedVault` uses).
/// 2. **Not `@MainActor`.** Encryption runs inside
///    `SigningKeyProvider.withPrivateKey`'s `nonisolated` closure (off the
///    main thread per Rule #28) and from the off-main refresh coordinator,
///    so the API is synchronous and isolation-free. Keychain calls are
///    thread-safe; the get-or-create handles the `errSecDuplicateItem`
///    race two threads could hit on first run.
///
/// **The plaintext key never persists.** `SigningKeyProvider` derives the
/// `PrivateKey` inside its closure and calls `seal(_:)` before the raw
/// bytes escape; only the returned `combined` ciphertext leaves. `open(_:)`
/// exists for the future signing-from-DB path and for tests' round-trip
/// proof.
enum ChainKeyVault {

    /// Keychain service + account for the single master symmetric key.
    private static let keyService = "com.thuglife.aperture.chainkey.master"
    private static let keyAccount = "v1"

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "chain-key-vault")

    /// Provenance tag persisted alongside each blob in
    /// `ChainStateRecord.keyEncryptionScheme`.
    static let scheme = "aesgcm256-v1"

    enum VaultError: Error, Sendable, Equatable {
        case keychainWriteFailed(OSStatus)
        case keychainReadFailed(OSStatus)
        case cryptoFailed
    }

    // MARK: - Public surface

    /// Encrypt `plaintext` (a raw private key) and return the AES-GCM
    /// `SealedBox.combined` ciphertext to persist. The master key is
    /// created on first use.
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

    /// Decrypt a `combined` ciphertext produced by `seal(_:)` back to the
    /// raw private key. The caller is responsible for using it within the
    /// narrowest possible scope and not retaining it.
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

    // MARK: - Master key (get-or-create)

    /// Fetch the master symmetric key from the Keychain, creating it on
    /// first use. Handles the `errSecDuplicateItem` race where two threads
    /// create simultaneously (re-read wins).
    private static func masterKey() throws(VaultError) -> SymmetricKey {
        if let existing = try readKey() {
            return SymmetricKey(data: existing)
        }
        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        do {
            try writeKey(raw)
            return fresh
        } catch .keychainWriteFailed(errSecDuplicateItem) {
            // Lost the create race — another thread wrote first. Re-read.
            guard let existing = try readKey() else { throw VaultError.keychainReadFailed(errSecItemNotFound) }
            return SymmetricKey(data: existing)
        }
    }

    private static func writeKey(_ data: Data) throws(VaultError) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("Keychain write failed status=\(status)")
            throw .keychainWriteFailed(status)
        }
    }

    private static func readKey() throws(VaultError) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
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
            log.error("Keychain read failed status=\(status)")
            throw .keychainReadFailed(status)
        }
    }
}
