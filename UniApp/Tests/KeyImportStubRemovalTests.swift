import Foundation
import Testing
@testable import Aperture

/// BUG-024: stub derivation must not exist as a live KeyImportService.
/// Production import uses WalletCore only; format detection is shape-only.
@Suite("Key import stub removal (BUG-024)")
struct KeyImportStubRemovalTests {

    @Test("ImportWalletState wires WalletCoreKeyImportService, not a stub")
    @MainActor
    func importStateUsesWalletCore() {
        let state = ImportWalletState()
        #expect(state.service is WalletCoreKeyImportService)
    }

    @Test("Format detector classifies EVM hex without deriving")
    func formatDetectorEVMHex() {
        let raw = "0x59c6995e998f97a5a0044966f094538f5dae440fdf24c8063c61fbb1c5ab7d7a"
        #expect(KeyImportFormatDetector.detectFormat(raw, on: .ethereum) == .evmHex)
        #expect(KeyImportFormatDetector.detectFormat("", on: .ethereum) == nil)
    }

    @Test("Format detector classifies xpub shape")
    func formatDetectorXpub() {
        // Shape-only: valid length not required; prefix + non-empty.
        let raw = "xpub6D4BDPcP2GT577Vvch3R8wDkScZWzQzMMUm3PWbmWvVJrZwQY4VUNgqFJPMM3No2dFDFGTsxxpG5uJh7n7epu4trkrX7x7DogT5Uv6fcLW5"
        let format = KeyImportFormatDetector.detectFormat(raw, on: .bitcoin)
        guard case .extendedPublicKey(let prefix) = format else {
            Issue.record("expected extendedPublicKey, got \(String(describing: format))")
            return
        }
        #expect(prefix == .xpub)
    }

    @Test("WalletCore detectFormat delegates to format detector")
    func walletCoreDetectFormatDelegates() {
        let service = WalletCoreKeyImportService()
        let raw = "0x59c6995e998f97a5a0044966f094538f5dae440fdf24c8063c61fbb1c5ab7d7a"
        #expect(service.detectFormat(raw, on: .ethereum) == .evmHex)
        #expect(
            service.detectFormat(raw, on: .ethereum)
                == KeyImportFormatDetector.detectFormat(raw, on: .ethereum)
        )
    }

    @Test("WalletCore mnemonic derivation never emits stub prefix")
    func walletCoreMnemonicNeverStub() async {
        let words = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            .split(separator: " ")
            .map(String.init)
        let service = WalletCoreKeyImportService()
        let addresses = await service.deriveAddresses(mnemonic: words, passphrase: "")
        #expect(!addresses.isEmpty)
        for (chain, address) in addresses {
            #expect(
                !address.hasPrefix(KeyImportFormatDetector.stubAddressPrefix),
                "\(chain.rawValue) must not be stub: \(address)"
            )
            #expect(!address.hasPrefix("[STUB"), "\(chain.rawValue) must not use STUB marker")
            #expect(!address.isEmpty)
        }
    }

    @Test("Legacy stubAddressPrefix constants stay aligned for UI filters")
    func legacyPrefixAligned() {
        #expect(StubKeyImportService.stubAddressPrefix == "[STUB]")
        #expect(StubKeyImportService.stubAddressPrefix == KeyImportFormatDetector.stubAddressPrefix)
    }

    @Test("StubKeyImportService is not a KeyImportService (no derivation surface)")
    func stubIsNotKeyImportService() {
        // Compile-time contract documented at runtime: the retired type is
        // an enum namespace, not a service you can inject as KeyImportService.
        let mirror = String(describing: type(of: StubKeyImportService.self))
        #expect(mirror.contains("StubKeyImportService"))
        // If this ever becomes a struct conforming again, fail loudly.
        #expect(!(StubKeyImportService.self is any KeyImportService.Type))
    }
}
