import Foundation

/// Inline Keccak-256 implementation — the hash function Ethereum uses
/// for address checksumming (EIP-55), function selectors, and the
/// majority of EVM cryptographic primitives. Same algorithm Trust
/// Wallet uses for its address checksumming. Lifted from the public
/// domain `tiny-keccak` reference.
///
/// **Why a shared file (Rule #3 native-only, no SPM).** Several
/// surfaces in Aperture need Keccak: `CoinMarkCache` (Trust Wallet
/// URL building), `ContractValidator` (EVM checksum verification),
/// future EVM signing paths. Each used to inline its own copy; one
/// shared helper means one audit surface.
///
/// **No CommonCrypto / CryptoKit dependency.** Apple's `CryptoKit`
/// doesn't expose Keccak — it ships SHA-3 (which is a different
/// padding scheme on the same permutation). The 80 lines of pure math
/// below are honest and auditable; the alternative (SPM dependency)
/// violates Rule #3.
enum Keccak256 {

    /// Compute Keccak-256 of `data`. Returns 32 bytes.
    static func hash(_ data: Data) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        let rate = 136
        var input = [UInt8](data)
        input.append(0x01)
        while input.count % rate != 0 { input.append(0x00) }
        input[input.count - 1] |= 0x80

        var offset = 0
        while offset < input.count {
            for i in 0..<(rate / 8) {
                let base = offset + i * 8
                var word: UInt64 = 0
                for j in 0..<8 {
                    word |= UInt64(input[base + j]) << (8 * j)
                }
                state[i] ^= word
            }
            keccakF(&state)
            offset += rate
        }

        var out = Data(count: 32)
        out.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<32 {
                bytes[i] = UInt8((state[i / 8] >> (8 * (i % 8))) & 0xff)
            }
        }
        return out
    }

    /// Apply the EIP-55 mixed-case checksum to an EVM contract
    /// address. Accepts the body (without `0x`) OR the full form
    /// (with `0x`). Returns the canonical checksummed form with the
    /// `0x` prefix.
    ///
    /// EIP-55 rule: lowercase the address, hash with Keccak-256, then
    /// for each character of the lowercased address, uppercase it if
    /// the corresponding nibble in the digest is ≥ 8.
    static func eip55Checksum(contract: String) -> String {
        let stripped = contract.hasPrefix("0x") || contract.hasPrefix("0X")
            ? String(contract.dropFirst(2))
            : contract
        let lowered = stripped.lowercased()
        guard let data = lowered.data(using: .utf8) else { return "0x" + lowered }
        let digest = hash(data).map { String(format: "%02x", $0) }.joined()
        var out = "0x"
        for (i, ch) in lowered.enumerated() {
            let nibble = digest[digest.index(digest.startIndex, offsetBy: i)]
            if ch.isLetter, let nibbleValue = Int(String(nibble), radix: 16), nibbleValue >= 8 {
                out.append(ch.uppercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Internals

    private static func keccakF(_ state: inout [UInt64]) {
        let rc: [UInt64] = [
            0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
            0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
            0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
            0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
            0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
            0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
        ]
        // Rotation constants paired index-for-index with `pi` below —
        // tiny-keccak's `keccakf_rotc`. Each entry is the rho offset of
        // the lane the in-place rho+pi cycle *reads* at that step, NOT
        // the (x,y)-ordered rotation-offset table.
        let rotc: [Int] = [
            1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44
        ]
        let pi: [Int] = [
            10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
        ]
        for round in 0..<24 {
            // Theta
            var c = [UInt64](repeating: 0, count: 5)
            for i in 0..<5 {
                c[i] = state[i] ^ state[i + 5] ^ state[i + 10] ^ state[i + 15] ^ state[i + 20]
            }
            for i in 0..<5 {
                let d = c[(i + 4) % 5] ^ rotateLeft(c[(i + 1) % 5], 1)
                for j in stride(from: 0, to: 25, by: 5) {
                    state[i + j] ^= d
                }
            }
            // Rho + Pi
            var t = state[1]
            for i in 0..<24 {
                let j = pi[i]
                let temp = state[j]
                state[j] = rotateLeft(t, rotc[i])
                t = temp
            }
            // Chi
            for j in stride(from: 0, to: 25, by: 5) {
                let s0 = state[j]; let s1 = state[j + 1]; let s2 = state[j + 2]; let s3 = state[j + 3]; let s4 = state[j + 4]
                state[j] = s0 ^ (~s1 & s2)
                state[j + 1] = s1 ^ (~s2 & s3)
                state[j + 2] = s2 ^ (~s3 & s4)
                state[j + 3] = s3 ^ (~s4 & s0)
                state[j + 4] = s4 ^ (~s0 & s1)
            }
            // Iota
            state[0] ^= rc[round]
        }
    }

    private static func rotateLeft(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}
