import Foundation
import Testing
@testable import Aperture

/// P1-004 / P1-005: multi-recipient **signing** was already correct (BUG-001);
/// compose fee quotes were still single-recipient and under-reserved native.
@Suite("Multi-recipient fee scale (P1-004 TON / P1-005 Solana)")
struct MultiRecipientFeeScaleTests {

    // MARK: - P1-004 TON jetton

    @Test("TON jetton fee is 0.05 per recipient (matches signer attach)")
    func tonJettonScalesWithRecipients() {
        #expect(
            ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 1)
                == TONTransactionSigner.jettonGasAttachTON
        )
        #expect(
            ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 2)
                == TONTransactionSigner.jettonGasAttachTON * 2
        )
        #expect(
            ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 4)
                == TONTransactionSigner.jettonGasAttachTON * 4
        )
        // Cap at wallet v4r2 max (4 messages).
        #expect(
            ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 10)
                == TONTransactionSigner.jettonGasAttachTON * 4
        )
        #expect(
            ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 0)
                == TONTransactionSigner.jettonGasAttachTON
        )
    }

    @Test("TON jetton multi: 4 recipients reserve 0.20 TON not 0.05")
    func tonJettonFourRecipientsNotOneX() {
        let one = ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 1)
        let four = ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 4)
        #expect(one == Decimal(string: "0.05"))
        #expect(four == Decimal(string: "0.20"))
        #expect(four == one * 4)
    }

    @Test("TON native multi also scales practical estimate per message")
    func tonNativeScales() {
        let one = ComposeFeeService.tonFeeNative(isToken: false, recipientCount: 1)
        let three = ComposeFeeService.tonFeeNative(isToken: false, recipientCount: 3)
        #expect(one == Decimal(string: "0.0055"))
        #expect(three == Decimal(string: "0.0165"))
    }

    @Test("TON jetton quote (live path) multiplies attach by recipientCount")
    func tonJettonQuoteMulti() async throws {
        let single = try await ComposeFeeService().tonQuote(.init(
            chain: .ton,
            fromAddress: "UQFromAddress",
            toAddress: "UQRecipient1",
            tokenContract: TONJettonRegistry.tokens[0].masterContract,
            tokenDecimals: 6,
            recipientCount: 1
        ))
        let multi = try await ComposeFeeService().tonQuote(.init(
            chain: .ton,
            fromAddress: "UQFromAddress",
            toAddress: "UQRecipient1",
            tokenContract: TONJettonRegistry.tokens[0].masterContract,
            tokenDecimals: 6,
            recipientCount: 4
        ))
        let s = try #require(single.normal)
        let m = try #require(multi.normal)
        #expect(s.estimatedTotalNative == TONTransactionSigner.jettonGasAttachTON)
        #expect(m.estimatedTotalNative == TONTransactionSigner.jettonGasAttachTON * 4)
        #expect(m.worstCaseTotalNative == m.estimatedTotalNative)
    }

    @Test("validator: multi jetton fee rejects native that only covers 1× attach")
    func tonValidatorRequiresFullAttach() {
        let feeNative = ComposeFeeService.tonFeeNative(isToken: true, recipientCount: 4)
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .tonFixed,
            estimatedTotalNative: feeNative,
            worstCaseTotalNative: feeNative
        )
        // Only enough for one jetton message attach.
        let onlyOne = TONTransactionSigner.jettonGasAttachTON
        #expect(onlyOne < fee.worstCaseTotalNative)

        let errors = SendDraftValidator().validate(.init(
            chain: .ton,
            isToken: true,
            nativeBalance: onlyOne,
            tokenBalance: 1_000,
            recipients: [
                SendRecipientAmount(address: "UQ1", amount: 1, name: nil),
                SendRecipientAmount(address: "UQ2", amount: 1, name: nil),
                SendRecipientAmount(address: "UQ3", amount: 1, name: nil),
                SendRecipientAmount(address: "UQ4", amount: 1, name: nil),
            ],
            fee: fee,
            state: .init(balance: onlyOne),
            memo: .none,
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: false,
            recipientRequiresMemo: false,
            recipientIsNew: false
        ))
        #expect(errors.contains {
            if case .insufficientNativeForFee(let needed, _) = $0 {
                return needed == feeNative
            }
            return false
        })
    }

    // MARK: - P1-005 Solana CU

    @Test("Solana CU limit scales with recipientCount (signer-aligned)")
    func solanaCUScales() {
        #expect(ComposeFeeService.solanaComputeUnitLimit(isToken: false, recipientCount: 1) == Decimal(450))
        #expect(ComposeFeeService.solanaComputeUnitLimit(isToken: false, recipientCount: 3) == Decimal(1_350))
        #expect(ComposeFeeService.solanaComputeUnitLimit(isToken: true, recipientCount: 1) == Decimal(50_000))
        #expect(ComposeFeeService.solanaComputeUnitLimit(isToken: true, recipientCount: 4) == Decimal(200_000))
        // Cap 15 (same as signer).
        #expect(ComposeFeeService.solanaComputeUnitLimit(isToken: true, recipientCount: 20) == Decimal(750_000))
        #expect(ComposeFeeService.solanaComputeUnitLimit(isToken: false, recipientCount: 0) == Decimal(450))
    }

    @Test("Solana priority fee scales with CU limit at fixed price")
    func solanaPriorityScalesWithCU() {
        let price: Decimal = 10_000 // microlamports per CU
        let baseLamports: Decimal = 5_000

        func total(forRecipients n: Int) -> Decimal {
            let limit = ComposeFeeService.solanaComputeUnitLimit(isToken: true, recipientCount: n)
            var c = FeeChoice(
                tier: .normal,
                feeModel: .solana,
                estimatedTotalNative: 0,
                worstCaseTotalNative: 0
            )
            c.computeUnitPrice = price
            c.computeUnitLimit = limit
            c.solanaBaseFeeLamports = baseLamports
            return ComposeFeeService.recomputeSolanaTotals(
                c,
                decimals: SupportedChain.solana.nativeDecimals
            ).worstCaseTotalNative
        }

        let one = total(forRecipients: 1)
        let four = total(forRecipients: 4)
        // Priority component is 4×; base is fixed → multi > single and
        // the delta equals 3× the single priority portion.
        #expect(four > one)

        let priority1 = ComposeDecimal.ceilMulDiv(price, 50_000, dividedBy: 1_000_000)
        let priority4 = ComposeDecimal.ceilMulDiv(price, 200_000, dividedBy: 1_000_000)
        #expect(priority4 == priority1 * 4)

        let expectedOne = ComposeDecimal.toDisplay(
            baseLamports + priority1,
            decimals: SupportedChain.solana.nativeDecimals
        )
        let expectedFour = ComposeDecimal.toDisplay(
            baseLamports + priority4,
            decimals: SupportedChain.solana.nativeDecimals
        )
        #expect(one == expectedOne)
        #expect(four == expectedFour)
    }

    @Test("Solana multi fee reserve: 4× CU implies many× priority vs 1× quote")
    func solanaLegacyUnderReserveRegression() {
        let price: Decimal = 5_000
        let limit1 = ComposeFeeService.solanaComputeUnitLimit(isToken: true, recipientCount: 1)
        let limit4 = ComposeFeeService.solanaComputeUnitLimit(isToken: true, recipientCount: 4)
        #expect(limit4 == limit1 * 4)

        let p1 = ComposeDecimal.ceilMulDiv(price, limit1, dividedBy: 1_000_000)
        let p4 = ComposeDecimal.ceilMulDiv(price, limit4, dividedBy: 1_000_000)
        // Pre-fix: compose used limit1 for multi; signer/on-chain used limit4.
        // Delta is exactly the under-reserve this bug caused.
        #expect(p4 - p1 == p1 * 3)
    }

    @Test("validator: multi Solana fee rejects native that only covers 1× CU priority")
    func solanaValidatorRequiresScaledFee() {
        let price: Decimal = 10_000
        let limit4 = ComposeFeeService.solanaComputeUnitLimit(isToken: true, recipientCount: 4)
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .solana,
            estimatedTotalNative: 0,
            worstCaseTotalNative: 0
        )
        fee.computeUnitPrice = price
        fee.computeUnitLimit = limit4
        fee.solanaBaseFeeLamports = 5_000
        fee = ComposeFeeService.recomputeSolanaTotals(
            fee,
            decimals: SupportedChain.solana.nativeDecimals
        )

        // Native enough for 1-recipient priority + base only.
        var oneX = FeeChoice(
            tier: .normal,
            feeModel: .solana,
            estimatedTotalNative: 0,
            worstCaseTotalNative: 0
        )
        oneX.computeUnitPrice = price
        oneX.computeUnitLimit = ComposeFeeService.solanaComputeUnitLimit(
            isToken: true,
            recipientCount: 1
        )
        oneX.solanaBaseFeeLamports = 5_000
        oneX = ComposeFeeService.recomputeSolanaTotals(
            oneX,
            decimals: SupportedChain.solana.nativeDecimals
        )

        #expect(oneX.worstCaseTotalNative < fee.worstCaseTotalNative)

        let errors = SendDraftValidator().validate(.init(
            chain: .solana,
            isToken: true,
            nativeBalance: oneX.worstCaseTotalNative,
            tokenBalance: 100,
            recipients: [
                SendRecipientAmount(address: "So1", amount: 1, name: nil),
                SendRecipientAmount(address: "So2", amount: 1, name: nil),
                SendRecipientAmount(address: "So3", amount: 1, name: nil),
                SendRecipientAmount(address: "So4", amount: 1, name: nil),
            ],
            fee: fee,
            state: .init(balance: oneX.worstCaseTotalNative),
            memo: .none,
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: false,
            recipientRequiresMemo: false,
            recipientIsNew: false
        ))
        #expect(errors.contains {
            if case .insufficientNativeForFee = $0 { return true }
            return false
        })
    }
}
