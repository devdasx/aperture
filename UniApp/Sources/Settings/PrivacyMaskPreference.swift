import Foundation

/// User preference for the privacy mask that covers the app whenever
/// the scene isn't fully active.
///
/// **What this controls.** When ON (default), `PrivacyMaskView`
/// renders an opaque brand surface (wordmark + app mark) over the
/// app any time `scenePhase != .active` AND a PIN is configured. The
/// mask serves two roles: hides wallet content from the iOS task-
/// switcher snapshot, and bridges the foreground reveal so the home
/// never flashes before the lock screen arrives. When OFF, the
/// scene's last-active frame is what iOS uses for the task-switcher
/// snapshot — the user opted out of the brand mask.
///
/// **Why default ON.** Privacy is the safer default for a self-
/// custody wallet: balances, addresses, transactions shouldn't be
/// visible in the task switcher to anyone who can glance at the
/// device. Banking apps, password managers, and Apple's own Wallet
/// all ship this on by default. Per the user direction
/// (2026-06-09), the toggle is available — but the default stays
/// on.
///
/// **PIN gate.** This preference is one of TWO conditions on the
/// privacy mask; the other is `PinCodePreference.isPinEnabled()`.
/// A user with no PIN configured already exposes their wallet
/// without authentication, so the privacy mask would be theatre.
/// The mask only matters as a protection if the user has a PIN.
enum PrivacyMaskPreference {
    static let storageKey = "privacyMaskEnabled"
    static let defaultValue = true

    static func isEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else { return defaultValue }
        return defaults.bool(forKey: storageKey)
    }
}
