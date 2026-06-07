import Foundation

/// Bitcoin-alphabet Base58 encoder. Pure-Swift, no third-party
/// dependency (Rule #3).
///
/// Alphabet excludes the visually-ambiguous characters `0`, `O`, `I`,
/// `l`. Used directly for Solana addresses; the Base58Check variant
/// (with the 4-byte SHA-256-SHA-256 checksum suffix) is needed for
/// Bitcoin / TRON / Ripple — those are intentionally not implemented
/// here because the upstream key derivation (secp256k1) is not in
/// CryptoKit and remains a follow-up.
///
/// **Honesty (Rule #2 §A.7).** Encoding is straightforward divmod-by-58
/// across the input bytes as one big-endian integer. The output
/// preserves leading zero bytes by emitting `1` (the alphabet's zero
/// digit) once per leading zero byte.
enum Base58 {
    static let alphabet: [Character] = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    /// Decode a Bitcoin-alphabet Base58 string back to `[UInt8]`
    /// bytes. Returns nil on any character outside the alphabet.
    /// Preserves leading zero bytes (each leading `1` in the input
    /// maps to a zero byte). Returning `[UInt8]` directly (not
    /// `Data`) avoids any slice-index ambiguity at the call site.
    static func decodeBytes(_ string: String) -> [UInt8]? {
        guard !string.isEmpty else { return [] }

        var indexOf: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() {
            indexOf[c] = i
        }

        var leadingOnes = 0
        for c in string {
            if c == "1" { leadingOnes += 1 } else { break }
        }

        var bytes: [UInt8] = [0]
        for c in string {
            guard let value = indexOf[c] else { return nil }
            var carry = value
            for i in 0..<bytes.count {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        var result: [UInt8] = Array(repeating: 0, count: leadingOnes)
        result.append(contentsOf: bytes.reversed())
        return result
    }

    /// Decode a Bitcoin-alphabet Base58 string back to bytes.
    /// Returns nil on any character outside the alphabet. Preserves
    /// leading zero bytes (each leading `1` in the input maps to a
    /// zero byte). Used by SS58 (Polkadot address) decoding.
    static func decode(_ string: String) -> Data? {
        guard !string.isEmpty else { return Data() }

        // Build alphabet index lookup. Computed once at first call
        // — not worth caching at module scope since decode is rare.
        var indexOf: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() {
            indexOf[c] = i
        }

        // Count leading `1`s — those map to leading zero bytes.
        var leadingOnes = 0
        for c in string {
            if c == "1" { leadingOnes += 1 } else { break }
        }

        // Convert from base-58 to base-256 via repeated multiply-add.
        var bytes: [UInt8] = [0]
        for c in string {
            guard let value = indexOf[c] else { return nil }
            var carry = value
            for i in 0..<bytes.count {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        // Reverse to big-endian and prepend leading zeros.
        var result = Data(repeating: 0, count: leadingOnes)
        result.append(contentsOf: bytes.reversed())
        return result
    }

    /// Encode raw bytes to a Bitcoin-alphabet Base58 string.
    /// 32-byte input produces ~44 characters of output.
    static func encode(_ bytes: Data) -> String {
        guard !bytes.isEmpty else { return "" }

        // Count leading zero bytes — those become `1` characters at
        // the start of the output, separate from the base conversion.
        var leadingZeros = 0
        for byte in bytes {
            if byte == 0 { leadingZeros += 1 } else { break }
        }

        // Convert the byte array (big-endian) to a base-58 digit array
        // via repeated divmod. We carry a running "remainder" through
        // each byte; for each pass we accumulate the base-58 digits.
        var digits: [UInt8] = [0]
        for byte in bytes {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }

        // The high-order digit ended up at the end — reverse to get
        // big-endian, then map through the alphabet.
        var output = String(repeating: "1", count: leadingZeros)
        for digit in digits.reversed() {
            output.append(alphabet[Int(digit)])
        }
        // The initial seed digits array starts with [0] which becomes a
        // bogus leading '1' after the high-order zero stripping above;
        // strip those extras so the count matches the leading-zero count.
        let extraLeadingOnes = output.prefix { $0 == "1" }.count - leadingZeros
        if extraLeadingOnes > 0 {
            output = String(output.dropFirst(extraLeadingOnes))
        }
        return output
    }
}

#if DEBUG
/// Debug-mode smoke check against the canonical Base58 test vectors
/// from Satoshi's original implementation. An assertion failure here
/// means the encoder has drifted; address generation is unsafe.
private let _base58SmokeCheck: Void = {
    // Empty input → empty output.
    assert(Base58.encode(Data()) == "")
    // Single zero byte → "1".
    assert(Base58.encode(Data([0x00])) == "1")
    // "Hello World!" → "2NEpo7TZRRrLZSi2U".
    let helloWorld = "Hello World!".data(using: .utf8)!
    let helloEncoded = Base58.encode(helloWorld)
    assert(
        helloEncoded == "2NEpo7TZRRrLZSi2U",
        "Base58 vector mismatch — got \(helloEncoded)"
    )
    // Two leading zeros → two leading '1's.
    assert(Base58.encode(Data([0x00, 0x00, 0x01])) == "112")
}()
#endif
