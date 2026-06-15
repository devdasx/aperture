import Foundation
import WalletCore

/// Resolves the wallet-core `PrivateKey` for a `(wallet, chain)` pair —
/// AT SIGN TIME ONLY — from the on-device secret in `MnemonicVault`.
///
/// **Why this exists / how it maps onto the proven pattern.** This is
/// the Aperture analogue of Stabro's `KeyManager.signTransaction(...)`
/// key-access path (`HDWallet(mnemonic:passphrase:) → getKeyForCoin`)
/// and is structurally identical to the app's already-shipped
/// `EVMDAppSigner` custody path. The derivation matches
/// `WalletCoreKeyImportService` EXACTLY (same `HDWallet`, same
/// `CoinType` via `ChainCoinType`, same `getKeyForCoin`) so the key the
/// signer uses always corresponds to the address the importer derived
/// and the user funded — key↔address parity is the whole point.
///
/// **SECURITY POSTURE (the contract this file is judged on).**
/// 1. Keys are produced ONLY inside `withPrivateKey(...)`'s closure and
///    dropped the instant it returns. Nothing here stores, caches, or
///    returns a `PrivateKey`/`HDWallet`/mnemonic/seed beyond that scope.
/// 2. NOTHING key-, mnemonic-, seed-, or signature-shaped is ever
///    logged (`print`/`os_log`/`AppLogger`). The only strings that may
///    appear in an error are addresses (public) and chain names.
/// 3. The `HDWallet` (a C++-backed reference type, not `Sendable`) is
///    constructed and consumed inside the SAME synchronous closure —
///    it never crosses an isolation boundary.
/// 4. Watch-only and (where the secret is gone) backed-up wallets get a
///    typed refusal (`.walletCannotSign` / `.secretUnavailable`) — never
///    a fabricated key.
/// 5. A BIP-39 passphrase is never persisted (schema contract — see
///    `WalletRecord.hasPassphrase`). Deriving with `""` would produce a
///    DIFFERENT key → a wrong-address signature → unrecoverable funds.
///    So a passphrase wallet refuses with `.secretUnavailable` UNLESS
///    the caller supplies the passphrase (the future T-019 prompt).
///
/// `enum` with only static members — no instance state to leak.
enum SigningKeyProvider {

    /// Run `body` with the freshly-derived `PrivateKey` for
    /// `(wallet, chain)`. The key (and the `HDWallet`/mnemonic it came
    /// from) live ONLY for the duration of `body` and drop at return.
    ///
    /// - Parameters:
    ///   - wallet: the persisted wallet record (resolved by the caller).
    ///   - chain: the target chain (selects the `CoinType` / curve).
    ///   - passphrase: the BIP-39 passphrase when the caller has it
    ///     (the T-019 prompt). `nil` means "not supplied"; a wallet with
    ///     `hasPassphrase == true` then refuses rather than derive a
    ///     wrong key.
    ///   - expectedAddress: when non-nil, the derived key's address for
    ///     this chain MUST equal it (key↔address parity) or the call
    ///     throws `.keyAddressMismatch` and never signs.
    ///   - body: receives the live `PrivateKey`; its return value is
    ///     forwarded. Make this the smallest possible scope — typically
    ///     just the `AnySigner.sign(...)` call.
    ///
    /// `nonisolated` + sync: callers run it inside a `Task.detached` /
    /// `@concurrent` so the PBKDF2 seed stretch + secp256k1/ed25519 sign
    /// stays off the main thread (Rule #28). The closure is `rethrows`
    /// so a `body` that throws `SigningError` propagates cleanly under
    /// typed throws.
    static func withPrivateKey<R>(
        wallet: WalletDescriptor,
        chain: SupportedChain,
        passphrase: String? = nil,
        expectedAddress: String?,
        _ body: (PrivateKey) throws -> R
    ) throws -> R {
        guard let coin = ChainCoinType.coinType(for: chain) else {
            throw SigningError.unsupportedCoin(chain)
        }

        switch wallet.kind {
        case .created, .importedMnemonic:
            return try withMnemonicKey(
                wallet: wallet, chain: chain, coin: coin,
                passphrase: passphrase, expectedAddress: expectedAddress, body
            )
        case .importedKey:
            return try withImportedKey(
                wallet: wallet, chain: chain, coin: coin,
                expectedAddress: expectedAddress, body
            )
        case .watchOnly:
            throw SigningError.walletCannotSign
        }
    }

    // MARK: - Mnemonic-backed wallets

    private static func withMnemonicKey<R>(
        wallet: WalletDescriptor,
        chain: SupportedChain,
        coin: CoinType,
        passphrase: String?,
        expectedAddress: String?,
        _ body: (PrivateKey) throws -> R
    ) throws -> R {
        // A passphrase-protected wallet derived its addresses WITH the
        // passphrase, which we never persist. Signing with "" would use
        // the wrong key. Refuse unless the caller supplied it.
        let resolvedPassphrase: String
        if wallet.hasPassphrase {
            guard let supplied = passphrase else {
                throw SigningError.secretUnavailable
            }
            resolvedPassphrase = supplied
        } else {
            // No-passphrase wallet: derive with "" (matches the importer
            // and the schema contract). Ignore any stray supplied value.
            resolvedPassphrase = passphrase ?? ""
        }

        // Load the mnemonic from the vault. A backed-up wallet keeps
        // only the derived seed on device; the phrase is gone by design.
        let words = (try? MnemonicVault.loadMnemonic(for: wallet.id)) ?? nil
        guard let words, !words.isEmpty else {
            throw SigningError.secretUnavailable
        }

        guard let hdWallet = HDWallet(
            mnemonic: words.joined(separator: " "),
            passphrase: resolvedPassphrase
        ) else {
            throw SigningError.invalidMnemonic
        }

        // Bitcoin family: the recipient/own UTXOs may sit on several
        // derived addresses (receive + change, multiple indices), so the
        // signer needs ALL the candidate keys — handled by the dedicated
        // Bitcoin path below. For a single-key request (EVM + the
        // account-model default), the coin's default-path key is what
        // the importer used.
        let privateKey = hdWallet.getKeyForCoin(coin: coin)
        try assertParity(privateKey: privateKey, coin: coin, expected: expectedAddress, chain: chain)
        return try body(privateKey)
        // `hdWallet`, `words`, and `privateKey` go out of scope here.
    }

    // MARK: - Single-private-key wallets

    private static func withImportedKey<R>(
        wallet: WalletDescriptor,
        chain: SupportedChain,
        coin: CoinType,
        expectedAddress: String?,
        _ body: (PrivateKey) throws -> R
    ) throws -> R {
        // The original imported key string (hex / WIF / base58) is
        // preserved in the vault; decode it to raw bytes for THIS chain
        // exactly the way the importer did (format- and chain-aware).
        let keyString = (try? MnemonicVault.loadPrivateKey(for: wallet.id)) ?? nil
        guard let keyString, !keyString.isEmpty else {
            throw SigningError.secretUnavailable
        }
        guard let keyData = try? WalletCoreKeyImportService.decodePrivateKeyBytes(keyString, on: chain),
              PrivateKey.isValid(data: keyData, curve: coin.curve),
              let privateKey = PrivateKey(data: keyData) else {
            throw SigningError.invalidPrivateKey
        }
        try assertParity(privateKey: privateKey, coin: coin, expected: expectedAddress, chain: chain)
        return try body(privateKey)
    }

    // MARK: - Bitcoin-family multi-key access

    /// Derive every candidate key whose address appears in
    /// `requiredAddresses` (the addresses owning the selected UTXOs).
    /// Bitcoin-family UTXOs may sit on the receive chain (`…/0/i`) and
    /// the change chain (`…/1/i`) across several indices; wallet-core's
    /// signer needs the key for each input's address. Mirrors Stabro's
    /// `KeyManager.signTransaction`'s Bitcoin branch (derive `0/i` +
    /// `1/i` until every UTXO address is covered).
    ///
    /// Same security scope as `withPrivateKey`: every key lives only
    /// inside `body` and drops at return; nothing is logged or retained.
    /// For imported single-key Bitcoin wallets, the lone key is used.
    static func withBitcoinKeys<R>(
        wallet: WalletDescriptor,
        chain: SupportedChain,
        passphrase: String? = nil,
        requiredAddresses: Set<String>,
        _ body: ([PrivateKey]) throws -> R
    ) throws -> R {
        guard let coin = ChainCoinType.coinType(for: chain) else {
            throw SigningError.unsupportedCoin(chain)
        }
        guard chain.family == .bitcoin else {
            throw SigningError.malformedDraft("Bitcoin key path used for non-Bitcoin chain \(chain.rawValue)")
        }

        switch wallet.kind {
        case .importedKey:
            return try withImportedKey(
                wallet: wallet, chain: chain, coin: coin,
                expectedAddress: nil
            ) { try body([$0]) }

        case .created, .importedMnemonic:
            let resolvedPassphrase: String
            if wallet.hasPassphrase {
                guard let supplied = passphrase else { throw SigningError.secretUnavailable }
                resolvedPassphrase = supplied
            } else {
                resolvedPassphrase = passphrase ?? ""
            }
            let words = (try? MnemonicVault.loadMnemonic(for: wallet.id)) ?? nil
            guard let words, !words.isEmpty else { throw SigningError.secretUnavailable }
            guard let hdWallet = HDWallet(
                mnemonic: words.joined(separator: " "),
                passphrase: resolvedPassphrase
            ) else {
                throw SigningError.invalidMnemonic
            }

            var keys: [PrivateKey] = []
            var covered: Set<String> = []
            let purpose = bitcoinPurpose(for: chain)
            let coinId = bitcoinSlip44(for: chain)

            // Receive chain (0) then change chain (1); scan a generous
            // gap so every selected UTXO address is covered. The default
            // single key (the coin's default address) is added first so
            // a wallet that only ever used its primary address signs
            // even if the per-path scan misses an unusual derivation.
            let defaultKey = hdWallet.getKeyForCoin(coin: coin)
            let defaultAddr = coin.deriveAddress(privateKey: defaultKey)
            keys.append(defaultKey)
            covered.insert(defaultAddr)

            for branch in 0...1 {
                for index in 0..<25 {
                    if requiredAddresses.isSubset(of: covered) { break }
                    let path = "m/\(purpose)'/\(coinId)'/0'/\(branch)/\(index)"
                    let key = hdWallet.getKey(coin: coin, derivationPath: path)
                    let addr = coin.deriveAddress(privateKey: key)
                    if covered.insert(addr).inserted {
                        keys.append(key)
                    }
                }
                if requiredAddresses.isSubset(of: covered) { break }
            }

            // Honest parity guard: every UTXO's owning address must be
            // one we can sign for; otherwise the signer would silently
            // drop an input or wallet-core would reject the tx.
            let uncovered = requiredAddresses.subtracting(covered)
            guard uncovered.isEmpty else {
                throw SigningError.keyAddressMismatch(
                    expected: uncovered.sorted().joined(separator: ","),
                    derived: ""
                )
            }
            return try body(keys)

        case .watchOnly:
            throw SigningError.walletCannotSign
        }
    }

    // MARK: - Key↔address parity

    /// Verify the derived key produces `expected` for `coin`. The whole
    /// safety reason this provider exists: never sign with a key whose
    /// public address isn't the wallet's funded address. EVM addresses
    /// compare case-insensitively (EIP-55 is display-only); everything
    /// else compares exactly.
    private static func assertParity(
        privateKey: PrivateKey,
        coin: CoinType,
        expected: String?,
        chain: SupportedChain
    ) throws {
        guard let expected, !expected.isEmpty else { return }
        let derived = coin.deriveAddress(privateKey: privateKey)
        let matches: Bool = chain.family == .evm
            ? derived.lowercased() == expected.lowercased()
            : derived == expected
        guard matches else {
            throw SigningError.keyAddressMismatch(expected: expected, derived: derived)
        }
    }

    // MARK: - Bitcoin-family BIP purpose / SLIP-44

    /// BIP purpose number per Bitcoin-family chain — the importer +
    /// wallet-core default-address path: BTC/LTC = BIP-84 (native
    /// SegWit), BCH/DOGE = BIP-44 (legacy P2PKH, no SegWit). Matches
    /// `HDKeyDerivation.derivationPath` in the reference + the matrix.
    private static func bitcoinPurpose(for chain: SupportedChain) -> Int {
        switch chain {
        case .bitcoin, .litecoin: return 84
        case .bitcoinCash, .dogecoin: return 44
        default: return 84
        }
    }

    /// SLIP-44 coin index for the Bitcoin-family derivation path.
    private static func bitcoinSlip44(for chain: SupportedChain) -> Int {
        switch chain {
        case .bitcoin: return 0
        case .litecoin: return 2
        case .dogecoin: return 3
        case .bitcoinCash: return 145
        default: return 0
        }
    }
}

/// A `Sendable` snapshot of the wallet fields the signer needs, so the
/// `SendExecutor` can resolve the wallet on the main actor (SwiftData)
/// and hand a value type to the off-main signing path — `WalletRecord`
/// (a SwiftData `@Model`) is main-actor-bound and not `Sendable`.
struct WalletDescriptor: Sendable, Hashable {
    let id: UUID
    let kind: WalletKind
    let hasPassphrase: Bool

    init(id: UUID, kind: WalletKind, hasPassphrase: Bool) {
        self.id = id
        self.kind = kind
        self.hasPassphrase = hasPassphrase
    }

    /// Build from a persisted record (call on the main actor where the
    /// record lives; the resulting value is `Sendable`).
    init(record: WalletRecord) {
        self.id = record.id
        self.kind = record.kind
        self.hasPassphrase = record.hasPassphrase
    }
}
