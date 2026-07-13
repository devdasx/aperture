import Foundation
import CryptoKit
import CommonCrypto
import Security

/// End-to-end encryption for **iCloud wallet backup** (2026-06-19 backup
/// handoff). The BIP-39 mnemonic is encrypted **on device** with a key
/// derived from the user's backup password; only the ciphertext + salt +
/// KDF parameters ever leave the device. Apple and Aperture can never read
/// it, and there is **no recoverable copy** of the password anywhere — lose
/// it and the backup is permanently unreadable (the design states this
/// unmistakably to the user).
///
/// **Construction.**
/// - **KDF:** PBKDF2-HMAC-SHA256, 600 000 iterations (OWASP 2023 guidance
///   for PBKDF2-SHA256) over a fresh 16-byte random salt → a 256-bit key.
///   The iteration count + salt travel in the blob so a future bump stays
///   backward-readable.
/// - **Cipher:** AES-GCM-256 (CryptoKit). The sealed box's `combined`
///   form (nonce ‖ ciphertext ‖ tag) is what we store. A wrong password
///   derives a wrong key and GCM authentication fails → `openFailed`,
///   which is how restore detects a bad password.
///
/// This type is pure, `Sendable`-safe (only value types + C calls), and has
/// no app dependencies so it can be unit-tested / CLI-verified in isolation.
enum WalletBackupCrypto {
    /// Identifier persisted in the blob so restore knows which KDF produced
    /// the key. Bump alongside `WalletBackupBlob.currentVersion` if changed.
    static let kdfName = "PBKDF2-HMAC-SHA256"
    /// OWASP-2023 minimum for PBKDF2-HMAC-SHA256. High enough to make an
    /// offline guess of a stolen ciphertext expensive; low enough to derive
    /// in well under a second on an A-series chip (runs off the main actor).
    static let defaultIterations = 600_000
    static let saltByteCount = 16
    private static let derivedKeyByteCount = 32 // 256-bit AES key

    enum CryptoError: Error, Equatable, Sendable {
        case emptyPassword
        case randomGenerationFailed(Int32)
        case kdfFailed(Int32)
        case sealFailed
        /// Wrong password or corrupted ciphertext — GCM auth tag mismatch.
        case openFailed
        case encodingFailed
    }

    // MARK: - Key derivation

    /// Derive the 256-bit AES key from `password` + `salt` via PBKDF2.
    ///
    /// Uses the canonical bridging form: the password `String` and the salt /
    /// output `[UInt8]` arrays are passed straight to `CCKeyDerivationPBKDF`,
    /// which Swift converts to the C pointers for the call's lifetime. (The
    /// earlier nested-`withUnsafeBytes` + `assumingMemoryBound(to: CChar.self)`
    /// form returned `kCCParamError` on device — 2026-06-20 fix.)
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: derivedKeyByteCount)

        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &derived, derived.count
        )
        guard status == Int32(kCCSuccess) else { throw CryptoError.kdfFailed(status) }
        return SymmetricKey(data: Data(derived))
    }

    // MARK: - Seal / open

    /// Encrypt `mnemonic` (the space-joined BIP-39 phrase) under `password`.
    /// Returns the random salt, the iteration count used, and the AES-GCM
    /// combined ciphertext — exactly the three fields the blob persists.
    static func encrypt(
        mnemonic: String,
        password: String,
        iterations: Int = defaultIterations
    ) throws -> (salt: Data, iterations: Int, ciphertext: Data) {
        guard !password.isEmpty else { throw CryptoError.emptyPassword }
        let salt = try randomBytes(saltByteCount)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        guard let plaintext = mnemonic.data(using: .utf8) else { throw CryptoError.encodingFailed }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw CryptoError.sealFailed }
            return (salt, iterations, combined)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.sealFailed
        }
    }

    /// Decrypt a backup's ciphertext with `password`. Throws `.openFailed`
    /// on a wrong password (GCM tag mismatch) or corrupt data — the caller
    /// surfaces that as "incorrect password".
    static func decrypt(
        ciphertext: Data,
        password: String,
        salt: Data,
        iterations: Int
    ) throws -> String {
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: ciphertext)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let secret = String(data: plaintext, encoding: .utf8) else {
                throw CryptoError.openFailed
            }
            return secret
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.openFailed
        }
    }

    // MARK: - CSPRNG

    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int32 in
            // `Data(count:)` with count > 0 always has a base address; guard
            // anyway so a degenerate count == 0 yields a clean error instead of
            // force-unwrapping nil and trapping inside a CSPRNG.
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else { throw CryptoError.randomGenerationFailed(status) }
        return data
    }
}

// MARK: - Honest error text

/// Human, diagnosable messages — so a backup failure never collapses to a
/// bare "(CryptoError error 2.)" again; the real CommonCrypto status shows.
extension WalletBackupCrypto.CryptoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return String.apertureLocalized("The backup password is empty.")
        case .randomGenerationFailed(let status):
            return String(format: String.apertureLocalized("Couldn't generate a secure salt (status %lld)."), Int64(status))
        case .kdfFailed(let status):
            return String(format: String.apertureLocalized("Couldn't derive the encryption key (PBKDF2 status %lld)."), Int64(status))
        case .sealFailed:
            return String.apertureLocalized("Couldn't encrypt the backup.")
        case .openFailed:
            return String.apertureLocalized("Wrong password, or the backup is corrupted.")
        case .encodingFailed:
            return String.apertureLocalized("Couldn't encode the backup.")
        }
    }
}
