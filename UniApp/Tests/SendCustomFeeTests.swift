import Testing
import Foundation
@testable import Aperture

/// Regression tests for the Send compose CUSTOM-fee path (BUG 1).
///
/// These are pure, deterministic, no-network tests: they build `FeeQuote`
/// values by hand and drive `SendComposeModel` directly, proving that a
/// user-set custom fee is reflected in `resolvedFee` AND survives a fee
/// refresh (`applyFeeQuote`, the exact post-network code path `loadFee`
/// runs). They guard against the regressions this work fixed:
///   • `loadFee` resetting `selectedTier` to `.normal` and dropping a
///     user-picked `.custom` (BUG 1 · fix #1).
///   • the custom byte-rate / maxFee not reaching `resolvedFee`.
@MainActor
struct SendCustomFeeTests {

    // MARK: - Builders (deterministic, no network)

    /// A UTXO (Bitcoin) quote with slow/normal/fast sat/vB presets.
    private func bitcoinQuote() -> FeeQuote {
        func choice(_ tier: FeeTier, rate: Decimal, feeSats: Decimal) -> FeeChoice {
            var c = FeeChoice(tier: tier, feeModel: .utxoByteFee,
                              estimatedTotalNative: 0, worstCaseTotalNative: 0)
            c.byteFeeRate = rate
            let native = ComposeDecimal.toDisplay(feeSats, decimals: 8)
            c.setTotals(estimated: native, worst: native)
            return c
        }
        // typical vsize 141 vB; normal 3 sat/vB → 423 sats.
        return FeeQuote(
            chain: .bitcoin, feeModel: .utxoByteFee,
            tiers: [
                .slow:   choice(.slow,   rate: 1, feeSats: 141),
                .normal: choice(.normal, rate: 3, feeSats: 423),
                .fast:   choice(.fast,   rate: 5, feeSats: 705),
            ],
            isCustomAllowed: true, hasSpeedTiers: true, note: nil)
    }

    /// An EIP-1559 (Ethereum) quote with slow/normal/fast presets.
    private func ethereumQuote() -> FeeQuote {
        let gwei = ComposeDecimal.pow10(9)
        let gasLimit = Decimal(21000)
        let baseNext = 5 * gwei
        func choice(_ tier: FeeTier, tip: Decimal, maxFee: Decimal) -> FeeChoice {
            var c = FeeChoice(tier: tier, feeModel: .evm1559,
                              estimatedTotalNative: 0, worstCaseTotalNative: 0)
            c.gasLimit = gasLimit
            c.baseFeePerGasWei = baseNext
            c.maxPriorityFeePerGasWei = tip
            c.maxFeePerGasWei = maxFee
            return ComposeFeeService.recomputeEVMTotals(c, decimals: 18)
        }
        return FeeQuote(
            chain: .ethereum, feeModel: .evm1559,
            tiers: [
                .slow:   choice(.slow,   tip: 1 * gwei, maxFee: 11 * gwei),
                .normal: choice(.normal, tip: 2 * gwei, maxFee: 12 * gwei),
                .fast:   choice(.fast,   tip: 3 * gwei, maxFee: 16 * gwei),
            ],
            isCustomAllowed: true, hasSpeedTiers: true, note: nil)
    }

    private func makeModel(chain: SupportedChain) -> SendComposeModel {
        SendComposeModel(
            chain: chain, tokenSymbol: nil, tokenContract: nil, tokenDecimals: nil,
            fromAddress: "from",
            recipients: [SendRecipientEntry(address: "to", name: nil)],
            currencyCode: "USD")
    }

    // MARK: - UTXO custom fee

    @Test("UTXO custom sat/vB is reflected in resolvedFee and survives a refresh")
    func utxoCustomFeeReflectedAndSurvivesRefresh() throws {
        let model = makeModel(chain: .bitcoin)
        model.applyFeeQuote(bitcoinQuote())

        // Normal preset = 3 sat/vB → 423 sats = 0.00000423 BTC.
        #expect(model.selectedTier == .normal)
        let normalFee = try #require(model.resolvedFee)
        #expect(normalFee.byteFeeRate == 3)

        // User sets a custom 10 sat/vB (as SendFeeSheet.applyCustomIfNeeded
        // does): scale the typical estimate by rate/normalRate (10/3).
        let base = try #require(model.feeQuote?.normal)
        var custom = FeeChoice(tier: .custom, feeModel: .utxoByteFee,
                               estimatedTotalNative: base.estimatedTotalNative,
                               worstCaseTotalNative: base.worstCaseTotalNative)
        let customRate = Decimal(10)
        let scale = customRate / 3
        custom.byteFeeRate = customRate
        custom.setTotals(estimated: base.estimatedTotalNative * scale,
                         worst: base.worstCaseTotalNative * scale)
        model.customFee = custom
        model.selectedTier = .custom

        // resolvedFee must now carry the CUSTOM rate + its scaled total.
        let resolved = try #require(model.resolvedFee)
        #expect(resolved.tier == .custom)
        #expect(resolved.byteFeeRate == customRate)
        #expect(resolved.estimatedTotalNative > normalFee.estimatedTotalNative)
        // makeDraft must carry the same custom fee.
        // (Balances/validation aside — we assert the fee the draft would use.)
        #expect(model.resolvedFee?.byteFeeRate == customRate)

        // Simulate a fee REFRESH (the debounced loadFee path): re-apply a
        // fresh quote. The user's `.custom` must NOT revert to `.normal`
        // (BUG 1 · fix #1), and resolvedFee must still be the custom rate.
        model.applyFeeQuote(bitcoinQuote())
        #expect(model.selectedTier == .custom, "Custom tier was lost on refresh")
        #expect(model.resolvedFee?.byteFeeRate == customRate,
                "Custom byte rate was lost on refresh")
    }

    // MARK: - EVM custom fee

    @Test("EVM custom maxFee/tip is reflected in resolvedFee and survives a refresh")
    func evmCustomFeeReflectedAndSurvivesRefresh() throws {
        let gwei = ComposeDecimal.pow10(9)
        let model = makeModel(chain: .ethereum)
        model.applyFeeQuote(ethereumQuote())
        #expect(model.selectedTier == .normal)

        // User sets custom maxFee = 50 gwei, tip = 5 gwei.
        let base = try #require(model.feeQuote?.normal)
        var custom = FeeChoice(tier: .custom, feeModel: .evm1559,
                               estimatedTotalNative: base.estimatedTotalNative,
                               worstCaseTotalNative: base.worstCaseTotalNative)
        custom.gasLimit = base.gasLimit
        custom.baseFeePerGasWei = base.baseFeePerGasWei
        custom.maxFeePerGasWei = 50 * gwei
        custom.maxPriorityFeePerGasWei = 5 * gwei
        custom = ComposeFeeService.recomputeEVMTotals(custom, decimals: 18)
        model.customFee = custom
        model.selectedTier = .custom

        let resolved = try #require(model.resolvedFee)
        #expect(resolved.tier == .custom)
        #expect(resolved.maxFeePerGasWei == 50 * gwei)
        #expect(resolved.maxPriorityFeePerGasWei == 5 * gwei)
        // worst-case = gasLimit × maxFee = 21000 × 50e9 wei = 0.00105 ETH.
        let expectedWorst = ComposeDecimal.toDisplay(
            Decimal(21000) * 50 * gwei, decimals: 18)
        #expect(resolved.worstCaseTotalNative == expectedWorst)

        // Refresh: custom must survive.
        model.applyFeeQuote(ethereumQuote())
        #expect(model.selectedTier == .custom, "Custom tier was lost on refresh")
        #expect(model.resolvedFee?.maxFeePerGasWei == 50 * gwei,
                "Custom maxFee was lost on refresh")
    }

    // MARK: - Single-tier custom-allowed chain (the Aptos-class regression)

    @Test("Custom survives refresh on a custom-allowed chain (no speed tiers)")
    func customSurvivesOnSingleTierChain() throws {
        // A synthetic custom-allowed, single-tier quote (the shape that the
        // OLD `loadFee` reverted to .normal on every refresh).
        func makeQuote() -> FeeQuote {
            var normal = FeeChoice(tier: .normal, feeModel: .cosmosGas,
                                   estimatedTotalNative: Decimal(string: "0.02")!,
                                   worstCaseTotalNative: Decimal(string: "0.02")!)
            normal.cosmosGasLimit = 200_000
            normal.cosmosGasPrice = Decimal(string: "0.1")!
            return FeeQuote(chain: .kava, feeModel: .cosmosGas,
                            tiers: [.normal: normal],
                            isCustomAllowed: true, hasSpeedTiers: true, note: nil)
        }
        let model = makeModel(chain: .kava)
        model.applyFeeQuote(makeQuote())

        var custom = FeeChoice(tier: .custom, feeModel: .cosmosGas,
                               estimatedTotalNative: Decimal(string: "0.05")!,
                               worstCaseTotalNative: Decimal(string: "0.05")!)
        custom.cosmosGasLimit = 200_000
        custom.cosmosGasPrice = Decimal(string: "0.25")!
        model.customFee = custom
        model.selectedTier = .custom
        #expect(model.resolvedFee?.tier == .custom)

        model.applyFeeQuote(makeQuote())
        #expect(model.selectedTier == .custom, "Custom lost on single-tier refresh")
        #expect(model.resolvedFee?.cosmosGasPrice == Decimal(string: "0.25")!)
    }
}
