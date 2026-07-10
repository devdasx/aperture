import SwiftUI

/// User-selectable appearance preference. System follows iOS and resolves
/// light to Cloud and dark to Midnight. Dark is the explicit true-black OLED
/// appearance.
enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case cloud
    case midnight
    case dark

    var id: String { rawValue }

    /// Default raw value for fresh installs and any `@GRDBStorage` reader
    /// whose key hasn't been written yet. Per the 2026-06-05 user
    /// direction, fresh installs follow the device's appearance — same
    /// shape as the Language and Currency defaults.
    static let defaultRaw: String = ThemePreference.system.rawValue

    /// Reads persisted values while preserving compatibility with installs
    /// that stored the previous `light` case.
    static func stored(_ rawValue: String) -> ThemePreference {
        if rawValue == "light" { return .cloud }
        return ThemePreference(rawValue: rawValue) ?? .system
    }

    /// The value to pass to `.preferredColorScheme(_:)`. `nil` lets iOS
    /// follow the system Dark/Light setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .cloud: return .light
        case .midnight, .dark: return .dark
        }
    }

    var apertureAppearance: ApertureAppearance {
        switch self {
        case .system: return .system
        case .cloud: return .cloud
        case .midnight: return .midnight
        case .dark: return .dark
        }
    }

    /// Localized label for Settings UI.
    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .cloud: return "Cloud"
        case .midnight: return "Midnight"
        case .dark: return "Dark"
        }
    }

    /// SF Symbol for the row leading icon.
    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .cloud: return "cloud"
        case .midnight: return "moon.stars"
        case .dark: return "moon.fill"
        }
    }
}
