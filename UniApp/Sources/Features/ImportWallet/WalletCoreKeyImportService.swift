import Foundation
import WalletCore

/// Production `KeyImportService` backed by Trust Wallet Core
/// (`HDWallet` + `CoinType`). Per Rule #3 §B exception logged in
/// `SHIPPED.md` 2026-06-06 — WalletCore is the canonical battle-
/// tested multi-chain cryptography library (secp256k1, ed25519,
/// SHA-3, BLAKE2b, StrKey, SS58, bech32, SLIP-0044). The UI never
/// imports `WalletCore` directly; it consumes this protocol.
///
/// **What this delivers (vs. the prior `StubKeyImportService`).**
/// All 24 supported chains receive their real derivation today —
/// Bitcoin / EVM family / Cosmos / TRON via secp256k1, Aptos / Sui /
/// Stellar / TON / NEAR / Solana / Polkadot via the appropriate
/// ed25519 / sr25519 / SCALE / StrKey primitives that WalletCore
/// already ships and Trust Wallet uses in production.
///
/// **Address parity with Trust Wallet.** Derivation paths match
/// Trust Wallet exactly because both apps consume WalletCore's
/// `getAddressForCoin(coin:)` default-path API. A user importing
/// the same mnemonic in Trust Wallet and Aperture sees the same
/// addresses on every chain WalletCore covers.
///
/// **Sendable contract.** `HDWallet` is a reference type backed by
/// C++ memory — not `Sendable`-clean. The service does NOT hold
/// `HDWallet` as state; it constructs one per `deriveAddresses`
/// call and lets it drop at the end of the scope so the Swift 6
/// strict-concurrency boundary stays honest. The service itself
/// is a struct (value type) with no mutable state — naturally
/// `Sendable`.
struct WalletCoreKeyImportService: KeyImportService {

    // MARK: - SupportedChain → CoinType id mapping
    //
    // Source: `wallet-core/registry.json` (audited 2026-06-06 against
    // WalletCore 4.6.13). When a chain has multiple Trust Wallet
    // derivations (e.g. Bitcoin SegWit vs Legacy vs Taproot) we
    // take the WalletCore default — which matches what Trust Wallet
    // Mobile ships, which is what the user asked us to match.

    private static let coinIdForChain: [SupportedChain: UInt32] = [
        // Bitcoin family (secp256k1 + BIP-32/44/49/84 + base58check / bech32)
        .bitcoin:      0,
        .bitcoinCash:  145,
        .litecoin:     2,
        .dogecoin:     3,

        // EVM family (secp256k1 + keccak256). Each chain has its own
        // SLIP-44 entry in Trust Wallet's registry — same secp256k1
        // key, same Ethereum-style 0x… address, but the derivation
        // path includes the chain's SLIP-44 index so different chains
        // can have different first addresses if the user wants to
        // keep funds segregated. We follow Trust Wallet's convention.
        .ethereum:     60,
        .arbitrum:     10042221,
        .base:         8453,
        .optimism:     10000070,
        .scroll:       534352,
        .zkSync:       10000324,
        .polygon:      966,
        .bnbChain:     20000714,   // "Smart Chain"
        .opBNB:        204,
        .avalanche:    10009000,   // C-Chain
        .celo:         52752,

        // Solana family (ed25519 + base58)
        .solana:       501,

        // XRP Ledger (secp256k1 + base58check, XRP alphabet)
        .ripple:       144,

        // Stellar (ed25519 + StrKey + CRC16-XModem)
        .stellar:      148,

        // NEAR (ed25519 + implicit-account hex)
        .near:         397,

        // TON (ed25519 + TON wallet contract address)
        .ton:          607,

        // TRON (secp256k1 + base58check + TRON address format)
        .tron:         195,

        // Polkadot (sr25519 + SS58 + SCALE)
        .polkadot:     354,

        // Aptos (ed25519 + SHA3-256 address)
        .aptos:        637,

        // Sui (ed25519 + BLAKE2b-256 address)
        .sui:          784,

    ]

    // MARK: - Mnemonic-based derivation (preferred API)

    /// Derive the canonical first address for every supported chain
    /// from a BIP-39 mnemonic + optional passphrase. Derivation runs
    /// in **parallel** via a `TaskGroup` — 26 chains resolve in
    /// roughly the time of the slowest single chain instead of
    /// 26× that.
    ///
    /// Returns: `[chain: address]` for every chain WalletCore knows;
    /// chains we couldn't resolve drop out of the map (the UI then
    /// renders them as derivation-pending — honest, Rule #2 §A.7).
    func deriveAddresses(
        mnemonic: [String],
        passphrase: String
    ) async -> [SupportedChain: String] {
        let phrase = mnemonic.joined(separator: " ")

        // Build the HDWallet ONCE on the calling actor (HDWallet is
        // not Sendable — it carries a C++ pointer). All per-chain
        // address reads are synchronous on the SAME thread, so we
        // don't need to ship HDWallet across actor boundaries.
        guard let wallet = HDWallet(mnemonic: phrase, passphrase: passphrase) else {
            return [:]
        }

        // Per-chain reads are cheap (microseconds each on the C++
        // side). We sequence them here rather than use a TaskGroup
        // because TaskGroup would have to ship `HDWallet` across
        // actor isolation and HDWallet isn't Sendable. The whole
        // loop completes in well under a millisecond — the
        // perceived "slow derivation" before was entirely the stub
        // hash work, not the C++ crypto.
        var addresses: [SupportedChain: String] = [:]
        addresses.reserveCapacity(SupportedChain.allCases.count)
        for chain in SupportedChain.allCases {
            guard let coinId = Self.coinIdForChain[chain],
                  let coin = CoinType(rawValue: coinId) else {
                continue
            }
            let address = wallet.getAddressForCoin(coin: coin)
            // Defensively reject empty strings — WalletCore returns
            // "" when a derivation can't be expressed for some
            // coin / path combinations; we treat that the same as
            // "derivation pending" so the UI stays honest.
            if !address.isEmpty {
                addresses[chain] = address
            }
        }
        return addresses
    }

    // MARK: - KeyImportService — protocol surface

    func detectFormat(_ raw: String, on chain: SupportedChain) -> KeyFormat? {
        // Format detection is shape-based and chain-aware. We delegate
        // to the existing stub heuristics; WalletCore's role is
        // derivation, not detection. The stub's detectFormat shipped
        // with explicit per-family heuristics and is the correct
        // surface for now.
        return StubKeyImportService().detectFormat(raw, on: chain)
    }

    func deriveAddress(
        fromPrivateKey raw: String,
        on chain: SupportedChain
    ) async throws -> String {
        guard let coinId = Self.coinIdForChain[chain],
              let coin = CoinType(rawValue: coinId) else {
            throw KeyImportError.unsupported
        }
        // Decode strictly by positively-identified format (hex, WIF,
        // Solana base58). Throws on anything ambiguous — an address
        // must never be derived from bytes whose encoding we merely
        // guessed at.
        let keyData = try Self.decodePrivateKeyBytes(raw, on: chain)
        // Validate the decoded scalar/seed against the coin's actual
        // curve before constructing the key. `PrivateKey(data:)` alone
        // accepts any 32-byte buffer; `isValid(data:curve:)` rejects
        // out-of-range secp256k1 scalars and malformed ed25519 seeds.
        guard PrivateKey.isValid(data: keyData, curve: coin.curve),
              let privateKey = PrivateKey(data: keyData) else {
            throw KeyImportError.invalidFormat
        }
        let publicKey = privateKey.getPublicKey(coinType: coin)
        let address = AnyAddress(publicKey: publicKey, coin: coin).description
        guard !address.isEmpty else {
            throw KeyImportError.derivationFailed
        }
        return address
    }

    // MARK: - Private-key byte decoding (format- and chain-aware)

    /// WIF version byte per Bitcoin-family chain (mainnet). Base58check
    /// WIF payloads begin with this byte; a mismatch means the key was
    /// exported for a different network and must be rejected, not
    /// silently re-interpreted.
    private static let wifVersionByte: [SupportedChain: UInt8] = [
        .bitcoin:     0x80,
        .bitcoinCash: 0x80,
        .litecoin:    0xB0,
        .dogecoin:    0x9E,
    ]

    /// Decode the user's raw private-key string into the exact key
    /// bytes for `chain`, branching on the **positively identified**
    /// format and the chain's curve:
    ///
    /// - 64-char hex (with or without `0x`) → 32 raw key bytes
    ///   (secp256k1 scalar or ed25519 seed, per the chain).
    /// - Bitcoin-family WIF → base58check decode, verify the chain's
    ///   version byte, drop it plus the optional `0x01` compression
    ///   flag → 32 raw secp256k1 bytes.
    /// - Solana base58 secret → base58 decode; a 64-byte secret yields
    ///   its first 32 bytes (the ed25519 seed), a 32-byte secret is
    ///   the seed itself.
    /// - XRP family seeds (`s…`) use the XRPL base58 alphabet, which
    ///   WalletCore's `Base58` (Bitcoin alphabet) cannot decode —
    ///   throws `.invalidFormat` honestly rather than deriving garbage.
    ///
    /// Throws `KeyImportError.invalidFormat` for anything that cannot
    /// be positively identified for the chain. Never returns bytes of
    /// an unidentified encoding.
    static func decodePrivateKeyBytes(
        _ raw: String,
        on chain: SupportedChain
    ) throws -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let format = StubKeyImportService().detectFormat(trimmed, on: chain) else {
            throw KeyImportError.invalidFormat
        }

        switch format {
        case .evmHex, .cosmosHex, .ed25519Hex:
            let bodyHex = trimmed.hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
            guard let keyData = Data(hexString: bodyHex), keyData.count == 32 else {
                throw KeyImportError.invalidFormat
            }
            return keyData

        case .bitcoinWIF:
            guard let expectedVersion = wifVersionByte[chain] else {
                throw KeyImportError.invalidFormat
            }
            // `WalletCore.Base58.decode` is base58check — it verifies
            // the 4-byte double-SHA256 checksum and returns the payload
            // without it. (Qualified: the project's own `Base58` enum in
            // Brand/ is a plain decoder with no checksum verification.)
            guard let payload = WalletCore.Base58.decode(string: trimmed) else {
                throw KeyImportError.invalidFormat
            }
            // Payload: version byte + 32 key bytes [+ 0x01 compression flag].
            let isUncompressed = payload.count == 33
            let isCompressed = payload.count == 34 && payload.last == 0x01
            guard payload.first == expectedVersion, isUncompressed || isCompressed else {
                throw KeyImportError.invalidFormat
            }
            return Data(payload.dropFirst().prefix(32))

        case .solanaBase58:
            // `solanaBase58` is a shape heuristic shared by the whole
            // ed25519 family; only Solana actually uses raw base58
            // secrets. Stellar (StrKey) and Sui (bech32/base64) keys
            // must not be decoded as if they were Solana's.
            guard chain == .solana,
                  let decoded = WalletCore.Base58.decodeNoCheck(string: trimmed) else {
                throw KeyImportError.invalidFormat
            }
            if decoded.count == 64 {
                // 64-byte secret = 32-byte ed25519 seed + 32-byte public key.
                return Data(decoded.prefix(32))
            }
            if decoded.count == 32 {
                return decoded
            }
            throw KeyImportError.invalidFormat

        case .xrpSeed:
            // XRPL `s…` seeds use Ripple's own base58 alphabet;
            // WalletCore exposes no decoder for it. Refuse honestly.
            throw KeyImportError.invalidFormat

        case .extendedPublicKey, .unknown:
            throw KeyImportError.invalidFormat
        }
    }

    func validateAddress(_ raw: String, on chain: SupportedChain) -> Bool {
        guard let coinId = Self.coinIdForChain[chain],
              let coin = CoinType(rawValue: coinId) else {
            return false
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return coin.validate(address: trimmed)
    }

    /// Number of external-chain receive addresses derived from a watch-only
    /// extended public key for the review screen / scanner.
    private static let extendedKeyAddressCount = 5

    /// Real extended-public-key (xpub / ypub / zpub) → first N receive
    /// addresses, via WalletCore (`HDWallet.getPublicKeyFromExtended` +
    /// `DerivationPath`), replacing the old `[STUB …]` placeholder fallback
    /// (2026-06-18, T-024 closure). The version-byte prefix selects BOTH the
    /// BIP purpose AND the receive-script type — `xpub` → 44' legacy P2PKH,
    /// `ypub` → 49' P2SH-wrapped SegWit, `zpub` → 84' native SegWit — so the
    /// derived addresses match exactly what Bitcoin Core / Electrum / Trust
    /// Wallet show for the same key. Public-key-only: only the non-hardened
    /// external chain (`.../0/i`) is reachable, which is exactly the receive
    /// path. Watch-only (no signing), so this can never move funds — a wrong
    /// key throws an honest error instead of inventing an address (Rule #16).
    func deriveAddresses(
        fromExtendedKey raw: String,
        on chain: SupportedChain
    ) async throws -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the Bitcoin family has extended public keys.
        guard chain.supportsExtendedPublicKey,
              let coinId = Self.coinIdForChain[chain],
              let coin = CoinType(rawValue: coinId) else {
            throw KeyImportError.unsupported
        }
        // Prefix → BIP purpose. Covers the standard mainnet version bytes for
        // BTC (x/y/z) and the LTC variants (Ltub/Mtub) that share the family.
        let purpose: Purpose
        switch String(trimmed.prefix(4)).lowercased() {
        case "xpub", "ltub", "dgub": purpose = .bip44   // legacy P2PKH
        case "ypub", "mtub":         purpose = .bip49   // P2SH-wrapped SegWit
        case "zpub":                 purpose = .bip84   // native SegWit
        default:                     throw KeyImportError.invalidFormat
        }
        var addresses: [String] = []
        for index in 0..<Self.extendedKeyAddressCount {
            let path = DerivationPath(
                purpose: purpose,
                coin: coin.slip44Id,
                account: 0,
                change: 0,
                address: UInt32(index)
            ).description
            guard let pubkey = HDWallet.getPublicKeyFromExtended(
                extended: trimmed, coin: coin, derivationPath: path
            ) else {
                // Malformed / wrong-network key, or a path the key can't reach.
                throw KeyImportError.invalidFormat
            }
            let address: String
            switch purpose {
            case .bip44:
                guard let addr = BitcoinAddress(publicKey: pubkey, prefix: coin.p2pkhPrefix) else {
                    throw KeyImportError.invalidFormat
                }
                address = addr.description
            case .bip49:
                address = BitcoinAddress.compatibleAddress(
                    publicKey: pubkey, prefix: coin.p2shPrefix
                ).description
            default: // .bip84 (native SegWit) — the coin's default encoder
                address = coin.deriveAddressFromPublicKey(publicKey: pubkey)
            }
            addresses.append(address)
        }
        guard !addresses.isEmpty else { throw KeyImportError.invalidFormat }
        return addresses
    }

    func deriveAddresses(fromSeed seed: Data) async throws -> [SupportedChain: String] {
        // Legacy seed-based API. WalletCore wants the mnemonic, not
        // the seed, so this throws. Mnemonic import now calls the
        // mnemonic-based API directly during commit; this method is kept
        // only for source compatibility.
        throw KeyImportError.unsupported
    }
}

struct MnemonicExtendedPublicKeys: Equatable, Sendable {
    let bitcoin: ChainExtendedPublicKey
    let ethereum: ChainExtendedPublicKey
}

struct ChainExtendedPublicKey: Equatable, Sendable {
    let chain: SupportedChain
    let derivationPath: String
    let xpub: String
}

enum MnemonicExtendedPublicKeyDerivationError: Error, Hashable, Sendable {
    case invalidMnemonic
    case derivationFailed(SupportedChain)
}

enum MnemonicExtendedPublicKeyDeriver {
    /// Derives account-level BIP-44 extended public keys from one BIP-39
    /// mnemonic. Ethereum does not have a chain-specific xpub prefix; this is
    /// the standard BIP-32 xpub for account `m/44'/60'/0'`.
    static func derive(
        fromMnemonic phrase: String,
        passphrase: String = ""
    ) throws -> MnemonicExtendedPublicKeys {
        try derive(
            mnemonic: phrase.split(whereSeparator: \.isWhitespace).map(String.init),
            passphrase: passphrase
        )
    }

    static func derive(
        mnemonic words: [String],
        passphrase: String = ""
    ) throws -> MnemonicExtendedPublicKeys {
        let phrase = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let wallet = HDWallet(mnemonic: phrase, passphrase: passphrase) else {
            throw MnemonicExtendedPublicKeyDerivationError.invalidMnemonic
        }

        return MnemonicExtendedPublicKeys(
            bitcoin: try accountXPub(
                wallet: wallet,
                chain: .bitcoin,
                coin: .bitcoin,
                path: "m/44'/0'/0'"
            ),
            ethereum: try accountXPub(
                wallet: wallet,
                chain: .ethereum,
                coin: .ethereum,
                path: "m/44'/60'/0'"
            )
        )
    }

    private static func accountXPub(
        wallet: HDWallet,
        chain: SupportedChain,
        coin: CoinType,
        path: String
    ) throws -> ChainExtendedPublicKey {
        let xpub = wallet.getExtendedPublicKey(
            purpose: .bip44,
            coin: coin,
            version: .xpub
        )
        guard !xpub.isEmpty else {
            throw MnemonicExtendedPublicKeyDerivationError.derivationFailed(chain)
        }
        return ChainExtendedPublicKey(
            chain: chain,
            derivationPath: path,
            xpub: xpub
        )
    }
}

// MARK: - Hex decoding helper (file-private)

private extension Data {
    /// Decode a hex string (with or without "0x" prefix, case-
    /// insensitive). Returns `nil` for non-hex characters or odd
    /// length. Used by `deriveAddress(fromPrivateKey:on:)` for the
    /// EVM hex / ed25519 hex paths.
    init?(hexString: String) {
        let cleaned = hexString.hasPrefix("0x")
            ? String(hexString.dropFirst(2))
            : hexString
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
