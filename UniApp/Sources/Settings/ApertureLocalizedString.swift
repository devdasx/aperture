import Foundation

/// Aperture-wide localized-string helper. Routes every
/// `String(localized:)`-equivalent lookup through the user's selected
/// in-app language (`@AppStorage("languagePreference")`), not through
/// `Bundle.main`'s launch-time `preferredLocalizations`.
///
/// **Why this exists.** Apple's stock `String(localized: "...")` resolves
/// the key through `Bundle.main`'s preferred localization chain, which
/// is fixed when the process launches. Aperture changes the in-app
/// language via SwiftUI's `\.environment(\.locale)` only (no
/// `AppleLanguages` `UserDefaults` rewrite — that would require an
/// app relaunch, breaking the live-rebuild pattern Rule #12 §F
/// established). Result: `String(localized:)` returns English even
/// when the user has selected Arabic in Settings → Language. The
/// catalog has the Arabic translation; it's just unreachable.
///
/// Fix: read the user's `languagePreference` from `UserDefaults`,
/// derive a `Locale`, and pass it to `String(localized:locale:)`
/// every time. This file is the single helper every site uses.
enum ApertureLocalization {

    /// The user's currently-selected `Locale`, derived from
    /// `@AppStorage("languagePreference")`. Falls back to the
    /// system locale when the user has selected "System" or hasn't
    /// chosen a language yet.
    static var currentLocale: Locale {
        let stored = UserDefaults.standard.string(forKey: "languagePreference")
            ?? LanguagePreference.systemCode
        return LanguagePreference.locale(for: stored) ?? .current
    }
}

extension String {
    /// Aperture's locale-aware variant of `String(localized:)`. Always
    /// reads through the user's selected in-app language. Use this
    /// at every site where you'd write
    /// `String(localized: "Some key")` AND the result is rendered
    /// to the user.
    ///
    /// Sites that don't need user-language honoring (e.g., debug
    /// logs, exception messages, file names) can keep
    /// `String(localized:)` — but in this codebase that's basically
    /// nowhere.
    static func apertureLocalized(_ key: String.LocalizationValue) -> String {
        String(localized: key, locale: ApertureLocalization.currentLocale)
    }
}
