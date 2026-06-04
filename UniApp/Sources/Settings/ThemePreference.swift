import SwiftUI

/// User-selectable appearance preference. Stored under `themePreference`
/// in `@AppStorage`. Resolves to a `ColorScheme?` for `.preferredColorScheme`
/// (`nil` means "follow the system").
///
/// Implements `TODO` T-006.
enum ThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The value to pass to `.preferredColorScheme(_:)`. `nil` lets iOS
    /// follow the system Dark/Light setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Localized label for Settings UI.
    var label: LocalizedStringKey {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// SF Symbol for the row leading icon.
    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
}
