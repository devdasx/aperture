import Foundation

/// **Unified sensitive-action authorization** (biometric-first when enabled).
///
/// Product rule (2026-07):
/// 1. If no app passcode → already authorized (caller may still show a confirm).
/// 2. If Face ID / Touch ID is enabled **and** available → prompt biometrics
///    **without** presenting the passcode sheet first.
/// 3. On biometric success → proceed.
/// 4. On biometric failure, cancel, or biometrics off/unavailable → present
///    the passcode sheet (`PinCodeView`). The sheet always keeps Face ID as
///    a keypad option when biometrics are still enabled in Aperture.
///
/// Every auth-gated surface (Security, export phrase/keys, remove wallet,
/// Reset Aperture, turn off / change passcode, send confirm, etc.) must use
/// this preflight so UX is identical app-wide. The passcode sheet remains
/// the single PIN UI (`PinCodeView` / Rule #17).
@MainActor
enum SensitiveActionAuth {

    /// Outcome of the silent preflight (no passcode UI yet).
    enum Gate: Sendable, Equatable {
        /// No PIN, or biometrics succeeded — proceed without a sheet.
        case authorized
        /// Present `PinCodeView` (passcode sheet).
        /// - `autoPromptBiometrics`: if `true`, the sheet may auto-fire Face ID
        ///   on appear. If `false`, user already tried Face ID in this preflight
        ///   — show the keypad first; Face ID remains available as the keypad
        ///   leading key whenever Aperture biometrics are still enabled.
        case presentPasscode(autoPromptBiometrics: Bool)
    }

    /// Run the shared gate.
    ///
    /// - Parameters:
    ///   - reason: Localized string shown under the system biometric glyph.
    ///   - preferBiometric: When `false`, skip the silent Face ID preflight
    ///     and go straight to the passcode sheet. The sheet still offers Face
    ///     ID on the keypad when biometrics are enabled (never passcode-only
    ///     while Face ID is on in Aperture). Prefer leaving this `true`.
    static func gate(
        reason: LocalizedStringResource,
        preferBiometric: Bool = true
    ) async -> Gate {
        guard PinCodeStorage.hasPin else {
            return .authorized
        }

        let biometricsEnabled = PinCodePreference.isBiometricEnabled()
        let service = BiometricService()

        // Never force passcode-only while the user has Face ID / Touch ID on.
        // Even when preferBiometric is false, the sheet may auto-prompt if
        // biometrics are enabled and available.
        guard preferBiometric, biometricsEnabled else {
            return .presentPasscode(
                autoPromptBiometrics: biometricsEnabled && service.isAvailable
            )
        }

        guard service.isAvailable else {
            // Hardware temporarily unavailable (lockout, not enrolled mid-session).
            // Sheet can still show the Face ID key if availability returns.
            return .presentPasscode(autoPromptBiometrics: false)
        }

        switch await service.authenticate(reason: reason) {
        case .success:
            return .authorized
        case .failure(let error):
            // Failed scan, user cancel, lockout, etc. → passcode sheet.
            // Do not immediately re-auto-prompt Face ID after the user just
            // dismissed or failed the system dialog; keypad Face ID key remains.
            // If biometrics became unavailable, still show passcode (no auto).
            let shouldAutoPrompt: Bool
            switch error {
            case .unavailable:
                // Preflight thought biometrics were available; they weren't.
                // Let the sheet try auto-prompt only if they report available again.
                shouldAutoPrompt = BiometricService().isAvailable
            case .userCancelled, .authenticationFailed, .systemError:
                shouldAutoPrompt = false
            }
            return .presentPasscode(autoPromptBiometrics: shouldAutoPrompt)
        }
    }

    /// Convenience: reason from the device biometry type's unlock string.
    static func gatePreferringBiometric() async -> Gate {
        let service = BiometricService()
        return await gate(reason: service.biometryType.unlockReason, preferBiometric: true)
    }

    /// Turn Passcode Off — Face ID first when enabled, then passcode sheet.
    static func gateTurnOffPasscode() async -> Gate {
        let service = BiometricService()
        return await gate(reason: service.biometryType.turnOffPasscodeReason, preferBiometric: true)
    }

    /// Change Passcode — Face ID first when enabled, then passcode sheet.
    static func gateChangePasscode() async -> Gate {
        let service = BiometricService()
        return await gate(reason: service.biometryType.changePasscodeReason, preferBiometric: true)
    }
}
