import Foundation

/// XXH64 (xxHash 64-bit) + Substrate's `twox128` helper. Used to
/// build Substrate `state_getStorage` keys: pallet + storage names
/// hashed with twox128, account-id with blake2_128_concat.
///
/// **Reference.** XXH64 spec by Yann Collet:
/// https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
///
/// **Implementation choice (same as BLAKE2b).** All buffers are
/// `[UInt8]` arrays so slice indices are unambiguous.
enum Twox {

    private static let prime1: UInt64 = 0x9E3779B185EBCA87
    private static let prime2: UInt64 = 0xC2B2AE3D27D4EB4F
    private static let prime3: UInt64 = 0x165667B19E3779F9
    private static let prime4: UInt64 = 0x85EBCA77C2B2AE63
    private static let prime5: UInt64 = 0x27D4EB2F165667C5

    /// Single-shot XXH64 hash of `input` with `seed`.
    static func xxh64(_ input: [UInt8], seed: UInt64 = 0) -> UInt64 {
        let n = input.count
        var h64: UInt64
        var idx = 0

        if n >= 32 {
            var v1 = seed &+ prime1 &+ prime2
            var v2 = seed &+ prime2
            var v3 = seed
            var v4 = seed &- prime1
            while idx + 32 <= n {
                v1 = round(v1, readU64LE(input, idx))
                v2 = round(v2, readU64LE(input, idx + 8))
                v3 = round(v3, readU64LE(input, idx + 16))
                v4 = round(v4, readU64LE(input, idx + 24))
                idx += 32
            }
            h64 = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            h64 = mergeRound(h64, v1)
            h64 = mergeRound(h64, v2)
            h64 = mergeRound(h64, v3)
            h64 = mergeRound(h64, v4)
        } else {
            h64 = seed &+ prime5
        }
        h64 = h64 &+ UInt64(n)

        while idx + 8 <= n {
            let k1 = round(0, readU64LE(input, idx))
            h64 ^= k1
            h64 = rotl(h64, 27) &* prime1 &+ prime4
            idx += 8
        }
        if idx + 4 <= n {
            h64 ^= UInt64(readU32LE(input, idx)) &* prime1
            h64 = rotl(h64, 23) &* prime2 &+ prime3
            idx += 4
        }
        while idx < n {
            h64 ^= UInt64(input[idx]) &* prime5
            h64 = rotl(h64, 11) &* prime1
            idx += 1
        }
        h64 ^= h64 >> 33
        h64 = h64 &* prime2
        h64 ^= h64 >> 29
        h64 = h64 &* prime3
        h64 ^= h64 >> 32
        return h64
    }

    /// Substrate `twox128`: XXH64 with seed 0 || XXH64 with seed 1,
    /// each as a little-endian 8-byte value. Returns 16 bytes.
    static func twox128(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for seed: UInt64 in [0, 1] {
            let h = xxh64(input, seed: seed)
            for i in 0..<8 {
                out.append(UInt8((h >> (8 * i)) & 0xff))
            }
        }
        return out
    }

    /// `Data` convenience overload.
    static func twox128(_ input: Data) -> Data {
        return Data(twox128(Array(input)))
    }

    // MARK: - Internals

    private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        var a = acc &+ (input &* prime2)
        a = rotl(a, 31)
        return a &* prime1
    }

    private static func mergeRound(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        let r = round(0, val)
        let a = acc ^ r
        return a &* prime1 &+ prime4
    }

    private static func rotl(_ x: UInt64, _ n: UInt64) -> UInt64 {
        return (x << n) | (x >> (64 - n))
    }

    private static func readU64LE(_ data: [UInt8], _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(data[at + i]) << (8 * i)
        }
        return v
    }

    private static func readU32LE(_ data: [UInt8], _ at: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(data[at + i]) << (8 * i)
        }
        return v
    }
}
