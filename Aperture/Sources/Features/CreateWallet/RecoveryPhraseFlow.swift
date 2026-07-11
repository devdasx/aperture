import SwiftUI

/// Destinations the recovery-phrase flow can push within its
/// `NavigationStack`. Encoded as a value enum so a hoisted
/// `NavigationPath` survives any content rebuild — same pattern
/// `SettingsView` uses for picker destinations.
enum RecoveryPhraseDestination: Hashable, Codable {
    /// P2-017: mental verify challenge before PIN / wallet-ready.
    case backupVerify
    /// Unified PIN + biometric setup. After the phrase is shown, the user
    /// creates a 6-digit passcode, confirms it, and is offered Face ID.
    case pinSetup
    /// (Legacy) biometric-only push target — preserved for back-compat;
    /// no longer used by the current flow. Kept so any cached
    /// `NavigationPath` from a prior session doesn't crash on decode.
    case biometric
    /// Terminal persistence handoff. Persists the generated wallet, then
    /// hands the user back to the app.
    case walletReady
}

/// Root content view for create-wallet presentations. The presenter supplies
/// the single slide-up cover; this view owns the `NavigationStack` after that.
/// Onboarding starts directly at the recovery phrase, then pushes the
/// passcode / Face ID setup and wallet-ready screens natively.
///
/// **State.** Owns a `CreateWalletState` for the duration of the cover —
/// the same instance backs `RecoveryPhraseView` (mnemonic + word-count
/// picker + passphrase entry) and `WalletReadyView` (which persists the
/// wallet). Released on dismiss; the passphrase lives only in-memory
/// (Rule #2 §A.7 honesty).
///
/// **Rule #12 compliance.** The cover's content is wrapped by the
/// presenter (`OnboardingView`) with `.id(sheetDirectionKey)` and
/// `.apertureEnvironment()`, so a mid-flight LTR ↔ RTL flip rebuilds this
/// tree while preserving the hoisted `navigationPath`.
struct RecoveryPhraseFlow: View {
    /// Hoisted navigation path — owned by `OnboardingView`, passed in as
    /// a binding. Survives `.id` rebuilds.
    @Binding var navigationPath: NavigationPath

    /// Fires when the user dismisses the entire flow — close button on the
    /// root screen, or successful persistence in `WalletReadyView`.
    let onDismiss: () -> Void

    /// Set after the user leaves the recovery phrase without completing a
    /// verified backup. The presenter persists a "has unbacked-up wallet"
    /// flag and the wallet row is saved with `requiresBackup == true`.
    let onUserContinuedWithoutVerifiedBackup: () -> Void

    /// Shared mnemonic + passphrase state for the entire cover. Built
    /// once on construction so every push destination reads from the
    /// same generated phrase.
    @State private var state = CreateWalletState()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
            .navigationDestination(for: RecoveryPhraseDestination.self) { destination in
                switch destination {
                case .backupVerify:
                    // P2-017: phrase verification before PIN/ready (same as Settings).
                    BackupVerifyView(state: state, onVerified: {
                        navigationPath.append(nextStepAfterVerifiedBackup())
                    })
                case .pinSetup:
                    PinSetupFlow(
                        onFinish: {
                            navigationPath.append(RecoveryPhraseDestination.walletReady)
                        },
                        onBack: {
                            // User tapped the leading back chevron on the
                            // `.set` step. Pop the parent NavigationStack
                            // so the user returns to RecoveryPhraseView.
                            // The closure guards against an empty path
                            // because SwiftUI calls toolbar item actions
                            // outside the regular layout pass.
                            if !navigationPath.isEmpty {
                                navigationPath.removeLast()
                            }
                        }
                    )
                case .biometric:
                    // P3-002: legacy path only (cached NavigationPath).
                    // Forward into the real PIN+biometric setup rather than
                    // a dead placeholder screen.
                    PinSetupFlow(
                        onFinish: {
                            navigationPath.append(RecoveryPhraseDestination.walletReady)
                        },
                        onBack: {
                            if !navigationPath.isEmpty {
                                navigationPath.removeLast()
                            }
                        }
                    )
                case .walletReady:
                    WalletReadyView(
                        state: state,
                        requiresBackup: false,
                        manualBackup: true
                    ) {
                        WalletCompletionNoticeCenter.enqueue(.created)
                        ScreenRestoration.routeToMainScreenNow()
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
    }

    @ViewBuilder
    private var rootContent: some View {
        recoveryPhraseScreen(showsCloseButton: true)
    }

    private func recoveryPhraseScreen(showsCloseButton: Bool) -> some View {
        RecoveryPhraseView(
            state: state,
            onClose: onDismiss,
            onContinue: {
                // P2-017: always verify the phrase before PIN / ready.
                navigationPath.append(RecoveryPhraseDestination.backupVerify)
            },
            showsCloseButton: showsCloseButton
        )
    }

    /// After a successful backup verify challenge: PIN setup if needed,
    /// otherwise wallet-ready with `requiresBackup == false`.
    private func nextStepAfterVerifiedBackup() -> RecoveryPhraseDestination {
        if PinCodeStorage.hasPin { return .walletReady }
        let activeWalletId = ActiveWalletPointer.rawValue
        if !activeWalletId.isEmpty { return .walletReady }
        return .pinSetup
    }

}

// MARK: - Previews

#Preview("Light") {
    RecoveryPhraseFlow(
        navigationPath: .constant(NavigationPath()),
        onDismiss: {},
        onUserContinuedWithoutVerifiedBackup: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    RecoveryPhraseFlow(
        navigationPath: .constant(NavigationPath()),
        onDismiss: {},
        onUserContinuedWithoutVerifiedBackup: {}
    )
    .preferredColorScheme(.dark)
}
