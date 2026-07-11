import Foundation

/// User preferences for the unified PIN + biometric system (Rule #17).
///
/// Mirrors `HapticPreference.swift` and `ThemePreference.swift` in shape —
/// a namespace exposing storage keys and read accessors that bypass
/// SwiftUI's environment for the rare non-view caller.
///
/// **Three keys, three meanings.**
/// - `pinEnabled` — the user has set a 6-digit PIN. Implies
///   `PinCodeStorage.hasPin == true` (we keep them in sync at the call site).
///   `false` means the user skipped PIN setup with honest warning; the
///   wallet is protected only by the iPhone's own lock screen.
/// - `biometricEnabled` — the user authenticated with device biometrics
///   during setup. `true` means they want biometrics for app unlock and
///   transaction confirmation. `false` is the safe default — set to `true`
///   only after a real `BiometricService.authenticate(...)` success.
/// - `requireBiometricForSend` — per-action biometric gate for transaction
///   signing. It follows `biometricEnabled` by default: enabling biometrics
///   turns this on, disabling biometrics turns it off.
/// - `forgotPasscodeResetEnabled` — optional lock-screen escape hatch that
///   lets a user erase Aperture from the forgot-passcode sheet. Off by default
///   because anyone holding the unlocked phone could use it to wipe local data.
///
/// Defaults: PIN and biometrics are `false`; the send gate defaults to `true`
/// only as the enabled-biometric default and is forced off whenever biometrics
/// are off.
enum PinCodePreference {
    /// `@GRDBStorage` key for the PIN-enabled flag. Mirrors `PinCodeStorage.hasPin`
    /// at the moment of setup; the GRDB preference is the user-intent flag
    /// while `local_secure_blobs` holds the actual material.
    static let pinEnabledKey: String = "pinEnabled"

    /// `@GRDBStorage` key for the biometric-enabled flag. Set to `true` only
    /// after a real `BiometricService.authenticate(...)` returns
    /// `.success(())` — never auto-enabled.
    static let biometricEnabledKey: String = "biometricEnabled"

    /// `@GRDBStorage` key for the "Use biometric auth for sending transactions"
    /// row. It is only meaningful while `biometricEnabled == true`.
    static let requireBiometricForSendKey: String = "requireBiometricForSend"

    /// `@GRDBStorage` key for the opt-in forgot-passcode reset hatch. When
    /// enabled, the lock-screen forgot-passcode sheet can erase all local
    /// wallet data so a backed-up user can start over and restore.
    static let forgotPasscodeResetEnabledKey: String = "forgotPasscodeResetEnabled"

    /// Tracks whether the Security screen has shown the first-enable warning
    /// for `forgotPasscodeResetEnabledKey`.
    static let forgotPasscodeResetEducationSeenKey: String = "forgotPasscodeResetEducationSeen"

    /// Default for both flags. Fresh-install users have not opted in to
    /// either protection.
    static let defaultValue: Bool = false

    /// Read `pinEnabled` without a SwiftUI view. Matches `@GRDBStorage`'s
    /// "absent key → default" semantics.
    static func isPinEnabled() -> Bool {
        AppPreferenceStore.shared.bool(pinEnabledKey, default: defaultValue)
    }

    /// Read `biometricEnabled` without a SwiftUI view.
    static func isBiometricEnabled() -> Bool {
        AppPreferenceStore.shared.bool(biometricEnabledKey, default: defaultValue)
    }

    /// Read the forgot-passcode reset opt-in without a SwiftUI view.
    static func isForgotPasscodeResetEnabled() -> Bool {
        AppPreferenceStore.shared.bool(forgotPasscodeResetEnabledKey, default: false)
    }
}
