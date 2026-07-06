import Testing
import Foundation
@testable import Aperture

struct SendTokenDescriptorTests {

    @Test("Send tokens preserve per-chain contract and decimals")
    func sendTokensPreserveChainSpecificMetadata() throws {
        let assets = [
            CatalogAsset(
                id: "evm.ethereum.usdt",
                chain: .ethereum,
                symbol: "USDT",
                name: "Tether USD",
                contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
                decimals: 6
            ),
            CatalogAsset(
                id: "trc.usdt",
                chain: .tron,
                symbol: "USDT",
                name: "Tether USD",
                contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
                decimals: 6
            )
        ]

        let rows = SendAsset.tokens(
            availableChains: [.ethereum, .tron],
            catalogAssets: assets
        )
        let row = try #require(rows.first)
        guard case let .token(symbol, _, tokens) = row else {
            Issue.record("Expected a token row")
            return
        }

        #expect(symbol == "USDT")
        let ethereum = try #require(tokens.first { $0.chain == .ethereum })
        let tron = try #require(tokens.first { $0.chain == .tron })
        #expect(ethereum.contract == "0xdAC17F958D2ee523a2206206994597C13D831ec7")
        #expect(ethereum.decimals == 6)
        #expect(tron.contract == "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
        #expect(tron.decimals == 6)
    }

    @Test("Send excludes Polkadot Asset Hub tokens until a signing path exists")
    func polkadotAssetHubTokensAreNotOfferedForSend() {
        let assets = [
            CatalogAsset(
                id: "dot.1337",
                chain: .polkadot,
                symbol: "USDT",
                name: "Tether USD",
                contract: "1337",
                decimals: 6
            )
        ]

        let rows = SendAsset.tokens(
            availableChains: [.polkadot],
            catalogAssets: assets
        )

        #expect(rows.isEmpty)
    }

    @MainActor
    @Test("Compose model keeps selected token contract and decimals")
    func composeModelKeepsSelectedTokenMetadata() {
        let token = SendTokenDescriptor(
            symbol: "USDT",
            name: "Tether USD",
            chain: .tron,
            contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            decimals: 6,
            source: .catalog
        )

        let model = SendComposeModel(
            chain: token.chain,
            tokenSymbol: token.symbol,
            tokenContract: token.contract,
            tokenDecimals: token.decimals,
            fromAddress: "TFromAddress",
            recipients: [SendRecipientEntry(address: "TRecipientAddress", name: nil)],
            currencyCode: "USD"
        )

        #expect(model.assetSymbol == "USDT")
        #expect(model.tokenContract == token.contract)
        #expect(model.effectiveDecimals == 6)
        #expect(model.isToken)
    }

    @MainActor
    @Test("XRP recipient destination tag reaches send draft")
    func xrpRecipientDestinationTagReachesDraft() throws {
        let model = SendComposeModel(
            chain: .ripple,
            tokenSymbol: nil,
            tokenContract: nil,
            tokenDecimals: nil,
            fromAddress: "rFromAddress",
            recipients: [
                SendRecipientEntry(
                    address: "rBuZfn1m4tA6znziHsRp9AyC1M3qg6rgbF",
                    name: nil,
                    memo: .destinationTag(42_424)
                )
            ],
            currencyCode: "USD"
        )

        model.applyFeeQuote(xrpQuote())
        model.setBalances(native: 1_000, token: nil, state: .init())
        model.primaryAmountText = "1"

        #expect(model.canReview)
        let draft = try #require(model.makeDraft())
        #expect(draft.memo == .destinationTag(42_424))
    }

    @MainActor
    @Test("Stellar recipient memo ID reaches send draft")
    func stellarRecipientMemoIDReachesDraft() throws {
        let memoID = UInt64(9_876_543_210)
        let model = SendComposeModel(
            chain: .stellar,
            tokenSymbol: nil,
            tokenContract: nil,
            tokenDecimals: nil,
            fromAddress: "GFROMADDRESS",
            recipients: [
                SendRecipientEntry(
                    address: "GDESTINATIONADDRESS",
                    name: nil,
                    memo: .stellarMemo(.id(memoID))
                )
            ],
            currencyCode: "USD"
        )

        model.applyFeeQuote(stellarQuote())
        model.setBalances(native: 1_000, token: nil, state: .init())
        model.primaryAmountText = "1"

        #expect(model.canReview)
        let draft = try #require(model.makeDraft())
        #expect(draft.memo == .stellarMemo(.id(memoID)))
    }

    @Test("Stellar typed memo validation accepts IDs and rejects malformed hashes")
    func stellarTypedMemoValidation() {
        let validator = SendDraftValidator()
        let fee = stellarFeeChoice()
        let recipient = SendRecipientAmount(address: "GDESTINATIONADDRESS", amount: 1, name: nil)
        let base = SendDraftValidator.Inputs(
            chain: .stellar,
            isToken: false,
            nativeBalance: 1_000,
            tokenBalance: nil,
            recipients: [recipient],
            fee: fee,
            state: .init(),
            memo: .stellarMemo(.id(123)),
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: false,
            recipientRequiresMemo: true,
            recipientIsNew: false
        )

        #expect(!validator.validate(base).contains(.memoRequired))

        let validHash = String(repeating: "a", count: 64)
        let validHashInputs = SendDraftValidator.Inputs(
            chain: base.chain,
            isToken: base.isToken,
            nativeBalance: base.nativeBalance,
            tokenBalance: base.tokenBalance,
            recipients: base.recipients,
            fee: base.fee,
            state: base.state,
            memo: .stellarMemo(.hashHex(validHash)),
            opReturnByteCount: base.opReturnByteCount,
            recipientRequiresDestinationTag: base.recipientRequiresDestinationTag,
            recipientRequiresMemo: base.recipientRequiresMemo,
            recipientIsNew: base.recipientIsNew
        )
        #expect(!validator.validate(validHashInputs).contains(.memoInvalid))

        let invalidHashInputs = SendDraftValidator.Inputs(
            chain: base.chain,
            isToken: base.isToken,
            nativeBalance: base.nativeBalance,
            tokenBalance: base.tokenBalance,
            recipients: base.recipients,
            fee: base.fee,
            state: base.state,
            memo: .stellarMemo(.hashHex("not-a-32-byte-hash")),
            opReturnByteCount: base.opReturnByteCount,
            recipientRequiresDestinationTag: base.recipientRequiresDestinationTag,
            recipientRequiresMemo: base.recipientRequiresMemo,
            recipientIsNew: base.recipientIsNew
        )
        #expect(validator.validate(invalidHashInputs).contains(.memoInvalid))
    }

    @Test("Aptos token sends clamp tiny max gas caps before signing")
    func aptosTokenSendsClampTinyMaxGasCaps() {
        let floor = AptosTransactionSigner.minimumMaxGasAmount

        #expect(ComposeFeeService.aptosMaxGasAmount(isToken: false) == Decimal(floor))
        #expect(ComposeFeeService.aptosMaxGasAmount(isToken: true) == Decimal(floor))
        #expect(AptosTransactionSigner.resolveMaxGas(5_000) == floor)
        #expect(AptosTransactionSigner.resolveMaxGas(nil) == floor)
        #expect(AptosTransactionSigner.resolveMaxGas(200_000) == 200_000)
    }

    @MainActor
    @Test("Fiat entry exposes available token balance in fiat")
    func fiatEntryExposesAvailableTokenBalanceInFiat() {
        let model = SendComposeModel(
            chain: .ton,
            tokenSymbol: "USDT",
            tokenContract: TONJettonRegistry.tokens[0].masterContract,
            tokenDecimals: 6,
            fromAddress: "UQFromAddress",
            recipients: [SendRecipientEntry(address: "UQRecipientAddress", name: nil)],
            currencyCode: "USD"
        )

        model.setBalances(native: 1, token: 15, state: .init())
        model.setPrices(asset: 1, native: 3)
        model.toggleEntryUnit()

        #expect(model.entryUnit == .fiat)
        #expect(model.availableAssetBalance == 15)
        #expect(model.availableAssetBalanceFiat == 15)
    }

    @Test("TON jetton quote matches signer attach reserve")
    func tonJettonQuoteMatchesSignerAttachReserve() async throws {
        let quote = try await ComposeFeeService().tonQuote(.init(
            chain: .ton,
            fromAddress: "UQFromAddress",
            toAddress: "UQRecipientAddress",
            tokenContract: TONJettonRegistry.tokens[0].masterContract,
            tokenDecimals: 6
        ))
        let normal = try #require(quote.normal)

        #expect(normal.estimatedTotalNative == TONTransactionSigner.jettonGasAttachTON)
        #expect(normal.worstCaseTotalNative == TONTransactionSigner.jettonGasAttachTON)
    }

    private func xrpQuote() -> FeeQuote {
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .xrpFixed,
            estimatedTotalNative: 0.00001,
            worstCaseTotalNative: 0.00001
        )
        fee.xrpDrops = 10
        return FeeQuote(
            chain: .ripple,
            feeModel: .xrpFixed,
            tiers: [.normal: fee],
            isCustomAllowed: true,
            hasSpeedTiers: true,
            note: nil
        )
    }

    private func stellarQuote() -> FeeQuote {
        FeeQuote(
            chain: .stellar,
            feeModel: .stellarPerOp,
            tiers: [.normal: stellarFeeChoice()],
            isCustomAllowed: true,
            hasSpeedTiers: true,
            note: nil
        )
    }

    private func stellarFeeChoice() -> FeeChoice {
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .stellarPerOp,
            estimatedTotalNative: 0.00001,
            worstCaseTotalNative: 0.00001
        )
        fee.stellarPerOpStroops = 100
        fee.stellarOpCount = 1
        return fee
    }
}
