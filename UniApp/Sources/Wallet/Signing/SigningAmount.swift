import Foundation

/// Amount encodings the non-EVM, non-Bitcoin signers need to feed
/// wallet-core. Money math stays in `Decimal` end-to-end (Rule: never
/// `Double`); each chain's wallet-core SigningInput wants a different
/// concrete wire form for the value/amount field:
///
/// - `UInt64` base units — Solana lamports, Sui MIST, TON nanoton,
///   Aptos octas, Stellar stroops (as `Int64`), XRP drops (as `Int64`).
/// - 16-byte LITTLE-endian `Data` — NEAR's Borsh `u128` deposit (the
///   wallet-core proto comment says "big endian" but `Serialization.cpp`
///   copies the bytes verbatim and Borsh is LE — verified in the
///   reference + the 4.6.13 `NEARTests.swift` fixture that sets
///   `deposit = 01000000…` for value 1).
/// - big-endian minimal `Data` — TRON's TRC-20 `amount` (`uint256`) and
///   Polkadot's encoded transfer value.
/// - decimal integer `String` — Cosmos `Amount.amount`, the exact wire
///   form Cosmos's protobuf wants for u128-safe amounts.
///
/// Every helper takes the ALREADY-base-unit integer `Decimal` (i.e.
/// display × 10^decimals, produced by `ComposeDecimal.toBaseUnits`) and
/// converts losslessly. The string/Data paths preserve full u128/u256
/// precision; the `UInt64`/`Int64` paths are for chains whose amounts
/// fit 64 bits (every supported native amount comfortably does — e.g.
/// the entire SOL supply ~6e17 lamports < 2^63).
enum SigningAmount {

    /// Base-unit integer `Decimal` → decimal integer `String` (no
    /// decimal point, no exponent). The canonical wire form for Cosmos
    /// `Amount.amount`. Empty/negative → `"0"`.
    static func baseUnitsString(_ baseUnits: Decimal) -> String {
        guard baseUnits > 0 else { return "0" }
        return NSDecimalNumber(decimal: integral(baseUnits)).stringValue
    }

    /// Display-unit `Decimal` → base-unit decimal integer `String` at
    /// `decimals`. Convenience that folds `ComposeDecimal.toBaseUnits`
    /// + `baseUnitsString`.
    static func baseUnitsString(display: Decimal, decimals: Int) -> String {
        baseUnitsString(ComposeDecimal.toBaseUnits(display, decimals: decimals))
    }

    /// Base-unit integer `Decimal` → `UInt64`. `nil` if negative or it
    /// overflows 64 bits (the caller surfaces `.malformedDraft`). Used
    /// for Solana lamports, Sui MIST, TON nanoton, Aptos octas.
    static func uint64(_ baseUnits: Decimal) -> UInt64? {
        let n = NSDecimalNumber(decimal: integral(baseUnits))
        guard n.compare(NSDecimalNumber.zero) != .orderedAscending,
              n.compare(NSDecimalNumber(value: UInt64.max)) != .orderedDescending else {
            return nil
        }
        return n.uint64Value
    }

    /// Display-unit `Decimal` → `UInt64` base units at `decimals`.
    static func uint64(display: Decimal, decimals: Int) -> UInt64? {
        uint64(ComposeDecimal.toBaseUnits(display, decimals: decimals))
    }

    /// Base-unit integer `Decimal` → `Int64`. `nil` on overflow/negative.
    /// Used for Stellar stroops, XRP drops, TRON native SUN.
    static func int64(_ baseUnits: Decimal) -> Int64? {
        let n = NSDecimalNumber(decimal: integral(baseUnits))
        guard n.compare(NSDecimalNumber.zero) != .orderedAscending,
              n.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else {
            return nil
        }
        return n.int64Value
    }

    /// Display-unit `Decimal` → `Int64` base units at `decimals`.
    static func int64(display: Decimal, decimals: Int) -> Int64? {
        int64(ComposeDecimal.toBaseUnits(display, decimals: decimals))
    }

    /// Base-unit integer `Decimal` → 16-byte LITTLE-endian `Data` for a
    /// Borsh `u128` (NEAR deposit / allowance / stake). Always exactly 16
    /// bytes (zero-padded). `nil` if the value needs more than 128 bits
    /// (impossible for any realistic amount) or is negative.
    ///
    /// Verified against `NEARTests.swift` (4.6.13): a deposit of value 1
    /// is the bytes `01000000000000000000000000000000`.
    static func u128LittleEndian(_ baseUnits: Decimal) -> Data? {
        guard baseUnits >= 0 else { return nil }
        var n = NSDecimalNumber(decimal: integral(baseUnits))
        let divisor = NSDecimalNumber(value: 256)
        let behavior = NSDecimalNumberHandler(
            roundingMode: .down, scale: 0,
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        var bytes: [UInt8] = []
        while n.compare(NSDecimalNumber.zero) == .orderedDescending {
            let quotient = n.dividing(by: divisor, withBehavior: behavior)
            let remainder = n.subtracting(quotient.multiplying(by: divisor, withBehavior: behavior))
            bytes.append(UInt8(truncating: remainder)) // LSB first → LE
            n = quotient
        }
        guard bytes.count <= 16 else { return nil }
        while bytes.count < 16 { bytes.append(0) }
        return Data(bytes)
    }

    /// Display-unit `Decimal` → 16-byte LE `u128` Data at `decimals`.
    static func u128LittleEndian(display: Decimal, decimals: Int) -> Data? {
        u128LittleEndian(ComposeDecimal.toBaseUnits(display, decimals: decimals))
    }

    /// Base-unit integer `Decimal` → minimal big-endian `Data` (no
    /// leading zeros; `Data([0])` for zero). The wire form for TRON's
    /// TRC-20 `uint256` amount and Polkadot's encoded value. Full u256
    /// precision via the decimal-string path in `SigningNumeric`.
    static func bigEndianMinimal(_ baseUnits: Decimal) -> Data? {
        SigningNumeric.bigEndianData(fromBaseUnitsString: baseUnitsString(baseUnits))
    }

    /// Display-unit `Decimal` → minimal big-endian `Data` at `decimals`.
    static func bigEndianMinimal(display: Decimal, decimals: Int) -> Data? {
        bigEndianMinimal(ComposeDecimal.toBaseUnits(display, decimals: decimals))
    }

    /// Round a `Decimal` DOWN to an integer (base units never have a
    /// fractional part; defensive against a stray fraction).
    private static func integral(_ value: Decimal) -> Decimal {
        var rounded = Decimal.zero
        var input = value
        NSDecimalRound(&rounded, &input, 0, .down)
        return rounded
    }
}
