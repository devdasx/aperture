import Testing
@testable import Aperture

/// Pure Swift tests for the current Ethereum balance path.
///
/// The app no longer batches token balances through Multicall3. It now reads
/// each supported Ethereum ERC-20 with `balanceOf(address)` through PublicNode,
/// so these tests lock down the small ABI surface the scanner depends on.
struct EVMBalanceOfCodecTests {

    @Test("ERC-20 balanceOf calldata is canonical")
    func balanceOfCalldata() throws {
        let holder = "0x52908400098527886E0F7030069857D2E4169EE7"
        let calldata = EVMTokenRegistry.balanceOfCallData(holder: holder)

        #expect(calldata.count == 74)
        #expect(calldata.hasPrefix("0x70a08231"))
        #expect(calldata == "0x70a08231" + String(repeating: "0", count: 24) + "52908400098527886e0f7030069857d2e4169ee7")
    }

    @Test("ERC-20 balanceOf calldata is case-insensitive for the holder")
    func balanceOfCalldataCaseInsensitive() throws {
        let mixed = EVMTokenRegistry.balanceOfCallData(holder: "0x52908400098527886E0F7030069857D2E4169EE7")
        let lower = EVMTokenRegistry.balanceOfCallData(holder: "0x52908400098527886e0f7030069857d2e4169ee7")

        #expect(mixed == lower)
    }

    @Test("Hex quantity decoder handles wei-sized balances exactly")
    func hexQuantityDecoder() throws {
        let oneEthWei = try EVMHexQuantity.decimalString(from: "0xde0b6b3a7640000")
        #expect(oneEthWei == "1000000000000000000")
        #expect(EVMHexQuantity.decimalAmount(rawBalance: oneEthWei, decimals: 18) == 1)
    }

    @Test("Hex quantity decoder accepts padded eth_call uint256 return data")
    func paddedBalanceOfReturnData() throws {
        let paddedUSDC = "0x" + String(repeating: "0", count: 58) + "0f4240"
        let raw = try EVMHexQuantity.decimalString(from: paddedUSDC)

        #expect(raw == "1000000")
        #expect(EVMHexQuantity.decimalAmount(rawBalance: raw, decimals: 6) == 1)
    }

    @Test("Hex quantity decoder rejects invalid hex")
    func hexQuantityRejectsInvalidInput() throws {
        var threw = false
        do {
            _ = try EVMHexQuantity.decimalString(from: "0xnot-hex")
        } catch {
            threw = true
        }

        #expect(threw)
    }

    @Test("Positive decimal detection treats exact zero as unused")
    func positiveDecimalDetection() throws {
        #expect(!EVMHexQuantity.isPositiveDecimalString("0"))
        #expect(!EVMHexQuantity.isPositiveDecimalString("000000"))
        #expect(EVMHexQuantity.isPositiveDecimalString("1"))
        #expect(EVMHexQuantity.isPositiveDecimalString("1000000000000000000"))
    }
}
