import SwiftUI

/// Destinations the recovery-phrase flow can push within its
/// `NavigationStack`. Encoded as a value enum so a hoisted
/// `NavigationPath` survives any content rebuild — same pattern
/// `SettingsView` uses for picker destinations.
enum RecoveryPhraseDestination: Hashable, Codable {
    /// Step 4 — re-enter the phrase via the multiple-choice verify view.
    case verify
    /// Step 5 — biometric setup (Face ID / passcode) + Keychain encrypt.
    /// Placeholder push target until `T-012` lands.
    case biometric
    /// Terminal — the "your wallet is ready" placeholder for `T-018`.
    case walletReady
}

/// Root content view for the `fullScreenCover` presented after the user
/// accepts the disclosure. Hosts the `NavigationStack` for the recovery
/// flow and owns the skip-backup-warning sheet that overlays the
/// recovery-phrase view.
///
/// **State.** Owns a `CreateWalletState` for the duration of the cover —
/// the same instance backs `RecoveryPhraseView` (mnemonic + word-count
/// picker + passphrase entry) and `BackupVerifyView` (which reads the
/// mnemonic to build challenge cards). Released on dismiss; the
/// passphrase lives only in-memory (Rule #2 §A.7 honesty).
///
/// **Rule #12 compliance.** The cover's content is wrapped by the
/// presenter (`OnboardingView`) with `.id(sheetDirectionKey)` and
/// `.uniAppEnvironment()`, so a mid-flight LTR ↔ RTL flip rebuilds this
/// tree while preserving the hoisted `navigationPath`.
struct RecoveryPhraseFlow: View {
    /// Hoisted navigation path — owned by `OnboardingView`, passed in as
    /// a binding. Survives `.id` rebuilds.
    @Binding var navigationPath: NavigationPath

    /// Fires when the user dismisses the entire flow — close button on
    /// `RecoveryPhraseView`, "Skip anyway" on the warning sheet, or
    /// "Done" on `WalletReadyView`.
    let onDismiss: () -> Void

    /// Set to `true` after the user opts to skip the backup so the
    /// presenter can persist a "has unbacked-up wallet" flag (`T-016`).
    let onUserSkippedBackup: () -> Void

    /// Set when the user successfully completes verification so the
    /// presenter can clear the unbacked-up flag.
    let onUserCompletedBackup: () -> Void

    /// Shared mnemonic + passphrase state for the entire cover. Built
    /// once on construction so every push destination reads from the
    /// same generated phrase.
    @State private var state = CreateWalletState()

    @State private var isShowingSkipWarning: Bool = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            RecoveryPhraseView(
                state: state,
                onClose: onDismiss,
                onBackUpNow: {
                    navigationPath.append(RecoveryPhraseDestination.verify)
                },
                onSkipForNow: {
                    isShowingSkipWarning = true
                }
            )
            .navigationDestination(for: RecoveryPhraseDestination.self) { destination in
                switch destination {
                case .verify:
                    BackupVerifyView(state: state) {
                        navigationPath.append(RecoveryPhraseDestination.walletReady)
                    }
                case .biometric:
                    // TODO: (T-012) biometric setup view (Face ID / passcode)
                    placeholderPushTarget(label: "Biometric setup")
                case .walletReady:
                    WalletReadyView {
                        onUserCompletedBackup()
                        onDismiss()
                    }
                }
            }
        }
        // The `fullScreenCover` content otherwise has a transparent
        // background — the underlying `OnboardingView` (slide copy,
        // page-indicator dots, CTAs) would bleed through behind the
        // recovery-phrase grid. An opaque system background on the
        // `NavigationStack` itself prevents the bleed without touching
        // the inner view layouts.
        .background(UniColors.Background.primary.ignoresSafeArea())
        .sheet(isPresented: $isShowingSkipWarning) {
            SkipBackupWarningSheet(
                onBackUpNow: {
                    // User changed their mind — dismiss the warning and
                    // route into verify, same as the primary CTA on the
                    // recovery view.
                    isShowingSkipWarning = false
                    navigationPath.append(RecoveryPhraseDestination.verify)
                },
                onSkipAnyway: {
                    // Persist the unbacked-up flag (T-016) then dismiss
                    // both the warning and the parent cover.
                    onUserSkippedBackup()
                    isShowingSkipWarning = false
                    onDismiss()
                }
            )
            .uniAppEnvironment()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    /// Stand-in destination view used until the biometric flow (`T-012`)
    /// lands. Plain centered label on the system background — no
    /// decoration, no "coming soon" theatre.
    private func placeholderPushTarget(label: String) -> some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()
            UniBody(text: LocalizedStringKey(label))
                .padding(UniSpacing.l)
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    RecoveryPhraseFlow(
        navigationPath: .constant(NavigationPath()),
        onDismiss: {},
        onUserSkippedBackup: {},
        onUserCompletedBackup: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    RecoveryPhraseFlow(
        navigationPath: .constant(NavigationPath()),
        onDismiss: {},
        onUserSkippedBackup: {},
        onUserCompletedBackup: {}
    )
    .preferredColorScheme(.dark)
}
