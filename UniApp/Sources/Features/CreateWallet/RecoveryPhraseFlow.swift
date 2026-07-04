import SwiftUI

/// Destinations the recovery-phrase flow can push within its
/// `NavigationStack`. Encoded as a value enum so a hoisted
/// `NavigationPath` survives any content rebuild — same pattern
/// `SettingsView` uses for picker destinations.
enum RecoveryPhraseDestination: Hashable, Codable {
    /// Step 2 — reveal the generated BIP-39 phrase after the disclosure.
    case recoveryPhrase
    /// Native backup chooser. From here, iCloud and manual backup each push
    /// their own real screens on this same stack.
    case backupMethod
    case backupICloudPassword
    case backupICloudProgress(password: String)
    case backupManualSafety
    case backupManualWriteDown
    case backupManualVerify
    case backupManualConfirmed
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

/// Root content view for create-wallet presentations. The presenter supplies
/// the single slide-up cover; this view owns the `NavigationStack` after that.
/// Onboarding starts at the disclosure screen, then pushes the recovery phrase
/// and every main backup/PIN/ready screen natively.
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

    /// `true` when the flow is entered from onboarding's "Create new wallet"
    /// button. The cover slides up once, then this stack pushes the
    /// disclosure → recovery phrase → backup/PIN/ready screens natively.
    var startsAtDisclosure: Bool = false

    /// Fires when the user dismisses the entire flow — close button on the
    /// root screen, or "Done" on `WalletReadyView`.
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

    /// Tracks whether the user reached PinSetup / WalletReady via the
    /// skip-backup branch or via the verify branch. Passed to
    /// `WalletReadyView` so the persisted `WalletRecord.requiresBackup`
    /// flag is honest (T-016).
    @State private var didSkipBackup: Bool = false

    /// `true` when the user finished a MANUAL backup (write-down + verify)
    /// via the chooser during creation — threaded to `WalletReadyView` so
    /// the persisted `WalletRecord.manualBackupCompleted` is accurate for
    /// create-flow manual backups, not just management ones (2026-06-20).
    @State private var didManualBackup: Bool = false
    @State private var isShowingSkipBackupAlert: Bool = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
            .navigationDestination(for: RecoveryPhraseDestination.self) { destination in
                switch destination {
                case .recoveryPhrase:
                    recoveryPhraseScreen(showsCloseButton: false)
                case .backupMethod:
                    ChooseMethodScreen(
                        onICloud: { navigationPath.append(RecoveryPhraseDestination.backupICloudPassword) },
                        onManual: { navigationPath.append(RecoveryPhraseDestination.backupManualSafety) },
                        onClose: onDismiss,
                        showsCloseButton: false
                    )
                case .backupICloudPassword:
                    ICloudPasswordScreen { password in
                        navigationPath.append(RecoveryPhraseDestination.backupICloudProgress(password: password))
                    }
                case .backupICloudProgress(let password):
                    ICloudProgressScreen(
                        walletId: state.pendingWalletId,
                        walletName: String.apertureLocalized("Wallet"),
                        words: state.words,
                        avatar: nil,
                        password: password,
                        onDone: {
                            didManualBackup = false
                            navigationPath.append(nextStepAfterVerify())
                        }
                    )
                case .backupManualSafety:
                    ManualSafetyScreen(
                        onContinue: { navigationPath.append(RecoveryPhraseDestination.backupManualWriteDown) },
                        onClose: onDismiss,
                        showsCloseButton: false
                    )
                case .backupManualWriteDown:
                    ManualWriteDownScreen(words: state.words) {
                        navigationPath.append(RecoveryPhraseDestination.backupManualVerify)
                    }
                case .backupManualVerify:
                    BackupVerifyView(state: state) {
                        didManualBackup = true
                        navigationPath.append(RecoveryPhraseDestination.backupManualConfirmed)
                    }
                case .backupManualConfirmed:
                    BackupConfirmedScreen {
                        navigationPath.append(nextStepAfterVerify())
                    }
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
                        requiresBackup: didSkipBackup,
                        manualBackup: didManualBackup
                    ) {
                        ScreenRestoration.routeToMainScreenNow()
                        onUserCompletedBackup()
                        onDismiss()
                    }
                }
            }
        }
        .alert(Text("Skip backup?"), isPresented: $isShowingSkipBackupAlert) {
            Button("Back up now") {
                navigationPath.append(RecoveryPhraseDestination.backupMethod)
            }
            Button("Skip anyway", role: .destructive) {
                skipBackupAndContinue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If this iPhone is lost, broken, or wiped before you save the recovery phrase, the wallet cannot be recovered. You can still back it up later in Settings.")
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
        if startsAtDisclosure {
            CreateWalletDisclosureScreen(
                onAccept: { navigationPath.append(RecoveryPhraseDestination.recoveryPhrase) },
                onCancel: onDismiss
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
        } else {
            recoveryPhraseScreen(showsCloseButton: true)
        }
    }

    private func recoveryPhraseScreen(showsCloseButton: Bool) -> some View {
        RecoveryPhraseView(
            state: state,
            onClose: onDismiss,
            onBackUpNow: {
                navigationPath.append(RecoveryPhraseDestination.backupMethod)
            },
            onSkipForNow: {
                isShowingSkipBackupAlert = true
            },
            coveredByChild: false,
            showsCloseButton: showsCloseButton
        )
    }

    private func skipBackupAndContinue() {
        didSkipBackup = true
        onUserSkippedBackup()
        navigationPath.append(nextStepAfterVerify())
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
    /// 2. At least one wallet already exists (`activeWalletId` GRDB preference
    ///    value non-empty). The user passed through PinSetupFlow on that
    ///    first wallet and made their choice — even if they tapped Skip
    ///    there, we honor that decision. Settings → Security is the
    ///    place to change their mind later.
    private func nextStepAfterVerify() -> RecoveryPhraseDestination {
        if PinCodeStorage.hasPin { return .walletReady }
        let activeWalletId = ActiveWalletPointer.rawValue
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
