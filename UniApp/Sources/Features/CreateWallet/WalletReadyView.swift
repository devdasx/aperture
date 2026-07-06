import SwiftUI
import OSLog

/// Terminal placeholder for the create-wallet flow, pushed onto the
/// cover's `NavigationStack` after `BackupVerifyView` succeeds.
///
/// **Intent (one sentence):** quietly acknowledge that the wallet exists
/// and hand the user back to the app, without theatre.
///
/// **What changed 2026-06-06.** This screen is now also the moment the
/// wallet is **persisted to the local database**. On appear, the view
/// runs `state.persist(into:requiresBackup:)` which encrypts and stores
/// the BIP-39 seed, mnemonic, and wallet rows via GRDB. The Done button is disabled until persistence
/// resolves so the user cannot dismiss with an unpersisted wallet. On
/// failure, the view surfaces an error footnote with a Retry button
/// rather than silently swallowing.
///
/// **No back navigation.** The verify step is final — once the user has
/// proven the phrase, they should land on the next surface, not be
/// able to wander back into a generation step. The system back button
/// is suppressed via `.navigationBarBackButtonHidden(true)`.
struct WalletReadyView: View {
    /// Shared mnemonic + passphrase state — same instance the cover
    /// has been threading through every screen. Needed here to call
    /// `state.persist(...)` once the user lands on the success screen.
    let state: CreateWalletState

    /// Set when the user reached this screen via the skip-backup
    /// branch. Threaded through to `WalletRecord.requiresBackup` so
    /// Settings → Wallets can surface a "back up your recovery phrase"
    /// row later (T-016).
    let requiresBackup: Bool

    /// `true` when the user reached this screen having completed a
    /// **manual** backup (write-down + verify) during creation. Threaded
    /// to `WalletRecord.manualBackupCompleted` so Settings → Wallet's
    /// manual-backup row is accurate for create-flow manual backups too,
    /// not just management ones (2026-06-20). Default `false` (iCloud
    /// backup or skip → manual not done).
    var manualBackup: Bool = false

    /// Fires when the user taps Done. The caller dismisses the
    /// `fullScreenCover` and clears the unbacked-up flag.
    let onDone: () -> Void

    private enum PersistState: Equatable {
        case idle
        case persisting
        case persisted
        case failed(String)
    }
    @State private var persistState: PersistState = .idle
    @State private var persistErrorReport: ApertureErrorReport?

    /// The in-flight persist task. Stored so Retry can cancel any
    /// previous launch before spawning a new one — two concurrent
    /// persists of the same wallet would race on GRDB writes.
    @State private var persistTask: Task<Void, Never>? = nil

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "wallet-ready"
    )

    var body: some View {
        Group {
            if case .failed(let message) = persistState {
                failureView(message)
            } else {
                // The SAME success screen as import (2026-06-20 user
                // direction), shown immediately — the wallet persists silently
                // in the background, so there is no "Saving your wallet…"
                // state. The card fills in from the screen's own GRDB observation as
                // the save lands; the CTA is gated until then so the user can
                // never leave onto a not-yet-saved wallet. The seal animation +
                // haptics are ImportSuccessView's, so create matches import.
                ImportSuccessView(
                    walletId: state.pendingWalletId,
                    result: .mnemonic,
                    onContinue: onDone,
                    isCreated: true,
                    isContinueEnabled: persistState == .persisted
                )
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { persistIfNeeded() }
    }

    /// Honest failure surface — shown ONLY if the background persist actually
    /// fails (rare). Keeps the diagnosable cause + Retry.
    @ViewBuilder
    private func failureView(_ message: String) -> some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 84, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Feedback.Error.foreground)
                .accessibilityHidden(true)
            VStack(spacing: UniSpacing.s) {
                UniLargeTitle(text: "Couldn't save your wallet.", alignment: .center)
                UniBody(
                    text: "Nothing was saved to this iPhone and your phrase isn't lost. Tap Retry to try again.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
            }
            .padding(.horizontal, UniSpacing.l)
            if let persistErrorReport {
                ApertureErrorSupportSection(report: persistErrorReport)
                    .padding(.horizontal, UniSpacing.l)
            }
            Spacer()
        }
        .uniBottomActionBar {
            VStack(spacing: UniSpacing.s) {
                UniFootnote(
                    text: LocalizedStringKey(message),
                    alignment: .center,
                    color: UniColors.Feedback.Error.foreground
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UniSpacing.m)
                UniButton(title: "Retry", variant: .primary) {
                    persistIfNeeded(force: true)
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.l)
        }
    }

    /// One-shot persistence kick. Idempotent — won't re-run if already
    /// persisting or persisted. Pass `force: true` from the Retry
    /// button to override the persisted-state guard. Re-entry safe:
    /// an in-flight persist always blocks a second launch (even a
    /// forced one), and the stored task is cancelled before a new
    /// one is spawned so retries can never run concurrently.
    private func persistIfNeeded(force: Bool = false) {
        guard persistState != .persisting else { return }
        if !force, persistState == .persisted { return }
        persistTask?.cancel()
        persistState = .persisting
        persistErrorReport = nil
        let repository = WalletCommandRepository()
        let requiresBackupFlag = requiresBackup
        let manualBackupFlag = manualBackup
        persistTask = Task { @MainActor in
            do {
                _ = try await state.persist(
                    into: repository,
                    requiresBackup: requiresBackupFlag,
                    manualBackup: manualBackupFlag
                )
                persistState = .persisted
                // The seed + encrypted mnemonic are in GRDB — wipe the
                // plaintext secrets before the user moves on. (The success
                // seal + its haptic are ImportSuccessView's, fired on appear,
                // so create matches import exactly.)
                state.zeroSensitiveState()
            } catch {
                Self.log.error(
                    "Create-wallet persist failed: \(String(describing: error), privacy: .public)"
                )
                let message = Self.failureMessage(for: error)
                persistErrorReport = ApertureErrorReport(
                    context: "Create wallet",
                    title: "Couldn't save your wallet",
                    message: message,
                    error: error,
                    recoverySuggestion: "Tap Retry. If it keeps failing, email support with the advanced details.",
                    metadata: [
                        "walletId": state.pendingWalletId.uuidString,
                        "requiresBackup": "\(requiresBackupFlag)",
                        "manualBackup": "\(manualBackupFlag)"
                    ]
                )
                persistState = .failed(message)
            }
        }
    }

    /// Turn the real persist error into an honest, diagnosable message.
    private static func failureMessage(for error: Error) -> String {
        if let vault = error as? SeedVault.VaultError {
            switch vault {
            case .invalidSeedLength:
                return String.apertureLocalized("The wallet's key material looked invalid. Tap Retry.")
            case .databaseWriteFailed(let detail), .databaseReadFailed(let detail), .databaseDeleteFailed(let detail):
                return String(format: String.apertureLocalized("Couldn't save your wallet to the database: %@. Tap Retry."), detail)
            default:
                return String.apertureLocalized("Couldn't save your wallet to the database. Tap Retry.")
            }
        }
        return String(format: String.apertureLocalized("Couldn't save your wallet: %@. Tap Retry."), error.localizedDescription)
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        WalletReadyView(state: CreateWalletState(), requiresBackup: false, onDone: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        WalletReadyView(state: CreateWalletState(), requiresBackup: false, onDone: {})
    }
    .preferredColorScheme(.dark)
}
