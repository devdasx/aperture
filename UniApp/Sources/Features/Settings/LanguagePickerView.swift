import SwiftUI

/// Picker for the 50 supported languages plus the "System" sentinel.
///
/// **Row anatomy (updated 2026-06-04 to feel native in every locale).**
/// Leading: the language's regional **flag emoji** (replacing the generic
/// `globe` symbol — the flag carries identification cleanly, the globe
/// was generic chrome). Primary line: the language's **native self-name**
/// (per HIG — "show each language in its own language so users can find
/// their own without reading English"). Secondary line: the language's
/// name **rendered in the user's currently-selected locale** via
/// `Locale.localizedString(forLanguageCode:)` — a Spanish user sees
/// "Inglés / Árabe / Bengalí"; a Japanese user sees "英語 / アラビア語".
/// Trailing region: a small **code chip** (e.g. "EN", "ZH-HANS") for
/// audit, then a `checkmark` on the selected row.
///
/// The localized-name resolution is fully native — iOS ships every
/// language name in every supported locale via `Locale.localizedString`.
/// No catalog entries are needed. When the user picks a new language,
/// the `\.locale` environment cascades and every secondary line
/// re-renders automatically.
///
/// Selecting a row writes through `@AppStorage("languagePreference")`,
/// which `UniAppApp` reads and binds to `.environment(\.locale, …)`.
/// Every `Text(LocalizedStringKey)` in the app — including the slides
/// behind this sheet — re-renders in the new language automatically.
///
/// RTL languages (`ar`, `fa`, `ur`, `he`) carry `isRTL = true` in their
/// `SupportedLanguage` record. Row layout flips for free via
/// `.environment(\.layoutDirection, …)` inherited from the locale — no
/// per-row code path needed. The one allowed Rule #11 exception is the
/// per-`Text` direction override on the native-name `Text`, so a Persian
/// self-name renders right-aligned inside an LTR English picker (and
/// vice-versa).
///
/// **Search.** On iOS 26, applying `.searchable(text:)` to a view inside
/// a `NavigationStack` causes the system to render the search field in a
/// **floating Liquid Glass container at the bottom of the screen** on
/// iPhone (top-trailing on iPad/macOS). This is Apple's default and
/// honors Rule #3 (native-only): we do not specify a `placement:` —
/// the platform decides. Filtering uses `localizedStandardContains`
/// against `nativeName`, `englishName`, the localized name, and `code`,
/// which is locale-aware and folds case + diacritics across scripts
/// (so "esp" finds "Español", "中" finds "简体中文", "ع" finds "العربية").
/// The "System" sentinel row stays pinned at the top regardless of
/// query — it is not a language entry.
struct LanguagePickerView: View {
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

    /// The user's currently-effective locale, propagated by the app-root
    /// `.environment(\.locale, …)` binding. Used to render each row's
    /// secondary line via `Locale.localizedString(forLanguageCode:)`.
    @Environment(\.locale) private var currentLocale

    @State private var searchText: String = ""

    /// Languages that match the trimmed query against native name,
    /// English name, the user-locale-resolved name, or BCP-47 code.
    /// Empty query returns the full list.
    private var filteredLanguages: [SupportedLanguage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return LanguagePreference.all }
        return LanguagePreference.all.filter { language in
            let localizedName = currentLocale.localizedString(forLanguageCode: language.code) ?? language.englishName
            return language.nativeName.localizedStandardContains(query)
                || language.englishName.localizedStandardContains(query)
                || localizedName.localizedStandardContains(query)
                || language.code.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                LanguageRow(
                    code: LanguagePreference.systemCode,
                    flag: nil,
                    nativeName: "System",
                    localizedName: String(localized: "Use iOS system language"),
                    isRTL: false,
                    isSelected: languageCode == LanguagePreference.systemCode,
                    isSystemRow: true
                ) {
                    languageCode = LanguagePreference.systemCode
                }
            }

            Section {
                ForEach(filteredLanguages) { language in
                    let localized = currentLocale.localizedString(forLanguageCode: language.code) ?? language.englishName
                    LanguageRow(
                        code: language.code,
                        flag: language.flag,
                        nativeName: language.nativeName,
                        localizedName: localized,
                        isRTL: language.isRTL,
                        isSelected: languageCode == language.code,
                        isSystemRow: false
                    ) {
                        languageCode = language.code
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("Choose language"))
        .navigationBarTitleDisplayMode(.inline)
        // Native iOS 26 behavior: the system renders this as a floating
        // Liquid Glass search field at the bottom of the screen on iPhone.
        // No `placement:` — the platform owns the decision.
        .searchable(text: $searchText, prompt: Text("Search"))
        // Rule #10: every preference change fires one selection beat.
        .uniHaptic(.selection, trigger: languageCode)
    }
}

// MARK: - Row

private struct LanguageRow: View {
    let code: String
    /// Flag emoji for the row, or `nil` for the System sentinel row
    /// (which uses an SF Symbol globe — no country represents "system").
    let flag: String?
    let nativeName: String
    /// The language name rendered in the user's currently-selected
    /// locale (e.g. "Inglés" for `en` when the locale is Spanish). For
    /// the System sentinel row this carries the localized "Use iOS
    /// system language" copy.
    let localizedName: String
    let isRTL: Bool
    let isSelected: Bool
    let isSystemRow: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: UniSpacing.s) {
                leadingMark

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    // Native name is the user's own-language self-name;
                    // do not localize through the catalog — the string is
                    // already in its target language. For the System row,
                    // localize the word "System".
                    if isSystemRow {
                        Text("System")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                            .multilineTextAlignment(.leading)
                        Text(verbatim: localizedName)
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(verbatim: nativeName)
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                            .multilineTextAlignment(isRTL ? .trailing : .leading)
                            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
                        Text(verbatim: localizedName)
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isSystemRow {
                    codeChip
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: isSystemRow ? "System" : "\(nativeName) — \(localizedName)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Leading column — a country/region flag emoji for language rows,
    /// the SF Symbol globe for the System sentinel row. The flag IS the
    /// visual identifier; the System row uses the canonical iOS
    /// "no-region" mark so users recognize it from iOS Settings.
    @ViewBuilder
    private var leadingMark: some View {
        if let flag {
            Text(verbatim: flag)
                .font(.system(size: 24))
                .frame(width: 32, alignment: .center)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 32, alignment: .center)
                .accessibilityHidden(true)
        }
    }

    /// Small capsule chip carrying the BCP-47 code (e.g. "EN",
    /// "ZH-HANS"). Restrained — caption2 weight on a tertiary-fill pill
    /// so it reads as a code, not as a label, and never competes with
    /// the native name to its left.
    private var codeChip: some View {
        Text(verbatim: code.uppercased())
            .font(UniTypography.caption2.weight(.semibold))
            .foregroundStyle(UniColors.Text.tertiary)
            .padding(.horizontal, UniSpacing.xs)
            .padding(.vertical, UniSpacing.xxs)
            .background(
                Capsule(style: .continuous)
                    .fill(UniColors.Fill.tertiary)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        LanguagePickerView()
    }
    .preferredColorScheme(.light)
}
