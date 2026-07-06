import Testing
import Foundation
import WalletCore
@testable import Aperture

/// Tests for real watch-only extended-public-key (xpub / ypub / zpub)
/// derivation in `WalletCoreKeyImportService` — the closure of the T-024
/// stub (`deriveAddresses(fromExtendedKey:)` used to return `[STUB …]`
/// placeholder addresses; it now derives the real receive addresses via
/// WalletCore's `HDWallet.getPublicKeyFromExtended` + `DerivationPath`).
///
/// **Vectors are authoritative.** The xpub / zpub strings and their expected
/// addresses are the exact published test vectors from WalletCore's own
/// `HDWalletTests.swift` (`testDeriveFromXPub` / `testDeriveFromZPub`), so a
/// green test proves Aperture derives byte-for-byte what Trust Wallet,
/// Electrum, and Bitcoin Core derive for the same key. The vectors target
/// receive indices 2 (xpub) and 4 (zpub), both inside the first-5 window the
/// service returns.
@Suite("Extended public key (xpub/ypub/zpub) watch-only derivation")
struct ExtendedKeyImportTests {

    private let service = WalletCoreKeyImportService()

    @Test("Mnemonic derives Bitcoin and Ethereum BIP-44 account xpubs")
    func mnemonicDerivesBitcoinAndEthereumXPubs() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let keys = try MnemonicExtendedPublicKeyDeriver.derive(fromMnemonic: mnemonic)

        #expect(keys.bitcoin.chain == .bitcoin)
        #expect(keys.bitcoin.derivationPath == "m/44'/0'/0'")
        #expect(keys.bitcoin.xpub == "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj")

        #expect(keys.ethereum.chain == .ethereum)
        #expect(keys.ethereum.derivationPath == "m/44'/60'/0'")
        #expect(keys.ethereum.xpub.hasPrefix("xpub"))
        #expect(keys.ethereum.xpub != keys.bitcoin.xpub)

        let bitcoinPublicKey = try #require(HDWallet.getPublicKeyFromExtended(
            extended: keys.bitcoin.xpub,
            coin: .bitcoin,
            derivationPath: "m/44'/0'/0'/0/0"
        ))
        let bitcoinAddress = try #require(BitcoinAddress(
            publicKey: bitcoinPublicKey,
            prefix: CoinType.bitcoin.p2pkhPrefix
        )?.description)
        #expect(bitcoinAddress == "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA")

        let ethereumPublicKey = try #require(HDWallet.getPublicKeyFromExtended(
            extended: keys.ethereum.xpub,
            coin: .ethereum,
            derivationPath: "m/44'/60'/0'/0/0"
        ))
        let ethereumAddress = AnyAddress(
            publicKey: ethereumPublicKey,
            coin: .ethereum
        ).description
        #expect(ethereumAddress == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
    }

    /// `xpub` → BIP-44 legacy P2PKH ("1…") receive addresses.
    @Test("xpub derives real BIP-44 P2PKH addresses (no stub placeholder)")
    func xpubLegacyAddresses() async throws {
        let xpub = "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj"
        let addresses = try await service.deriveAddresses(fromExtendedKey: xpub, on: .bitcoin)

        #expect(addresses.count == 5)
        // WalletCore canonical vector for external index 2.
        #expect(addresses[2] == "1MNF5RSaabFwcbtJirJwKnDytsXXEsVsNb")
        // Every address is a real legacy P2PKH, never a "[STUB …]" placeholder.
        #expect(addresses.allSatisfy { $0.hasPrefix("1") })
        #expect(addresses.allSatisfy { !$0.hasPrefix(StubKeyImportService.stubAddressPrefix) })
        // Real addresses are unique per index.
        #expect(Set(addresses).count == addresses.count)
    }

    /// `zpub` → BIP-84 native SegWit ("bc1…") receive addresses.
    @Test("zpub derives real BIP-84 native SegWit addresses")
    func zpubSegwitAddresses() async throws {
        let zpub = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
        let addresses = try await service.deriveAddresses(fromExtendedKey: zpub, on: .bitcoin)

        #expect(addresses.count == 5)
        // WalletCore canonical vector for external index 4.
        #expect(addresses[4] == "bc1qm97vqzgj934vnaq9s53ynkyf9dgr05rargr04n")
        #expect(addresses.allSatisfy { $0.hasPrefix("bc1") })
        #expect(Set(addresses).count == addresses.count)
    }

    @Test("Bitcoin recipient validation accepts every standard output address family")
    func bitcoinRecipientValidationAcceptsStandardOutputFamilies() {
        let addresses = [
            "1AC4gh14wwZPULVPCdxUkgqbtPvC92PQPN", // BIP44 / P2PKH
            "396BPtVBUXqigCS2RCbUs4LFuA4QWW9djN", // BIP49 / P2SH
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", // BIP84 / P2WPKH
            "bc1pnncpg8s7gu7t6xmmzxqarcj8ydthmaz8gr4m76eephjfprs53maswgel0w", // BIP86 / P2TR
            "bc1qcuqamesrt803xld4l2j2vxx8rxmrx7aq82mkw7xwxh643wzqjlnqutkcv2" // BIP48-style P2WSH output
        ]

        for address in addresses {
            #expect(service.validateAddress(address, on: .bitcoin))
            #expect(!BitcoinScript.lockScriptForAddress(address: address, coin: .bitcoin).data.isEmpty)
        }
    }

    @Test("BIP86 child paths derive Taproot addresses")
    func bip86ChildPathsDeriveTaprootAddresses() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let wallet = try #require(HDWallet(mnemonic: mnemonic, passphrase: ""))
        let path = "m/86'/0'/0'/0/0"
        let privateKey = wallet.getKey(coin: .bitcoin, derivationPath: path)
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true)
        let address = CoinType.bitcoin.deriveAddressFromPublicKeyAndDerivation(
            publicKey: publicKey,
            derivation: .bitcoinTaproot
        )

        #expect(address == wallet.getAddressDerivation(coin: .bitcoin, derivation: .bitcoinTaproot))
        #expect(address.hasPrefix("bc1p"))
    }

    /// A garbage string that isn't an extended key throws an HONEST error —
    /// it must never fabricate an address (Rule #16).
    @Test("Non-extended-key input is rejected, never mocked")
    func rejectsNonExtendedKey() async {
        await #expect(throws: (any Error).self) {
            _ = try await service.deriveAddresses(fromExtendedKey: "definitely-not-a-key", on: .bitcoin)
        }
    }

    /// Non-Bitcoin-family chains have no extended-key concept — honest refusal.
    @Test("Non-Bitcoin-family chains reject extended-key derivation")
    func rejectsNonBitcoinFamily() async {
        let xpub = "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj"
        await #expect(throws: (any Error).self) {
            _ = try await service.deriveAddresses(fromExtendedKey: xpub, on: .ethereum)
        }
    }
}
