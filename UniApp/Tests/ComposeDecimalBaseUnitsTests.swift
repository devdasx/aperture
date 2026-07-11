import Foundation
import Testing
@testable import Aperture

/// BUG-007: display → base units must **floor**, never round up past
/// spendable balance (fiat→crypto and fractional display edges).
struct ComposeDecimalBaseUnitsTests {

    // MARK: - Floor vs half-up

    @Test("toBaseUnits floors fractional base units (no half-up)")
    func floorsFractionalBaseUnits() {
        // 1.5 sat with 8 decimals would be nonsense; use 8 dec ETH-like:
        // 1.000000001 ETH → 1000000001 wei if rounded, but 1 + 0.5 wei:
        // display = 1 / 1e8 * 1.5 = 0.000000015 → * 1e8 = 1.5 → floor 1
        let display = Decimal(string: "0.000000015")! // 1.5 base units at 8 dec
        let base = ComposeDecimal.toBaseUnits(display, decimals: 8)
        #expect(base == 1, "1.5 base units must floor to 1, not round to 2")

        // Classic half-up trap: 0.5 base unit at 0 decimals → floor 0
        #expect(ComposeDecimal.toBaseUnits(Decimal(string: "0.5")!, decimals: 0) == 0)

        // 1.999... sats (8 dec): 1.999999999e-8 display * 1e8 ≈ 1.999… → 1
        let almostTwo = Decimal(string: "0.00000001999")!
        #expect(ComposeDecimal.toBaseUnits(almostTwo, decimals: 8) == 1)
    }

    @Test("toBaseUnits never exceeds exact display × 10^decimals")
    func neverExceedsExactProduct() {
        // Values that half-up (.plain) would bump up by 1 base unit.
        let cases: [(display: String, decimals: Int)] = [
            ("1.000000005", 8),   // 100000000.5 sats-equivalent → floor 100000000
            ("0.1", 1),           // 1.0 exactly
            ("0.15", 1),          // 1.5 → 1
            ("99.999999999", 8),  // just under 100e8 base
            ("1.234567891234", 8)
        ]
        for c in cases {
            let display = Decimal(string: c.display)!
            let base = ComposeDecimal.toBaseUnits(display, decimals: c.decimals)
            let exact = display * ComposeDecimal.pow10(c.decimals)
            #expect(base <= exact, "\(c.display) @\(c.decimals): base \(base) > exact \(exact)")
            // Re-encoded display must be ≤ original
            let back = ComposeDecimal.toDisplay(base, decimals: c.decimals)
            #expect(back <= display)
        }
    }

    @Test("exact base units stay exact (no floor damage)")
    func exactAmountsUnchanged() {
        #expect(ComposeDecimal.toBaseUnits(1, decimals: 8) == 100_000_000)
        #expect(ComposeDecimal.toBaseUnits(Decimal(string: "0.00000001")!, decimals: 8) == 1)
        #expect(ComposeDecimal.toBaseUnits(Decimal(string: "21")!, decimals: 0) == 21)
        #expect(ComposeDecimal.toBaseUnits(0, decimals: 18) == 0)
    }

    @Test("non-positive display yields zero base units")
    func nonPositiveZero() {
        #expect(ComposeDecimal.toBaseUnits(0, decimals: 8) == 0)
        #expect(ComposeDecimal.toBaseUnits(Decimal(string: "-1")!, decimals: 8) == 0)
    }

    // MARK: - quantizeDisplay (fiat→crypto path)

    @Test("quantizeDisplay floors to asset decimals")
    func quantizeFloorsToDecimals() {
        // 1/3 ETH-like at 8 decimals must not exceed spendable quanta.
        let third = Decimal(1) / Decimal(3) // 0.333…
        let q = ComposeDecimal.quantizeDisplay(third, decimals: 8)
        let base = ComposeDecimal.toBaseUnits(q, decimals: 8)
        #expect(base == ComposeDecimal.toBaseUnits(third, decimals: 8))
        #expect(q == ComposeDecimal.toDisplay(base, decimals: 8))
        #expect(q <= third)
    }

    @Test("fiat conversion then quantize never overspends base balance")
    func fiatConversionNeverOverspends() {
        // User types $100, price $3/token, decimals 6.
        // 100/3 = 33.333… → floor base units must be ≤ balance of same.
        let fiat: Decimal = 100
        let price: Decimal = 3
        let decimals = 6
        let crypto = fiat / price
        let quantized = ComposeDecimal.quantizeDisplay(crypto, decimals: decimals)
        let spendBase = ComposeDecimal.toBaseUnits(quantized, decimals: decimals)

        // Balance is exactly the floored amount (MAX edge).
        let balanceBase = spendBase
        #expect(spendBase <= balanceBase)
        #expect(spendBase == ComposeDecimal.toBaseUnits(crypto, decimals: decimals))

        // .plain half-up trap: 1.5 base units of a 6-dec token from fiat.
        // Construct display such that × 10^6 = n + 0.5
        let halfUpTrap = ComposeDecimal.toDisplay(Decimal(string: "1.5")!, decimals: 6)
        let plainWouldBeTwo = NSDecimalNumber(decimal: halfUpTrap * ComposeDecimal.pow10(6))
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0,
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false
            )).intValue
        #expect(plainWouldBeTwo == 2)
        #expect(ComposeDecimal.toBaseUnits(halfUpTrap, decimals: 6) == 1)
    }

    @Test("MAX near-full-balance: floor amount + fee never exceeds balance")
    func maxNearFullBalance() {
        // Balance 1_000_000 sats; fee 141 sats; max send display from remainder.
        let balanceSats: Decimal = 1_000_000
        let feeSats: Decimal = 141
        let decimals = 8
        let availableDisplay = ComposeDecimal.toDisplay(balanceSats - feeSats, decimals: decimals)
        // Dirty float-like inflation of available (as if fiat round-tripped).
        let inflated = availableDisplay + Decimal(string: "0.000000005")! // +0.5 sat
        let flooredBase = ComposeDecimal.toBaseUnits(inflated, decimals: decimals)
        #expect(flooredBase + feeSats <= balanceSats)

        // Old .plain behavior would have rounded 0.5 sat up → overspend.
        var plain = Decimal.zero
        var input = inflated * ComposeDecimal.pow10(decimals)
        NSDecimalRound(&plain, &input, 0, .plain)
        #expect(plain == flooredBase + 1 || plain == flooredBase) // document half-up risk
        if plain > flooredBase {
            #expect(plain + feeSats > balanceSats)
            #expect(flooredBase + feeSats <= balanceSats)
        }
    }

    // MARK: - SigningAmount uses floor path

    @Test("SigningAmount.uint64 uses floored base units")
    func signingAmountUint64Floors() {
        // 1.9 lamports at 9 decimals as display 1.9e-9
        let display = ComposeDecimal.toDisplay(Decimal(string: "1.9")!, decimals: 9)
        let u = SigningAmount.uint64(display: display, decimals: 9)
        #expect(u == 1)
    }

    @Test("fees still use ceil (unaffected by send-amount floor)")
    func feesStillCeil() {
        #expect(ComposeDecimal.ceilToInteger(Decimal(string: "1.1")!) == 2)
        #expect(ComposeDecimal.ceilMulDiv(3, 5, dividedBy: 2) == 8) // ceil(15/2)=8
    }
}
