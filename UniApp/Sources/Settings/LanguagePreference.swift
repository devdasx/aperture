import Foundation
import SwiftUI

/// User-selectable in-app language. `nil` (= `.system`) means follow the
/// iOS-level preferred language list. A non-nil value overrides via
/// `.environment(\.locale, …)` at the app root.
///
/// Source of truth for the 50 supported languages — must stay in sync with
/// `CLAUDE.md` Rule #9 Part A and the two translator agents.
struct SupportedLanguage: Identifiable, Hashable, Sendable {
    /// BCP-47 code (matches the `Localizable.xcstrings` localization key).
    let code: String
    /// English name (for fallback / audit). Note: the picker no longer
    /// renders this directly — it resolves the language's name in the
    /// user's currently-selected locale via
    /// `Locale.localizedString(forLanguageCode:)` so the secondary line
    /// follows the chosen UI language. `englishName` remains as a stable
    /// audit field and a last-resort fallback.
    let englishName: String
    /// Native-language self-name (what the user sees in the picker — the
    /// most important field, per HIG: "show each language in its own
    /// language so users can find their own without reading English").
    let nativeName: String
    /// `true` for languages that lay out right-to-left.
    let isRTL: Bool
    /// Unicode regional-indicator flag emoji for the language's most
    /// representative country/region. Carries identity at a glance and
    /// replaces the generic globe glyph that used to lead each row.
    /// Catalan uses 🇪🇸 (no Catalonia flag in Unicode); Swahili uses 🇰🇪
    /// (Kenya, the more recognizable co-official Swahili nation).
    let flag: String

    var id: String { code }
}

enum LanguagePreference {
    /// Sentinel for the picker meaning "follow iOS".
    static let systemCode = "system"

    /// All 50 target languages plus English source. The picker prepends the
    /// "System" sentinel itself at render time. Order: English source first
    /// (the source-of-truth language for the catalog), then alphabetized by
    /// BCP-47 code. The native-name self-renders in each row regardless of
    /// the user's currently-selected locale.
    ///
    /// Native-name spelling verified against iOS Settings (Apple's canonical
    /// rendering) for every script. CJK + Indic + Arabic-script forms use
    /// the language's own writing system — not transliterated Latin — so the
    /// user finds their language without reading English. Per Rule #8
    /// (`MISTAKES.md`), a misspelled native name in the picker is a logged
    /// design error; this list is checked against Apple's references before
    /// shipping.
    static let all: [SupportedLanguage] = [
        // Source language
        .init(code: "en",       englishName: "English",                nativeName: "English",          isRTL: false, flag: "🇺🇸"),

        // Targets — alphabetized by BCP-47 code
        .init(code: "af",       englishName: "Afrikaans",              nativeName: "Afrikaans",        isRTL: false, flag: "🇿🇦"),
        .init(code: "ar",       englishName: "Arabic",                 nativeName: "العربية",          isRTL: true,  flag: "🇸🇦"),
        .init(code: "bg",       englishName: "Bulgarian",              nativeName: "Български",        isRTL: false, flag: "🇧🇬"),
        .init(code: "bn",       englishName: "Bengali",                nativeName: "বাংলা",            isRTL: false, flag: "🇧🇩"),
        .init(code: "ca",       englishName: "Catalan",                nativeName: "Català",           isRTL: false, flag: "🇪🇸"),
        .init(code: "cs",       englishName: "Czech",                  nativeName: "Čeština",          isRTL: false, flag: "🇨🇿"),
        .init(code: "da",       englishName: "Danish",                 nativeName: "Dansk",            isRTL: false, flag: "🇩🇰"),
        .init(code: "de",       englishName: "German",                 nativeName: "Deutsch",          isRTL: false, flag: "🇩🇪"),
        .init(code: "el",       englishName: "Greek",                  nativeName: "Ελληνικά",         isRTL: false, flag: "🇬🇷"),
        .init(code: "es",       englishName: "Spanish",                nativeName: "Español",          isRTL: false, flag: "🇪🇸"),
        .init(code: "et",       englishName: "Estonian",               nativeName: "Eesti",            isRTL: false, flag: "🇪🇪"),
        .init(code: "fa",       englishName: "Persian",                nativeName: "فارسی",            isRTL: true,  flag: "🇮🇷"),
        .init(code: "fi",       englishName: "Finnish",                nativeName: "Suomi",            isRTL: false, flag: "🇫🇮"),
        .init(code: "fil",      englishName: "Filipino",               nativeName: "Filipino",         isRTL: false, flag: "🇵🇭"),
        .init(code: "fr",       englishName: "French",                 nativeName: "Français",         isRTL: false, flag: "🇫🇷"),
        .init(code: "he",       englishName: "Hebrew",                 nativeName: "עברית",            isRTL: true,  flag: "🇮🇱"),
        .init(code: "hi",       englishName: "Hindi",                  nativeName: "हिन्दी",            isRTL: false, flag: "🇮🇳"),
        .init(code: "hr",       englishName: "Croatian",               nativeName: "Hrvatski",         isRTL: false, flag: "🇭🇷"),
        .init(code: "hu",       englishName: "Hungarian",              nativeName: "Magyar",           isRTL: false, flag: "🇭🇺"),
        .init(code: "id",       englishName: "Indonesian",             nativeName: "Bahasa Indonesia", isRTL: false, flag: "🇮🇩"),
        .init(code: "is",       englishName: "Icelandic",              nativeName: "Íslenska",         isRTL: false, flag: "🇮🇸"),
        .init(code: "it",       englishName: "Italian",                nativeName: "Italiano",         isRTL: false, flag: "🇮🇹"),
        .init(code: "ja",       englishName: "Japanese",               nativeName: "日本語",            isRTL: false, flag: "🇯🇵"),
        .init(code: "ko",       englishName: "Korean",                 nativeName: "한국어",            isRTL: false, flag: "🇰🇷"),
        .init(code: "lt",       englishName: "Lithuanian",             nativeName: "Lietuvių",         isRTL: false, flag: "🇱🇹"),
        .init(code: "lv",       englishName: "Latvian",                nativeName: "Latviešu",         isRTL: false, flag: "🇱🇻"),
        .init(code: "ml",       englishName: "Malayalam",              nativeName: "മലയാളം",          isRTL: false, flag: "🇮🇳"),
        .init(code: "mr",       englishName: "Marathi",                nativeName: "मराठी",            isRTL: false, flag: "🇮🇳"),
        .init(code: "ms",       englishName: "Malay",                  nativeName: "Bahasa Melayu",    isRTL: false, flag: "🇲🇾"),
        .init(code: "nb",       englishName: "Norwegian Bokmål",       nativeName: "Norsk bokmål",     isRTL: false, flag: "🇳🇴"),
        .init(code: "nl",       englishName: "Dutch",                  nativeName: "Nederlands",       isRTL: false, flag: "🇳🇱"),
        .init(code: "pa",       englishName: "Punjabi (Gurmukhi)",     nativeName: "ਪੰਜਾਬੀ",            isRTL: false, flag: "🇮🇳"),
        .init(code: "pl",       englishName: "Polish",                 nativeName: "Polski",           isRTL: false, flag: "🇵🇱"),
        .init(code: "pt-BR",    englishName: "Portuguese (Brazil)",    nativeName: "Português (Brasil)", isRTL: false, flag: "🇧🇷"),
        .init(code: "ro",       englishName: "Romanian",               nativeName: "Română",           isRTL: false, flag: "🇷🇴"),
        .init(code: "ru",       englishName: "Russian",                nativeName: "Русский",          isRTL: false, flag: "🇷🇺"),
        .init(code: "sk",       englishName: "Slovak",                 nativeName: "Slovenčina",       isRTL: false, flag: "🇸🇰"),
        .init(code: "sl",       englishName: "Slovenian",              nativeName: "Slovenščina",      isRTL: false, flag: "🇸🇮"),
        .init(code: "sr",       englishName: "Serbian",                nativeName: "Српски",           isRTL: false, flag: "🇷🇸"),
        .init(code: "sv",       englishName: "Swedish",                nativeName: "Svenska",          isRTL: false, flag: "🇸🇪"),
        .init(code: "sw",       englishName: "Swahili",                nativeName: "Kiswahili",        isRTL: false, flag: "🇰🇪"),
        .init(code: "ta",       englishName: "Tamil",                  nativeName: "தமிழ்",            isRTL: false, flag: "🇮🇳"),
        .init(code: "te",       englishName: "Telugu",                 nativeName: "తెలుగు",           isRTL: false, flag: "🇮🇳"),
        .init(code: "th",       englishName: "Thai",                   nativeName: "ไทย",              isRTL: false, flag: "🇹🇭"),
        .init(code: "tr",       englishName: "Turkish",                nativeName: "Türkçe",           isRTL: false, flag: "🇹🇷"),
        .init(code: "uk",       englishName: "Ukrainian",              nativeName: "Українська",       isRTL: false, flag: "🇺🇦"),
        .init(code: "ur",       englishName: "Urdu",                   nativeName: "اُردُو",            isRTL: true,  flag: "🇵🇰"),
        .init(code: "vi",       englishName: "Vietnamese",             nativeName: "Tiếng Việt",       isRTL: false, flag: "🇻🇳"),
        .init(code: "zh-Hans",  englishName: "Chinese (Simplified)",   nativeName: "简体中文",          isRTL: false, flag: "🇨🇳"),
        .init(code: "zh-Hant",  englishName: "Chinese (Traditional)",  nativeName: "繁體中文",          isRTL: false, flag: "🇹🇼")
    ]

    /// Resolve a stored preference (`code` or `systemCode`) to an explicit
    /// `Locale?` for `.environment(\.locale, …)`. `nil` = follow system.
    static func locale(for code: String) -> Locale? {
        guard code != systemCode, !code.isEmpty else { return nil }
        return Locale(identifier: code)
    }

    /// Look up a language by code; returns nil for `systemCode`.
    static func language(for code: String) -> SupportedLanguage? {
        all.first { $0.code == code }
    }

    /// Resolve a stored preference to a SwiftUI `LayoutDirection` for the
    /// app root. RTL languages (`ar`, `fa`, `ur`, `he`) return `.rightToLeft`;
    /// everything else returns `.leftToRight`. For `systemCode`, defers to
    /// the system locale's character direction so iOS keeps owning the
    /// choice when the user picks "System".
    ///
    /// Used by `UniAppApp` to bind `.environment(\.layoutDirection, …)` at
    /// the WindowGroup. Per `CLAUDE.md` Rule #11, no view downstream should
    /// override layout direction — children inherit and re-layout
    /// automatically when the preference changes.
    static func layoutDirection(for code: String) -> LayoutDirection {
        let locale = LanguagePreference.locale(for: code) ?? .current
        return locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }
}
