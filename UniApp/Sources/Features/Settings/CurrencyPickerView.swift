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

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestedCurrencies: [SupportedCurrency] {
        let regionCurrency = CurrencyPreference.defaultForCurrentRegion()
        return currencies(for: [regionCurrency] + CurrencyPreference.mostUsedCodes)
    }

    private var suggestedCurrencyCodes: Set<String> {
        Set(suggestedCurrencies.map(\.code))
    }

    private var remainingCurrencies: [SupportedCurrency] {
        CurrencyPreference.all.filter { !suggestedCurrencyCodes.contains($0.code) }
    }

    private var filteredCurrencies: [SupportedCurrency] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return CurrencyPreference.all }
        return CurrencyPreference.all.filter { currency in
            let localizedName = currentLocale.localizedString(forCurrencyCode: currency.code) ?? currency.englishName
            let regionName = CurrencyPreference.regionName(for: currency.code, locale: currentLocale) ?? ""
            return localizedName.localizedStandardContains(query)
                || currency.englishName.localizedStandardContains(query)
                || regionName.localizedStandardContains(query)
                || currency.code.localizedStandardContains(query)
                || currency.symbol.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            if isSearching {
                Section {
                    currencyRows(filteredCurrencies)
                }
            } else {
                Section {
                    currencyRows(suggestedCurrencies)
                } header: {
                    Text("Most used")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }

                Section {
                    currencyRows(remainingCurrencies)
                } header: {
                    Text("All currencies")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
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

    @ViewBuilder
    private func currencyRows(_ currencies: [SupportedCurrency]) -> some View {
        ForEach(currencies) { currency in
            let localized = currentLocale.localizedString(forCurrencyCode: currency.code) ?? currency.englishName
            CurrencyRow(
                currency: currency,
                localizedName: localized,
                flag: CurrencyPreference.flag(for: currency.code),
                isSelected: currencyCode == currency.code
            ) {
                currencyCode = currency.code
            }
            .listRowBackground(UniColors.List.rowBackground)
        }
    }

    private func currencies(for codes: [String]) -> [SupportedCurrency] {
        var seen: Set<String> = []
        return codes.compactMap { code in
            guard seen.insert(code).inserted else { return nil }
            return CurrencyPreference.currency(for: code)
        }
    }
}

private struct CurrencyRow: View {
    let currency: SupportedCurrency
    let localizedName: String
    let flag: String?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: UniSpacing.s) {
                leadingMark

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: localizedName)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)

                    Text(verbatim: "\(currency.code) · \(currency.symbol)")
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
            .uniListRowHitTarget()
        }
        .buttonStyle(.uniListRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(localizedName) — \(currency.code)"))
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
            Text(verbatim: currency.symbol)
                .font(UniTypography.body.weight(.semibold))
                .foregroundStyle(UniColors.Text.primary)
                .frame(width: 32, alignment: .center)
                .accessibilityHidden(true)
        }
    }
}

#Preview("Light") {
    NavigationStack {
        CurrencyPickerView()
    }
    .preferredColorScheme(.light)
}
