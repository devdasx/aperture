import Foundation
import SwiftData
import WalletCore

/// Real EVM signing for the dApp browser's confirmation sheets —
/// `personal_sign` / `eth_sign` (EIP-191) and `eth_signTypedData_v4`
/// (EIP-712). Resolves the active wallet, reconstructs the Ethereum
/// key from the on-device mnemonic, signs, and returns the 65-byte
/// `r || s || v` signature as 0x-hex.
///
/// **Custody boundaries (Rule #16, honest by construction).**
///   - Only wallets backed by a mnemonic can sign (`created` /
///     `importedMnemonic`). Watch-only and single-key imports get an
///     honest error — never a fabricated signature.
///   - Wallets whose mnemonic is no longer on the device (the user
///     completed backup, so `MnemonicVault` deleted the local copy)
///     and wallets protected by a BIP-39 passphrase (never persisted)
///     also get an honest error rather than a wrong-key signature.
///   - Key material stays scoped to the signing call: the mnemonic
///     and the derived `PrivateKey` are locals that drop at function
///     exit. Nothing key-, mnemonic-, or signature-shaped is logged.
@MainActor
enum EVMDAppSigner {

    enum SignerError: Error, Sendable {
        case noActiveWallet
        case walletCannotSign
        case mnemonicUnavailable
        case invalidPayload
        case signingFailed
    }

    // MARK: - Public surface (async — preferred)

    /// EIP-191 personal message signature, with the heavy section
    /// (BIP-39 PBKDF2 seed derivation + HD key derivation + secp256k1
    /// sign — 15–50 ms) executed OFF the main actor via `@concurrent`
    /// (2026-06-12). Wallet resolution and the Keychain/vault read
    /// stay on `@MainActor` (`MnemonicVault` is main-actor-bound);
    /// only Sendable value types cross the boundary, and the mnemonic
    /// words remain locals that drop at function exit.
    static func signPersonalMessage(messageHex: String) async throws(SignerError) -> String {
        let words = try loadSigningWords()
        return try await deriveAndSignDetached(
            digest: personalMessageDigest(messageHex: messageHex),
            words: words
        )
    }

    /// EIP-712 typed-data signature (`eth_signTypedData_v4`) with the
    /// key-derivation + signing pipeline off the main actor — see
    /// `signPersonalMessage(messageHex:) async`.
    static func signTypedData(json: String) async throws(SignerError) -> String {
        let digest = try typedDataDigest(json: json)
        let words = try loadSigningWords()
        return try await deriveAndSignDetached(digest: digest, words: words)
    }

    /// Map a signer failure to the JSON-RPC error the page receives.
    /// Accepts `any Error` so untyped `catch` blocks at the call sites
    /// can pass straight through; non-signer errors map to a generic
    /// internal error rather than leaking a description to the page.
    static func requestError(for error: any Error) -> DAppRequestError {
        guard let signerError = error as? SignerError else {
            return .internalError
        }
        switch signerError {
        case .noActiveWallet:
            return DAppRequestError(code: 4100, message: "No active wallet")
        case .walletCannotSign:
            return DAppRequestError(code: 4200, message: "This wallet can't sign browser requests")
        case .mnemonicUnavailable:
            return DAppRequestError(code: 4200, message: "Aperture can't sign this request yet")
        case .invalidPayload:
            return .invalidParams
        case .signingFailed:
            return .internalError
        }
    }

    // MARK: - Signing core

    /// EIP-191 digest: message bytes prefixed with
    /// `"\u{19}Ethereum Signed Message:\n" + length`, Keccak-256 hashed.
    private static func personalMessageDigest(messageHex: String) -> Data {
        let message = messageBytes(from: messageHex)
        let prefix = "\u{19}Ethereum Signed Message:\n\(message.count)"
        var payload = Data(prefix.utf8)
        payload.append(message)
        return Keccak256.hash(payload)
    }

    /// EIP-712 digest via WalletCore's `EthereumAbi.encodeTyped` —
    /// the canonical `keccak256("\x19\x01" ‖ domainSeparator ‖
    /// hashStruct(message))` computed from the JSON payload.
    private static func typedDataDigest(json: String) throws(SignerError) -> Data {
        let digest = EthereumAbi.encodeTyped(messageJson: json)
        guard digest.count == 32 else {
            // WalletCore returns empty data for malformed payloads.
            throw .invalidPayload
        }
        return digest
    }

    /// Resolve the active wallet, enforce the custody boundaries, and
    /// load the mnemonic words from the vault. Stays on `@MainActor`
    /// — SwiftData lookup + `MnemonicVault` (main-actor-bound). The
    /// returned words are `Sendable` and must stay locals at every
    /// call site (key material never outlives the signing call).
    private static func loadSigningWords() throws(SignerError) -> [String] {
        guard let record = activeWallet() else { throw .noActiveWallet }
        switch record.kind {
        case .created, .importedMnemonic:
            break
        case .importedKey, .watchOnly:
            throw .walletCannotSign
        }
        // A BIP-39 passphrase is never persisted (schema contract) —
        // deriving with an empty passphrase would sign with the WRONG
        // key. Honest refusal until a passphrase prompt flow exists.
        guard !record.hasPassphrase else { throw .mnemonicUnavailable }

        let stored = (try? MnemonicVault.loadMnemonic(for: record.id)) ?? nil
        guard let words = stored, !words.isEmpty else {
            // Backed-up wallets keep only the derived seed on device;
            // the phrase itself is gone by design.
            throw .mnemonicUnavailable
        }
        return words
    }

    /// `deriveAndSign` on the global concurrent executor — the
    /// PBKDF2-HMAC-SHA512 seed stretch (2048 iterations), HD key
    /// derivation, and secp256k1 sign run off the main actor so the
    /// confirmation sheet's dismiss animation never drops frames.
    @concurrent
    private nonisolated static func deriveAndSignDetached(
        digest: Data,
        words: [String]
    ) async throws(SignerError) -> String {
        try deriveAndSign(digest: digest, words: words)
    }

    /// Sign a 32-byte digest with the Ethereum key derived from
    /// `words`. Pure compute, no UI state — `nonisolated` so both the
    /// main-thread legacy path and the `@concurrent` path share one
    /// implementation. Returns 0x-hex of `r || s || v` with `v`
    /// adjusted to 27/28. The mnemonic and the derived `PrivateKey`
    /// are locals that drop at function exit; nothing key-shaped is
    /// logged or retained.
    private nonisolated static func deriveAndSign(
        digest: Data,
        words: [String]
    ) throws(SignerError) -> String {
        guard let wallet = HDWallet(mnemonic: words.joined(separator: " "), passphrase: "") else {
            throw .signingFailed
        }
        let privateKey = wallet.getKeyForCoin(coin: .ethereum)
        guard var signature = privateKey.sign(digest: digest, curve: .secp256k1),
              signature.count == 65 else {
            throw .signingFailed
        }
        // WalletCore returns the recovery id (0/1) in the last byte;
        // Ethereum's `v` convention is 27/28.
        signature[signature.count - 1] += 27
        return "0x" + signature.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    /// Resolve the active wallet — same lookup contract as
    /// `ActiveWalletReader` (shared `activeWalletId` default, first
    /// wallet as fallback) so the signer and the address the dApp saw
    /// always agree. Targeted fetches (2026-06-12): a predicate +
    /// `fetchLimit 1` for the active id, falling back to a
    /// `fetchLimit 1` fetch — never materializes every wallet just to
    /// pick one.
    private static func activeWallet() -> WalletRecord? {
        let activeId = UserDefaults.standard.string(forKey: "activeWalletId") ?? ""
        let modelContext = ModelContext(ApertureDatabase.shared.container)
        if let activeUUID = UUID(uuidString: activeId) {
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == activeUUID }
            )
            descriptor.fetchLimit = 1
            if let match = (try? modelContext.fetch(descriptor))?.first {
                return match
            }
        }
        var fallback = FetchDescriptor<WalletRecord>()
        fallback.fetchLimit = 1
        return (try? modelContext.fetch(fallback))?.first
    }

    /// Decode the dApp's message param: 0x-hex when valid, otherwise
    /// the literal UTF-8 bytes of the string (MetaMask-compatible).
    private static func messageBytes(from raw: String) -> Data {
        if raw == "0x" || raw == "0X" { return Data() }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X"),
           let bytes = data(fromHex: String(raw.dropFirst(2))) {
            return bytes
        }
        return Data(raw.utf8)
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
