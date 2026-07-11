import Foundation

/// Numeric encodings the EVM signer needs to feed wallet-core. All
/// money/amount math is `Decimal` (Rule: never `Double`); the wire form
/// wallet-core's `EthereumSigningInput` wants is **big-endian minimal
/// `Data`** for every quantity (chainID, nonce, gasLimit, the 1559 fee
/// caps, gasPrice, value, and the ERC-20 amount).
///
/// Doc: Ethereum JSON-RPC QUANTITY rule (minimal big-endian, no leading
/// zeros) — https://ethereum.org/en/developers/docs/apis/json-rpc/ ;
/// wallet-core Ethereum.proto fields are raw big-endian byte strings.
enum SigningNumeric {

    /// Convert a non-negative whole-number `Decimal` (base units —
    /// already × 10^decimals, integral) to minimal big-endian `Data`.
    ///
    /// **BUG-025:** routes through the integer-string encoder so values
    /// wider than Decimal's 38 significant digits are not re-rounded by
    /// NSDecimalNumber divmod. Prefer calling
    /// `bigEndianData(fromBaseUnitsString:)` directly when you already
    /// hold a base-units string.
    static func bigEndianData(fromWholeDecimal value: Decimal) -> Data? {
        guard value >= 0 else { return nil }
        var rounded = Decimal.zero
        var input = value
        NSDecimalRound(&rounded, &input, 0, .down)
        guard rounded == value else { return nil }
        return bigEndianData(fromBaseUnitsString: ComposeDecimal.plainDecimalString(rounded))
    }

    /// Convert a base-units integer STRING (e.g. "1000000000000000000")
    /// to minimal big-endian `Data`. Exact for any width (256-bit and
    /// beyond) because it processes the decimal digits directly —
    /// preferred over the `Decimal` path for the value/amount fields
    /// where full u256 precision matters. Returns `nil` for non-digit
    /// input; `Data([0])` for "0" / "".
    static func bigEndianData(fromBaseUnitsString decimal: String) -> Data? {
        let trimmed = decimal.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "0" { return Data([0]) }
        guard trimmed.allSatisfy({ $0.isNumber }) else { return nil }
        // Base-256 long division of the decimal string (LSB-out, then
        // reverse). Standard arbitrary-precision base conversion.
        var bytes: [UInt8] = []
        var digits = Array(trimmed).map { Int(String($0))! }
        while !(digits.count == 1 && digits[0] == 0) {
            var remainder = 0
            var quotient: [Int] = []
            for d in digits {
                let acc = remainder * 10 + d
                let q = acc / 256
                remainder = acc % 256
                if !quotient.isEmpty || q > 0 { quotient.append(q) }
            }
            bytes.append(UInt8(remainder))
            digits = quotient.isEmpty ? [0] : quotient
        }
        return Data(bytes.reversed())
    }

    /// Minimal big-endian `Data` for a `UInt64` (chainID / nonce /
    /// gasLimit are comfortably within 64 bits). Zero → `Data([0])`.
    static func bigEndianData(fromUInt64 value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var v = value.bigEndian
        let raw = withUnsafeBytes(of: &v) { Array($0) }
        let trimmed = Array(raw.drop(while: { $0 == 0 }))
        return Data(trimmed)
    }

    /// ERC-20 `transfer(address,uint256)` call data as `Data`:
    /// selector `0xa9059cbb` + 32-byte left-padded recipient + 32-byte
    /// big-endian amount (token base units). The `value` of the EVM tx
    /// is 0 for a token transfer; the amount rides in this calldata.
    ///
    /// Doc: ERC-20 standard `transfer(address _to, uint256 _value)`,
    /// selector = first 4 bytes of keccak256("transfer(address,uint256)")
    /// = `0xa9059cbb` (verified — the same selector the app's read path
    /// uses for `balanceOf` siblings). Live `eth_estimateGas` for this
    /// calldata shape returned 0xa31a (~41,754 gas) for USDT, matrix §G2.
    static func erc20TransferCallData(to recipient: String, amountBaseUnits: String) -> Data? {
        var data = Data([0xa9, 0x05, 0x9c, 0xbb]) // transfer selector
        // Recipient: 20-byte address, left-padded to 32 bytes.
        let addrHex = recipient.hasPrefix("0x") || recipient.hasPrefix("0X")
            ? String(recipient.dropFirst(2)) : recipient
        guard let addrBytes = hexToData(addrHex), addrBytes.count == 20 else { return nil }
        data.append(Data(repeating: 0, count: 12))
        data.append(addrBytes)
        // Amount: uint256, right-aligned (left-padded) to 32 bytes.
        guard let amountBE = bigEndianData(fromBaseUnitsString: amountBaseUnits),
              amountBE.count <= 32 else { return nil }
        // A single 0x00 from "0"/"" is fine — pad to 32.
        let amount = amountBE == Data([0]) ? Data() : amountBE
        data.append(Data(repeating: 0, count: 32 - amount.count))
        data.append(amount)
        return data
    }

    /// Decode a hex string (no `0x`) to `Data`. `nil` on odd length /
    /// non-hex.
    static func hexToData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            out.append(byte)
            i = next
        }
        return out
    }

    /// `0x`-prefixed lowercase hex for `data`.
    static func hexString0x(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    /// Bare lowercase hex for `data` (no prefix) — Bitcoin-family
    /// broadcast wire form.
    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
