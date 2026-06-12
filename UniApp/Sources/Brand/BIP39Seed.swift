import Foundation
import CryptoKit

/// BIP-39 seed derivation per the spec §6 (Seed).
///
/// > seed = PBKDF2(
/// >     password = mnemonic_words_joined_by_space,
/// >     salt     = "mnemonic" + passphrase,
/// >     PRF      = HMAC-SHA512,
/// >     c        = 2048,
/// >     dkLen    = 64
/// > )
///
/// The seed is a 64-byte value that feeds BIP-32 HD derivation. This file
/// adds the derivation surface to ``BIP39`` without touching the generation
/// path (which already lives in `BIP39.swift`).
///
/// **Native-only.** PBKDF2 is implemented as a pure-Swift loop over
/// `CryptoKit.HMAC<SHA512>` — Apple's CryptoKit ships HMAC primitives but
/// not PBKDF2 itself, so we run the recipe directly. No `CommonCrypto`
/// bridge, no SPM dependency, no hand-rolled SHA-512 — the HMAC inside the
/// loop is Apple's vetted implementation.
///
/// **Honesty (Rule #2 §A.7).** The 64-byte seed is the *real* root of the
/// HD tree. It must never be logged, never persisted to `UserDefaults`,
/// never sent over the network. The current call site (`CreateWalletState`)
/// holds it in memory only for the lifetime of the create-wallet cover;
/// Keychain persistence lands with T-012.
extension BIP39 {

    /// Derives the 64-byte BIP-39 seed from a mnemonic + optional passphrase.
    ///
    /// - Parameters:
    ///   - words: The mnemonic words in canonical order, as produced by
    ///     ``generateMnemonic(wordCount:)``. The spec requires the words to
    ///     be joined by a single ASCII space.
    ///   - passphrase: The optional BIP-39 "25th word". Pass `""` for the
    ///     no-passphrase case (the spec defines the salt as `"mnemonic"` in
    ///     that case — concatenating an empty string is the same thing).
    /// - Returns: 64 raw bytes of HD-root material.
    static func deriveSeed(words: [String], passphrase: String = "") -> Data {
        // BIP-39 §Seed requires both the mnemonic sentence and the salt
        // ("mnemonic" + passphrase) to be UTF-8 **NFKD** normalized before
        // PBKDF2. English words are ASCII (no-op), but the passphrase is
        // free-form user text — iOS keyboards emit precomposed NFC, which
        // would derive a seed incompatible with every spec-compliant
        // wallet (Trezor, Ledger, Electrum) for accented/non-Latin input.
        let mnemonic = words.joined(separator: " ")
            .decomposedStringWithCompatibilityMapping
        let salt = ("mnemonic" + passphrase)
            .decomposedStringWithCompatibilityMapping
        return pbkdf2HmacSha512(
            password: Data(mnemonic.utf8),
            salt: Data(salt.utf8),
            iterations: 2048,
            keyLength: 64
        )
    }

    // MARK: - PBKDF2-HMAC-SHA512 (RFC 2898)

    /// Pure-Swift PBKDF2 using HMAC-SHA512 as the PRF, per RFC 2898 §5.2.
    ///
    /// Algorithm (the only piece we own — the HMAC comes from CryptoKit):
    /// 1. Output is `dkLen` bytes split into `l = ceil(dkLen / hLen)` blocks
    ///    where `hLen = 64` for SHA-512.
    /// 2. For each block index `i = 1...l`:
    ///    - `U_1 = HMAC(password, salt || INT(i))` (INT(i) = 4-byte big-endian)
    ///    - `U_j = HMAC(password, U_{j-1})` for `j = 2...c`
    ///    - `T_i = U_1 XOR U_2 XOR … XOR U_c`
    /// 3. The derived key is `T_1 || T_2 || … || T_l`, truncated to `dkLen`.
    ///
    /// For BIP-39 the parameters are fixed: `c = 2048`, `dkLen = 64`, so
    /// exactly one 64-byte block is produced (`l = 1`).
    private static func pbkdf2HmacSha512(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        precondition(iterations > 0, "PBKDF2 iteration count must be positive")
        precondition(keyLength > 0, "PBKDF2 derived key length must be positive")

        let key = SymmetricKey(data: password)
        let hLen = 64 // SHA-512 output size in bytes
        let blockCount = (keyLength + hLen - 1) / hLen

        var derived = Data()
        derived.reserveCapacity(blockCount * hLen)

        for blockIndex in 1...blockCount {
            // INT(i) — 4-byte big-endian block index.
            var indexBytes = Data(count: 4)
            indexBytes[0] = UInt8((blockIndex >> 24) & 0xff)
            indexBytes[1] = UInt8((blockIndex >> 16) & 0xff)
            indexBytes[2] = UInt8((blockIndex >> 8) & 0xff)
            indexBytes[3] = UInt8(blockIndex & 0xff)

            // U_1 = HMAC(password, salt || INT(i))
            var u = Data(HMAC<SHA512>.authenticationCode(
                for: salt + indexBytes,
                using: key
            ))
            var t = u

            // U_j = HMAC(password, U_{j-1}); T_i ^= U_j
            for _ in 1..<iterations {
                u = Data(HMAC<SHA512>.authenticationCode(for: u, using: key))
                for byteIndex in 0..<hLen {
                    t[byteIndex] ^= u[byteIndex]
                }
            }

            derived.append(t)
        }

        return derived.prefix(keyLength)
    }
}

#if DEBUG
/// Debug-mode smoke check: verify the PBKDF2-HMAC-SHA512 implementation
/// produces the canonical BIP-39 spec test vector. Runs once on first
/// access; an assertion failure here means the seed derivation has
/// drifted from the spec.
///
/// Test vector from the BIP-39 spec's appendix (with TREZOR passphrase):
/// - mnemonic:   "abandon abandon abandon abandon abandon abandon abandon
///                abandon abandon abandon abandon about"
/// - passphrase: "TREZOR"
/// - seed (hex): c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04
private let _bip39SeedSmokeCheck: Void = {
    let words: [String] = [
        "abandon", "abandon", "abandon", "abandon",
        "abandon", "abandon", "abandon", "abandon",
        "abandon", "abandon", "abandon", "about"
    ]
    let seed = BIP39.deriveSeed(words: words, passphrase: "TREZOR")
    let expected = "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
    let got = seed.map { String(format: "%02x", $0) }.joined()
    assert(
        got == expected,
        "BIP-39 seed derivation TREZOR vector mismatch — got \(got)"
    )

    // No-passphrase variant: salt is exactly "mnemonic".
    let seedNoPassphrase = BIP39.deriveSeed(words: words, passphrase: "")
    assert(
        seedNoPassphrase.count == 64,
        "BIP-39 seed must be exactly 64 bytes — got \(seedNoPassphrase.count)"
    )

    // NFKD normalization (BIP-39 §Seed): precomposed (NFC) and decomposed
    // (NFD) forms of the same passphrase must derive the identical seed.
    let seedNFC = BIP39.deriveSeed(words: words, passphrase: "caf\u{00E9}")
    let seedNFD = BIP39.deriveSeed(words: words, passphrase: "cafe\u{0301}")
    assert(
        seedNFC == seedNFD,
        "BIP-39 seed derivation must NFKD-normalize the passphrase"
    )
}()
#endif
