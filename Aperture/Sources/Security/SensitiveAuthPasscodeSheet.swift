import SwiftUI

/// Standard passcode sheet for `SensitiveActionAuth` fallbacks.
/// Always the same chrome: large sheet, drag indicator, app environment.
///
/// Face ID policy: when Aperture biometrics are enabled, the keypad always
/// offers Face ID / Touch ID (`allowsBiometrics` defaults true). Callers
/// should not pass `allowsBiometrics: false` while Face ID is on — that is
/// the force-passcode bug product forbids.
struct SensitiveAuthPasscodeSheet: View {
    let accessContext: PinCodeView.AccessContext?
    /// When false, no auto Face ID on appear (preflight already tried).
    /// Keypad Face ID key still appears when `allowsBiometrics` and the
    /// user has biometrics enabled in Security.
    var autoPromptBiometrics: Bool = true
    /// Prefer leaving `true`. When Face ID is enabled in Aperture, product
    /// requires the keypad biometric key — never passcode-only.
    var allowsBiometrics: Bool = true
    var attemptsRemaining: (() -> Int?)? = nil
    var onFailedAttempt: (() -> Void)? = nil
    let onComplete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in onComplete() },
                onCancel: onCancel,
                onFailedAttempt: onFailedAttempt,
                // Never strip Face ID while the user has it on in Aperture,
                // even if a caller passes allowsBiometrics: false by mistake.
                allowsBiometrics: allowsBiometrics || PinCodePreference.isBiometricEnabled(),
                autoPromptBiometrics: autoPromptBiometrics,
                attemptsRemaining: attemptsRemaining,
                showsNavigationControls: false,
                accessContext: accessContext
            )
        }
        .apertureEnvironment()
        .uniSheetDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
    }
}
