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
/// - `biometricEnabled` — the user authenticated with Face ID / Touch ID
///   during setup. `true` means they want biometrics for app unlock and
///   transaction confirmation. `false` is the safe default — set to `true`
///   only after a real `BiometricService.authenticate(...)` success.
/// - `requireBiometricForSend` — per-action Face ID gate for transaction
///   signing. It follows `biometricEnabled` by default: enabling Face ID turns
///   this on, disabling Face ID turns it off.
///
/// Defaults: PIN and biometrics are `false`; the send gate defaults to `true`
/// only as the enabled-Face-ID default and is forced off whenever biometrics
/// are off.
enum PinCodePreference {
    /// `@GRDBStorage` key for the PIN-enabled flag. Mirrors `PinCodeStorage.hasPin`
    /// at the moment of setup; the GRDB preference is the user-intent flag
    /// while Keychain holds the actual material.
    static let pinEnabledKey: String = "pinEnabled"

    /// `@GRDBStorage` key for the biometric-enabled flag. Set to `true` only
    /// after a real `BiometricService.authenticate(...)` returns
    /// `.success(())` — never auto-enabled.
    static let biometricEnabledKey: String = "biometricEnabled"

    /// `@GRDBStorage` key for the "Use Face ID For → Sending transactions"
    /// row. It is only meaningful while `biometricEnabled == true`.
    static let requireBiometricForSendKey: String = "requireBiometricForSend"

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
}
