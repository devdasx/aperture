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
    func regenerate() {
        words = BIP39.generateMnemonic(wordCount: wordCount)
    }

    /// Derives the 64-byte BIP-39 seed from the current mnemonic +
    /// passphrase, per spec §6 (PBKDF2-HMAC-SHA512, 2048 iterations). The
    /// seed is the real root of the HD key tree.
    ///
    /// Called lazily by the verification flow once the user has proven
    /// they wrote the phrase down. The result is **not** cached or
    /// persisted in this pass — Keychain storage is T-012. The function
    /// is here (rather than buried in a future `WalletService`) so the
    /// passphrase entered in `PassphraseSheet` is honestly consumed
    /// today, not silently dropped on the floor.
    func deriveSeed() -> Data {
        BIP39.deriveSeed(words: words, passphrase: passphrase)
    }
}
