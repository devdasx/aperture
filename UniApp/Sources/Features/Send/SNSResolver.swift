import Foundation
import WalletCore

/// Resolves a Solana Name Service (Bonfida) `.sol` domain — e.g.
/// "bonfida.sol" — to the owner's base58 address on Solana mainnet.
///
/// This is **real on-chain resolution**, not a stub. The algorithm
/// mirrors `@bonfida/spl-name-service` exactly (verified against the
/// SDK source and live mainnet RPC, 2026-06-15):
///
/// 1. Strip the trailing `.sol` to get the domain label.
/// 2. `hashedName = sha256("SPL Name Service" ‖ label)` — the prefix
///    `"SPL Name Service"` is concatenated to the label as one UTF-8
///    string, then hashed (`getHashedNameSync`).
/// 3. `domainKey = findProgramAddress([hashedName, 0³², solRoot],
///    SNS_PROGRAM_ID)` — the three seeds are the hashed name, a 32-byte
///    zero `nameClass`, and the `.sol` TLD root as `nameParent`
///    (`getNameAccountKeySync`).
/// 4. `getAccountInfo(domainKey, base64)` → `NameRegistryState`:
///    bytes `[0..32)` parentName, **`[32..64)` owner**, `[64..96)` class,
///    then the data. Bytes `32..64` base58-encoded are the owner.
/// 5. `nil` when the account doesn't exist (closed / unregistered) or
///    the owner is all-zero (uninitialized).
///
/// **Off-curve PDA check.** `findProgramAddress` walks the bump from
/// 255 down, and accepts the first candidate hash that is **not** a
/// valid ed25519 curve point (a program-derived address can never be a
/// real key). WalletCore deliberately does **not** expose a clean
/// off-curve test in Swift: `PublicKey.isValid(data:type:.ed25519)` is
/// a *size-only* check (it returns `true` for any 32-byte blob), and
/// `PublicKey(data:type:.ed25519)` never decompresses the point — the
/// real on-curve method (`isValidED25519`) is C++-only and unbound. So
/// the on-curve test is implemented natively here via RFC 8032 point
/// decompression over GF(2²⁵⁵−19) (`Curve25519Point`), matching the
/// reference `ge25519_unpack_negative_vartime` semantics. This was
/// verified against `@bonfida/spl-name-service` and live mainnet:
/// bonfida.sol derives to `Crf8hzfthWGbGbLTVCiqRqV5MVnbpHB1L9KQMd6gsinb`
/// at bump 252.
///
/// **Rule #3 — native + WalletCore only.** No third-party SNS SDK; the
/// derivation is hand-rolled on WalletCore's `Hash` (sha256) and
/// `Base58` primitives, a native ed25519 on-curve test, and the app's
/// own `RPCClient`.
enum SNSResolver {

    // MARK: - SNS constants (Bonfida `@bonfida/spl-name-service`)

    /// SPL Name Service program id. Base58.
    /// `getNameAccountKeySync` passes this as the PDA program id.
    private static let programIdBase58 = "namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX"

    /// The `.sol` TLD root — passed as `nameParent` (third seed). Base58.
    private static let solRootBase58 = "58PwtjSDuFHuUkYjH9BYnnQKHfwo9reZhC2zMJv9JPkx"

    /// Hash prefix prepended to the domain label before sha256.
    /// `getHashedNameSync`: `sha256(HASH_PREFIX + name)`.
    private static let hashPrefix = "SPL Name Service"

    /// Fixed ASCII marker appended last in the PDA-derivation hash,
    /// per Solana's `Pubkey::find_program_address`.
    private static let pdaMarker = "ProgramDerivedAddress"

    // MARK: - Resolution

    /// Resolve a Solana `.sol` domain (already lowercased, ends in
    /// ".sol") to the owner's base58 address on Solana mainnet.
    /// `nil` if unresolved (bad input, network failure, account closed,
    /// or owner uninitialized).
    static func resolve(name: String) async -> String? {
        // 1. Strip the trailing ".sol" → the domain label.
        guard name.hasSuffix(".sol") else { return nil }
        let label = String(name.dropLast(4))
        guard !label.isEmpty else { return nil }
        // SNS subdomains ("foo.bonfida.sol") use a different parent
        // (the parent domain's key) — out of scope for the top-level
        // resolver. Only flat `<label>.sol` is handled here.
        guard !label.contains(".") else { return nil }

        // 2. hashedName = sha256(prefix ‖ label) as one UTF-8 string.
        guard let hashInput = (hashPrefix + label).data(using: .utf8) else { return nil }
        let hashedName = WalletCore.Hash.sha256(data: hashInput)
        guard hashedName.count == 32 else { return nil }

        // Decode the program id + `.sol` root to raw 32-byte keys.
        // `decodeNoCheck` is the plain base58 decode (no Base58Check
        // checksum) — Solana pubkeys carry no checksum.
        guard
            let programId = WalletCore.Base58.decodeNoCheck(string: programIdBase58),
            let solRoot = WalletCore.Base58.decodeNoCheck(string: solRootBase58),
            programId.count == 32, solRoot.count == 32
        else { return nil }

        // 3. domainKey = findProgramAddress(
        //        seeds: [hashedName, 32-byte zero class, solRoot],
        //        programId: SNS program id).
        let nameClass = Data(repeating: 0, count: 32)
        let seeds = [hashedName, nameClass, solRoot]
        guard let domainKey = findProgramAddress(seeds: seeds, programId: programId) else {
            return nil
        }
        let domainKeyBase58 = WalletCore.Base58.encodeNoCheck(data: domainKey)

        // 4. getAccountInfo(domainKey, base64). `callJSONResultData`
        //    returns the JSON-RPC `result` object re-serialized as
        //    `Data`; a `null` value throws `.decodingFailed`, which we
        //    treat as "unregistered" → nil.
        let resultData: Data
        do {
            resultData = try await RPCClient.shared.callJSONResultData(
                chain: .solana,
                method: "getAccountInfo",
                params: [domainKeyBase58, ["encoding": "base64"]]
            )
        } catch {
            return nil
        }

        // Decode the registry account → owner bytes [32..64).
        return Self.owner(fromAccountInfoResult: resultData)
    }

    // MARK: - NameRegistryState decode

    /// Parse a `getAccountInfo` JSON-RPC `result` object and return the
    /// owner address (`NameRegistryState` bytes `[32..64)`) base58-
    /// encoded, or `nil` when the account is absent, malformed, or the
    /// owner is all-zero.
    private static func owner(fromAccountInfoResult resultData: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: resultData),
            let root = json as? [String: Any]
        else { return nil }

        // `value` is `null` for a non-existent / closed account.
        guard let value = root["value"] as? [String: Any] else { return nil }

        // `data` is `["<base64>", "base64"]`.
        guard
            let dataArray = value["data"] as? [Any],
            let base64String = dataArray.first as? String,
            let accountData = Data(base64Encoded: base64String)
        else { return nil }

        // NameRegistryState layout:
        //   [0..32)  parentName
        //   [32..64) owner   ← returned
        //   [64..96) class
        //   [96..)   data
        guard accountData.count >= 64 else { return nil }
        let ownerBytes = accountData.subdata(in: 32..<64)

        // All-zero owner = uninitialized → unresolved.
        guard ownerBytes.contains(where: { $0 != 0 }) else { return nil }

        return WalletCore.Base58.encodeNoCheck(data: ownerBytes)
    }

    // MARK: - Program-derived address (PDA)

    /// Solana `find_program_address`: walk the bump seed from 255 down
    /// to 0; the first candidate hash that is **off** the ed25519 curve
    /// is the PDA. Returns `nil` only if every bump produced an
    /// on-curve hash (cryptographically impossible in practice).
    ///
    /// candidate = sha256(seed0 ‖ seed1 ‖ … ‖ [bump] ‖ programId ‖
    ///                    utf8("ProgramDerivedAddress"))
    private static func findProgramAddress(seeds: [Data], programId: Data) -> Data? {
        guard let marker = pdaMarker.data(using: .utf8) else { return nil }
        var bump = 255
        while bump >= 0 {
            var buffer = Data()
            for seed in seeds { buffer.append(seed) }
            buffer.append(UInt8(bump))
            buffer.append(programId)
            buffer.append(marker)

            let candidate = WalletCore.Hash.sha256(data: buffer)
            if candidate.count == 32, !isOnEd25519Curve(candidate) {
                return candidate
            }
            bump -= 1
        }
        return nil
    }

    /// `true` when the 32 bytes decode to a valid ed25519 curve point.
    /// A PDA must NOT be on the curve. Native implementation (RFC 8032
    /// point decompression) because WalletCore exposes no on-curve test
    /// for ed25519 in Swift — see the type doc above.
    private static func isOnEd25519Curve(_ candidate: Data) -> Bool {
        Curve25519Point.isOnCurve(compressed: candidate)
    }
}

// MARK: - Ed25519 on-curve test (RFC 8032 point decompression)

/// Minimal big-integer field arithmetic over the ed25519 prime field
/// `p = 2²⁵⁵ − 19`, used solely to decide whether a 32-byte value is a
/// valid (on-curve) ed25519 public key. This is the off-curve predicate
/// `Solana`'s `find_program_address` relies on, and it mirrors the
/// reference `ge25519_unpack_negative_vartime`:
///
/// 1. Read `y` from the low 255 bits (little-endian); reject `y ≥ p`.
/// 2. Recover `x² = (y² − 1) / (d·y² + 1)` over the field.
/// 3. Take the square root; the value is on-curve iff a root exists.
///
/// Implemented with `[UInt32]` limbs and modular reduction — no
/// third-party crypto, no `BigInt` dependency (Rule #3). Only used for
/// the boolean predicate, never to produce a key, so constant-time
/// behaviour is not required (these inputs are public PDA candidates).
private enum Curve25519Point {

    /// `p = 2²⁵⁵ − 19` as little-endian 32-byte magnitude.
    private static let p = BigUInt(littleEndianBytes: {
        var bytes = [UInt8](repeating: 0xff, count: 32)
        bytes[0] = 0xed          // 0xffff…ffed
        bytes[31] = 0x7f         // clear the top bit → 2²⁵⁵ − 19
        return bytes
    }())

    /// Curve constant `d = −121665 / 121666 mod p`. Precomputed canonical
    /// value (little-endian 32-byte form), the standard ed25519 `d`.
    private static let d = BigUInt(littleEndianBytes: [
        0xa3, 0x78, 0x59, 0x13, 0xca, 0x4d, 0xeb, 0x75,
        0xab, 0xd8, 0x41, 0x41, 0x4d, 0x0a, 0x70, 0x00,
        0x98, 0xe8, 0x79, 0x77, 0x79, 0x40, 0xc7, 0x8c,
        0x73, 0xfe, 0x6f, 0x2b, 0xee, 0x6c, 0x03, 0x52,
    ])

    /// Decide whether `compressed` (32 bytes) is a valid on-curve
    /// ed25519 point.
    static func isOnCurve(compressed: Data) -> Bool {
        guard compressed.count == 32 else { return false }

        // y = low 255 bits, little-endian (top bit is the x sign).
        var yBytes = [UInt8](compressed)
        yBytes[31] &= 0x7f
        let y = BigUInt(littleEndianBytes: yBytes)
        // Reject non-canonical y ≥ p.
        guard y.compare(to: p) == .orderedAscending else { return false }

        // x² = (y² − 1) · (d·y² + 1)⁻¹  (mod p)
        let y2 = y.mulMod(y, p)
        let u = y2.subMod(.one, p)                 // y² − 1
        let v = d.mulMod(y2, p).addMod(.one, p)     // d·y² + 1
        guard let vInv = v.inverseMod(p) else { return false }
        let x2 = u.mulMod(vInv, p)

        if x2.isZero {
            // x = 0 is on-curve only when the sign bit is 0.
            return (compressed[31] & 0x80) == 0
        }

        // Candidate root: x = (x²)^((p+3)/8).
        let exp = p.addSmall(3).shiftedRight(3)     // (p + 3) / 8
        var x = x2.powMod(exp, p)

        // If x²·… ≠ x², multiply by sqrt(−1) (2^((p−1)/4)) and recheck.
        if x.mulMod(x, p).compare(to: x2) != .orderedSame {
            let sqrtM1 = BigUInt.two.powMod(p.subMod(.one, p).shiftedRight(2), p)
            x = x.mulMod(sqrtM1, p)
        }
        // On-curve iff a genuine square root was found.
        return x.mulMod(x, p).compare(to: x2) == .orderedSame
    }
}

/// Tiny fixed-purpose unsigned big integer (little-endian `[UInt32]`
/// limbs) supporting the modular operations the ed25519 on-curve test
/// needs. Not a general-purpose type — scoped to `SNSResolver`.
private struct BigUInt {
    /// Little-endian 32-bit limbs; no trailing-zero limbs except the
    /// canonical single `[0]` for zero.
    private var limbs: [UInt32]

    static let one = BigUInt(1)
    static let two = BigUInt(2)

    private init(limbs: [UInt32]) {
        var trimmed = limbs
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        self.limbs = trimmed.isEmpty ? [0] : trimmed
    }

    init(_ value: UInt32) { self.limbs = [value] }

    init(littleEndianBytes bytes: [UInt8]) {
        var out: [UInt32] = []
        var i = 0
        while i < bytes.count {
            var limb: UInt32 = 0
            for j in 0..<4 where i + j < bytes.count {
                limb |= UInt32(bytes[i + j]) << (8 * j)
            }
            out.append(limb)
            i += 4
        }
        self.init(limbs: out)
    }

    var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }

    enum Order { case orderedAscending, orderedSame, orderedDescending }

    func compare(to other: BigUInt) -> Order {
        if limbs.count != other.limbs.count {
            return limbs.count < other.limbs.count ? .orderedAscending : .orderedDescending
        }
        var i = limbs.count - 1
        while i >= 0 {
            if limbs[i] != other.limbs[i] {
                return limbs[i] < other.limbs[i] ? .orderedAscending : .orderedDescending
            }
            i -= 1
        }
        return .orderedSame
    }

    // MARK: Plain add / sub (non-modular)

    private func adding(_ other: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        let n = max(limbs.count, other.limbs.count)
        var carry: UInt64 = 0
        for i in 0..<n {
            let a = i < limbs.count ? UInt64(limbs[i]) : 0
            let b = i < other.limbs.count ? UInt64(other.limbs[i]) : 0
            let sum = a + b + carry
            result.append(UInt32(sum & 0xffff_ffff))
            carry = sum >> 32
        }
        if carry != 0 { result.append(UInt32(carry)) }
        return BigUInt(limbs: result)
    }

    /// `self − other`, assuming `self ≥ other`.
    private func subtracting(_ other: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        var borrow: Int64 = 0
        for i in 0..<limbs.count {
            let a = Int64(limbs[i])
            let b = i < other.limbs.count ? Int64(other.limbs[i]) : 0
            var diff = a - b - borrow
            if diff < 0 { diff += 0x1_0000_0000; borrow = 1 } else { borrow = 0 }
            result.append(UInt32(diff))
        }
        return BigUInt(limbs: result)
    }

    func addSmall(_ value: UInt32) -> BigUInt { adding(BigUInt(value)) }

    /// `self >> bits` (small shift, `bits < 32` use-cases only here:
    /// 2 and 3). Implemented bit-by-bit for clarity over the few calls.
    func shiftedRight(_ bits: Int) -> BigUInt {
        var current = self
        for _ in 0..<bits {
            var result = [UInt32](repeating: 0, count: current.limbs.count)
            var carry: UInt32 = 0
            var i = current.limbs.count - 1
            while i >= 0 {
                let limb = current.limbs[i]
                result[i] = (limb >> 1) | (carry << 31)
                carry = limb & 1
                i -= 1
            }
            current = BigUInt(limbs: result)
        }
        return current
    }

    // MARK: Modular ops

    /// Total bit length (position of the highest set bit + 1).
    private var bitWidth: Int {
        if isZero { return 0 }
        let top = limbs[limbs.count - 1]
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    /// Test bit `index` (0 = least significant).
    private func bit(at index: Int) -> Bool {
        let limbIndex = index / 32
        guard limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> UInt32(index % 32)) & 1 == 1
    }

    /// `self << bits` (general left shift). Used only by `mod`'s
    /// long-division alignment.
    private func shiftedLeft(_ bits: Int) -> BigUInt {
        if isZero || bits == 0 { return self }
        let limbShift = bits / 32
        let bitShift = bits % 32
        var result = [UInt32](repeating: 0, count: limbs.count + limbShift + 1)
        for i in 0..<limbs.count {
            let v = UInt64(limbs[i]) << UInt64(bitShift)
            result[i + limbShift] |= UInt32(v & 0xffff_ffff)
            result[i + limbShift + 1] |= UInt32(v >> 32)
        }
        return BigUInt(limbs: result)
    }

    /// Reduce `self mod m` via binary long division. Clean and
    /// obviously-correct: align `m` to the top bit of `self`, then for
    /// each lower bit position subtract the shifted divisor when it
    /// fits. `self` is at most ~512 bits here (a product of two sub-`p`
    /// values), so the loop is short.
    private func mod(_ m: BigUInt) -> BigUInt {
        if compare(to: m) == .orderedAscending { return self }
        if m.isZero { return self } // never happens (m = p); guard anyway
        var remainder = self
        let shift = remainder.bitWidth - m.bitWidth
        guard shift >= 0 else { return remainder }
        var k = shift
        while k >= 0 {
            let shifted = m.shiftedLeft(k)
            if shifted.compare(to: remainder) != .orderedDescending {
                remainder = remainder.subtracting(shifted)
            }
            k -= 1
        }
        return remainder
    }

    func addMod(_ other: BigUInt, _ m: BigUInt) -> BigUInt {
        adding(other).mod(m)
    }

    func subMod(_ other: BigUInt, _ m: BigUInt) -> BigUInt {
        // self − other (mod m), with self,other < m.
        if compare(to: other) == .orderedAscending {
            // self < other → self + m − other.
            return adding(m).subtracting(other).mod(m)
        }
        return subtracting(other).mod(m)
    }

    func mulMod(_ other: BigUInt, _ m: BigUInt) -> BigUInt {
        var result: [UInt64] = [UInt64](repeating: 0, count: limbs.count + other.limbs.count)
        for i in 0..<limbs.count {
            var carry: UInt64 = 0
            let a = UInt64(limbs[i])
            for j in 0..<other.limbs.count {
                let cur = result[i + j] + a * UInt64(other.limbs[j]) + carry
                result[i + j] = cur & 0xffff_ffff
                carry = cur >> 32
            }
            result[i + other.limbs.count] += carry
        }
        return BigUInt(limbs: result.map { UInt32($0 & 0xffff_ffff) }).mod(m)
    }

    /// Modular exponentiation by square-and-multiply.
    func powMod(_ exponent: BigUInt, _ m: BigUInt) -> BigUInt {
        var result = BigUInt.one
        var base = mod(m)
        // Iterate exponent bits from least to most significant.
        for limb in exponent.limbs {
            var bit: UInt32 = 1
            for _ in 0..<32 {
                if limb & bit != 0 {
                    result = result.mulMod(base, m)
                }
                base = base.mulMod(base, m)
                bit <<= 1
            }
        }
        return result
    }

    /// Modular inverse via Fermat: `self^(m−2) mod m` (m prime).
    func inverseMod(_ m: BigUInt) -> BigUInt? {
        if isZero { return nil }
        let exp = m.subtracting(BigUInt(2))
        return powMod(exp, m)
    }
}
