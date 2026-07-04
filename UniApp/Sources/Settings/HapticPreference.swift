import Foundation

/// User preference for app-wide haptic feedback.
///
/// Stored in GRDB under the key `hapticFeedbackEnabled` and read
/// throughout the app via `@GRDBStorage("hapticFeedbackEnabled")`. Default is
/// `true` — haptics are on out of the box per `CLAUDE.md` Rule #10 Part C.
///
/// Most call sites bind to `@GRDBStorage` directly inside a `View`. This
/// namespace exists for two reasons:
///
///  1. To declare the storage key and default value in one canonical place
///     so they cannot drift across the codebase.
///  2. To expose `isEnabled()` for the rare non-`View` call site (e.g., an
///     intent handler, an actor-isolated service) that needs to consult the
///     preference without owning a SwiftUI environment.
enum HapticPreference {
    /// `@GRDBStorage` key for the haptic-enabled flag.
    static let storageKey = "hapticFeedbackEnabled"

    /// Shipped default — haptics on. Mirrors `@GRDBStorage` default values
    /// used at call sites; both must move together.
    static let defaultValue = true

    /// Read the preference without a SwiftUI view. Returns `defaultValue`
    /// when the key has never been written (matching `@GRDBStorage`'s own
    /// "use default for absent key" behavior).
    static func isEnabled() -> Bool {
        AppPreferenceStore.shared.bool(storageKey, default: defaultValue)
    }
}
