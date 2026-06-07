import SwiftUI
import SwiftData

/// Full-screen lock surface presented over the wallet home when
/// `AutoLockController.isLocked` is `true`. Wraps the canonical
/// `PinCodeView(mode: .verify)` per Rule #17 § H — same dots, same
/// keypad, same Face ID fallback position as the create-wallet PIN
/// screen. Muscle memory IS a security property.
///
/// **Cold launch path:** if the user has a PIN, this presents
/// immediately as a `.fullScreenCover` over the wallet home before any
/// data is visible. After successful auth, the cover dismisses and the
/// wallet home is revealed.
///
/// **Background-return path:** if elapsed time exceeded
/// `AutoLockPreference.resolvedDuration(...)`, this presents on the
/// `.active` phase transition.
///
/// **Forgot PIN:** routes to a Rule #16-honest sheet that explains
/// recovery requires re-importing from the recovery phrase. No "reset
/// PIN with email" path — Aperture has no email.
struct AppLockView: View {
    @Environment(\.autoLockController) private var lockController
    @Environment(\.modelContext) private var modelContext
    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = false

    @State private var isShowingForgotSheet: Bool = false

    var body: some View {
        PinCodeView(
            mode: .verify,
            onComplete: { _ in
                lockController.unlock()
                // Capture a fresh biometric snapshot after every
                // successful unlock so drift detection stays accurate
                // (Rule #17 mechanism + the BiometricEnrollmentTracker
                // shipped 2026-06-06).
                if biometricEnabled {
                    BiometricEnrollmentTracker.captureSnapshot(in: modelContext.container)
                }
            },
            onCancel: {
                // Cancel from a verify-mode PIN keeps the wallet
                // locked — the user must authenticate to enter.
            },
            onForgotPin: {
                isShowingForgotSheet = true
            }
        )
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
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $isShowingForgotSheet) {
            ForgotPinSheet()
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
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

    var body: some View {
        UniSheet(title: "Forgot your passcode?") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                hero
                UniBody(
                    text: "Aperture does not store your passcode. There is no reset link, no email recovery, no support team that can unlock your wallet for you.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                UniBody(
                    text: "To regain access, reinstall Aperture and restore your wallet from your recovery phrase. The phrase is the only key.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) { dismiss() }
        }
    }

    private var hero: some View {
        Image(systemName: "key.slash")
            .font(.system(size: 44, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Status.warningForeground)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, UniSpacing.s)
            .accessibilityHidden(true)
    }
}
