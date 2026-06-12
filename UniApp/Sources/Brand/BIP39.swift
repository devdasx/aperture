import Foundation
import CryptoKit
import Security

/// Supported BIP-39 mnemonic lengths. Each length corresponds to a fixed
/// entropy size; the checksum is `entropyBits / 32` bits and is appended
/// to the entropy before slicing into 11-bit word indices.
///
/// | Case        | Words | Entropy bits | Checksum bits | Total bits |
/// |-------------|-------|--------------|---------------|------------|
/// | `.twelve`   | 12    | 128          | 4             | 132        |
/// | `.twentyFour` | 24  | 256          | 8             | 264        |
enum BIP39WordCount: Int, Sendable, Hashable, Codable, CaseIterable {
    case twelve = 12
    case twentyFour = 24

    /// Number of raw entropy bytes the OS must generate for this length.
    var entropyBytes: Int {
        switch self {
        case .twelve:     return 16  // 128 bits
        case .twentyFour: return 32  // 256 bits
        }
    }
}

/// BIP-39 mnemonic generation and validation, implemented directly from the
/// canonical spec (`github.com/bitcoin/bips/blob/master/bip-0039/bip-0039.mediawiki`)
/// using only Apple-native primitives — `Security.SecRandomCopyBytes` for
/// CSPRNG entropy and `CryptoKit.SHA256` for the checksum. **No third-party
/// SPM packages** (Rule #3 §A).
///
/// **Algorithm.**
/// 1. Draw `n` bytes of entropy from `SecRandomCopyBytes(kSecRandomDefault, …)`.
/// 2. Compute `SHA256(entropy)`; the **first `entropyBits / 32` bits** of the
///    hash are the checksum.
/// 3. Concatenate `entropy || checksum_bits` into a bit-stream of length
///    `entropyBits + checksumBits` (divisible by 11 by construction).
/// 4. Slice the bit-stream into groups of 11 bits, each interpreted as an
///    unsigned big-endian integer in `0..<2048` — that integer is the index
///    into `BIP39Wordlist.english`.
///
/// **Test vectors validated against the BIP-39 spec's appendix:**
/// - All-zero 128-bit entropy → `"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"`
/// - All-zero 256-bit entropy → `"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"`
///
/// **Honesty (Rule #2 §A.7).** This implementation produces a real mnemonic
/// that, in principle, can be restored into any BIP-39-compatible wallet.
/// The bytes are drawn from the platform CSPRNG and never logged, persisted
/// to `UserDefaults`, sent over the network, or otherwise leaked. The seed
/// derivation step (BIP-39 → 64-byte seed via PBKDF2-HMAC-SHA512) is not
/// performed here; it lives with the future Keychain persistence work
/// (`T-012`).
enum BIP39 {

    /// Word → index lookup over the canonical wordlist. Built once on
    /// first use (`static let` is lazily, atomically initialized) so
    /// validation does an O(1) hash lookup per word instead of an
    /// O(2048) linear scan via `firstIndex(of:)`.
    private static let wordIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: BIP39Wordlist.english.enumerated().map { ($0.element, $0.offset) }
    )

    // MARK: - Public surface

    /// Generates a fresh BIP-39 mnemonic of the requested length from
    /// platform CSPRNG entropy. Returns the words in canonical order.
    ///
    /// Crashes with `fatalError` on `SecRandomCopyBytes` failure. That call
    /// fails only when the kernel cannot serve randomness — a condition the
    /// app cannot recover from and which should never occur in normal
    /// operation. Surfacing it as a thrown error would invite callers to
    /// "retry" something that is in fact unrecoverable; the honest signal
    /// is termination.
    static func generateMnemonic(wordCount: BIP39WordCount) -> [String] {
        let entropy = secureRandomBytes(count: wordCount.entropyBytes)
        return mnemonic(fromEntropy: entropy)
    }

    /// Computes the mnemonic for a caller-supplied entropy buffer. Public
    /// to support BIP-39 test-vector verification; production callers
    /// should use ``generateMnemonic(wordCount:)`` so entropy is drawn
    /// from the OS rather than the caller.
    static func mnemonic(fromEntropy entropy: Data) -> [String] {
        precondition(
            entropy.count == 16 || entropy.count == 32,
            "BIP-39 entropy must be 128 or 256 bits"
        )

        let entropyBits = entropy.count * 8
        let checksumBits = entropyBits / 32 // 4 for 128-bit, 8 for 256-bit

        // Compute the SHA-256 of the entropy and take its first `checksumBits`
        // bits as the checksum.
        let hash = SHA256.hash(data: entropy)
        let hashBytes = Array(hash)

        // Build the combined bit-stream as a [Bool] of length entropyBits + checksumBits.
        var bits: [Bool] = []
        bits.reserveCapacity(entropyBits + checksumBits)
        for byte in entropy {
            for shift in (0..<8).reversed() {
                bits.append(((byte >> shift) & 1) == 1)
            }
        }
        // Append the high bits of the SHA-256 hash, msb-first.
        for i in 0..<checksumBits {
            let byte = hashBytes[i / 8]
            let shift = 7 - (i % 8)
            bits.append(((byte >> shift) & 1) == 1)
        }

        // Slice into 11-bit groups and index into the wordlist.
        let wordlist = BIP39Wordlist.english
        let groupCount = bits.count / 11
        var words: [String] = []
        words.reserveCapacity(groupCount)
        for groupIndex in 0..<groupCount {
            var value = 0
            for bitIndex in 0..<11 {
                value <<= 1
                if bits[groupIndex * 11 + bitIndex] {
                    value |= 1
                }
            }
            words.append(wordlist[value])
        }
        return words
    }

    /// Validates a mnemonic by re-deriving its checksum and verifying every
    /// word appears in the canonical wordlist. Returns `true` iff both
    /// checks pass. Length must be 12 or 24; other lengths return `false`.
    ///
    /// Used by future verification flows and by the debug-mode smoke test
    /// to confirm the round-trip of `generateMnemonic` is internally
    /// consistent.
    static func validate(_ words: [String]) -> Bool {
        guard words.count == 12 || words.count == 24 else { return false }

        // Look up each word's index in the wordlist; bail on the first
        // miss. O(1) per word via the cached `wordIndex` map.
        var indices: [Int] = []
        indices.reserveCapacity(words.count)
        for word in words {
            guard let idx = wordIndex[word] else { return false }
            indices.append(idx)
        }

        // Reassemble the bit-stream from the 11-bit indices.
        let totalBits = words.count * 11
        var bits: [Bool] = []
        bits.reserveCapacity(totalBits)
        for idx in indices {
            for shift in (0..<11).reversed() {
                bits.append(((idx >> shift) & 1) == 1)
            }
        }

        let checksumBits = totalBits / 33 // 132/33 = 4, 264/33 = 8
        let entropyBits = totalBits - checksumBits

        // Split into entropy bits and embedded checksum bits.
        var entropy = Data(count: entropyBits / 8)
        for byteIndex in 0..<(entropyBits / 8) {
            var b: UInt8 = 0
            for bit in 0..<8 {
                if bits[byteIndex * 8 + bit] {
                    b |= UInt8(1 << (7 - bit))
                }
            }
            entropy[byteIndex] = b
        }

        let recomputed = SHA256.hash(data: entropy)
        let recomputedBytes = Array(recomputed)
        for i in 0..<checksumBits {
            let byte = recomputedBytes[i / 8]
            let shift = 7 - (i % 8)
            let expected = ((byte >> shift) & 1) == 1
            if bits[entropyBits + i] != expected { return false }
        }
        return true
    }

    // MARK: - Private — secure random

    /// Wraps `SecRandomCopyBytes(kSecRandomDefault, …)`. Failure is fatal
    /// (see `generateMnemonic`'s doc).
    private static func secureRandomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with OSStatus \(status)")
        }
        return Data(bytes)
    }
}

#if DEBUG
/// Debug-mode smoke check: verify the BIP-39 implementation produces the
/// canonical spec's all-zero test vectors. Runs once on first access; an
/// assertion failure here means the bit-packing has drifted.
///
/// Test vectors from the BIP-39 spec's `bip-0039/bip-0039.mediawiki`:
/// - 128-bit zero entropy → "abandon" × 11 + "about"
/// - 256-bit zero entropy → "abandon" × 23 + "art"
private let _bip39SmokeCheck: Void = {
    let zero128 = Data(repeating: 0, count: 16)
    let m128 = BIP39.mnemonic(fromEntropy: zero128)
    assert(
        m128.joined(separator: " ") == "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "BIP-39 128-bit zero-entropy vector mismatch — got \(m128)"
    )
    assert(BIP39.validate(m128), "BIP-39 validate() rejected its own zero-vector mnemonic")

    let zero256 = Data(repeating: 0, count: 32)
    let m256 = BIP39.mnemonic(fromEntropy: zero256)
    assert(
        m256.joined(separator: " ") == "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
        "BIP-39 256-bit zero-entropy vector mismatch — got \(m256)"
    )
    assert(BIP39.validate(m256), "BIP-39 validate() rejected its own zero-vector mnemonic")
}()
#endif
