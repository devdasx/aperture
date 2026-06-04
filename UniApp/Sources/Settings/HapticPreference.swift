import Foundation

/// User preference for app-wide haptic feedback.
///
/// Stored in `UserDefaults` under the key `hapticFeedbackEnabled` and read
/// throughout the app via `@AppStorage("hapticFeedbackEnabled")`. Default is
/// `true` — haptics are on out of the box per `CLAUDE.md` Rule #10 Part C.
///
/// Most call sites bind to `@AppStorage` directly inside a `View`. This
/// namespace exists for two reasons:
///
///  1. To declare the storage key and default value in one canonical place
///     so they cannot drift across the codebase.
///  2. To expose `isEnabled()` for the rare non-`View` call site (e.g., an
///     intent handler, an actor-isolated service) that needs to consult the
///     preference without owning a SwiftUI environment.
enum HapticPreference {
    /// `@AppStorage` / `UserDefaults` key for the haptic-enabled flag.
    static let storageKey = "hapticFeedbackEnabled"

    /// Shipped default — haptics on. Mirrors `@AppStorage` default values
    /// used at call sites; both must move together.
    static let defaultValue = true

    /// Read the preference without a SwiftUI view. Returns `defaultValue`
    /// when the key has never been written (matching `@AppStorage`'s own
    /// "use default for absent key" behavior).
    static func isEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else { return defaultValue }
        return defaults.bool(forKey: storageKey)
    }
}
