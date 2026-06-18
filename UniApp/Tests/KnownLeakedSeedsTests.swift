import Testing
import Foundation
@testable import Aperture

/// Tests for `KnownLeakedSeeds` — the compiled-in blocklist that warns a user
/// when they're about to import a publicly-known tutorial mnemonic or private
/// key (T-032). Verifies real detection, case/whitespace normalization, and —
/// critically — that a genuine user seed is NEVER falsely flagged.
@Suite("Known-leaked seed & key detection")
struct KnownLeakedSeedsTests {

    // MARK: - Mnemonics

    @Test("The canonical BIP-39 all-`abandon` vector is flagged")
    func bip39AbandonVectorFlagged() {
        let words = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".split(separator: " ").map(String.init)
        #expect(KnownLeakedSeeds.isLeaked(mnemonic: words))
    }

    @Test("The Hardhat and Ganache default dev mnemonics are flagged")
    func devDefaultsFlagged() {
        let hardhat = "test test test test test test test test test test test junk".split(separator: " ").map(String.init)
        let ganache = "myth like bonus scare over problem client lizard pioneer submit female collect".split(separator: " ").map(String.init)
        #expect(KnownLeakedSeeds.isLeaked(mnemonic: hardhat))
        #expect(KnownLeakedSeeds.isLeaked(mnemonic: ganache))
    }

    @Test("Matching is case-insensitive and whitespace-normalized")
    func mnemonicNormalization() {
        // Mixed case + extra/leading/trailing whitespace must still match.
        let messy = "  Test   TEST test\ttest test test test test test test test JUNK  "
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        #expect(KnownLeakedSeeds.isLeaked(mnemonic: messy))
    }

    @Test("A genuine (non-public) mnemonic is NOT flagged")
    func realMnemonicNotFlagged() {
        // A valid-shape 12-word phrase that isn't in any public list.
        let real = "ridge flock crouch caught mango oyster pelican sketch fringe vivid tunnel ginger".split(separator: " ").map(String.init)
        #expect(!KnownLeakedSeeds.isLeaked(mnemonic: real))
    }

    // MARK: - Private keys

    @Test("The `key = 1` and Hardhat/Anvil default keys are flagged")
    func leakedKeysFlagged() {
        #expect(KnownLeakedSeeds.isLeaked(privateKey: "0000000000000000000000000000000000000000000000000000000000000001"))
        #expect(KnownLeakedSeeds.isLeaked(privateKey: "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"))
        #expect(KnownLeakedSeeds.isLeaked(privateKey: "8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"))
    }

    @Test("Key matching ignores the `0x` prefix and case")
    func keyNormalization() {
        #expect(KnownLeakedSeeds.isLeaked(privateKey: "0xAC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80"))
    }

    @Test("A genuine (non-public) private key is NOT flagged")
    func realKeyNotFlagged() {
        #expect(!KnownLeakedSeeds.isLeaked(privateKey: "1f2e3d4c5b6a7988796a5b4c3d2e1f00112233445566778899aabbccddeeff11"))
    }
}
