import Testing
import Foundation
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
