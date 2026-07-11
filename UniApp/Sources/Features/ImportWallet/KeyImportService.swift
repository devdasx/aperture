import Foundation

/// Result of a key-format detection pass — what `KeyImportService`
/// thinks the user's raw input looks like for a given chain.
enum KeyFormat: Hashable, Sendable {
    case bitcoinWIF
    case evmHex
    case solanaBase58
    case xrpSeed
    case ed25519Hex
    case extendedPublicKey(prefix: ExtendedKeyPrefix)
    case unknown

    enum ExtendedKeyPrefix: String, Hashable, Sendable {
        case xpub, ypub, zpub
    }
}

/// Contract for chain-aware key / address operations used by the
/// import flow. Production uses `WalletCoreKeyImportService` only.
protocol KeyImportService: Sendable {
    /// Heuristic guess at the format of a raw user-input string, for
    /// the chain they have selected. Returns `nil` if the string
    /// doesn't plausibly parse for that chain.
    func detectFormat(_ raw: String, on chain: SupportedChain) -> KeyFormat?

    /// Derive the address for a private key on the chain. Throws if
    /// the key cannot be parsed or address derivation fails.
    func deriveAddress(fromPrivateKey raw: String, on chain: SupportedChain) async throws -> String

    /// Whether a raw string is a valid address for the chain.
    func validateAddress(_ raw: String, on chain: SupportedChain) -> Bool

    /// Derive watch-only addresses from an extended public key
    /// (xpub/ypub/zpub). Only Bitcoin-family chains support this; for
    /// other chains throws `KeyImportError.unsupported`.
    func deriveAddresses(fromExtendedKey raw: String, on chain: SupportedChain) async throws -> [String]

    /// Derive the first address per supported chain from a BIP-39 seed
    /// (32 or 64 bytes). Legacy API kept for older importer call sites.
    ///
    /// **Deprecated path.** The WalletCore-backed service (`WalletCoreKeyImportService`)
    /// can't use this — WalletCore takes the mnemonic words, not the
    /// derived seed bytes. New code should call
    /// `deriveAddresses(mnemonic:passphrase:)` instead.
    func deriveAddresses(fromSeed seed: Data) async throws -> [SupportedChain: String]

    /// Derive the first address per supported chain directly from a
    /// BIP-39 mnemonic phrase + optional passphrase. Preferred over
    /// `deriveAddresses(fromSeed:)` — WalletCore's `HDWallet` accepts
    /// the mnemonic and runs BIP-39 → BIP-32 → chain-specific
    /// derivation in one pipeline.
    func deriveAddresses(mnemonic: [String], passphrase: String) async -> [SupportedChain: String]
}

enum KeyImportError: Error, Hashable, Sendable {
    case unsupported
    case invalidFormat
    case derivationFailed
}

// MARK: - Format detection (shape only — no derivation)

/// Pure shape heuristics for private-key / seed input classification.
///
/// **BUG-024.** This is intentionally **not** a `KeyImportService`.
/// It never derives addresses. Production derivation is exclusively
/// `WalletCoreKeyImportService`. WalletCore still delegates format
/// detection here (shape-only, no crypto).
enum KeyImportFormatDetector {

    /// Historical sentinel that marked placeholder addresses from the
    /// retired stub derivation path. Production never emits this;
    /// review UI / scanners still filter it as defense-in-depth
    /// (Rule #16 — a placeholder must never look spendable).
    static let stubAddressPrefix = "[STUB]"

    /// Heuristic guess at the format of a raw user-input string for
    /// the selected chain. Returns `nil` only for empty input.
    static func detectFormat(_ raw: String, on chain: SupportedChain) -> KeyFormat? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch chain.family {
        case .bitcoin:
            // Bitcoin WIF: 51-52 chars, base58 alphabet, starts with
            // K/L (compressed) or 5 (uncompressed) for mainnet.
            if (51...52).contains(trimmed.count),
               trimmed.allSatisfy(isBase58) {
                return .bitcoinWIF
            }
            // xpub/ypub/zpub for watch-only path:
            if let prefix = extendedKeyPrefix(trimmed) {
                return .extendedPublicKey(prefix: prefix)
            }
        case .evm:
            // 32-byte hex with or without 0x prefix.
            let body = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
            if body.count == 64, body.allSatisfy(\.isHexDigit) {
                return .evmHex
            }
        case .ed25519:
            // Solana base58 secret keys are ~88 chars; Stellar/Sui
            // formats differ. Heuristic: ~80-90 chars base58.
            if (60...90).contains(trimmed.count), trimmed.allSatisfy(isBase58) {
                return .solanaBase58
            }
            // ed25519 hex (32-byte private key) is 64 hex chars.
            if trimmed.count == 64, trimmed.allSatisfy(\.isHexDigit) {
                return .ed25519Hex
            }
        case .ripple:
            // XRP family seeds are base58 starting with 's', ~29 chars.
            if trimmed.hasPrefix("s"), (28...29).contains(trimmed.count),
               trimmed.allSatisfy(isBase58) {
                return .xrpSeed
            }
        case .aptos, .near, .polkadot, .ton, .tron:
            // Generic 32-byte hex catch-all for chains we haven't
            // chain-family-specialized yet.
            let body = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
            if body.count == 64, body.allSatisfy(\.isHexDigit) {
                return .ed25519Hex
            }
        }

        return .unknown
    }

    // MARK: - Private helpers

    private static func extendedKeyPrefix(_ raw: String) -> KeyFormat.ExtendedKeyPrefix? {
        if raw.hasPrefix("xpub") { return .xpub }
        if raw.hasPrefix("ypub") { return .ypub }
        if raw.hasPrefix("zpub") { return .zpub }
        return nil
    }

    /// The Bitcoin base58 alphabet — excludes 0, O, I, and l.
    private static let base58Alphabet: Set<Character> = Set(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    private static func isBase58(_ c: Character) -> Bool {
        base58Alphabet.contains(c)
    }
}

// MARK: - Retired type name (API compatibility for prefix constant only)

/// **BUG-024.** Former stub `KeyImportService` that could emit `[STUB]`
/// fake addresses. Derivation was removed; only the historical prefix
/// constant remains for UI defense-in-depth filtering.
///
/// Do **not** reintroduce derivation methods here. Use
/// `WalletCoreKeyImportService` for any key → address work.
enum StubKeyImportService {
    /// Same sentinel as `KeyImportFormatDetector.stubAddressPrefix`.
    static let stubAddressPrefix = KeyImportFormatDetector.stubAddressPrefix
}
