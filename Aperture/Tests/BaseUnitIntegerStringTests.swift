import Foundation
import Testing
@testable import Aperture

/// BUG-025: wire amounts must not depend on Decimal's 38 significant digits.
/// Integer-string / Data paths cover EVM u256, NEAR u128, and fixed-width
/// chains (UInt64/Int64) consistently.
@Suite("Base-unit integer strings (BUG-025)")
struct BaseUnitIntegerStringTests {

    // MARK: - Floor shift (all chains)

    @Test("toBaseUnitsString floors fractional base units")
    func floorShift() {
        #expect(ComposeDecimal.toBaseUnitsString(displayString: "0.000000015", decimals: 8) == "1")
        #expect(ComposeDecimal.toBaseUnitsString(displayString: "1.5", decimals: 0) == "1")
        #expect(ComposeDecimal.toBaseUnitsString(displayString: "0.5", decimals: 0) == "0")
        #expect(ComposeDecimal.toBaseUnitsString(displayString: "1", decimals: 18) == "1000000000000000000")
        #expect(ComposeDecimal.toBaseUnitsString(displayString: "1.234567891234567891", decimals: 18)
            == "1234567891234567891")
    }

    @Test("Normal chain decimals match expected base units")
    func allFamilyNormalAmounts() {
        // BTC-family 8
        #expect(SigningAmount.baseUnitsString(display: Decimal(string: "0.5")!, decimals: 8) == "50000000")
        // EVM 18
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 18) == "1000000000000000000")
        // SOL 9
        #expect(SigningAmount.baseUnitsString(display: Decimal(string: "1.5")!, decimals: 9) == "1500000000")
        // XRP 6
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 6) == "1000000")
        // NEAR 24
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 24) == "1000000000000000000000000")
        // TRON 6
        #expect(SigningAmount.baseUnitsString(display: Decimal(string: "10.5")!, decimals: 6) == "10500000")
        // DOT 10
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 10) == "10000000000")
        // APT 8
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 8) == "100000000")
        // SUI 9
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 9) == "1000000000")
        // TON 9
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 9) == "1000000000")
        // XLM 7
        #expect(SigningAmount.baseUnitsString(display: 1, decimals: 7) == "10000000")
    }

    @Test("Pathological width: base units string exceeds 38 digits exactly")
    func exceeds38DigitsExact() {
        // 40 nines display integer part × 18 decimals = 58 digit base string —
        // far past Decimal's 38 significant digits if multiplied in Decimal.
        let intPart = String(repeating: "9", count: 40)
        let display = intPart + ".123456789012345678"
        let base = ComposeDecimal.toBaseUnitsString(displayString: display, decimals: 18)
        #expect(base == intPart + "123456789012345678")
        #expect(base?.count == 58)

        // Wire BE data must accept the full string.
        let data = SigningNumeric.bigEndianData(fromBaseUnitsString: base!)
        #expect(data != nil)
        #expect(data!.count > 0)
        #expect(data != Data([0]))
    }

    @Test("ERC-20 call data uses full base-units string")
    func erc20CallDataFullWidth() throws {
        let amount = String(repeating: "1", count: 50) // 50-digit token amount
        let data = try #require(SigningNumeric.erc20TransferCallData(
            to: "0x1111111111111111111111111111111111111111",
            amountBaseUnits: amount
        ))
        // selector(4) + address pad(32) + amount(32) = 68
        #expect(data.count == 68)
        #expect(data.prefix(4) == Data([0xa9, 0x05, 0x9c, 0xbb]))
        // Amount right-aligned in last 32 bytes must be non-zero.
        #expect(data.suffix(32).contains { $0 != 0 })
    }

    // MARK: - Fixed-width chains (string → UInt64/Int64)

    @Test("UInt64 / Int64 parsers reject overflow, accept normal")
    func fixedWidth() {
        #expect(SigningAmount.uint64(display: 1, decimals: 9) == 1_000_000_000) // SOL
        #expect(SigningAmount.int64(display: 1, decimals: 8) == 100_000_000) // BTC sats
        #expect(SigningAmount.int64(display: 1, decimals: 6) == 1_000_000) // XRP/TRX

        // Overflow: 2^64 as string
        let tooBig = "18446744073709551616" // UInt64.max + 1
        #expect(SigningAmount.uint64(baseUnitsString: tooBig) == nil)
        #expect(SigningAmount.int64(baseUnitsString: "9223372036854775808") == nil) // Int64.max+1
    }

    // MARK: - NEAR u128 LE

    @Test("NEAR u128 little-endian: 1 and large yocto")
    func nearU128() throws {
        let one = try #require(SigningAmount.u128LittleEndian(baseUnitsString: "1"))
        #expect(one.count == 16)
        #expect(one[0] == 1)
        #expect(one.dropFirst().allSatisfy { $0 == 0 })

        // 1 NEAR = 10^24 yocto
        let oneNear = try #require(
            SigningAmount.u128LittleEndian(display: 1, decimals: 24)
        )
        #expect(oneNear.count == 16)
        // Round-trip via BE string path equality of magnitude: not zero.
        #expect(oneNear.contains { $0 != 0 })

        // 38-digit yocto amount fits u128 and exceeds Decimal's 38-sig
        // product risk when formed as display × 10^24 in Decimal math.
        let huge = "1" + String(repeating: "0", count: 37) // 10^37
        let data = try #require(SigningAmount.u128LittleEndian(baseUnitsString: huge))
        #expect(data.count == 16)
        #expect(data.contains { $0 != 0 })
    }

    @Test("u128 rejects values needing more than 16 bytes")
    func u128Overflow() {
        // 2^128 as decimal
        let twoTo128 = "340282366920938463463374607431768211456"
        #expect(SigningAmount.u128LittleEndian(baseUnitsString: twoTo128) == nil)
    }

    // MARK: - Hex quantity → integer string (EVM balances)

    @Test("Hex quantity to decimal string is exact for wide values")
    func hexToDecimalString() throws {
        // 2^255 as hex
        let hex = "0x8000000000000000000000000000000000000000000000000000000000000000"
        let dec = try EVMHexQuantity.decimalString(from: hex)
        #expect(dec == "57896044618658097711785492504343953926634992332820282019728792003956564819968")
        #expect(dec.count > 38)
    }

    @Test("displayAmount from raw string is digit-exact beyond 38 digits")
    func displayFromRawWide() {
        let raw = String(repeating: "9", count: 40) + "000000000000000000" // 40 nines + 18 zeros
        let display = EVMHexQuantity.displayAmount(rawBalance: raw, decimals: 18)
        #expect(display == String(repeating: "9", count: 40))
    }

    @Test("plainDecimalString avoids scientific notation")
    func noScientific() {
        let d = Decimal(string: "1000000000000000000")!
        let s = ComposeDecimal.plainDecimalString(d)
        #expect(!s.contains("E") && !s.contains("e"))
        #expect(s == "1000000000000000000")
    }

    @Test("SigningAmount display paths match floor of ComposeDecimal for normal sizes")
    func parityWithDecimalPath() {
        let samples: [(String, Int)] = [
            ("0.000000015", 8),
            ("1.23456789", 8),
            ("99.999999999", 9),
            ("0.15", 1),
        ]
        for (display, dec) in samples {
            let d = Decimal(string: display)!
            let viaString = SigningAmount.baseUnitsString(display: d, decimals: dec)
            let viaDecimal = NSDecimalNumber(
                decimal: ComposeDecimal.toBaseUnits(d, decimals: dec)
            ).stringValue
            #expect(viaString == viaDecimal, "\(display)@\(dec): \(viaString) vs \(viaDecimal)")
        }
    }

    @Test("TRON TRC-20 big-endian minimal from display")
    func tronTRC20BE() throws {
        let data = try #require(SigningAmount.bigEndianMinimal(display: 1, decimals: 6))
        // 1_000_000 = 0x0F4240
        #expect(data == Data([0x0F, 0x42, 0x40]))
    }
}
