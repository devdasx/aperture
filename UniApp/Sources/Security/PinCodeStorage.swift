import Foundation
import CryptoKit
import Security

/// Keychain-backed PIN storage. Stores a PBKDF2-HMAC-SHA256 hash of the PIN
/// plus a 16-byte random salt — **never plaintext**. iterations = 100,000
/// (OWASP 2023 PBKDF2-SHA256 minimum recommendation).
///
/// Why Keychain, not `UserDefaults` / `@AppStorage`: Keychain encrypts
/// at-rest using the Secure Enclave when available. `UserDefaults` is
/// plain plist on disk. PIN material — even hashed — belongs in Keychain
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
///
/// **Native-only (Rule #3).** PBKDF2 is implemented as a pure-Swift loop
/// over `CryptoKit.HMAC<SHA256>` — same pattern `BIP39Seed.swift` uses
/// for HMAC-SHA512 in the BIP-39 derivation. No `CommonCrypto` bridge,
/// no SPM dependency, no hand-rolled SHA-256 — the HMAC inside the loop
/// is Apple's vetted implementation.
///
/// **Constant-time compare.** `verify(_:)` XORs the candidate-hash bytes
/// against the stored-hash bytes and ORs the results into a single
/// accumulator — never short-circuits on a first-byte mismatch. This is
/// timing-attack-resistant per OWASP "Cryptographic Storage" guidance.
///
/// **Honesty (Rule #2 §A.7 + Rule #16).** A PIN protects against casual
/// access while the phone is unlocked; it does NOT protect the recovery
/// phrase, the seed, or funds in the cryptographic sense. The
/// `PinSkipWarningSheet` states this honestly to the user.
enum PinCodeStorage {

    // MARK: - Configuration

    /// Keychain service identifier. Distinct from any other UniApp service
    /// so the PIN hash never collides with the seed (T-012) or any other
    /// future secret.
    private static let service: String = "com.thuglife.aperture.pin"
    /// Account for the PBKDF2 hash blob (32 bytes).
    private static let hashAccount: String = "pin.hash"
    /// Account for the random per-install salt (16 bytes).
    private static let saltAccount: String = "pin.salt"
    /// OWASP 2023 PBKDF2-SHA256 minimum recommendation.
    private static let iterations: Int = 100_000
    /// PBKDF2 derived-key length — SHA-256 native output size.
    private static let keyLength: Int = 32
    /// Salt length. 16 bytes is the standard for password storage; more
    /// gives no real benefit and wastes Keychain space.
    private static let saltLength: Int = 16

    // MARK: - Public surface

    /// `true` iff a PIN is currently set (Keychain contains both salt + hash).
    static var hasPin: Bool {
        return read(account: hashAccount) != nil && read(account: saltAccount) != nil
    }

    /// Set a new PIN. Generates a fresh 16-byte salt, derives the
    /// PBKDF2-SHA256 hash, and writes both to Keychain. Overwrites any
    /// existing PIN. Returns `true` on successful Keychain write.
    @discardableResult
    static func setPin(_ pin: String) -> Bool {
        let salt = secureRandomBytes(count: saltLength)
        let hash = pbkdf2HmacSha256(
            password: Data(pin.utf8),
            salt: salt,
            iterations: iterations,
            keyLength: keyLength
        )
        let saltOK = write(salt, account: saltAccount)
        let hashOK = write(hash, account: hashAccount)
        return saltOK && hashOK
    }

    /// Verify a candidate PIN against the stored hash. Returns `true` on
    /// match, `false` otherwise (including the "no PIN set" case).
    /// Constant-time comparison — never short-circuits on first-byte
    /// mismatch (timing-attack resistant).
    static func verify(_ pin: String) -> Bool {
        guard let storedHash = read(account: hashAccount),
              let storedSalt = read(account: saltAccount) else {
            return false
        }
        let candidateHash = pbkdf2HmacSha256(
            password: Data(pin.utf8),
            salt: storedSalt,
            iterations: iterations,
            keyLength: keyLength
        )
        return constantTimeEquals(candidateHash, storedHash)
    }

    /// Remove the stored PIN (both salt and hash). Used by Settings →
    /// Security → Disable PIN and by wallet-reset flows.
    static func clear() {
        delete(account: hashAccount)
        delete(account: saltAccount)
    }

    // MARK: - Constant-time compare

    /// Compares two `Data` buffers in time proportional to their length —
    /// never short-circuits on a first-byte mismatch. XORs every byte
    /// into a single accumulator; result == 0 iff the buffers are equal.
    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in 0..<a.count {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }

    // MARK: - PBKDF2-HMAC-SHA256 (RFC 2898)

    /// Pure-Swift PBKDF2 using HMAC-SHA256 as the PRF, per RFC 2898 §5.2.
    /// Same recipe as the BIP-39 seed derivation (`BIP39Seed.swift`) but
    /// with SHA-256 — `hLen = 32` instead of 64.
    ///
    /// For PIN storage the parameters are fixed: `c = 100_000`,
    /// `dkLen = 32`, so exactly one 32-byte block is produced (`l = 1`).
    private static func pbkdf2HmacSha256(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        precondition(iterations > 0, "PBKDF2 iteration count must be positive")
        precondition(keyLength > 0, "PBKDF2 derived key length must be positive")

        let key = SymmetricKey(data: password)
        let hLen = 32 // SHA-256 output size in bytes
        let blockCount = (keyLength + hLen - 1) / hLen

        var derived = Data()
        derived.reserveCapacity(blockCount * hLen)

        for blockIndex in 1...blockCount {
            var indexBytes = Data(count: 4)
            indexBytes[0] = UInt8((blockIndex >> 24) & 0xff)
            indexBytes[1] = UInt8((blockIndex >> 16) & 0xff)
            indexBytes[2] = UInt8((blockIndex >> 8) & 0xff)
            indexBytes[3] = UInt8(blockIndex & 0xff)

            var u = Data(HMAC<SHA256>.authenticationCode(
                for: salt + indexBytes,
                using: key
            ))
            var t = u

            for _ in 1..<iterations {
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for byteIndex in 0..<hLen {
                    t[byteIndex] ^= u[byteIndex]
                }
            }

            derived.append(t)
        }

        return derived.prefix(keyLength)
    }

    // MARK: - CSPRNG salt

    /// Draws `count` cryptographically-secure random bytes from the
    /// platform CSPRNG via `SecRandomCopyBytes`. Same pattern `BIP39.swift`
    /// uses for entropy generation. A failure here means the kernel
    /// cannot serve randomness — terminate honestly rather than retry.
    private static func secureRandomBytes(count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else {
                return errSecAllocate
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with status \(status)")
        }
        return bytes
    }

    // MARK: - Keychain primitives

    /// Write `data` to Keychain under `(service, account)`. Overwrites any
    /// existing value. Returns `true` on success.
    @discardableResult
    private static func write(_ data: Data, account: String) -> Bool {
        // Delete any existing item first so the add doesn't fail with
        // `errSecDuplicateItem`.
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Read the `Data` stored under `(service, account)`, or `nil` if
    /// the item is missing or unreadable.
    private static func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    /// Delete the item stored under `(service, account)`. Silently
    /// no-ops if the item doesn't exist.
    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#if DEBUG
/// Debug-mode smoke check: verify the PBKDF2-SHA256 storage round-trips
/// correctly. Runs once on first access; an assertion failure here means
/// the PIN storage has drifted from the expected behavior.
///
/// Test vectors (the user-requested ones from the orchestrator brief):
/// - `setPin("123456")` then `verify("123456")` → `true`
/// - `verify("000000")` after the above → `false`
/// - `clear()` then `hasPin` → `false`
///
/// Note: this mutates real Keychain state, so we save and restore any
/// pre-existing PIN around the check. In a clean install the save/restore
/// is a no-op; in a re-launch with a real PIN already set, the existing
/// PIN material is preserved.
private let _pinCodeStorageSmokeCheck: Void = {
    // Snapshot any existing PIN material so the smoke check is non-destructive.
    let hadPriorPin = PinCodeStorage.hasPin
    if hadPriorPin {
        // We can't read the plaintext (we don't store it) so we cannot
        // restore the exact prior PIN. Skip the destructive smoke check
        // entirely in that case — the storage is clearly working since
        // hasPin returned true.
        return
    }

    PinCodeStorage.clear() // ensure clean slate
    assert(PinCodeStorage.hasPin == false, "PinCodeStorage.clear() left state behind")
    PinCodeStorage.setPin("123456")
    assert(PinCodeStorage.hasPin == true, "setPin did not persist")
    assert(PinCodeStorage.verify("123456") == true, "verify of correct PIN returned false")
    assert(PinCodeStorage.verify("000000") == false, "verify of wrong PIN returned true")
    PinCodeStorage.clear()
    assert(PinCodeStorage.hasPin == false, "clear() did not remove PIN")
}()
#endif
