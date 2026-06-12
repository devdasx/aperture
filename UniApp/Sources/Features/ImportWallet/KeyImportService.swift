import Foundation

/// Result of a key-format detection pass — what `KeyImportService`
/// thinks the user's raw input looks like for a given chain.
enum KeyFormat: Hashable, Sendable {
    case bitcoinWIF
    case evmHex
    case solanaBase58
    case xrpSeed
    case cosmosHex
    case ed25519Hex
    case extendedPublicKey(prefix: ExtendedKeyPrefix)
    case unknown

    enum ExtendedKeyPrefix: String, Hashable, Sendable {
        case xpub, ypub, zpub
    }
}

/// Contract for chain-aware key / address operations used by the
/// import flow. Implementations are stub-first today (see
/// `StubKeyImportService`) so the UI ships while per-family parsers
/// land incrementally as T-024 through T-031.
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
    /// (32 or 64 bytes). Used by the mnemonic-import review step.
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

/// **Stub** implementation per the jony-ive 2026-06-05 design audit
/// ("stub-first" — the UI ships today; real per-family cryptography
/// lands as T-024..T-031). Returns deterministic, clearly-mock
/// addresses so the review steps show *something honest* — every
/// derived value is prefixed with a recognizable mock marker so the
/// user (and reviewer) can never confuse it with a real address.
struct StubKeyImportService: KeyImportService {

    // MARK: - Format detection (shape-only heuristics)

    func detectFormat(_ raw: String, on chain: SupportedChain) -> KeyFormat? {
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
            if body.count == 64, body.allSatisfy(isHex) {
                return .evmHex
            }
        case .ed25519:
            // Solana base58 secret keys are ~88 chars; Stellar/Sui
            // formats differ. Heuristic: ~80-90 chars base58.
            if (60...90).contains(trimmed.count), trimmed.allSatisfy(isBase58) {
                return .solanaBase58
            }
            // ed25519 hex (32-byte private key) is 64 hex chars.
            if trimmed.count == 64, trimmed.allSatisfy(isHex) {
                return .ed25519Hex
            }
        case .ripple:
            // XRP family seeds are base58 starting with 's', ~29 chars.
            if trimmed.hasPrefix("s"), (28...29).contains(trimmed.count),
               trimmed.allSatisfy(isBase58) {
                return .xrpSeed
            }
        case .cosmos, .aptos, .near, .polkadot, .ton, .tron:
            // Generic 32-byte hex catch-all for chains we haven't
            // chain-family-specialized yet.
            let body = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
            if body.count == 64, body.allSatisfy(isHex) {
                return chain.family == .cosmos ? .cosmosHex : .ed25519Hex
            }
        }

        return .unknown
    }

    // MARK: - Address derivation (stub)

    // TODO: (T-024) Bitcoin family secp256k1 + BIP-32 + base58check.
    // TODO: (T-025) EVM secp256k1 + keccak256 + EIP-55.
    // TODO: (T-026) Solana ed25519 + base58.
    // TODO: (T-027) XRP family seed parsing + base58check (XRP alphabet).
    // TODO: (T-028) Cosmos / Kava secp256k1 + bech32.
    // TODO: (T-029) NEAR ed25519 + implicit / named accounts.
    // TODO: (T-030) TON ed25519 + wallet-contract address encoding.
    // TODO: (T-031) Aptos / Sui / Stellar / Polkadot / TRON — per-family parsers.
    func deriveAddress(fromPrivateKey raw: String, on chain: SupportedChain) async throws -> String {
        guard detectFormat(raw, on: chain) != nil else {
            throw KeyImportError.invalidFormat
        }
        return mockAddress(for: chain, salt: raw)
    }

    func validateAddress(_ raw: String, on chain: SupportedChain) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Stub: minimum-length per family.
        switch chain.family {
        case .bitcoin:  return trimmed.count >= 26 && trimmed.count <= 90
        case .evm:      return trimmed.hasPrefix("0x") && trimmed.count == 42 && String(trimmed.dropFirst(2)).allSatisfy(isHex)
        case .ed25519, .ripple, .cosmos, .aptos, .near, .polkadot, .ton, .tron:
            return trimmed.count >= 26
        }
    }

    func deriveAddresses(fromExtendedKey raw: String, on chain: SupportedChain) async throws -> [String] {
        guard chain.supportsExtendedPublicKey else {
            throw KeyImportError.unsupported
        }
        guard let prefix = extendedKeyPrefix(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw KeyImportError.invalidFormat
        }
        // Stub: return 5 mock addresses so the review screen has
        // something to show. Real BIP-32 derivation lives in T-024.
        return (0..<5).map { i in
            "[STUB \(prefix.rawValue) #\(i)] " + mockAddress(for: chain, salt: "\(raw)-\(i)")
        }
    }

    func deriveAddresses(fromSeed seed: Data) async throws -> [SupportedChain: String] {
        // Hybrid: real BIP-44 derivation for chains where CryptoKit
        // ships the underlying primitive (Solana, NEAR — both ed25519
        // via Curve25519 + Base58 / hex). Stub for everything else
        // until the per-chain crypto lands (T-024..T-031). Stub
        // addresses are clearly marked with a `[STUB]` prefix so the
        // user / reviewer can never confuse them for real ones
        // (Rule #2 §A.7).
        var addresses: [SupportedChain: String] = [:]
        let salt = seed.prefix(8).map { String(format: "%02x", $0) }.joined()
        for chain in SupportedChain.allCases {
            switch chain {
            case .solana:
                addresses[chain] = Ed25519Derivation.solanaAddress(seed: seed)
            case .near:
                addresses[chain] = Ed25519Derivation.nearImplicitAccount(seed: seed)
            default:
                addresses[chain] = mockAddress(for: chain, salt: salt)
            }
        }
        return addresses
    }

    /// Whether `deriveAddresses(fromSeed:)` will produce a real,
    /// on-chain-valid address for `chain` (vs. a `[STUB]` placeholder).
    /// The review UI uses this to label each row honestly.
    static func usesRealDerivation(for chain: SupportedChain) -> Bool {
        switch chain {
        case .solana, .near: return true
        default:             return false
        }
    }

    /// Mnemonic-based fallback. The stub returns the seed-based result
    /// so callers that use this path get the same hybrid behavior as
    /// before. Production callers should use `WalletCoreKeyImportService`.
    func deriveAddresses(mnemonic: [String], passphrase: String) async -> [SupportedChain: String] {
        let seed = BIP39.deriveSeed(words: mnemonic, passphrase: passphrase)
        return (try? await deriveAddresses(fromSeed: seed)) ?? [:]
    }

    // MARK: - Helpers

    /// Sentinel prefix that marks every address `StubKeyImportService`
    /// emits as a placeholder. Real per-chain derivation (Solana, NEAR
    /// today via `Ed25519Derivation`) bypasses this entirely. The
    /// review UI splits the prefix off and renders the row in its
    /// "Derivation pending" state so the user can never confuse a
    /// stub for a real address (Rule #2 §A.7).
    static let stubAddressPrefix = "[STUB]"

    private func mockAddress(for chain: SupportedChain, salt: String) -> String {
        // Deterministic mock address per (chain, salt) prefixed with
        // an unambiguous sentinel. The body still has a shape that
        // resembles the chain's address so existing UI components
        // (truncation, monospaced rendering) don't have to special-case
        // anything beyond the prefix check.
        let digest = simpleHash(salt + chain.rawValue)
        let body: String
        switch chain.family {
        case .bitcoin:
            body = "bc1q\(digest.prefix(38))"
        case .evm:
            body = "0x\(digest.prefix(40))"
        case .ed25519:
            body = String(digest.prefix(44))
        case .ripple:
            body = "r\(digest.prefix(33))"
        case .cosmos:
            body = "kava1\(digest.prefix(38))"
        case .aptos:
            body = "0x\(digest.prefix(64))"
        case .near:
            body = "\(digest.prefix(20)).near"
        case .polkadot:
            body = "1\(digest.prefix(46))"
        case .ton:
            body = "EQ\(digest.prefix(46))"
        case .tron:
            body = "T\(digest.prefix(33))"
        }
        return Self.stubAddressPrefix + body
    }

    private func simpleHash(_ input: String) -> String {
        // Non-cryptographic, deterministic mock hash — for stub addresses
        // only. The real implementation in T-024..T-031 uses CryptoKit
        // primitives (SHA256, keccak256, etc.).
        var hash: UInt64 = 14695981039346656037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let hex = String(format: "%016llx", hash)
        // Pad to a usable length by repeating.
        return String(repeating: hex, count: 8)
    }

    private func extendedKeyPrefix(_ raw: String) -> KeyFormat.ExtendedKeyPrefix? {
        if raw.hasPrefix("xpub") { return .xpub }
        if raw.hasPrefix("ypub") { return .ypub }
        if raw.hasPrefix("zpub") { return .zpub }
        return nil
    }

    /// The Bitcoin base58 alphabet — excludes 0, O, I, and l, which
    /// the previous predicate (`isLetter || isNumber`) wrongly accepted.
    private static let base58Alphabet: Set<Character> = Set(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    private func isBase58(_ c: Character) -> Bool {
        Self.base58Alphabet.contains(c)
    }

    private func isHex(_ c: Character) -> Bool {
        c.isHexDigit
    }
}
