import Foundation

/// Auto-lock duration preference. Decides how long after a wallet
/// scene becomes inactive (backgrounded, screen-off) before the lock
/// screen is required to return. `@AppStorage("autoLockSeconds")`
/// integer, default `30` (the iOS-banking-app convention).
///
/// `0` means "lock immediately" — the lock screen presents the
/// instant the scene becomes active after any background period.
/// `Int.max` (`-1` in storage to avoid the `Int.max` literal) means
/// "never" — the wallet stays unlocked across foregrounds until the
/// user explicitly locks (future hatch). For v1 we ship the four
/// natural options below; the `Int` `@AppStorage` accepts arbitrary
/// values so a future hatch can extend without migration.
enum AutoLockPreference {
    static let storageKey = "autoLockSeconds"
    static let defaultValue = 30

    enum Option: Int, CaseIterable, Identifiable, Sendable {
        case immediately = 0
        case thirtySeconds = 30
        case oneMinute = 60
        case fiveMinutes = 300
        case never = -1

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .immediately:    return String.apertureLocalized("Immediately")
            case .thirtySeconds:  return String.apertureLocalized("After 30 seconds")
            case .oneMinute:      return String.apertureLocalized("After 1 minute")
            case .fiveMinutes:    return String.apertureLocalized("After 5 minutes")
            case .never:          return String.apertureLocalized("Never")
            }
        }
    }

    /// Resolve the stored raw value to a duration in seconds. Returns
    /// `nil` for the "never" sentinel so the controller treats it as
    /// "do not auto-lock."
    static func resolvedDuration(_ raw: Int) -> TimeInterval? {
        if raw < 0 { return nil }
        return TimeInterval(raw)
    }

    /// Resolve the stored raw value to its Option for picker
    /// rendering. Falls back to the default if the stored value
    /// doesn't match a known option (forward-compat for future custom
    /// values).
    static func option(for raw: Int) -> Option {
        Option(rawValue: raw) ?? .thirtySeconds
    }
}
