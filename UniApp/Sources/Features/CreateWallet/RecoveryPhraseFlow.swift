import SwiftUI

/// Destinations the recovery-phrase flow can push within its
/// `NavigationStack`. Encoded as a value enum so a hoisted
/// `NavigationPath` survives any content rebuild — same pattern
/// `SettingsView` uses for picker destinations.
enum RecoveryPhraseDestination: Hashable, Codable {
    /// Step 4 — re-enter the phrase via the multiple-choice verify view.
    case verify
    /// Step 5 — unified PIN + biometric setup (Rule #17). After
    /// `BackupVerifyView` success, the user is invited to set a 6-digit
    /// PIN and (optionally) enable Face ID. PIN is optional with honest
    /// skip warning. Lands `PinSetupFlow`.
    case pinSetup
    /// (Legacy) biometric-only push target — preserved for back-compat;
    /// no longer used by the current flow. Kept so any cached
    /// `NavigationPath` from a prior session doesn't crash on decode.
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

    /// Tracks whether the user reached PinSetup / WalletReady via the
    /// skip-backup branch or via the verify branch. Passed to
    /// `WalletReadyView` so the persisted `WalletRecord.requiresBackup`
    /// flag is honest (T-016).
    @State private var didSkipBackup: Bool = false

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
                        // Rule #17 §E — after verify, route through the
                        // unified PIN setup flow (set → confirm → biometric
                        // prompt or honest skip). The PIN flow itself
                        // pushes onto its own internal NavigationStack;
                        // when it resolves, the parent advances to
                        // WalletReadyView.
                        //
                        // **Skip if already configured.** The passcode is
                        // a device-level setting protecting every wallet
                        // in the app, not a per-wallet credential. If
                        // the user already set one when they created the
                        // first wallet (or imported it), DON'T re-prompt
                        // — go straight to WalletReady. Also skip if the
                        // user explicitly opted out earlier in this
                        // session (`pinEnabled = false` after they took
                        // the skip path). Settings → Security is where
                        // they can change their mind later.
                        navigationPath.append(nextStepAfterVerify())
                    }
                case .pinSetup:
                    PinSetupFlow(
                        onFinish: {
                            navigationPath.append(RecoveryPhraseDestination.walletReady)
                        },
                        onBack: {
                            // User tapped the leading back chevron on the
                            // `.set` step. Pop the parent NavigationStack
                            // so the user returns to the previous step
                            // (BackupVerifyView, or RecoveryPhraseView if
                            // they reached PIN via the skip-backup path).
                            // The closure guards against an empty path
                            // because SwiftUI calls toolbar item actions
                            // outside the regular layout pass.
                            if !navigationPath.isEmpty {
                                navigationPath.removeLast()
                            }
                        }
                    )
                case .biometric:
                    // Legacy destination — never pushed by the current
                    // flow. Reachable only if a cached NavigationPath
                    // from a prior session is restored. Surface a calm
                    // placeholder rather than crash. See T-012 history.
                    placeholderPushTarget(label: "Biometric setup")
                case .walletReady:
                    WalletReadyView(
                        state: state,
                        requiresBackup: didSkipBackup
                    ) {
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
                    // Persist the unbacked-up flag (T-016), dismiss the
                    // warning, and route through PinSetup — per the
                    // user's 2026-06-04 direction, BOTH paths (backup
                    // or skip-backup) must land in the PIN-setup step.
                    // PIN protects the local wallet whether or not the
                    // user has saved the recovery phrase; the two
                    // protections are independent and both should be
                    // offered. PinSetupFlow itself is optional via its
                    // own skip — the user can still finish without a
                    // PIN if they choose, but they always pass through
                    // the offer.
                    didSkipBackup = true
                    onUserSkippedBackup()
                    isShowingSkipWarning = false
                    navigationPath.append(nextStepAfterVerify())
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    /// Pick the next destination after the user finishes (or skips) the
    /// recovery-phrase verification. The passcode + biometric offer is
    /// a device-level decision, made once when the user has no wallets
    /// yet. Re-prompting on every subsequent create/import is noise
    /// (and per the user's 2026-06-06 report, alarming — they think
    /// the app forgot their earlier choice). Two skip conditions, any
    /// one of them sufficient:
    /// 1. A passcode is already stored in Keychain (`PinCodeStorage.hasPin`).
    ///    The new wallet is automatically protected by it; no setup needed.
    /// 2. At least one wallet already exists (`activeWalletId` UserDefaults
    ///    value non-empty). The user passed through PinSetupFlow on that
    ///    first wallet and made their choice — even if they tapped Skip
    ///    there, we honor that decision. Settings → Security is the
    ///    place to change their mind later.
    private func nextStepAfterVerify() -> RecoveryPhraseDestination {
        if PinCodeStorage.hasPin { return .walletReady }
        let activeWalletId = UserDefaults.standard.string(forKey: "activeWalletId") ?? ""
        if !activeWalletId.isEmpty { return .walletReady }
        return .pinSetup
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
