import SwiftUI

/// The canonical app-environment modifier. Applies the user's persisted
/// preferences for color scheme, locale, and layout direction to a view tree.
///
/// **Apply at every presentation surface root** — `WindowGroup` content, every
/// `.sheet(...)` content view, every `.fullScreenCover(...)`, every
/// `.popover(...)`, every standalone `UIWindow` if we ever add one. Without
/// this on a sheet's content, the sheet inherits the system's color scheme
/// instead of the user's preference (because `.preferredColorScheme(_:)` is
/// scoped to the presenting window — sheets get their own scope).
///
/// See `CLAUDE.md` Rule #12 for the full contract.
struct UniAppEnvironmentModifier: ViewModifier {
    @AppStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

    private var theme: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.colorScheme)
            .environment(\.locale, LanguagePreference.locale(for: languageCode) ?? .current)
            .environment(\.layoutDirection, LanguagePreference.layoutDirection(for: languageCode))
    }
}

extension View {
    /// Applies `themePreference` + `languagePreference` (locale + layout
    /// direction) to this view. Required on every presentation surface root
    /// per `CLAUDE.md` Rule #12.
    func uniAppEnvironment() -> some View {
        modifier(UniAppEnvironmentModifier())
    }
}
