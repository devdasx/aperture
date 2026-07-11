import Foundation

/// Pure Polkadot `System.Account` decode + free/reserved/total helpers (P0-005).
///
/// Spendable balance for Send/MAX is always **free**, never free+reserved.
enum PolkadotAccountBalanceCodec {

    struct Decoded: Sendable, Equatable {
        let freePlancks: String
        let reservedPlancks: String
        let frozenPlancks: String
        /// free + reserved (portfolio total only).
        let totalPlancks: String
        let nonce: UInt32
        let consumers: UInt32
        let providers: UInt32
        let sufficients: UInt32
    }

    /// Decode SCALE `AccountInfo` + `AccountData` from a `state_getStorage` hex.
    static func decodeAccountInfo(hex: String) throws -> Decoded {
        let bytes = try hexBytes(hex)
        guard bytes.count >= 48 else {
            throw DecodeError.tooShort(bytes.count)
        }

        let nonce = UInt32(littleEndianBytes: Array(bytes[0..<4]))
        let consumers = UInt32(littleEndianBytes: Array(bytes[4..<8]))
        let providers = UInt32(littleEndianBytes: Array(bytes[8..<12]))
        let sufficients = UInt32(littleEndianBytes: Array(bytes[12..<16]))
        let free = decimalStringLittleEndian(Array(bytes[16..<32]))
        let reserved = decimalStringLittleEndian(Array(bytes[32..<48]))
        let frozen = bytes.count >= 64
            ? decimalStringLittleEndian(Array(bytes[48..<64]))
            : "0"
        let total = addDecimalStrings(free, reserved)
        return Decoded(
            freePlancks: free,
            reservedPlancks: reserved,
            frozenPlancks: frozen,
            totalPlancks: total,
            nonce: nonce,
            consumers: consumers,
            providers: providers,
            sufficients: sufficients
        )
    }

    /// The raw balance that must be written to `token_balances` for DOT.
    static func spendableRawBalance(free: String, reserved: String) -> String {
        // Intentionally ignore reserved — spendable is free only (P0-005).
        _ = reserved
        let trimmed = free.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "0" : stripLeadingZeros(trimmed)
    }

    static func addDecimalStrings(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.reversed().map { Int(String($0)) ?? 0 }
        let right = rhs.reversed().map { Int(String($0)) ?? 0 }
        let count = max(left.count, right.count)
        var carry = 0
        var result: [Int] = []
        result.reserveCapacity(count + 1)
        for index in 0..<count {
            let sum = (index < left.count ? left[index] : 0)
                + (index < right.count ? right[index] : 0)
                + carry
            result.append(sum % 10)
            carry = sum / 10
        }
        while carry > 0 {
            result.append(carry % 10)
            carry /= 10
        }
        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result.reversed().map(String.init).joined()
    }

    enum DecodeError: Error, Equatable {
        case tooShort(Int)
        case invalidHex
    }

    // MARK: - Private

    private static func hexBytes(_ hex: String) throws -> [UInt8] {
        var cleaned = hex
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        guard cleaned.count.isMultiple(of: 2) else { throw DecodeError.invalidHex }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                throw DecodeError.invalidHex
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func decimalStringLittleEndian(_ bytes: [UInt8]) -> String {
        let hex = bytes.reversed().map { String(format: "%02x", $0) }.joined()
        return (try? EVMHexQuantity.decimalString(from: hex)) ?? "0"
    }

    private static func stripLeadingZeros(_ digits: String) -> String {
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }
}

private extension UInt32 {
    init(littleEndianBytes bytes: [UInt8]) {
        var value: UInt32 = 0
        for (index, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        self = value
    }
}
