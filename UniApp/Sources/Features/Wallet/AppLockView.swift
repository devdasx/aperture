import SwiftUI

/// Full-screen lock surface shown over the app when
/// `AutoLockController.isLocked` is `true`. Wraps the canonical
/// `PinCodeView(mode: .verify)` per Rule #17 § H — same dots, same
/// keypad, same biometric fallback position as the create-wallet PIN
/// screen. Muscle memory IS a security property.
///
/// **Hosting (2026-06-13 — detached overlay window).** Rendered by
/// `LockOverlayRoot` (UniAppApp.swift) inside a dedicated `UIWindow`
/// layered above the main window. The content tree underneath —
/// every `NavigationStack`, every presented sheet and
/// `fullScreenCover` — is never unmounted by a lock; unlocking just
/// fades this overlay away and the user is exactly where they were.
///
/// **Cold launch path:** if the user has a PIN, this becomes visible
/// the instant the splash hands off, before any data is visible.
///
/// **Background-return path:** if the time spent in `.background`
/// exceeded `AutoLockPreference.resolvedDuration(...)`, this appears
/// on the `.active` phase transition, beneath the fading privacy
/// mask. `.inactive` bounces (system prompts, biometric sheets) never
/// arm it.
///
/// **Forgot PIN:** routes to a Rule #16-honest sheet that explains
/// recovery requires re-importing from the recovery phrase. No "reset
/// PIN with email" path — Aperture has no email.
struct AppLockView: View {
    @Environment(\.autoLockController) private var lockController
    @GRDBStorage("biometricEnabled") private var biometricEnabled: Bool = false
    /// Optional iOS-style "Erase Data": wipe the app after
    /// `PinCodeStorage.eraseDataThreshold` failed LOCK-SCREEN attempts.
    /// Off by default; the user arms it in Settings → Security.
    @GRDBStorage("eraseDataAfterFailedAttempts") private var eraseDataEnabled: Bool = false

    @State private var isShowingForgotSheet: Bool = false
    /// Guards the wipe so it runs at most once even if a queued attempt
    /// races the threshold crossing.
    @State private var isErasing: Bool = false

    var body: some View {
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in
                    // 2026-06-09 v3 — wrap the unlock in a smooth iOS 26
                    // spring so the lock's exit transition (scale 1.08
                    // + opacity, set in `AppRoot`) and the home's
                    // scale-from-0.97 reveal animate together. Without
                    // `withAnimation` the state change is instantaneous
                    // and SwiftUI uses no curve.
                    withAnimation(.smooth(duration: 0.55)) {
                        lockController.unlock()
                    }
                    // Capture a fresh biometric snapshot after every
                    // successful unlock so drift detection stays accurate
                    // (Rule #17 mechanism + the BiometricEnrollmentTracker
                    // shipped 2026-06-06).
                    if biometricEnabled {
                        BiometricEnrollmentTracker.captureSnapshot(database: AppDatabase.shared)
                    }
                    // A successful unlock clears the Erase-Data counter — the
                    // threshold counts only CONSECUTIVE lock-screen failures.
                    PinCodeStorage.clearUnlockFailures()
                },
                onCancel: {
                    // Cancel from a verify-mode PIN keeps the wallet
                    // locked — the user must authenticate to enter.
                },
                onForgotPin: {
                    isShowingForgotSheet = true
                },
                onFailedAttempt: { handleFailedUnlock() },
                // The wrong-passcode line shows "N attempts remaining" ONLY when
                // the user armed Erase Data — that's the only mode with a real
                // finite count (the wipe at the threshold). Read after the failure
                // is recorded, so it reflects the just-incremented count.
                attemptsRemaining: {
                    guard eraseDataEnabled else { return nil }
                    return max(0, PinCodeStorage.eraseDataThreshold - PinCodeStorage.unlockFailureCount())
                },
                showsAccessContextToolbar: true,
                showsForgotPasscodeOption: true,
                accessContext: .unlockApp
            )
        }
        // Opaque backing. `AppLockView` used to ship inside a
        // `.fullScreenCover`, which provided window-level opacity
        // automatically — when the cover moved into `AppRoot`'s
        // ZStack on 2026-06-07 (for the splash race + foreground
        // flash fixes) the cover semantics went away and the
        // wallet home started bleeding through the keypad gaps.
        // The lock owning its own background is the honest fix:
        // the surface guarantees its own opacity regardless of how
        // it's presented, so any future caller (a sheet, a cover, a
        // direct mount in another stack) gets correct behavior for
        // free.
        .background(UniColors.Background.primary.ignoresSafeArea())
        .sheet(isPresented: $isShowingForgotSheet) {
            ForgotPinSheet(
                onResetAperture: {
                    guard !isErasing else { return }
                    isShowingForgotSheet = false
                    isErasing = true
                    Task { await eraseEverything() }
                }
            )
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Erase Data (optional, off by default)

    /// Called after each failed LOCK-SCREEN attempt. Records it in the
    /// dedicated unlock counter and, when the user has armed "Erase Data"
    /// and the count reaches the threshold, performs the full factory wipe.
    private func handleFailedUnlock() {
        let count = PinCodeStorage.recordUnlockFailure()
        guard eraseDataEnabled,
              !isErasing,
              count >= PinCodeStorage.eraseDataThreshold
        else { return }
        isErasing = true
        Task { await eraseEverything() }
    }

    /// The destructive wipe — the SAME routine "Reset Aperture" runs. After
    /// it returns there are zero wallets, so `RootGate` routes to onboarding;
    /// we also drop the lock overlay so the user isn't left staring at a
    /// keypad for an app that no longer has anything to unlock.
    @MainActor
    private func eraseEverything() async {
        try? await FactoryReset.performFullWipe(database: AppDatabase.shared)
        PinCodeStorage.clearUnlockFailures()
        withAnimation(.smooth(duration: 0.4)) {
            lockController.unlock()
        }
    }
}

// MARK: - Forgot PIN sheet

/// Rule #16-honest explanation: there is no PIN reset. The only path
/// back from a forgotten PIN is to restore the wallet from its
/// recovery phrase on a fresh install. Aperture has no email, no
/// account, no server-side reset.
private struct ForgotPinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @GRDBStorage(PinCodePreference.forgotPasscodeResetEnabledKey) private var resetFromForgotPasscodeEnabled: Bool = false

    let onResetAperture: () -> Void

    @State private var isConfirmingReset: Bool = false
    @State private var biometricService = BiometricService()

    var body: some View {
        UniSheet(
            title: "Forgot your passcode?",
            icon: "key.slash",
            iconTint: UniColors.Feedback.Warning.foreground
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                UniBody(
                    text: "Aperture does not store your passcode. There is no reset link, no email recovery, no support team that can unlock your wallet for you.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)

                if resetFromForgotPasscodeEnabled {
                    Text(verbatim: "Because lock-screen reset is enabled, you can erase Aperture from this iPhone and set it up again. This removes every local wallet, recovery phrase, passcode, \(resetSecurityItemName), transaction cache, custom token, and app setting from this device.")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.secondary)
                        .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                    UniBody(
                        text: "Only continue if your recovery phrases are backed up. Any wallet that was not backed up cannot be recovered.",
                        color: UniColors.Feedback.Error.foreground
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    UniBody(
                        text: "To regain access, reinstall Aperture and restore your wallet from your recovery phrase. The phrase is the only key.",
                        color: UniColors.Text.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    UniBody(
                        text: "You can enable lock-screen reset later from Security settings while you still know your passcode. It is off by default so someone holding your phone cannot erase Aperture without your permission.",
                        color: UniColors.Text.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            VStack(spacing: UniSpacing.s) {
                if resetFromForgotPasscodeEnabled {
                    UniButton(title: "Reset Aperture", variant: .destructive) {
                        isConfirmingReset = true
                    }
                }
                UniButton(title: "Got it", variant: resetFromForgotPasscodeEnabled ? .secondary : .primary) {
                    dismiss()
                }
            }
        }
        .alert(Text("Erase Aperture from this iPhone?"), isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Erase Aperture", role: .destructive) {
                onResetAperture()
            }
        } message: {
            Text(verbatim: "This removes all local wallets, recovery phrases, passcodes, \(resetSecurityItemName), transaction history cache, custom tokens, and app data from this device. Wallets can only be restored from their recovery phrases.")
        }
    }

    private var resetSecurityItemName: String {
        biometricService.isAvailable ? "\(biometricService.biometryType.displayName) settings" : "security settings"
    }
}
