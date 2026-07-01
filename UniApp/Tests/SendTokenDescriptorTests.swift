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
}
