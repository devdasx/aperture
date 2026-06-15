import Foundation

/// Decimal helpers for the compose fee/amount math. Money math is always
/// `Decimal` (never `Double`) — magnitudes here reach u128/u256 (wei,
/// yoctoNEAR 10^24, plancks) so `Double` would lose precision.
enum ComposeDecimal {

    /// Parse an EVM hex quantity (`0x…`, minimal big-endian per the
    /// Ethereum JSON-RPC QUANTITY rule) into a `Decimal`. Handles
    /// arbitrary width by accumulating nibble-by-nibble (× 16 + digit),
    /// so a 32-byte wei value never overflows.
    static func fromHexQuantity(_ hex: String) -> Decimal? {
        var s = hex.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard !s.isEmpty else { return nil }
        var result = Decimal.zero
        let sixteen = Decimal(16)
        for ch in s {
            guard let nibble = ch.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(nibble)
        }
        return result
    }

    /// Parse a decimal integer string (e.g. "115123062500", a plancks /
    /// yocto / drops / lamports / octas string from a JSON-RPC body)
    /// into a `Decimal`, preserving full precision (no Double round-trip).
    static func fromIntegerString(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // `Decimal(string:)` parses big integers exactly (it is a
        // base-10 fixed-precision type with 38 significant digits — wide
        // enough for u128; for u256 wei we accept its rounding at the
        // 38th digit, which is sub-attowei and irrelevant to display).
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Convert a base-unit `Decimal` (wei, sats, drops, octas, …) to
    /// display units by dividing by `10^decimals`.
    static func toDisplay(_ base: Decimal, decimals: Int) -> Decimal {
        guard decimals > 0 else { return base }
        return base / pow10(decimals)
    }

    /// Convert a display-unit `Decimal` to base units (× 10^decimals),
    /// rounded to an integer (no fractional base units exist).
    static func toBaseUnits(_ display: Decimal, decimals: Int) -> Decimal {
        let raw = display * pow10(decimals)
        var rounded = Decimal.zero
        var input = raw
        NSDecimalRound(&rounded, &input, 0, .plain)
        return rounded
    }

    /// `10^n` as a `Decimal` (exact).
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
    /// amounts that must be whole base units (Cosmos fee = ceil(gas ×
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
}
