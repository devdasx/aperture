import Foundation
import Testing
import WalletCore
@testable import Aperture

/// BUG-002: all EVM chains share the Ethereum derivation path / coin type
/// (MetaMask parity). Private-key and mnemonic paths must agree.
struct EVMUnifiedDerivationTests {

    @Test("ChainCoinType maps every EVM chain to Ethereum coin id 60")
    func allEVMChainsUseEthereumCoinType() {
        let evm = SupportedChain.allCases.filter { $0.family == .evm }
        #expect(!evm.isEmpty)
        for chain in evm {
            let coin = ChainCoinType.coinType(for: chain)
            #expect(coin != nil, "missing coin for \(chain.rawValue)")
            #expect(coin?.rawValue == ChainCoinType.evmCoinId, "\(chain.rawValue) must be coin 60")
        }
        #expect(ChainCoinType.evm.rawValue == 60)
    }

    @Test("Mnemonic derivation stamps the same address on every EVM chain")
    func mnemonicSameAddressAcrossEVM() async {
        // Fixed BIP-39 test vector (well-known; not a real user wallet).
        let words = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            .split(separator: " ")
            .map(String.init)
        let service = WalletCoreKeyImportService()
        let addresses = await service.deriveAddresses(mnemonic: words, passphrase: "")
        let evmAddresses = SupportedChain.allCases
            .filter { $0.family == .evm }
            .compactMap { addresses[$0] }
        #expect(evmAddresses.count == SupportedChain.allCases.filter { $0.family == .evm }.count)
        let unique = Set(evmAddresses.map { $0.lowercased() })
        #expect(unique.count == 1, "EVM addresses must be identical, got \(unique)")

        // Cross-check WalletCore Ethereum default path directly.
        let wallet = HDWallet(mnemonic: words.joined(separator: " "), passphrase: "")
        let eth = wallet?.getAddressForCoin(coin: .ethereum)
        #expect(eth != nil)
        #expect(unique.first == eth?.lowercased())
    }

    @Test("Non-EVM coin types stay distinct from Ethereum")
    func nonEVMUnchanged() {
        #expect(ChainCoinType.coinType(for: .bitcoin)?.rawValue == 0)
        #expect(ChainCoinType.coinType(for: .solana)?.rawValue == 501)
        #expect(ChainCoinType.coinType(for: .tron)?.rawValue == 195)
    }
}
