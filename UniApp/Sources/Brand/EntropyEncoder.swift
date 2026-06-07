import Foundation
import CryptoKit

/// Converts user-supplied entropy (dice rolls, coin flips, or hex digits)
/// into a BIP-39 mnemonic via the SHA-256 collapse pipeline used by
/// ColdCard, Trezor, and SeedSigner.
///
/// **Algorithm.** Per the `jony-ive` design audit 2026-06-05:
/// 1. Serialise the user's input as a deterministic UTF-8 string (mode-
///    specific format — see `Mode.serialize`).
/// 2. `SHA256(input.utf8)` → 32 bytes.
/// 3. Take the first 16 bytes (12-word phrase, 128 bits) or all 32
///    (24-word phrase, 256 bits).
/// 4. Feed into `BIP39.mnemonic(fromEntropy:)`. The checksum is computed
///    by `BIP39` from that entropy, so the resulting phrase validates
///    under the standard BIP-39 checksum and is restorable into any
///    BIP-39-compatible wallet.
///
/// **Honesty.** This is the same pipeline hardware wallets use for the
/// "user-supplied entropy" feature. The user's rolls / flips / digits
/// are not stored anywhere — they pass through `SHA256` once and the
/// raw input is discarded. The resulting mnemonic is real, on-spec, and
/// can be entered into any BIP-39 wallet that supports the same word
/// count.
enum EntropyEncoder {
    /// The three user-supplied entropy modes the create-wallet flow
    /// surfaces. Each mode has its own input alphabet, deterministic
    /// serialisation format, and required count for 128 / 256-bit
    /// targets.
    enum Mode: String, Sendable, Hashable, CaseIterable {
        case dice
        case coin
        case numbers

        /// Required input count for the given word count, per the
        /// design audit:
        /// - Dice: `log₂(6) ≈ 2.585 bits` per roll → ⌈128 / 2.585⌉ = 50
        ///   rolls for 128 bits, ⌈256 / 2.585⌉ = 100 for 256.
        /// - Coin: 1 bit per flip → 128 / 256 flips.
        /// - Numbers (hex): 4 bits per digit → 32 / 64 digits.
        func requiredCount(for wordCount: BIP39WordCount) -> Int {
            switch (self, wordCount) {
            case (.dice, .twelve):       return 50
            case (.dice, .twentyFour):   return 100
            case (.coin, .twelve):       return 128
            case (.coin, .twentyFour):   return 256
            case (.numbers, .twelve):    return 32
            case (.numbers, .twentyFour): return 64
            }
        }

        /// Returns the entries the user types for this mode, as their
        /// canonical short string form. Used by the UI to render the
        /// keypad keys and to build the running chip row of recent
        /// inputs.
        ///
        /// - Dice: `["1", "2", "3", "4", "5", "6"]`
        /// - Coin: `["0", "1"]` (rendered as Heads / Tails in the UI)
        /// - Numbers: `["0"..."9", "a"..."f"]`
        var alphabet: [String] {
            switch self {
            case .dice:    return ["1", "2", "3", "4", "5", "6"]
            case .coin:    return ["0", "1"]
            case .numbers: return ["0", "1", "2", "3", "4", "5", "6", "7",
                                   "8", "9", "a", "b", "c", "d", "e", "f"]
            }
        }

        /// Serialise a collected buffer of inputs into the deterministic
        /// UTF-8 string the SHA-256 step hashes:
        /// - Dice: `"3-5-1-6-2-4-..."` (digits joined by `-` so the
        ///   boundary between rolls is unambiguous — `"35"` could
        ///   otherwise mean "3 then 5" or "thirty-five").
        /// - Coin: `"01101001..."` (each flip is a single bit; no
        ///   separator needed).
        /// - Numbers: `"a3f9..."` (each hex digit is a single nibble;
        ///   no separator needed).
        func serialize(_ buffer: [String]) -> String {
            switch self {
            case .dice:
                return buffer.joined(separator: "-")
            case .coin, .numbers:
                return buffer.joined()
            }
        }
    }

    /// Convert a fully-collected user buffer into a BIP-39 mnemonic for
    /// the requested word count. Caller is responsible for ensuring the
    /// buffer is exactly `mode.requiredCount(for: wordCount)` long.
    /// Shorter buffers still produce a (valid) mnemonic — the SHA-256
    /// collapse is well-defined for any input length — but they offer
    /// less than 128 / 256 bits of real entropy, which would silently
    /// violate the user's expectation. The UI guards against this by
    /// gating the "Generate phrase" CTA on completion.
    static func mnemonic(from buffer: [String], mode: Mode, wordCount: BIP39WordCount) -> [String] {
        let input = mode.serialize(buffer)
        let bytes = SHA256.hash(data: Data(input.utf8))
        let entropy = Data(bytes.prefix(wordCount.entropyBytes))
        return BIP39.mnemonic(fromEntropy: entropy)
    }
}
