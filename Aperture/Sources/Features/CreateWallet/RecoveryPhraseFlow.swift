import SwiftUI
import OSLog

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
    /// Legacy terminal screen. Create flow no longer pushes this — it
    /// routes through `.provisioning` instead. Kept for path decode only.
    case walletReady
    /// Real progress handoff: encrypt + save keys, then dismiss to main.
    case provisioning(requiresBackup: Bool, manualBackup: Bool)
}

/// Root content view for create-wallet presentations. The presenter supplies
/// the single slide-up cover; this view owns the `NavigationStack` after that.
/// Flow (onboarding): recovery phrase → passcode → Face ID → **process** (last).
/// Flow (add wallet): recovery phrase → **process** (last; no passcode force).
struct RecoveryPhraseFlow: View {
    @Binding var navigationPath: NavigationPath

    let onDismiss: () -> Void

    /// Set after the user leaves the recovery phrase without completing a
    /// verified backup. The presenter persists a "has unbacked-up wallet"
    /// flag and the wallet row is saved with `requiresBackup == true`.
    let onUserContinuedWithoutVerifiedBackup: () -> Void

    /// When `true` (onboarding create only), push passcode setup if this
    /// device has no PIN yet. When `false` (add wallet from home / settings),
    /// never force passcode — the user may have disabled it on purpose.
    var requiresPasscodeSetup: Bool = false

    @State private var state = CreateWalletState()
    /// Pending backup flags while the user is on PIN setup (before
    /// provisioning). Cleared once provisioning is pushed.
    @State private var pendingRequiresBackup = true
    @State private var pendingManualBackup = false
    /// Prevents double-tap Continue / PIN finish from stacking destinations.
    @State private var isAdvancing = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
            .navigationDestination(for: RecoveryPhraseDestination.self) { destination in
                switch destination {
                case .backupVerify:
                    BackupVerifyView(state: state, onVerified: {
                        // Verified write-down → still PIN if needed, then provision.
                        continueAfterPhrase(requiresBackup: false, manualBackup: true)
                    })
                case .pinSetup:
                    // Passcode set → confirm → Face ID (inside PinSetupFlow).
                    // Only when that whole chain finishes do we open process.
                    PinSetupFlow(
                        onFinish: {
                            // Last security step done → process is always last.
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            pushProvisioning(
                                requiresBackup: pendingRequiresBackup,
                                manualBackup: pendingManualBackup
                            )
                        },
                        onBack: {
                            isAdvancing = false
                            popAnimated()
                        }
                    )
                case .biometric:
                    // Legacy path: same full PIN + Face ID chain, then process.
                    PinSetupFlow(
                        onFinish: {
                            guard !isAdvancing else { return }
                            isAdvancing = true
                            pushProvisioning(
                                requiresBackup: pendingRequiresBackup,
                                manualBackup: pendingManualBackup
                            )
                        },
                        onBack: {
                            isAdvancing = false
                            popAnimated()
                        }
                    )
                case .walletReady:
                    // Legacy path only (old NavigationPath). Route into the
                    // modern provisioning screen immediately.
                    Color.clear
                        .navigationBarBackButtonHidden(true)
                        .task {
                            pushProvisioning(requiresBackup: true, manualBackup: false)
                        }
                case .provisioning(let requiresBackup, let manualBackup):
                    CreateWalletProvisioningView(
                        state: state,
                        requiresBackup: requiresBackup,
                        manualBackup: manualBackup,
                        onFinished: {
                            var transaction = Transaction(animation: .default)
                            transaction.disablesAnimations = false
                            withTransaction(transaction) {
                                onDismiss()
                            }
                        },
                        onRequiresBackupFlag: {
                            onUserContinuedWithoutVerifiedBackup()
                        }
                    )
                }
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
    }

    @ViewBuilder
    private var rootContent: some View {
        recoveryPhraseScreen(showsCloseButton: true)
    }

    private func recoveryPhraseScreen(showsCloseButton: Bool) -> some View {
        RecoveryPhraseView(
            state: state,
            onClose: {
                onDismiss()
            },
            onContinue: {
                // Immediate navigation — never block on the phrase screen.
                continueAfterPhrase(requiresBackup: true, manualBackup: false)
            },
            showsCloseButton: showsCloseButton
        )
    }

    /// After the phrase (or verify): from **onboarding only**, open PIN when
    /// this device has none. From home/settings create, skip straight to
    /// provisioning — never re-prompt after the user disabled passcode.
    private func continueAfterPhrase(requiresBackup: Bool, manualBackup: Bool) {
        guard !isAdvancing else { return }
        isAdvancing = true
        pendingRequiresBackup = requiresBackup
        pendingManualBackup = manualBackup
        if requiresPasscodeSetup, !PinCodeStorage.hasPin {
            // Allow re-advance if the user backs out of PIN setup.
            isAdvancing = false
            pushAnimated(.pinSetup)
            return
        }
        pushProvisioning(requiresBackup: requiresBackup, manualBackup: manualBackup)
    }

    /// Push the modern process screen right away so Continue never freezes
    /// on the recovery phrase while keys encrypt / save.
    private func pushProvisioning(requiresBackup: Bool, manualBackup: Bool) {
        pushAnimated(.provisioning(requiresBackup: requiresBackup, manualBackup: manualBackup))
    }

    private func pushAnimated(_ destination: RecoveryPhraseDestination) {
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction(animation: .default)
            transaction.disablesAnimations = false
            withTransaction(transaction) {
                navigationPath.append(destination)
            }
        }
    }

    private func popAnimated() {
        guard !navigationPath.isEmpty else { return }
        var transaction = Transaction(animation: .default)
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            navigationPath.removeLast()
        }
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
