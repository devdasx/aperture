import Foundation

/// Pure-Swift BLAKE2b (RFC 7693). Sequential mode, no key.
/// Output lengths 1…64 bytes supported. Aperture uses the 16-byte
/// variant (`blake2_128`) for Substrate storage-key construction
/// and the 64-byte variant for SS58 checksum verification.
///
/// **Why pure-Swift.** CryptoKit ships SHA-2 family but no BLAKE2.
/// Polkadot storage reads require BLAKE2b-128 to build the storage
/// key for `System::Account` lookups; without it, the only way to
/// read DOT balance is through a paid indexer API (Subscan w/ key).
///
/// **Implementation choice.** All buffers are `[UInt8]` arrays (not
/// `Data`) so we never accidentally inherit a slice's non-zero
/// startIndex — `block[base + j]` is unambiguous on a `[UInt8]`
/// whose indices are always 0-based. This is the bug that took
/// down the first attempt at Polkadot balance (M-010).
enum BLAKE2b {

    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ]

    private static let sigma: [[Int]] = [
        [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15],
        [14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3],
        [11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4],
        [ 7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8],
        [ 9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13],
        [ 2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9],
        [12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11],
        [13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10],
        [ 6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,12,13, 0],
        [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15],
        [14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3]
    ]

    /// Hash `input` to `outlen` bytes (1…64).
    static func hash(_ input: [UInt8], outlen: Int) -> [UInt8] {
        guard (1...64).contains(outlen) else { return [] }

        var h = iv
        h[0] ^= UInt64(0x01010000) | UInt64(outlen)
        var t0: UInt64 = 0
        var t1: UInt64 = 0

        // Process full blocks, except keep at least one byte for
        // the final (flagged) block.
        var idx = 0
        let n = input.count
        while idx + 128 < n {
            let block = Array(input[idx..<(idx + 128)])
            t0 = t0 &+ 128
            if t0 < 128 { t1 = t1 &+ 1 }
            compress(h: &h, block: block, t0: t0, t1: t1, last: false)
            idx += 128
        }
        // Final block (0…128 bytes from the input, then zero-padded).
        var finalBlock = Array(input[idx..<n])
        let finalLen = finalBlock.count
        while finalBlock.count < 128 {
            finalBlock.append(0)
        }
        t0 = t0 &+ UInt64(finalLen)
        if t0 < UInt64(finalLen) { t1 = t1 &+ 1 }
        compress(h: &h, block: finalBlock, t0: t0, t1: t1, last: true)

        // Truncate state words (LE) to outlen bytes.
        var out: [UInt8] = []
        out.reserveCapacity(outlen)
        outer: for word in h {
            for i in 0..<8 {
                out.append(UInt8((word >> (8 * i)) & 0xff))
                if out.count == outlen { break outer }
            }
        }
        return out
    }

    /// `Data` convenience overload.
    static func hash(_ input: Data, outlen: Int) -> Data {
        return Data(hash(Array(input), outlen: outlen))
    }

    // MARK: - Compression

    private static func compress(
        h: inout [UInt64],
        block: [UInt8],
        t0: UInt64,
        t1: UInt64,
        last: Bool
    ) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var w: UInt64 = 0
            let base = i * 8
            for j in 0..<8 {
                w |= UInt64(block[base + j]) << (8 * j)
            }
            m[i] = w
        }
        var v = [UInt64](repeating: 0, count: 16)
        for i in 0..<8 { v[i] = h[i] }
        for i in 0..<8 { v[8 + i] = iv[i] }
        v[12] ^= t0
        v[13] ^= t1
        if last { v[14] ^= 0xffffffffffffffff }

        for r in 0..<12 {
            let s = sigma[r]
            g(&v, 0, 4,  8, 12, m[s[0]],  m[s[1]])
            g(&v, 1, 5,  9, 13, m[s[2]],  m[s[3]])
            g(&v, 2, 6, 10, 14, m[s[4]],  m[s[5]])
            g(&v, 3, 7, 11, 15, m[s[6]],  m[s[7]])
            g(&v, 0, 5, 10, 15, m[s[8]],  m[s[9]])
            g(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(&v, 2, 7,  8, 13, m[s[12]], m[s[13]])
            g(&v, 3, 4,  9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    private static func g(
        _ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int,
        _ x: UInt64, _ y: UInt64
    ) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr64(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]
        v[b] = rotr64(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr64(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotr64(v[b] ^ v[c], 63)
    }

    private static func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 {
        return (x >> n) | (x << (64 - n))
    }
}
