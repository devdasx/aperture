import Foundation
import Testing
@testable import Aperture

/// P1-003: NEAR FT always prepends `storage_deposit` (0.00125 NEAR).
/// Fee/Max must include that deposit (and full attached gas) so native
/// balance checks and the fee sheet never understate cost.
@Suite("NEAR FT storage_deposit fee (P1-003)")
struct NearFTStorageDepositFeeTests {

    /// Network gas_price floor used by the fee service when RPC is quiet.
    private let gasPriceYocto = Decimal(100_000_000)

    @Test("signer constants: 0.00125 NEAR deposit and 40 Tgas attach")
    func signerConstants() {
        #expect(NearTransactionSigner.storageDepositYocto == "1250000000000000000000")
        #expect(NearTransactionSigner.storageDepositNEAR == Decimal(string: "0.00125"))
        #expect(NearTransactionSigner.ftAttachedGasUnits == 40_000_000_000_000)
    }

    @Test("native NEAR fee is gas-only (no storage deposit)")
    func nativeFeeIsGasOnly() {
        let resolved = ComposeFeeService.nearFeeTotals(
            isToken: false,
            gasPriceYocto: gasPriceYocto
        )
        #expect(resolved.gasUnits == Decimal(446_365_125_000))
        let expectedYocto = Decimal(446_365_125_000) * gasPriceYocto
        let expected = ComposeDecimal.toDisplay(
            expectedYocto,
            decimals: SupportedChain.near.nativeDecimals
        )
        #expect(resolved.totalNative == expected)
        #expect(resolved.totalNative < NearTransactionSigner.storageDepositNEAR)
    }

    @Test("FT fee includes gas + 0.00125 NEAR storage_deposit")
    func ftFeeIncludesStorageDeposit() {
        let resolved = ComposeFeeService.nearFeeTotals(
            isToken: true,
            gasPriceYocto: gasPriceYocto
        )
        #expect(resolved.gasUnits == Decimal(NearTransactionSigner.ftAttachedGasUnits))

        let gasYocto = Decimal(NearTransactionSigner.ftAttachedGasUnits) * gasPriceYocto
        let depositYocto = ComposeDecimal.fromIntegerString(
            NearTransactionSigner.storageDepositYocto
        )!
        let expected = ComposeDecimal.toDisplay(
            gasYocto + depositYocto,
            decimals: SupportedChain.near.nativeDecimals
        )
        #expect(resolved.totalNative == expected)

        // Deposit alone is the bulk of a typical FT fee at floor gas price.
        #expect(resolved.totalNative >= NearTransactionSigner.storageDepositNEAR)

        // Must exceed gas-only by exactly the deposit (display precision).
        let gasOnly = ComposeDecimal.toDisplay(
            gasYocto,
            decimals: SupportedChain.near.nativeDecimals
        )
        #expect(resolved.totalNative - gasOnly == NearTransactionSigner.storageDepositNEAR)
    }

    @Test("FT fee is strictly larger than pre-P1-003 30-Tgas-only quote")
    func ftFeeExceedsLegacy30TgasOnly() {
        let legacyGasUnits = Decimal(30_000_000_000_000)
        let legacyGasOnly = ComposeDecimal.toDisplay(
            legacyGasUnits * gasPriceYocto,
            decimals: SupportedChain.near.nativeDecimals
        )
        let fixed = ComposeFeeService.nearFeeTotals(
            isToken: true,
            gasPriceYocto: gasPriceYocto
        )
        // Legacy understated by ~0.00125 NEAR (plus 10 Tgas).
        #expect(fixed.totalNative > legacyGasOnly)
        #expect(
            fixed.totalNative - legacyGasOnly
                >= NearTransactionSigner.storageDepositNEAR
        )
    }

    @Test("validator rejects FT send when native covers gas but not storage deposit")
    func validatorRequiresDepositInNative() {
        let fixed = ComposeFeeService.nearFeeTotals(
            isToken: true,
            gasPriceYocto: gasPriceYocto
        )
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .nearGas,
            estimatedTotalNative: fixed.totalNative,
            worstCaseTotalNative: fixed.totalNative
        )
        fee.nearGasPriceYocto = gasPriceYocto
        fee.nearGasUnits = fixed.gasUnits

        // Gas-only native balance: enough for prepaid gas, short by the deposit.
        let gasOnlyNative = ComposeDecimal.toDisplay(
            Decimal(NearTransactionSigner.ftAttachedGasUnits) * gasPriceYocto,
            decimals: SupportedChain.near.nativeDecimals
        )
        #expect(gasOnlyNative < fee.worstCaseTotalNative)

        let errors = SendDraftValidator().validate(.init(
            chain: .near,
            isToken: true,
            nativeBalance: gasOnlyNative,
            tokenBalance: Decimal(100),
            recipients: [SendRecipientAmount(address: "alice.near", amount: 1, name: nil)],
            fee: fee,
            state: .init(balance: gasOnlyNative),
            memo: .none,
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: false,
            recipientRequiresMemo: false,
            recipientIsNew: false
        ))
        #expect(errors.contains {
            if case .insufficientNativeForFee(let needed, _) = $0 {
                return needed == fee.worstCaseTotalNative
            }
            return false
        })

        // With deposit covered, validation passes on funds.
        let funded = fee.worstCaseTotalNative
        let ok = SendDraftValidator().validate(.init(
            chain: .near,
            isToken: true,
            nativeBalance: funded,
            tokenBalance: Decimal(100),
            recipients: [SendRecipientAmount(address: "alice.near", amount: 1, name: nil)],
            fee: fee,
            state: .init(balance: funded),
            memo: .none,
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: false,
            recipientRequiresMemo: false,
            recipientIsNew: false
        ))
        #expect(!ok.contains {
            if case .insufficientNativeForFee = $0 { return true }
            return false
        })
    }

    @Test("token MAX stays full token balance; native fee carries the deposit")
    func tokenMaxUnchangedNativeFeeHoldsDeposit() {
        let feeTotals = ComposeFeeService.nearFeeTotals(
            isToken: true,
            gasPriceYocto: gasPriceYocto
        )
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .nearGas,
            estimatedTotalNative: feeTotals.totalNative,
            worstCaseTotalNative: feeTotals.totalNative
        )
        fee.nearGasUnits = feeTotals.gasUnits

        let max = SendAmountMath.maxSend(
            chain: .near,
            nativeBalance: 1,
            tokenBalance: 50,
            isToken: true,
            fee: fee,
            state: .init(balance: 1),
            recipientNeedsActivation: false
        )
        #expect(max == 50)
        // The honesty fix lives on the fee, not the token MAX.
        #expect(fee.worstCaseTotalNative >= NearTransactionSigner.storageDepositNEAR)
    }
}
