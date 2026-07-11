import Foundation

/// Amount encodings the non-EVM, non-Bitcoin signers need to feed
/// wallet-core. UI money math may use `Decimal`; **wire** amounts use
/// integer strings / fixed-width integers / raw `Data` so values beyond
/// Decimal's 38 significant digits stay exact (BUG-025).
///
/// Each chain's wallet-core SigningInput wants a different concrete
/// wire form for the value/amount field:
///
/// - `UInt64` base units — Solana lamports, Sui MIST, TON nanoton,
///   Aptos octas, Stellar stroops (as `Int64`), XRP drops (as `Int64`).
/// - 16-byte LITTLE-endian `Data` — NEAR's Borsh `u128` deposit.
/// - big-endian minimal `Data` — TRON TRC-20 `amount` (`uint256`) and
///   Polkadot-style encoded values.
/// - decimal integer `String` — whole base-unit amount without a
///   fractional point (u128/u256-safe wire forms).
///
/// Display → base conversion always goes through
/// `ComposeDecimal.toBaseUnitsString` (floor, integer digits) so EVM
/// wei, NEAR yocto, and huge ERC-20/TRC-20 amounts never round at the
/// 38th significant digit on the way to the wire.
enum SigningAmount {

    /// Base-unit integer `Decimal` → decimal integer `String`.
    /// Prefer `baseUnitsString(display:decimals:)` for new call sites.
    static func baseUnitsString(_ baseUnits: Decimal) -> String {
        if baseUnits <= 0 { return "0" }
        // Already-integral base units: plain string without scientific notation.
        let plain = ComposeDecimal.plainDecimalString(baseUnits)
        // Drop any fractional tail (defensive floor).
        if let dot = plain.firstIndex(of: ".") {
            let intPart = String(plain[..<dot])
            return intPart.isEmpty || intPart == "-" ? "0" : stripNonDigitsLeading(intPart)
        }
        return stripNonDigitsLeading(plain)
    }

    /// Display-unit `Decimal` → base-unit decimal integer `String` at
    /// `decimals` (floor). **Wire-safe** for full u256 / u128 widths.
    static func baseUnitsString(display: Decimal, decimals: Int) -> String {
        ComposeDecimal.toBaseUnitsString(display, decimals: decimals)
    }

    /// Base-unit integer `Decimal` → `UInt64`. `nil` if negative or it
    /// overflows 64 bits. Solana lamports, Sui MIST, TON nanoton, Aptos octas.
    static func uint64(_ baseUnits: Decimal) -> UInt64? {
        uint64(baseUnitsString: baseUnitsString(baseUnits))
    }

    /// Display-unit `Decimal` → `UInt64` base units at `decimals`.
    static func uint64(display: Decimal, decimals: Int) -> UInt64? {
        uint64(baseUnitsString: baseUnitsString(display: display, decimals: decimals))
    }

    static func uint64(baseUnitsString: String) -> UInt64? {
        let s = baseUnitsString.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.allSatisfy(\.isNumber), let v = UInt64(s) else { return nil }
        return v
    }

    /// Base-unit integer `Decimal` → `Int64`. `nil` on overflow/negative.
    /// Stellar stroops, XRP drops, TRON native SUN, Bitcoin sats.
    static func int64(_ baseUnits: Decimal) -> Int64? {
        int64(baseUnitsString: baseUnitsString(baseUnits))
    }

    /// Display-unit `Decimal` → `Int64` base units at `decimals`.
    static func int64(display: Decimal, decimals: Int) -> Int64? {
        int64(baseUnitsString: baseUnitsString(display: display, decimals: decimals))
    }

    static func int64(baseUnitsString: String) -> Int64? {
        let s = baseUnitsString.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.allSatisfy(\.isNumber), let v = Int64(s) else { return nil }
        return v
    }

    /// Base-unit integer `Decimal` → 16-byte LITTLE-endian `Data` for a
    /// Borsh `u128` (NEAR). Prefer the string overload for full width.
    static func u128LittleEndian(_ baseUnits: Decimal) -> Data? {
        u128LittleEndian(baseUnitsString: baseUnitsString(baseUnits))
    }

    /// Display-unit `Decimal` → 16-byte LE `u128` Data at `decimals`.
    static func u128LittleEndian(display: Decimal, decimals: Int) -> Data? {
        u128LittleEndian(baseUnitsString: baseUnitsString(display: display, decimals: decimals))
    }

    /// Integer base-units string → 16-byte LITTLE-endian `Data` (Borsh u128).
    /// Exact for any width ≤ 128 bits; `nil` if larger or non-numeric.
    ///
    /// Verified shape: value 1 → `01000000000000000000000000000000`.
    static func u128LittleEndian(baseUnitsString: String) -> Data? {
        let trimmed = baseUnitsString.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "0" {
            return Data(repeating: 0, count: 16)
        }
        guard trimmed.allSatisfy(\.isNumber) else { return nil }

        // Base-256 long division (LSB-out), same algorithm as
        // SigningNumeric.bigEndianData(fromBaseUnitsString:) then reverse
        // for little-endian and pad to 16.
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
            bytes.append(UInt8(remainder)) // LSB first → LE
            digits = quotient.isEmpty ? [0] : quotient
            if bytes.count > 16 { return nil }
        }
        while bytes.count < 16 { bytes.append(0) }
        return Data(bytes)
    }

    /// Base-unit integer `Decimal` → minimal big-endian `Data`.
    /// Routes through the integer-string path (full u256).
    static func bigEndianMinimal(_ baseUnits: Decimal) -> Data? {
        SigningNumeric.bigEndianData(fromBaseUnitsString: baseUnitsString(baseUnits))
    }

    /// Display-unit `Decimal` → minimal big-endian `Data` at `decimals`.
    static func bigEndianMinimal(display: Decimal, decimals: Int) -> Data? {
        SigningNumeric.bigEndianData(
            fromBaseUnitsString: baseUnitsString(display: display, decimals: decimals)
        )
    }

    // MARK: - Private

    private static func stripNonDigitsLeading(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }
}
