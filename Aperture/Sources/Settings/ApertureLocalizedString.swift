import Foundation

/// Aperture-wide localized-string helper. Routes every
/// `String(localized:)`-equivalent lookup through the user's selected
/// in-app language (`@GRDBStorage("languagePreference")`), not through
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
/// **Why `locale:` alone is not enough.** `String(localized:locale:)` uses
/// `locale` for *formatting* (numbers, dates), **not** for picking which
/// `.lproj` translation to load. Translation selection still follows
/// `Bundle.preferredLocalizations` (launch-time English on most devices).
/// Filter-sheet previews like “Showing all 0 transactions” stayed English
/// while the rest of the sheet (SwiftUI `Text` keys) followed the
/// environment locale.
///
/// **Fix:** resolve the matching `*.lproj` bundle for the in-app language
/// and pass it as `bundle:` to `String(localized:bundle:locale:)` (or
/// `NSLocalizedString` for raw keys).
enum ApertureLocalization {

    /// The user's currently-selected `Locale`, derived from
    /// `@GRDBStorage("languagePreference")`. Falls back to the
    /// system locale when the user has selected "System" or hasn't
    /// chosen a language yet.
    static var currentLocale: Locale {
        let stored = AppPreferenceStore.shared.string("languagePreference", default: LanguagePreference.systemCode)
        return LanguagePreference.locale(for: stored) ?? .current
    }

    /// BCP-47 code of the language whose `.lproj` we should load, or `nil`
    /// to use `Bundle.main` (system / unknown).
    private static var preferredLanguageCode: String? {
        let stored = AppPreferenceStore.shared.string(
            "languagePreference",
            default: LanguagePreference.systemCode
        )
        if stored != LanguagePreference.systemCode, !stored.isEmpty {
            return stored
        }
        return LanguagePreference.preferredSystemLanguageCode()
    }

    /// Bundle whose `Localizable.strings` match the in-app language.
    /// Falls back to `Bundle.main` when no matching `.lproj` exists.
    static var localizationBundle: Bundle {
        guard let code = preferredLanguageCode else { return .main }
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        // e.g. "pt_BR" → try "pt-BR"; "zh_CN" → "zh-Hans" already handled
        // by LanguagePreference codes. Last resort: language-only code.
        if let dash = code.split(separator: "-").first.map(String.init),
           dash != code,
           let path = Bundle.main.path(forResource: dash, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
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
        String(
            localized: key,
            bundle: ApertureLocalization.localizationBundle,
            locale: ApertureLocalization.currentLocale
        )
    }

    /// Runtime catalog key (English source string already stored in a `String`
    /// variable). Prefer the `LocalizationValue` overload for string literals.
    /// Use this for fee notes and other dynamic keys so they still honor the
    /// in-app language and resolve through `Localizable.xcstrings`.
    static func apertureLocalizedKey(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: ApertureLocalization.localizationBundle,
            value: key,
            comment: ""
        )
    }
}
