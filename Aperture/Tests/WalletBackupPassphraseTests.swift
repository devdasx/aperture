import Foundation
import Testing
@testable import Aperture

/// P0-003: iCloud backup must flag BIP-39 passphrase wallets and restore
/// must refuse silent empty-passphrase derivation.
@Suite("Wallet backup passphrase (P0-003)")
struct WalletBackupPassphraseTests {

    private let words12 = Array(repeating: "abandon", count: 11) + ["about"]

    @Test("Blob encodes hasPassphrase and survives round-trip")
    func encodeRoundTrip() throws {
        let blob = try WalletBackupBlob.make(
            walletId: UUID(),
            walletName: "Pass Wallet",
            words: words12,
            password: "correct-horse-battery-staple-99",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasPassphrase: true
        )
        #expect(blob.hasPassphrase)
        #expect(blob.requiresBIP39Passphrase)
        #expect(blob.version == WalletBackupBlob.currentVersion)

        let data = try blob.encoded()
        let decoded = try WalletBackupBlob.decode(data)
        #expect(decoded.hasPassphrase == true)
        #expect(decoded.walletName == "Pass Wallet")
        #expect(decoded.wordCount == 12)

        let recovered = try decoded.recoverWords(password: "correct-horse-battery-staple-99")
        #expect(recovered == words12)
    }

    @Test("Legacy v1 JSON without hasPassphrase decodes as false")
    func legacyDecodeDefaultsFalse() throws {
        // Minimal v1-shaped envelope (no hasPassphrase key).
        let sealed = try WalletBackupCrypto.encrypt(
            mnemonic: words12.joined(separator: " "),
            password: "pw-for-legacy-test-99"
        )
        let legacy: [String: Any] = [
            "version": 1,
            "walletId": UUID().uuidString,
            "walletName": "Old",
            "createdAt": 1_700_000_000.0,
            "wordCount": 12,
            "kdf": WalletBackupCrypto.kdfName,
            "kdfIterations": sealed.iterations,
            "salt": sealed.salt.base64EncodedString(),
            "ciphertext": sealed.ciphertext.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        // JSONDecoder needs ISO8601 or seconds for Date — use make() encode
        // of a false-passphrase blob and strip key instead for reliability.
        let modern = try WalletBackupBlob.make(
            walletId: UUID(),
            walletName: "Old",
            words: words12,
            password: "pw-for-legacy-test-99",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            hasPassphrase: false
        )
        var obj = try JSONSerialization.jsonObject(with: modern.encoded()) as! [String: Any]
        obj.removeValue(forKey: "hasPassphrase")
        // Force version 1
        obj["version"] = 1
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try WalletBackupBlob.decode(stripped)
        #expect(decoded.hasPassphrase == false)
        #expect(decoded.requiresBIP39Passphrase == false)
        _ = data // silence unused if path unused
    }

    @Test("resolvedPassphrase refuses empty when hasPassphrase is true")
    func refuseEmptyWhenFlagged() {
        #expect(throws: RestorePassphraseError.passphraseRequired) {
            _ = try WalletBackupBlob.resolvedPassphrase(hasPassphrase: true, passphrase: "")
        }
        #expect(throws: RestorePassphraseError.passphraseRequired) {
            _ = try WalletBackupBlob.resolvedPassphrase(hasPassphrase: true, passphrase: "   ")
        }
        let ok = try? WalletBackupBlob.resolvedPassphrase(hasPassphrase: true, passphrase: "my-secret")
        #expect(ok == "my-secret")
    }

    @Test("resolvedPassphrase allows empty when flag is false")
    func allowEmptyWhenUnflagged() throws {
        #expect(try WalletBackupBlob.resolvedPassphrase(hasPassphrase: false, passphrase: "") == "")
        #expect(try WalletBackupBlob.resolvedPassphrase(hasPassphrase: false, passphrase: "legacy") == "legacy")
    }

    @Test("Different passphrases produce different first addresses")
    func passphraseChangesAddresses() async {
        let service = WalletCoreKeyImportService()
        let plain = await service.deriveAddresses(mnemonic: words12, passphrase: "")
        let withPass = await service.deriveAddresses(mnemonic: words12, passphrase: "TREZOR")
        #expect(!plain.isEmpty && !withPass.isEmpty)
        #expect(plain[.ethereum] != withPass[.ethereum])
        #expect(plain[.bitcoin] != withPass[.bitcoin])
    }

    @Test("Restore error copy is honest")
    func errorCopy() {
        let msg = RestorePassphraseError.passphraseRequired.userMessage
        #expect(msg.localizedCaseInsensitiveContains("passphrase"))
        #expect(msg.localizedCaseInsensitiveContains("empty"))
    }
}
