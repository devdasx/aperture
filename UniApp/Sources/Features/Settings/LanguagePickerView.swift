import SwiftUI

/// Picker for the supported languages plus the "System" sentinel.
///
/// Selection writes through `@AppStorage("languagePreference")`. The
/// secondary row line is rendered in the user's currently-selected
/// locale via `Locale.localizedString(forLanguageCode:)`. Filtering via
/// native `.searchable`.
struct LanguagePickerView: View {
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @Environment(\.locale) private var currentLocale
    @State private var searchText: String = ""

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
                    // Pass `locale:` explicitly. `String(localized:)`
                    // without it resolves through `Bundle.main`'s
                    // launch-time `preferredLocalizations`, which
                    // does NOT honor SwiftUI's `\.environment(\.locale)`.
                    // Aperture changes the in-app language via the
                    // environment binding only (no `AppleLanguages`
                    // UserDefaults rewrite, which would require an
                    // app restart). Passing `locale: currentLocale`
                    // routes the lookup through the user-selected
                    // language. Same fix pattern needed at every
                    // `String(localized:)` site whose output reaches
                    // a `Text` view in the UI.
                    localizedName: String(localized: "Use iOS system language", locale: currentLocale),
                    isRTL: false,
                    isSelected: languageCode == LanguagePreference.systemCode,
                    isSystemRow: true
                ) {
                    languageCode = LanguagePreference.systemCode
                }
                .listRowBackground(UniColors.Background.secondary)
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
                    .listRowBackground(UniColors.Background.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Choose language"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search"))
        .uniHaptic(.selection, trigger: languageCode)
    }
}

private struct LanguageRow: View {
    let code: String
    let flag: String?
    let nativeName: String
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
                if !isSystemRow { codeChip }
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

#Preview("Light") {
    NavigationStack {
        LanguagePickerView()
    }
    .preferredColorScheme(.light)
}
