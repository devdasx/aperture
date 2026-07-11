import Foundation
import Testing
@testable import Aperture

/// BUG-014: Solana native outgoing activity must not double-count fee.
@Suite("Solana native activity amount (BUG-014)")
struct SolanaNativeActivityAmountTests {

    // MARK: - Outgoing fee payer (common path)

    @Test("Outgoing fee-payer amount is |delta| minus fee (matches BTC style)")
    func outgoingFeePayerSubtractsFee() throws {
        // Send 1 SOL (1e9 lamports) + 5000 fee → balance drops 1_000_005_000.
        let delta = Decimal(-1_000_005_000)
        let fee: Int64 = 5_000
        let resolved = try #require(
            SolanaNativeActivityAmount.resolve(
                balanceDeltaLamports: delta,
                feeLamports: fee,
                ownerIsFeePayer: true
            )
        )
        #expect(resolved.direction == .outgoing)
        #expect(resolved.amountLamports == Decimal(1_000_000_000))

        // Display should be "1" SOL (9 decimals), not "1.000005".
        let display = try #require(
            EVMHexQuantity.displayAmount(
                rawBalance: NSDecimalNumber(decimal: resolved.amountLamports).stringValue,
                decimals: SupportedChain.solana.nativeDecimals
            )
        )
        #expect(display == "1" || display.hasPrefix("1"))
        #expect(!display.hasPrefix("1.000005"))
    }

    @Test("Outgoing with only fee (no transfer) is dropped")
    func pureFeeOutgoingDropped() {
        let resolved = SolanaNativeActivityAmount.resolve(
            balanceDeltaLamports: Decimal(-5_000),
            feeLamports: 5_000,
            ownerIsFeePayer: true
        )
        #expect(resolved == nil)
    }

    @Test("Outgoing fee larger than delta clamps and drops zero")
    func feeLargerThanDeltaDropped() {
        // Should not go negative; amount 0 → nil.
        let resolved = SolanaNativeActivityAmount.resolve(
            balanceDeltaLamports: Decimal(-1_000),
            feeLamports: 5_000,
            ownerIsFeePayer: true
        )
        #expect(resolved == nil)
    }

    // MARK: - Incoming / non-fee-payer

    @Test("Incoming amount is full positive delta (fee not subtracted)")
    func incomingKeepsFullDelta() throws {
        let resolved = try #require(
            SolanaNativeActivityAmount.resolve(
                balanceDeltaLamports: Decimal(2_500_000_000),
                feeLamports: 5_000,
                ownerIsFeePayer: false
            )
        )
        #expect(resolved.direction == .incoming)
        #expect(resolved.amountLamports == Decimal(2_500_000_000))
    }

    @Test("Outgoing non-fee-payer keeps full |delta| (fee paid by someone else)")
    func outgoingNonFeePayerDoesNotSubtract() throws {
        // Recipient of a self-transfer pattern / funded by another payer:
        // balance only drops by the transferred amount.
        let resolved = try #require(
            SolanaNativeActivityAmount.resolve(
                balanceDeltaLamports: Decimal(-500_000_000),
                feeLamports: 5_000,
                ownerIsFeePayer: false
            )
        )
        #expect(resolved.direction == .outgoing)
        #expect(resolved.amountLamports == Decimal(500_000_000))
    }

    @Test("Zero delta yields nil")
    func zeroDeltaNil() {
        #expect(
            SolanaNativeActivityAmount.resolve(
                balanceDeltaLamports: 0,
                feeLamports: 5_000,
                ownerIsFeePayer: true
            ) == nil
        )
    }

    // MARK: - Realistic wire-shaped fixture

    @Test("Real-shaped getTransaction balances: 0.5 SOL send + 5000 lamport fee")
    func realisticHalfSolSend() throws {
        // pre = 10 SOL, post = 10 − 0.5 − 0.000005 = 9.499995 SOL
        let pre: Int64 = 10_000_000_000
        let transfer: Int64 = 500_000_000
        let fee: Int64 = 5_000
        let post = pre - transfer - fee
        let delta = Decimal(post) - Decimal(pre)

        let resolved = try #require(
            SolanaNativeActivityAmount.resolve(
                balanceDeltaLamports: delta,
                feeLamports: fee,
                ownerIsFeePayer: true
            )
        )
        #expect(resolved.direction == .outgoing)
        #expect(resolved.amountLamports == Decimal(transfer))

        let display = try #require(
            EVMHexQuantity.displayAmount(
                rawBalance: NSDecimalNumber(decimal: resolved.amountLamports).stringValue,
                decimals: 9
            )
        )
        // 0.5 SOL — not 0.500005
        #expect(display == "0.5" || display.hasPrefix("0.5"))
        #expect(display != "0.500005")
    }

    @Test("BUG-014 regression: amount + fee must reconstruct balance delta")
    func amountPlusFeeReconstructsDelta() throws {
        let cases: [(delta: Int64, fee: Int64)] = [
            (-1_000_005_000, 5_000),
            (-500_000_000 - 10_000, 10_000),
            (-1 - 5_000, 5_000),
            (-42_000_000_000 - 5_000, 5_000)
        ]
        for item in cases {
            let resolved = try #require(
                SolanaNativeActivityAmount.resolve(
                    balanceDeltaLamports: Decimal(item.delta),
                    feeLamports: item.fee,
                    ownerIsFeePayer: true
                )
            )
            let reconstructed = resolved.amountLamports + Decimal(item.fee)
            #expect(reconstructed == Decimal(-item.delta), "delta=\(item.delta) fee=\(item.fee)")
        }
    }
}
