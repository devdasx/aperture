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
/// — never persisted to `@GRDBStorage`, never written to GRDB in this
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

    /// Set when CSPRNG entropy fails (P3-006). UI must refuse Continue.
    private(set) var generationFailed: Bool = false

    /// Stable identifier for the wallet being created. Generated once
    /// at construction so the same UUID flows through wallet-secret rows
    /// and `WalletRepository.insertCreatedWallet`. If the user regenerates
    /// the phrase (word-count change or Roll your own commit), this id is
    /// rolled too — a different phrase is a different wallet identity, even
    /// before persistence.
    private(set) var pendingWalletId: UUID = UUID()

    init(wordCount: BIP39WordCount = .twelve) {
        self.wordCount = wordCount
        self.passphrase = ""
        // P3-006: never invent a zero-entropy phrase on CSPRNG failure.
        if let generated = try? BIP39.generateMnemonic(wordCount: wordCount) {
            self.words = generated
            self.generationFailed = false
        } else {
            self.words = []
            self.generationFailed = true
        }
    }

    /// Build directly from an **already-known** phrase, WITHOUT drawing fresh
    /// entropy. Used by the backup-verify challenge, which only needs `words`
    /// to build its cards — `generateMnemonic` there would be pure waste and
    /// (when done lazily on navigation) caused a stuck "Preparing…" screen.
    /// Setting `wordCount` in `init` does not fire its `didSet`, so no
    /// regeneration happens. Instant by construction. (2026-06-20 fix.)
    init(words: [String]) {
        self.wordCount = words.count == 24 ? .twentyFour : .twelve
        self.passphrase = ""
        self.words = words
    }

    /// Discards the current mnemonic and draws a fresh one from CSPRNG
    /// entropy. Called automatically when `wordCount` changes; safe to
    /// call externally for "Show me a new phrase" flows.
    ///
    /// Also rolls `pendingWalletId` because a different phrase is a
    /// different wallet identity. If we kept the same id, a regenerated
    /// phrase could land in the old seed row — fine mechanically but
    /// conceptually wrong, and would give the new wallet the createdAt
    /// of the old one if the `WalletRecord` was already persisted.
    func regenerate() {
        if let generated = try? BIP39.generateMnemonic(wordCount: wordCount) {
            words = generated
            generationFailed = false
        } else {
            words = []
            generationFailed = true
        }
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
    /// seed and the encrypted mnemonic now live in GRDB; the
    /// plaintext words and passphrase have no reason to outlive the
    /// flow. Called by `WalletReadyView` after a successful
    /// `persist(into:requiresBackup:)`, before the PIN flow.
    func zeroSensitiveState() {
        words = []
        passphrase = ""
    }

    /// Persist this wallet end-to-end: encrypt + store the 64-byte
    /// seed, mnemonic, wallet metadata, and addresses via the supplied
    /// `WalletCommandRepository`. The repository writes them in one GRDB
    /// transaction, so there is no split secret/database state to roll back.
    ///
    /// - parameters:
    ///   - repository: a GRDB-backed `WalletCommandRepository`.
    ///   - requiresBackup: `true` when the user reached this method via
    ///     the skip-backup branch (they have not yet verified the
    ///     phrase). Used to set the `WalletRecord.requiresBackup`
    ///     flag so Settings → Wallets later surfaces a "back up now"
    ///     row (T-016).
    /// - returns: the persisted wallet's UUID (same as
    ///   `pendingWalletId`).
    /// - throws: Any database error if the row insert fails. Caller surfaces
    ///   the error via the wallet-ready screen's error state.
    @discardableResult
    func persist(
        into repository: WalletCommandRepository,
        requiresBackup: Bool,
        manualBackup: Bool = false,
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

        // Derive a per-chain address for every supported chain via
        // Trust Wallet Core (same library + paths Trust Wallet uses),
        // then write the WalletRecord + WalletAddressRecord rows in
        // one transaction. Previously the create path inserted only
        // the wallet metadata — Receive / WalletHome / refresh all
        // read addresses from `WalletAddressRecord`, so the user saw
        // an empty wallet with "No addresses available for this
        // wallet yet" until they re-imported. With this step the
        // new wallet has its 24-chain address set in GRDB before
        // `persist(...)` returns.
        let service = WalletCoreKeyImportService()
        let derivedAddresses = await service.deriveAddresses(
            mnemonic: lowercasedWords,
            passphrase: passphrase
        )
        // Defensive: a freshly app-generated mnemonic always derives the full
        // address set, so this never fires in practice — but never persist a
        // zero-address wallet. Fail loud rather than leaving an addressless wallet the user
        // can't receive into. (Mirrors the same guard on the import path.)
        guard !derivedAddresses.isEmpty else {
            throw KeyImportError.derivationFailed
        }
        // Phantom + Trust account-0 Solana paths both land in GRDB so the
        // home scanner balances both; only `is_receive_preferred` is used
        // for send/receive (Phantom preferred by insert order).
        let addressEntries = SolanaPathProvisioning.expandAddressEntries(
            derivedByChain: derivedAddresses,
            words: lowercasedWords,
            passphrase: passphrase
        )

        try await repository.insertCreatedWallet(
            id: walletId,
            name: resolvedName,
            mnemonicWordCount: wordCount.rawValue,
            hasPassphrase: !passphrase.isEmpty,
            colorTag: "default",
            requiresBackup: requiresBackup,
            manualBackupCompleted: manualBackup,
            seedData: seed,
            mnemonicWords: lowercasedWords,
            addresses: addressEntries
        )

        // The wallet is now fully persisted in SQLite: seed, mnemonic,
        // metadata, addresses, and per-chain encrypted key blobs.
        // Make it the active wallet immediately so the user lands
        // on it after WalletReadyView and so the refresh coordinator
        // starts pulling balances/history/tokens for it. Persisted
        // via the same `"activeWalletId"` GRDB preference key the
        // wallet-home + settings + receive views read via
        // `@GRDBStorage`. Writing here keeps the contract centralized:
        // anything that successfully runs `persist(...)` becomes
        // active, without each caller needing to remember.
        ActiveWalletPointer.set(walletId)
        return walletId
    }
}
