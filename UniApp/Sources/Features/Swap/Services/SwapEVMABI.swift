import Foundation

/// Minimal ABI encode/decode for the two ERC-20 calls swap execution needs:
/// `allowance(owner, spender)` (read, to decide whether an approval is
/// required) and `approve(spender, amount)` (the approval tx's calldata).
///
/// **Why hand-rolled (Rule #3 lens).** These are two fixed, well-known
/// function selectors with fixed 32-byte-word ABI layouts — there is no
/// system API for ABI encoding, and pulling a web3 dependency for two
/// selectors is exactly the bloat Rule #3 forbids. The selectors are the
/// canonical `keccak256(signature)[0..<4]` constants (live-verified).
///
/// **u256 comparison without `Decimal`.** A token allowance can be up to
/// 2^256-1 (~1.16e77), which overflows `Decimal`'s 38 significant digits.
/// So sufficiency is compared as big-endian unsigned byte arrays, never as
/// `Decimal` — `isAllowance(_:atLeast:)`.
enum SwapEVMABI {

    /// `approve(address,uint256)` selector = keccak256("approve(address,uint256)")[0..<4].
    static let approveSelector = "095ea7b3"
    /// `allowance(address,address)` selector = keccak256("allowance(address,address)")[0..<4].
    static let allowanceSelector = "dd62ed3e"
    /// 2^256 - 1 as 64 hex chars — the "unlimited" approval amount.
    static let maxUint256Hex = String(repeating: "f", count: 64)

    // MARK: - Encode

    /// `eth_call` calldata for `allowance(owner, spender)` → `0x…`.
    static func allowanceCallData(owner: String, spender: String) -> String? {
        guard let o = padAddress(owner), let s = padAddress(spender) else { return nil }
        return "0x" + allowanceSelector + o + s
    }

    /// `approve(spender, amount)` calldata → `0x…`. `amountHex32` is the
    /// 64-hex-char (32-byte) amount; defaults to MAX_UINT256 (one-time
    /// unlimited approval — the convention every major aggregator wallet
    /// uses, avoiding a fresh approve before every swap of the same token).
    static func approveCallData(spender: String, amountHex32: String = maxUint256Hex) -> String? {
        guard let s = padAddress(spender), amountHex32.count == 64 else { return nil }
        return "0x" + approveSelector + s + amountHex32.lowercased()
    }

    // MARK: - Decode / compare

    /// Is the on-chain `allowance` result (a 0x / raw hex 32-byte word)
    /// at least `required` base units? Compared as big-endian unsigned
    /// integers (no `Decimal` — u256 overflows it).
    static func isAllowance(_ allowanceHex: String, atLeast required: Data) -> Bool {
        let allowance = trimLeadingZeros(hexToBytes(strip0x(allowanceHex)))
        let need = trimLeadingZeros([UInt8](required))
        if allowance.count != need.count { return allowance.count > need.count }
        // Same length → lexicographic big-endian compare.
        for (a, b) in zip(allowance, need) where a != b { return a > b }
        return true // equal → sufficient
    }

    // MARK: - Hex helpers

    /// Strip an optional `0x`/`0X` prefix; lowercase.
    static func strip0x(_ s: String) -> String {
        let lower = s.lowercased()
        return lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
    }

    /// A hex-quantity string (`"0x.."`, possibly odd-length or `"0x0"`) →
    /// big-endian `Data` for a wallet-core amount/value field. Zero (or
    /// empty) → `Data([0])`. Leading zeros trimmed (wallet-core wants the
    /// minimal big-endian representation).
    static func quantityToData(_ hex: String) -> Data {
        let bytes = trimLeadingZeros(hexToBytes(strip0x(hex)))
        return bytes.isEmpty ? Data([0]) : Data(bytes)
    }

    /// Parse a hex-quantity string to `UInt64` (gas limit / gas price —
    /// comfortably within 64 bits). `nil` if it overflows or is malformed.
    static func quantityToUInt64(_ hex: String) -> UInt64? {
        UInt64(strip0x(hex), radix: 16)
    }

    /// Left-pad a 20-byte EVM address to a 32-byte ABI word (64 hex chars).
    /// Returns `nil` if the input isn't a 40-hex-char address.
    private static func padAddress(_ address: String) -> String? {
        let hex = strip0x(address)
        guard hex.count == 40, hex.allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 24) + hex
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        let clean = hex.count % 2 == 0 ? hex : "0" + hex
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return [] }
            out.append(b)
            i = j
        }
        return out
    }

    private static func trimLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        var result = bytes
        while result.first == 0 { result.removeFirst() }
        return result
    }
}
