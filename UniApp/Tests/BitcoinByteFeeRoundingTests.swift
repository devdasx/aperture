import Foundation
import Testing
@testable import Aperture

/// BUG-017: Bitcoin-family `byteFee` must ceil fractional sat/vB (or sat/byte),
/// never truncate with `int64Value`. Applies to BTC / BCH / LTC / DOGE via
/// the shared `BitcoinTransactionSigner`.
@Suite("Bitcoin-family byte fee rounding (BUG-017)")
struct BitcoinByteFeeRoundingTests {

    @Test("Fractional rates ceil (1.9 → 2, 0.1 → 1)")
    func fractionalRatesCeil() throws {
        #expect(try BitcoinTransactionSigner.integerByteFee(from: Decimal(string: "1.9")!) == 2)
        #expect(try BitcoinTransactionSigner.integerByteFee(from: Decimal(string: "1.1")!) == 2)
        #expect(try BitcoinTransactionSigner.integerByteFee(from: Decimal(string: "0.1")!) == 1)
        #expect(try BitcoinTransactionSigner.integerByteFee(from: Decimal(string: "0.01")!) == 1)
        #expect(try BitcoinTransactionSigner.integerByteFee(from: Decimal(string: "3.01")!) == 4)
    }

    @Test("Whole rates stay unchanged")
    func wholeRatesUnchanged() throws {
        #expect(try BitcoinTransactionSigner.integerByteFee(from: 1) == 1)
        #expect(try BitcoinTransactionSigner.integerByteFee(from: 5) == 5)
        #expect(try BitcoinTransactionSigner.integerByteFee(from: 100) == 100)
    }

    @Test("BUG-017 regression: int64Value truncation would underpay")
    func truncationWouldUnderpay() throws {
        let rate = Decimal(string: "1.9")!
        let truncated = NSDecimalNumber(decimal: rate).int64Value
        let ceiled = try BitcoinTransactionSigner.integerByteFee(from: rate)
        #expect(truncated == 1, "documents the old bug")
        #expect(ceiled == 2)
        #expect(ceiled > truncated)
    }

    @Test("Non-positive rates are rejected after ceil")
    func rejectsNonPositive() {
        #expect(throws: SigningError.self) {
            _ = try BitcoinTransactionSigner.integerByteFee(from: nil)
        }
        #expect(throws: SigningError.self) {
            _ = try BitcoinTransactionSigner.integerByteFee(from: 0)
        }
        #expect(throws: SigningError.self) {
            _ = try BitcoinTransactionSigner.integerByteFee(from: Decimal(string: "-1")!)
        }
    }

    @Test("Coin selection already ceils fee totals (parity with signer rate)")
    func coinSelectionCeilsFeeTotals() {
        // UTXOService.feeSats uses ComposeDecimal.ceilToInteger(rate * vsize).
        // A 1.9 sat/vB rate on 140 vB must not be 1*140=140.
        let rate = Decimal(string: "1.9")!
        let vsize = 140
        let truncatedTotal = NSDecimalNumber(decimal: rate).int64Value * Int64(vsize)
        let ceiledTotal = NSDecimalNumber(
            decimal: ComposeDecimal.ceilToInteger(rate * Decimal(vsize))
        ).int64Value
        #expect(truncatedTotal == 140)
        #expect(ceiledTotal == 266) // ceil(1.9 * 140) = ceil(266) = 266
        #expect(ceiledTotal > truncatedTotal)
    }
}
