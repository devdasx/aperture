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
        #expect(CustomTokenSupport.preferredInitialChain(availableChains: [.tron, .ethereum]) == .ethereum)
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
    }
}
