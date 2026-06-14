import Foundation

/// SCALE (Simple Concatenated Aggregate Little-Endian) codec for Substrate
/// extrinsics. Ported faithfully from the Stabro reference wallet's
/// `SCALECodec.swift` — the byte-exact encoding of compact integers,
/// fixed-width integers, the mortal era, `MultiAddress::Id`, and
/// `MultiSignature::Ed25519` that the Polkadot runtime expects on a signed
/// extrinsic.
///
/// **Why this is hand-rolled (Rule #3 carve-out for THIS task).** wallet-core
/// ships a Polkadot signer, but it omits signed extensions the current
/// relay-chain / Asset Hub runtime requires (CheckNonZeroSender, CheckWeight,
/// CheckMetadataHash, StorageWeightReclaim). The extrinsic must therefore be
/// assembled byte-by-byte; this codec is the primitive layer for that. Every
/// method here is a pure value→bytes transform — no I/O, no secrets, no
/// logging.
enum SCALECodec {

    // MARK: - Compact Encoding

    /// Encodes a compact integer (SCALE `Compact<T>`). Supports values up to
    /// `UInt64.max` — the four modes (single / two-byte / four-byte / big)
    /// match the SCALE spec exactly.
    static func encodeCompact(_ value: UInt64) -> Data {
        if value <= 0x3F {
            // Single-byte mode (6-bit value).
            return Data([UInt8(value << 2)])
        } else if value <= 0x3FFF {
            // Two-byte mode (14-bit value).
            let encoded = UInt16(value << 2) | 0x01
            return withUnsafeBytes(of: encoded.littleEndian) { Data($0) }
        } else if value <= 0x3FFF_FFFF {
            // Four-byte mode (30-bit value).
            let encoded = UInt32(value << 2) | 0x02
            return withUnsafeBytes(of: encoded.littleEndian) { Data($0) }
        } else {
            // Big-integer mode: header byte + little-endian value bytes.
            var v = value
            var bytes = [UInt8]()
            while v > 0 {
                bytes.append(UInt8(v & 0xFF))
                v >>= 8
            }
            let header = UInt8((bytes.count - 4) << 2) | 0x03
            return Data([header]) + Data(bytes)
        }
    }

    /// Encodes a compact 128-bit integer from a big-endian byte representation
    /// of an unsigned value (used for amounts that can exceed `UInt64`, e.g.
    /// a planck balance > 1.8e19). The four small modes match `encodeCompact`;
    /// values wider than `UInt64` use big-integer mode with up to 16 LE bytes.
    static func encodeCompactU128(bigEndianBytes: [UInt8]) -> Data {
        // Strip leading zeros from the big-endian input.
        var be = bigEndianBytes
        while be.count > 1 && be.first == 0 { be.removeFirst() }
        // Reverse to little-endian.
        var le = Array(be.reversed())
        while le.count > 1 && le.last == 0 { le.removeLast() }

        // If it fits in UInt64, defer to the canonical compact encoder so the
        // small-value modes (single / two / four byte) are produced identically.
        if le.count <= 8 {
            var v: UInt64 = 0
            for (i, b) in le.enumerated() { v |= UInt64(b) << (8 * i) }
            return encodeCompact(v)
        }
        // Big-integer mode for the 9…16-byte range.
        let header = UInt8((le.count - 4) << 2) | 0x03
        return Data([header]) + Data(le)
    }

    // MARK: - Fixed-Width Integers

    /// Encodes a `UInt32` as 4 bytes little-endian.
    static func encodeU32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: - Mortal Era

    /// Encodes a mortal era for extrinsic mortality.
    ///
    /// - Parameters:
    ///   - period: The era period (rounded to next power of 2, min 4, max 65536).
    ///   - current: The current (finalized) block number.
    /// - Returns: 2-byte SCALE-encoded mortal era (little-endian).
    static func encodeMortalEra(period: UInt64, current: UInt64) -> Data {
        let calPeriod = nextPowerOf2(max(min(period, 1 << 16), 4))
        let phase = current % calPeriod
        let quantizeFactor = max(calPeriod >> 12, 1)
        let quantizedPhase = (phase / quantizeFactor) * quantizeFactor

        let periodLog2 = calPeriod.trailingZeroBitCount
        let encoded = UInt16(min(15, max(1, periodLog2 - 1)))
            | UInt16((quantizedPhase / quantizeFactor) << 4)

        return withUnsafeBytes(of: encoded.littleEndian) { Data($0) }
    }

    // MARK: - MultiAddress

    /// Encodes a `MultiAddress::Id` variant: `0x00` prefix + 32-byte account ID.
    static func encodeMultiAddressId(_ accountId: Data) -> Data {
        Data([0x00]) + accountId
    }

    // MARK: - MultiSignature

    /// Encodes a `MultiSignature::Ed25519` variant: `0x00` prefix + 64-byte
    /// signature. (sr25519 would be variant `0x01`; the ported builder signs
    /// with Ed25519 — see `PolkadotExtrinsicBuilder` for the rationale.)
    static func encodeMultiSignatureEd25519(_ signature: Data) -> Data {
        Data([0x00]) + signature
    }

    // MARK: - Helpers

    /// Returns the smallest power of 2 that is ≥ `value`.
    private static func nextPowerOf2(_ value: UInt64) -> UInt64 {
        guard value > 1 else { return value }
        var v = value - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
