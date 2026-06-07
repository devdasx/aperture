import Foundation

/// User preferences for the unified PIN + biometric system (Rule #17).
///
/// Mirrors `HapticPreference.swift` and `ThemePreference.swift` in shape —
/// a namespace exposing storage keys and read accessors that bypass
/// SwiftUI's environment for the rare non-view caller.
///
/// **Two keys, two meanings.**
/// - `pinEnabled` — the user has set a 6-digit PIN. Implies
///   `PinCodeStorage.hasPin == true` (we keep them in sync at the call site).
///   `false` means the user skipped PIN setup with honest warning; the
///   wallet is protected only by the iPhone's own lock screen.
/// - `biometricEnabled` — the user authenticated with Face ID / Touch ID
///   during setup. `true` means they want biometrics for app unlock and
///   transaction confirmation. `false` is the safe default — set to `true`
///   only after a real `BiometricService.authenticate(...)` success.
///
/// Defaults: both `false`. This matches the create-wallet flow where a
/// fresh-install user has not yet chosen.
enum PinCodePreference {
    /// `@AppStorage` key for the PIN-enabled flag. Mirrors `PinCodeStorage.hasPin`
    /// at the moment of setup; the AppStorage value is the user-intent flag
    /// while Keychain holds the actual material.
    static let pinEnabledKey: String = "pinEnabled"

    /// `@AppStorage` key for the biometric-enabled flag. Set to `true` only
    /// after a real `BiometricService.authenticate(...)` returns
    /// `.success(())` — never auto-enabled.
    static let biometricEnabledKey: String = "biometricEnabled"

    /// Default for both flags. Fresh-install users have not opted in to
    /// either protection.
    static let defaultValue: Bool = false

    /// Read `pinEnabled` without a SwiftUI view. Matches `@AppStorage`'s
    /// "absent key → default" semantics.
    static func isPinEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: pinEnabledKey) != nil else { return defaultValue }
        return defaults.bool(forKey: pinEnabledKey)
    }

    /// Read `biometricEnabled` without a SwiftUI view.
    static func isBiometricEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: biometricEnabledKey) != nil else { return defaultValue }
        return defaults.bool(forKey: biometricEnabledKey)
    }
}
