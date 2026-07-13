import SwiftUI

/// Picker for the supported languages plus the "System" sentinel.
///
/// Selection writes through `@GRDBStorage("languagePreference")`. The
/// secondary row line is rendered in the user's currently-selected
/// locale via `Locale.localizedString(forLanguageCode:)`. Filtering via
/// native `.searchable`.
struct LanguagePickerView: View {
    @GRDBStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @Environment(\.locale) private var currentLocale
    @State private var searchText: String = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestedLanguages: [SupportedLanguage] {
        languages(for: [
            LanguagePreference.regionalLanguageCode(),
            LanguagePreference.preferredSystemLanguageCode()
        ].compactMap { $0 } + LanguagePreference.mostUsedCodes)
    }

    private var suggestedLanguageCodes: Set<String> {
        Set(suggestedLanguages.map(\.code))
    }

    private var remainingLanguages: [SupportedLanguage] {
        LanguagePreference.all.filter { !suggestedLanguageCodes.contains($0.code) }
    }

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
            if isSearching {
                Section {
                    languageRows(filteredLanguages)
                }
            } else {
                Section {
                    languageRows(suggestedLanguages)
                } header: {
                    Text("Most used")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }

                Section {
                    systemRow
                }

                Section {
                    languageRows(remainingLanguages)
                } header: {
                    Text("All languages")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
        }
        .uniListPageChrome()
        .navigationTitle(Text("Choose language"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text(verbatim: String.apertureLocalized("Search")))
        .uniHaptic(.selection, trigger: languageCode)
    }

    private var systemRow: some View {
        LanguageRow(
            flag: nil,
            nativeName: "System",
            // Pass `locale:` explicitly. `String(localized:)`
            // without it resolves through `Bundle.main`'s
            // launch-time `preferredLocalizations`, which
            // does NOT honor SwiftUI's `\.environment(\.locale)`.
            // Aperture changes the in-app language via the
            // environment binding only (no `AppleLanguages`
            // process-global rewrite, which would require an
            // app restart). Passing `locale: currentLocale`
            // routes the lookup through the user-selected
            // language. Same fix pattern needed at every
            // `String(localized:)` site whose output reaches
            // a `Text` view in the UI.
            localizedName: String.apertureLocalized("Use iOS system language"),
            isSelected: languageCode == LanguagePreference.systemCode,
            isSystemRow: true
        ) {
            languageCode = LanguagePreference.systemCode
        }
        .uniListRowSurface()
    }

    @ViewBuilder
    private func languageRows(_ languages: [SupportedLanguage]) -> some View {
        ForEach(languages) { language in
            let localized = currentLocale.localizedString(forLanguageCode: language.code) ?? language.englishName
            LanguageRow(
                flag: language.flag,
                nativeName: language.nativeName,
                localizedName: localized,
                isSelected: languageCode == language.code,
                isSystemRow: false
            ) {
                languageCode = language.code
            }
            .uniListRowSurface()
        }
    }

    private func languages(for codes: [String]) -> [SupportedLanguage] {
        var seen: Set<String> = []
        return codes.compactMap { code in
            guard seen.insert(code).inserted else { return nil }
            return LanguagePreference.language(for: code)
        }
    }
}

private struct LanguageRow: View {
    let flag: String?
    let nativeName: String
    let localizedName: String
    let isSelected: Bool
    let isSystemRow: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: UniSpacing.s) {
                leadingMark
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
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
                        // Native script (including Arabic/Hebrew) stays
                        // left-aligned in the same slot as every other
                        // language — do not flip the row for RTL scripts.
                        Text(verbatim: nativeName)
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: localizedName)
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(UniColors.Icon.accent)
                        .accessibilityHidden(true)
                }
            }
            // Force LTR chrome for every row so the app's RTL locale
            // (when Arabic/Hebrew is selected) does not reverse flag /
            // name / checkmark order across languages.
            .environment(\.layoutDirection, .leftToRight)
            .uniListRowHitTarget()
        }
        .buttonStyle(.uniListRow)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: isSystemRow ? "System" : "\(nativeName) — \(localizedName)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

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
}

#Preview("Light") {
    NavigationStack {
        LanguagePickerView()
    }
    .preferredColorScheme(.light)
}
