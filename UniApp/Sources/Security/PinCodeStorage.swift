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
    /// Account for the failed-attempt record (4-byte count + 8-byte
    /// last-failure timestamp). Lives alongside the hash/salt items with
    /// the same accessibility class, so the brute-force counter survives
    /// app kill and reinstall just like the PIN material it protects.
    private static let failureAccount: String = "pin.failures"
    /// Attempts 1–4 carry no delay; the escalating lockout starts at 5.
    private static let lockoutThreshold: Int = 5
    /// Escalation cap: 960 s = 16 minutes per attempt.
    private static let maxLockoutDelay: TimeInterval = 960
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

    /// Set a new PIN, off the calling thread. The 100k-iteration PBKDF2
    /// derivation takes tens of milliseconds on modern hardware — too
    /// long for the main thread mid-interaction. The synchronous core
    /// runs on a detached task; the caller awaits the result.
    ///
    /// Generates a fresh 16-byte salt, derives the PBKDF2-SHA256 hash,
    /// writes both to Keychain, and resets the failed-attempt record
    /// (a fresh PIN starts with a clean slate). Overwrites any existing
    /// PIN. Returns `true` on successful Keychain write.
    static func setPin(_ pin: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { _setPinSync(pin) }.value
    }

    /// Synchronous `setPin` wrapper. Prefer the async variant — this
    /// exists for legacy synchronous call sites (Settings → Change
    /// passcode commits from a sync closure) and runs the full PBKDF2
    /// derivation on the calling thread.
    @discardableResult
    static func setPin(_ pin: String) -> Bool {
        _setPinSync(pin)
    }

    /// Verify a candidate PIN against the stored hash, off the calling
    /// thread (the PBKDF2 derivation is deliberately slow). Returns
    /// `true` on match, `false` otherwise (including the "no PIN set"
    /// case). Constant-time comparison — never short-circuits on
    /// first-byte mismatch (timing-attack resistant).
    static func verify(_ pin: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { _verifySync(pin) }.value
    }

    /// Remove the stored PIN (salt, hash, and failed-attempt record).
    /// Used by Settings → Security → Disable PIN and by wallet-reset
    /// flows.
    static func clear() {
        delete(account: hashAccount)
        delete(account: saltAccount)
        delete(account: failureAccount)
    }

    // MARK: - Failed-attempt rate limiting

    /// Record a failed verify attempt. Persists the incremented count and
    /// the current timestamp to Keychain (same accessibility class as the
    /// PIN material, so the counter survives app kill and reinstall).
    /// Returns the new failure count.
    @discardableResult
    static func recordFailure() -> Int {
        let newCount = (readFailureRecord()?.count ?? 0) + 1
        writeFailureRecord(count: newCount, lastFailure: Date())
        return newCount
    }

    /// Reset the failed-attempt record. Called on every successful
    /// verification (and implicitly by `clear()` / `setPin`).
    static func clearFailures() {
        delete(account: failureAccount)
    }

    /// Seconds remaining before another verify attempt is allowed.
    /// `0` means no lockout is active.
    ///
    /// Escalation schedule: attempts 1–4 carry no delay; from attempt 5
    /// the delay is `min(2^(attempts - 5), 960)` seconds — 1 s, 2 s,
    /// 4 s, … capped at 16 minutes. There is no permanent wipe: the
    /// recovery path for a forgotten PIN is the recovery phrase, not
    /// data destruction.
    static func lockoutRemaining() -> TimeInterval {
        guard let record = readFailureRecord(),
              record.count >= lockoutThreshold else {
            return 0
        }
        let exponent = Double(record.count - lockoutThreshold)
        let delay = min(pow(2.0, exponent), maxLockoutDelay)
        let elapsed = Date().timeIntervalSince(record.lastFailure)
        guard elapsed >= 0 else {
            // Wall clock rolled backwards — honest worst case: the full
            // delay applies again rather than trusting a bogus elapsed.
            return delay
        }
        return max(0, delay - elapsed)
    }

    /// Decode the 12-byte failure record: 4-byte big-endian count +
    /// 8-byte big-endian `Double.bitPattern` of the last-failure
    /// `timeIntervalSince1970`. Malformed data reads as "no record".
    private static func readFailureRecord() -> (count: Int, lastFailure: Date)? {
        guard let data = read(account: failureAccount), data.count == 12 else {
            return nil
        }
        let bytes = [UInt8](data)
        var count: UInt32 = 0
        for index in 0..<4 {
            count = (count << 8) | UInt32(bytes[index])
        }
        var stampBits: UInt64 = 0
        for index in 4..<12 {
            stampBits = (stampBits << 8) | UInt64(bytes[index])
        }
        let stamp = Double(bitPattern: stampBits)
        guard stamp.isFinite else { return nil }
        return (Int(count), Date(timeIntervalSince1970: stamp))
    }

    /// Encode and persist the failure record (format documented on
    /// `readFailureRecord`).
    private static func writeFailureRecord(count: Int, lastFailure: Date) {
        let countBits = UInt32(clamping: count)
        let stampBits = lastFailure.timeIntervalSince1970.bitPattern
        var data = Data(capacity: 12)
        for shift in stride(from: 24, through: 0, by: -8) {
            data.append(UInt8((countBits >> UInt32(shift)) & 0xff))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((stampBits >> UInt64(shift)) & 0xff))
        }
        write(data, account: failureAccount)
    }

    // MARK: - Synchronous cores

    /// Synchronous `setPin` core. Runs the full PBKDF2 derivation on the
    /// calling thread — only ever invoked from the async variant's
    /// detached task or the legacy sync wrapper.
    private static func _setPinSync(_ pin: String) -> Bool {
        let salt = secureRandomBytes(count: saltLength)
        let hash = pbkdf2HmacSha256(
            password: Data(pin.utf8),
            salt: salt,
            iterations: iterations,
            keyLength: keyLength
        )
        let saltOK = write(salt, account: saltAccount)
        let hashOK = write(hash, account: hashAccount)
        if saltOK && hashOK {
            clearFailures()
        }
        return saltOK && hashOK
    }

    /// Synchronous `verify` core. Runs the full PBKDF2 derivation on the
    /// calling thread — only ever invoked from the async variant's
    /// detached task.
    private static func _verifySync(_ pin: String) -> Bool {
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
    /// existing value. Returns `true` on success. The `service` parameter
    /// defaults to the production PIN service; the DEBUG smoke check
    /// passes a distinct test service so it never touches real PIN
    /// material.
    @discardableResult
    private static func write(
        _ data: Data,
        account: String,
        service: String = PinCodeStorage.service
    ) -> Bool {
        // Delete any existing item first so the add doesn't fail with
        // `errSecDuplicateItem`.
        delete(account: account, service: service)
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
    private static func read(
        account: String,
        service: String = PinCodeStorage.service
    ) -> Data? {
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
    private static func delete(
        account: String,
        service: String = PinCodeStorage.service
    ) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#if DEBUG
extension PinCodeStorage {
    /// Keychain service used exclusively by the DEBUG smoke check —
    /// distinct from the production PIN service so the check never
    /// reads, writes, or deletes real PIN material.
    fileprivate static let smokeCheckService: String = "com.thuglife.aperture.pin.smoketest"

    /// Debug-mode smoke check: verify the PBKDF2-SHA256 storage
    /// round-trips correctly. An assertion failure here means the PIN
    /// storage has drifted from the expected behavior.
    ///
    /// Two hardening properties (2026-06-10):
    /// 1. **Distinct service.** All Keychain traffic goes to
    ///    `smokeCheckService`, never the production PIN service, so a
    ///    user's real PIN can never be racing against (or clobbered by)
    ///    the smoke check.
    /// 2. **Off the main thread.** The check runs two full
    ///    100k-iteration PBKDF2 derivations — far too slow for app
    ///    startup on the main thread. It runs on a detached
    ///    utility-priority task.
    fileprivate static func debugSmokeCheck() {
        Task.detached(priority: .utility) {
            let service = smokeCheckService
            // Clean slate in the test service.
            delete(account: hashAccount, service: service)
            delete(account: saltAccount, service: service)

            let salt = secureRandomBytes(count: saltLength)
            let hash = pbkdf2HmacSha256(
                password: Data("123456".utf8),
                salt: salt,
                iterations: iterations,
                keyLength: keyLength
            )
            assert(write(salt, account: saltAccount, service: service),
                   "smoke check: salt write failed")
            assert(write(hash, account: hashAccount, service: service),
                   "smoke check: hash write failed")

            guard let storedSalt = read(account: saltAccount, service: service),
                  let storedHash = read(account: hashAccount, service: service) else {
                assertionFailure("smoke check: read-back of salt/hash failed")
                return
            }
            let correct = pbkdf2HmacSha256(
                password: Data("123456".utf8),
                salt: storedSalt,
                iterations: iterations,
                keyLength: keyLength
            )
            let wrong = pbkdf2HmacSha256(
                password: Data("000000".utf8),
                salt: storedSalt,
                iterations: iterations,
                keyLength: keyLength
            )
            assert(constantTimeEquals(correct, storedHash),
                   "smoke check: verify of correct PIN returned false")
            assert(!constantTimeEquals(wrong, storedHash),
                   "smoke check: verify of wrong PIN returned true")

            delete(account: hashAccount, service: service)
            delete(account: saltAccount, service: service)
            assert(read(account: hashAccount, service: service) == nil,
                   "smoke check: cleanup did not remove test items")
        }
    }
}

/// Lazy-global trigger for the smoke check. Initialization only spawns
/// the detached task — the PBKDF2 work itself never touches the thread
/// that first references this global.
private let _pinCodeStorageSmokeCheck: Void = PinCodeStorage.debugSmokeCheck()
#endif
