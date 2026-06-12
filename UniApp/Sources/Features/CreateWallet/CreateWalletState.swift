import Foundation
import SwiftUI

/// Observable state for the entire create-wallet flow. Owns the generated
/// mnemonic, the user's word-count preference, and the (optional) BIP-39
/// passphrase. Lives as `@State` on `OnboardingView` and is passed down
/// through `RecoveryPhraseFlow` so the same instance backs every screen
/// in the cover.
///
/// **Why one model.** The mnemonic and the passphrase must agree across
/// the recovery-phrase view, the passphrase sheet, and the verification
/// view. A single observable container removes the synchronisation
/// problem entirely.
///
/// **Concurrency.** `@MainActor` because every consumer is a SwiftUI view.
/// `@Observable` (Swift 6.2 macro) per `CLAUDE.md` Rule #3's
/// `ObservableObject`-is-banned-in-this-project list.
///
/// **Passphrase storage.** The `passphrase` field lives **in memory only**
/// — never persisted to `@AppStorage`, never written to Keychain in this
/// pass (`T-019`). When the cover dismisses, the entire state instance is
/// released and the passphrase is gone. The future seed-derivation step
/// (`T-012`) is what consumes mnemonic + passphrase together via
/// PBKDF2-HMAC-SHA512 to produce the 64-byte BIP-39 seed; the passphrase
/// is never persisted because BIP-39 spec defines it as a memorised
/// "25th word" that the user is responsible for.
@MainActor
@Observable
final class CreateWalletState {
    /// User-selected mnemonic length (12 or 24 words). Default 12 — the
    /// industry norm for self-custody wallets and the BIP-39 security
    /// floor (128 bits of entropy). Changing this value regenerates the
    /// mnemonic immediately so the displayed phrase always matches the
    /// chosen length.
    var wordCount: BIP39WordCount {
        didSet {
            guard oldValue != wordCount else { return }
            regenerate()
        }
    }

    /// Optional BIP-39 passphrase ("25th word"). In-memory only. The user
    /// is responsible for remembering it — Aperture does not store it.
    var passphrase: String

    /// The currently displayed BIP-39 mnemonic.
    private(set) var words: [String]

    /// Stable identifier for the wallet being created. Generated once
    /// at construction so the same UUID flows through `SeedVault.storeSeed`
    /// and `WalletRepository.insertCreatedWallet`. If the user regenerates
    /// the phrase (screenshot warning → "Generate new phrase", Roll your
    /// own commit), this id is rolled too — a different phrase is a
    /// different wallet identity, even before persistence.
    private(set) var pendingWalletId: UUID = UUID()

    init(wordCount: BIP39WordCount = .twelve) {
        self.wordCount = wordCount
        self.passphrase = ""
        self.words = BIP39.generateMnemonic(wordCount: wordCount)
    }

    /// Discards the current mnemonic and draws a fresh one from CSPRNG
    /// entropy. Called automatically when `wordCount` changes; safe to
    /// call externally for "Show me a new phrase" flows in the future
    /// (used by the screenshot-warning sheet's "Generate new phrase"
    /// CTA — the screenshot of the previous phrase is then a screenshot
    /// of an invalidated wallet).
    ///
    /// Also rolls `pendingWalletId` because a different phrase is a
    /// different wallet identity. If we kept the same id, the
    /// screenshot-of-a-now-invalidated-phrase scenario would land in
    /// `SeedVault` overwriting the old seed under the same Keychain
    /// account — fine for storage but conceptually wrong, and would
    /// give the new wallet the createdAt of the old one if the
    /// `WalletRecord` was already persisted.
    func regenerate() {
        words = BIP39.generateMnemonic(wordCount: wordCount)
        pendingWalletId = UUID()
    }

    /// Replace the displayed words with a user-supplied mnemonic
    /// (e.g. one derived from the "Roll your own" dice / coin / hex
    /// flow). The caller is responsible for ensuring the words are a
    /// valid BIP-39 mnemonic of the matching word count; the typical
    /// caller is `EntropyEncoder.mnemonic(from:mode:wordCount:)` which
    /// goes through `BIP39.mnemonic(fromEntropy:)` and so produces a
    /// spec-correct phrase by construction. Also zeroes any passphrase
    /// because a passphrase combined with a new mnemonic produces a
    /// wallet the user never explicitly chose — anything else would
    /// be dishonest. Same `pendingWalletId` roll as `regenerate()`.
    func commit(words newWords: [String]) {
        words = newWords
        passphrase = ""
        pendingWalletId = UUID()
    }

    /// Derives the 64-byte BIP-39 seed from the supplied mnemonic +
    /// passphrase, per spec §6 (PBKDF2-HMAC-SHA512, 2048 iterations).
    /// The seed is the real root of the HD key tree. The function is
    /// here so the passphrase entered in `PassphraseSheet` is honestly
    /// consumed via PBKDF2, not silently dropped on the floor.
    ///
    /// Runs **off the main actor**: the class is `@MainActor`, and the
    /// 2048 sequential HMAC-SHA512 iterations would otherwise stall
    /// the UI thread mid-`persist` — exactly while `WalletReadyView`
    /// is animating in. Mirrors `ImportWalletState.deriveSeedOffMain`.
    nonisolated private static func deriveSeedOffMain(
        words: [String],
        passphrase: String
    ) async -> Data {
        await Task.detached(priority: .userInitiated) {
            BIP39.deriveSeed(words: words, passphrase: passphrase)
        }.value
    }

    /// Wipe the in-memory secrets once persistence has succeeded. The
    /// seed and the encrypted mnemonic now live in Keychain; the
    /// plaintext words and passphrase have no reason to outlive the
    /// flow. Called by `WalletReadyView` after a successful
    /// `persist(into:requiresBackup:)`, before the PIN flow.
    func zeroSensitiveState() {
        words = []
        passphrase = ""
    }

    /// Persist this wallet end-to-end: encrypt + store the 64-byte
    /// seed in `SeedVault` (Keychain), then insert the `WalletRecord`
    /// (SwiftData) via the supplied `WalletRepository`. Both writes are
    /// gated on each other — if the Keychain write fails, the database
    /// row is not inserted (the seed is the wallet; there's no point
    /// storing metadata for a wallet whose key material we couldn't
    /// save). If the database write fails after Keychain succeeded,
    /// the Keychain item is removed to leave consistent state.
    ///
    /// - parameters:
    ///   - repository: a `WalletRepository` bound to the app's
    ///     `ModelContainer` (typically built ad-hoc by the caller as
    ///     `WalletRepository(modelContainer: container)`).
    ///   - requiresBackup: `true` when the user reached this method via
    ///     the skip-backup branch (they have not yet verified the
    ///     phrase). Used to set the `WalletRecord.requiresBackup`
    ///     flag so Settings → Wallets later surfaces a "back up now"
    ///     row (T-016).
    /// - returns: the persisted wallet's UUID (same as
    ///   `pendingWalletId`).
    /// - throws: `SeedVault.VaultError` if Keychain refuses; any
    ///   SwiftData error if the row insert fails. Caller surfaces the
    ///   error via the wallet-ready screen's error state.
    @discardableResult
    func persist(
        into repository: WalletRepository,
        requiresBackup: Bool,
        defaultName: String? = nil
    ) async throws -> UUID {
        let walletId = pendingWalletId
        // Capture the inputs as values on-main, derive off-main.
        let seed = await Self.deriveSeedOffMain(
            words: words,
            passphrase: passphrase
        )

        // Compute a locale-aware, auto-numbered default name when
        // the caller didn't supply an explicit name. `String(localized:)`
        // resolves "Wallet" through the catalog (so a Russian user
        // sees "Кошелёк 2", an Arabic user sees "محفظة 2", etc.) and
        // the counter is `walletCount + 1` so a fresh install starts
        // at "Wallet 1" rather than just "Wallet".
        let resolvedName: String
        if let defaultName, !defaultName.isEmpty {
            resolvedName = defaultName
        } else {
            let existingCount = (try? await repository.walletCount()) ?? 0
            let prefix = String.apertureLocalized("Wallet")
            resolvedName = "\(prefix) \(existingCount + 1)"
        }

        // Canonical lowercase form of the phrase — BIP-39 words are
        // lowercase by definition, and derivation below consumes the
        // lowercased words. The stored mnemonic must match what was
        // derived from, byte for byte.
        let lowercasedWords = words.map { $0.lowercased() }

        // Keychain first — if this fails, the database is untouched.
        try SeedVault.storeSeed(seed, for: walletId)

        // ALWAYS store the mnemonic in `MnemonicVault` so the user
        // can re-view it from Settings → Wallets → "View recovery
        // phrase" at any time. The vault uses AES-GCM 256-bit with
        // the per-wallet symmetric key in Keychain under
        // `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` — the
        // phrase is encrypted at rest, accessible only when the
        // device is unlocked, and never leaves the iPhone. The
        // earlier contract (delete after backup verification) was
        // contrary to the user's mental model: a self-custody
        // wallet you re-imported on a new device should be able to
        // show you the phrase you typed in. The encrypted local
        // copy is the honest extension of "your iPhone is your
        // wallet". User deletion / Reset Aperture still wipes the
        // entry per `WalletDetailView.deleteWallet` and
        // `AdvancedSettingsView.resetAperture`.
        do {
            try MnemonicVault.storeMnemonic(lowercasedWords, for: walletId)
        } catch {
            try? SeedVault.deleteSeed(for: walletId)
            throw error
        }

        // Derive a per-chain address for every supported chain via
        // Trust Wallet Core (same library + paths Trust Wallet uses),
        // then write the WalletRecord + WalletAddressRecord rows in
        // one transaction. Previously the create path inserted only
        // the wallet metadata — Receive / WalletHome / refresh all
        // read addresses from `WalletAddressRecord`, so the user saw
        // an empty wallet with "No addresses available for this
        // wallet yet" until they re-imported. With this step the
        // new wallet has its 24-chain address set on disk before
        // `persist(...)` returns.
        let service = WalletCoreKeyImportService()
        let derivedAddresses = await service.deriveAddresses(
            mnemonic: lowercasedWords,
            passphrase: passphrase
        )
        let addressEntries: [(chainRaw: String, address: String)] =
            derivedAddresses.map { (chain, address) in
                (chainRaw: chain.rawValue, address: address)
            }

        // Database last. On failure, roll back both Keychain items
        // so we don't leave an orphaned seed or mnemonic.
        do {
            try await repository.insertCreatedWallet(
                id: walletId,
                name: resolvedName,
                mnemonicWordCount: wordCount.rawValue,
                hasPassphrase: !passphrase.isEmpty,
                colorTag: "default",
                requiresBackup: requiresBackup,
                addresses: addressEntries
            )
        } catch {
            try? SeedVault.deleteSeed(for: walletId)
            try? MnemonicVault.deleteMnemonic(for: walletId)
            throw error
        }

        // The wallet is now fully persisted (seed in Keychain,
        // mnemonic encrypted in Keychain, metadata in SwiftData).
        // Make it the active wallet immediately so the user lands
        // on it after WalletReadyView and so the refresh coordinator
        // starts pulling balances/history/tokens for it. Persisted
        // via the same `"activeWalletId"` UserDefaults key the
        // wallet-home + settings + receive views read via
        // `@AppStorage`. Writing here keeps the contract centralized:
        // anything that successfully runs `persist(...)` becomes
        // active, without each caller needing to remember.
        UserDefaults.standard.set(
            walletId.uuidString,
            forKey: "activeWalletId"
        )
        return walletId
    }
}
