import Foundation
import Testing
@testable import Aperture

struct CustomTokenSupportTests {
    private let usdtTronContract = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    private let usdtTronHex = "41A614F803B6FD780986A42C78EC9C7F77E6DED13C"

    @Test("Custom token support includes TRON and prefers available custom-token chains")
    func customTokenSupportIncludesTron() {
        #expect(CustomTokenSupport.supports(.ethereum))
        #expect(CustomTokenSupport.supports(.solana))
        #expect(CustomTokenSupport.supports(.tron))
        #expect(!CustomTokenSupport.supports(.bitcoin))
        #expect(CustomTokenSupport.preferredInitialChain(availableChains: [.bitcoin, .tron]) == .tron)
        #expect(CustomTokenSupport.preferredInitialChain(availableChains: [.tron, .ethereum]) == .tron)
        #expect(CustomTokenSupport.preferredInitialChain(availableChains: [.ethereum, .solana]) == .solana)
    }

    @Test("Custom token support orders networks for the add-token picker")
    func customTokenSupportOrdersNetworksForAddPicker() {
        let scoped = CustomTokenSupport.orderedChains(availableChains: [
            .polygon, .bitcoin, .tron, .ethereum, .solana, .base, .avalanche
        ])
        #expect(scoped == [.solana, .tron, .ethereum, .base, .polygon, .avalanche])
        #expect(Array(CustomTokenSupport.chains.prefix(3)) == [.solana, .tron, .ethereum])
    }

    @Test("TRON contract validation accepts Base58Check and 41-prefixed hex")
    func tronContractValidationNormalizesSupportedFormats() {
        #expect(ContractValidator.validateTronContract(usdtTronContract) == .valid(normalized: usdtTronContract))
        #expect(ContractValidator.validateTronContract(usdtTronHex) == .valid(normalized: usdtTronContract))
        #expect(ContractValidator.validateTronContract("0x\(usdtTronHex)") == .valid(normalized: usdtTronContract))
        #expect(TronAddressCodec.hexPayloadWithoutPrefix(usdtTronContract) == "a614f803b6fd780986a42c78ec9c7f77e6ded13c")
    }

    @Test("TRON contract validation rejects checksum and alphabet errors")
    func tronContractValidationRejectsBadInput() {
        #expect(ContractValidator.validateTronContract("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6u") == .invalid(.invalidChecksum))
        #expect(ContractValidator.validateTronContract("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj60") == .invalid(.invalidCharacter))
    }

    @Test("Contract search matches normalized TRON and EVM contracts")
    func contractSearchMatchesNormalizedContracts() {
        #expect(ContractTokenDiscovery.contractMatches(usdtTronContract, chain: .tron, query: usdtTronHex))
        #expect(ContractTokenDiscovery.contractMatches(
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            chain: .ethereum,
            query: "a0b86991c6218b36"
        ))
    }

    @Test("Custom token CSV parses and exports token rows")
    func customTokenCSVParsesAndExports() throws {
        let csv = """
        chain,contract,symbol,name,decimals,metadata_from_chain
        tron,\(usdtTronContract),USDT,Tether USD,6,true
        ethereum,0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,USDC,USD Coin,6,true
        """

        let result = CustomTokenCSV.parse(csv, allowedChains: [.tron, .ethereum])
        #expect(result.errors.isEmpty)
        #expect(result.rows.count == 2)
        #expect(result.rows.first?.contract == usdtTronContract)
        #expect(result.rows.first?.metadataFromChain == true)

        let exported = CustomTokenCSV.export(records: [
            CustomTokenRecord(
                chainRaw: SupportedChain.tron.rawValue,
                contract: usdtTronContract,
                symbol: "USDT",
                name: "Tether USD",
                decimals: 6,
                metadataFromChain: true
            )
        ])
        #expect(exported.contains(CustomTokenCSV.header))
        #expect(exported.contains("tron,\(usdtTronContract),USDT,Tether USD,6,true"))
    }

    @Test("Receive tokens include custom TRON token rows")
    func receiveTokensIncludeCustomTronRows() throws {
        let record = CustomTokenRecord(
            chainRaw: SupportedChain.tron.rawValue,
            contract: usdtTronContract,
            symbol: "SUN",
            name: "Sun Token",
            decimals: 18
        )

        let rows = ReceiveAsset.tokens(
            availableChains: [.tron],
            customTokens: [CustomTokenSnapshot(from: record)],
            catalogAssets: []
        )

        let row = try #require(rows.first)
        guard case let .token(symbol, name, chains) = row else {
            Issue.record("Expected a custom token row")
            return
        }
        #expect(symbol == "SUN")
        #expect(name == "Sun Token")
        #expect(chains == [.tron])
        #expect(row.logoContract(on: .tron, customTokens: [CustomTokenSnapshot(from: record)]) == usdtTronContract)
    }
}
