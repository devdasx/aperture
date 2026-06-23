import Foundation

/// Minimal ABI encoding for the two ERC-20 calls the **Token Approvals**
/// feature needs: `allowance(owner, spender)` (read, to surface a live
/// allowance) and `approve(spender, amount)` (the revoke tx's calldata,
/// with `amount == 0`).
///
/// **Why hand-rolled (Rule #3 lens).** These are two fixed, well-known
/// function selectors with fixed 32-byte-word ABI layouts — there is no
/// system API for ABI encoding, and pulling a web3 dependency for two
/// selectors is exactly the bloat Rule #3 forbids. The selectors are the
/// canonical `keccak256(signature)[0..<4]` constants (live-verified).
///
/// Pure compute, value-type namespace — no shared state.
enum EVMERC20ABI {

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
    /// 64-hex-char (32-byte) amount; defaults to MAX_UINT256 (an unlimited
    /// grant). The Approvals revoke flow overrides it with 64 zero nibbles
    /// to set the allowance back to zero.
    static func approveCallData(spender: String, amountHex32: String = maxUint256Hex) -> String? {
        guard let s = padAddress(spender), amountHex32.count == 64 else { return nil }
        return "0x" + approveSelector + s + amountHex32.lowercased()
    }

    // MARK: - Hex helpers

    /// Strip an optional `0x`/`0X` prefix; lowercase.
    static func strip0x(_ s: String) -> String {
        let lower = s.lowercased()
        return lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
    }

    /// Left-pad a 20-byte EVM address to a 32-byte ABI word (64 hex chars).
    /// Returns `nil` if the input isn't a 40-hex-char address.
    private static func padAddress(_ address: String) -> String? {
        let hex = strip0x(address)
        guard hex.count == 40, hex.allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 24) + hex
    }
}
