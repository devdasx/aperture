import Foundation

/// Decimal helpers for the compose fee/amount math. Money math for **UI**
/// is `Decimal` (never `Double`). **Wire amounts** (signing / RPC base
/// units) use integer-string paths — see `toBaseUnitsString` — because
/// `Decimal` only has 38 significant digits while u256 wei and NEAR
/// yocto can need more (BUG-025).
enum ComposeDecimal {

    /// Parse an EVM hex quantity (`0x…`, minimal big-endian per the
    /// Ethereum JSON-RPC QUANTITY rule) into a `Decimal`. Handles
    /// arbitrary width by accumulating nibble-by-nibble (× 16 + digit).
    ///
    /// **BUG-025:** for full-width u256 wire work prefer
    /// `EVMHexQuantity.decimalString(from:)` (integer string) over this;
    /// `Decimal` rounds beyond 38 significant digits.
    static func fromHexQuantity(_ hex: String) -> Decimal? {
        guard let integer = try? EVMHexQuantity.decimalString(from: hex) else { return nil }
        return fromIntegerString(integer)
    }

    /// Parse a decimal integer string (e.g. "115123062500", a plancks /
    /// yocto / drops / lamports / octas string from a JSON-RPC body)
    /// into a `Decimal`.
    ///
    /// **BUG-025:** `Decimal` holds 38 significant digits. Values wider
    /// than that are rounded when forced into `Decimal`. Prefer keeping
    /// the integer string for wire encoding (`SigningNumeric`,
    /// `SigningAmount` string paths).
    static func fromIntegerString(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Convert a base-unit `Decimal` (wei, sats, drops, octas, …) to
    /// display units by dividing by `10^decimals`.
    static func toDisplay(_ base: Decimal, decimals: Int) -> Decimal {
        guard decimals > 0 else { return base }
        return base / pow10(decimals)
    }

    /// Convert a display-unit `Decimal` to base units (× 10^decimals),
    /// as a whole integer (no fractional base units exist).
    ///
    /// **BUG-007:** uses **floor** (`.down`) for positive amounts so
    /// fiat→crypto and fractional display never produce **one base unit
    /// more** than the user can fund (broadcast overspend / rejection).
    /// Fees that must round up use `ceilToInteger` / `ceilMulDiv` instead.
    ///
    /// **BUG-025:** this returns `Decimal` and is fine for UI and for
    /// amounts that fit in 38 significant digits (every normal transfer).
    /// For signing wire amounts use `toBaseUnitsString` instead.
    static func toBaseUnits(_ display: Decimal, decimals: Int) -> Decimal {
        if display <= 0 { return 0 }
        // Prefer string floor-shift so we don't invent extra precision
        // mid-product; then parse back for UI math that still wants Decimal.
        let string = toBaseUnitsString(display, decimals: decimals)
        return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    // MARK: - BUG-025 integer-string base units (wire-safe)

    /// Display amount → base-unit **integer string** with floor, without
    /// relying on `Decimal`'s 38-digit significand for the product.
    ///
    /// Used by every chain's signing path for amounts that may become
    /// large base units (EVM wei / ERC-20, NEAR yocto, TRC-20 uint256,
    /// Polkadot plancks strings, etc.). Chains whose wire type is
    /// `UInt64`/`Int64` still go through this then parse to fixed width.
    static func toBaseUnitsString(_ display: Decimal, decimals: Int) -> String {
        if display <= 0 { return "0" }
        let plain = plainDecimalString(display)
        return toBaseUnitsString(displayString: plain, decimals: decimals) ?? "0"
    }

    /// Plain decimal **string** (e.g. user input or expanded formatter
    /// output) → floored base-unit integer string. `nil` if the string
    /// is not a finite non-negative decimal number.
    static func toBaseUnitsString(displayString: String, decimals: Int) -> String? {
        let trimmed = displayString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("-") { return "0" }

        let unsigned = trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        guard let (integerDigits, fractionDigits) = splitDecimalString(unsigned) else {
            return nil
        }

        let scale = max(0, decimals)
        if scale == 0 {
            return stripLeadingZeros(integerDigits.isEmpty ? "0" : integerDigits)
        }

        // Floor: take `scale` fraction digits (pad with 0, truncate excess).
        var fraction = fractionDigits
        if fraction.count < scale {
            fraction += String(repeating: "0", count: scale - fraction.count)
        } else if fraction.count > scale {
            fraction = String(fraction.prefix(scale))
        }

        let combined = (integerDigits.isEmpty ? "0" : integerDigits) + fraction
        return stripLeadingZeros(combined)
    }

    /// Snap a display-unit amount down to an exact multiple of
    /// `10^-decimals` (floor in base units, then convert back).
    /// Use on fiat→crypto and typed crypto before validate/sign so the
    /// draft amount never exceeds what `toBaseUnits` will encode.
    static func quantizeDisplay(_ display: Decimal, decimals: Int) -> Decimal {
        if display <= 0 { return 0 }
        let base = toBaseUnits(display, decimals: decimals)
        return toDisplay(base, decimals: max(0, decimals))
    }

    /// `10^n` as a `Decimal` (exact within Decimal's range).
    static func pow10(_ n: Int) -> Decimal {
        guard n != 0 else { return 1 }
        var result = Decimal(1)
        let ten = Decimal(10)
        if n > 0 {
            for _ in 0..<n { result *= ten }
        } else {
            for _ in 0..<(-n) { result /= ten }
        }
        return result
    }

    /// Round a `Decimal` UP to the next integer (ceil) — used for fee
    /// amounts that must be whole base units (e.g. fee = ceil(gas ×
    /// price), Solana priority = ceil(price × limit / 1e6)).
    static func ceilToInteger(_ value: Decimal) -> Decimal {
        var result = Decimal.zero
        var input = value
        NSDecimalRound(&result, &input, 0, .up)
        return result
    }

    /// Multiply two integers expressed as `Decimal` and ceil-divide by a
    /// divisor — the Solana priority-fee shape
    /// `ceil(price × limit / 1_000_000)`.
    static func ceilMulDiv(_ a: Decimal, _ b: Decimal, dividedBy d: Decimal) -> Decimal {
        guard d != 0 else { return 0 }
        return ceilToInteger((a * b) / d)
    }

    // MARK: - Plain decimal string (no scientific notation)

    /// Render a `Decimal` as a plain base-10 string without grouping or
    /// scientific notation, suitable for digit-wise base-unit conversion.
    static func plainDecimalString(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        // Prefer a fixed formatter so large magnitudes never become "1E+40".
        let formatter = Self.plainFormatter
        if let s = formatter.string(from: number) {
            return s
        }
        // Fallback: expand scientific notation from stringValue if needed.
        return expandScientificNotation(number.stringValue) ?? "0"
    }

    private static let plainFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 38
        f.minimumFractionDigits = 0
        f.maximumIntegerDigits = 128
        return f
    }()

    /// Expand `"1.23E+10"` / `"1.5e-8"` into a plain digit string.
    static func expandScientificNotation(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eIndex = s.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            return s
        }
        let mantissa = String(s[..<eIndex])
        let expString = String(s[s.index(after: eIndex)...])
        guard let exp = Int(expString) else { return nil }
        guard let (intPart, fracPart) = splitDecimalString(
            mantissa.hasPrefix("+") ? String(mantissa.dropFirst()) : mantissa
        ) else { return nil }

        let negative = mantissa.hasPrefix("-")
        let digits = (intPart == "0" || intPart.isEmpty ? "" : intPart) + fracPart
        let pointAt = (intPart == "0" || intPart.isEmpty ? 0 : intPart.count) + exp

        let plain: String
        if pointAt <= 0 {
            plain = "0." + String(repeating: "0", count: -pointAt) + digits
        } else if pointAt >= digits.count {
            plain = digits + String(repeating: "0", count: pointAt - digits.count)
        } else {
            let idx = digits.index(digits.startIndex, offsetBy: pointAt)
            plain = String(digits[..<idx]) + "." + String(digits[idx...])
        }
        return negative ? "-" + plain : plain
    }

    // MARK: - Digit helpers

    private static func splitDecimalString(_ s: String) -> (integer: String, fraction: String)? {
        // Reject non-digit content except a single '.'.
        var sawDot = false
        var integer = ""
        var fraction = ""
        for ch in s {
            if ch == "." {
                if sawDot { return nil }
                sawDot = true
                continue
            }
            guard ch.isNumber else { return nil }
            if sawDot {
                fraction.append(ch)
            } else {
                integer.append(ch)
            }
        }
        if integer.isEmpty && fraction.isEmpty { return nil }
        if integer.isEmpty { integer = "0" }
        return (integer, fraction)
    }

    private static func stripLeadingZeros(_ digits: String) -> String {
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }
}
