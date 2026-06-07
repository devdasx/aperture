import SwiftUI

/// Picker for the supported fiat currencies. Selection writes through
/// `@AppStorage(CurrencyPreference.storageKey)`. The row's primary
/// label is rendered in the user's currently-selected locale via
/// `Locale.localizedString(forCurrencyCode:)`. Filtering via native
/// `.searchable`.
struct CurrencyPickerView: View {
    @AppStorage(CurrencyPreference.storageKey)
    private var currencyCode: String = CurrencyPreference.defaultCode

    @Environment(\.locale) private var currentLocale
    @State private var searchText: String = ""

    private var filteredCurrencies: [SupportedCurrency] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return CurrencyPreference.all }
        return CurrencyPreference.all.filter { currency in
            let localizedName = currentLocale.localizedString(forCurrencyCode: currency.code) ?? currency.englishName
            return localizedName.localizedStandardContains(query)
                || currency.englishName.localizedStandardContains(query)
                || currency.code.localizedStandardContains(query)
                || currency.symbol.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredCurrencies) { currency in
                    let localized = currentLocale.localizedString(forCurrencyCode: currency.code) ?? currency.englishName
                    CurrencyRow(
                        currency: currency,
                        localizedName: localized,
                        isSelected: currencyCode == currency.code
                    ) {
                        currencyCode = currency.code
                    }
                    .listRowBackground(UniColors.Background.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Choose currency"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search"))
        .uniHaptic(.selection, trigger: currencyCode)
    }
}

private struct CurrencyRow: View {
    let currency: SupportedCurrency
    let localizedName: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: UniSpacing.s) {
                Text(verbatim: currency.symbol)
                    .font(UniTypography.body.weight(.semibold))
                    .foregroundStyle(UniColors.Text.primary)
                    .frame(width: 32, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: localizedName)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)

                    Text(verbatim: currency.code)
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .accessibilityLabel(Text(verbatim: "\(localizedName) — \(currency.code)"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview("Light") {
    NavigationStack {
        CurrencyPickerView()
    }
    .preferredColorScheme(.light)
}
