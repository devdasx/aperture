import SwiftUI

/// Picker for the 20 supported fiat currencies. Mirrors the structure of
/// `LanguagePickerView`: an `insetGrouped` list of rows, each showing the
/// currency's glyph + English name + ISO-4217 code, with a trailing
/// `checkmark` on the currently-selected row.
///
/// Selection writes through `@AppStorage("currencyPreference")` (the
/// canonical key declared in `CurrencyPreference.storageKey`). The
/// `PriceService` reads the same key when fetching from Coinbase, so
/// every quoted price flips to the new fiat as soon as the row is tapped.
///
/// The picker stays pushed within the Settings sheet's `NavigationStack`
/// — no dismiss-on-tap. The user pops back via the system back button.
/// This matches `LanguagePickerView` and `AppearancePickerView`.
///
/// Per Rule #10, the view applies `.uniHaptic(.selection, trigger:)` so
/// every change in `currencyCode` produces one selection beat.
///
/// **Localized currency names (T-020 resolved 2026-06-04).** The row's
/// primary label is no longer the hardcoded English `englishName`. It is
/// the currency's name **rendered in the user's currently-selected
/// locale** via `Locale.localizedString(forCurrencyCode:)` — so a
/// Spanish user sees "Dólar estadounidense / Euro / Libra esterlina";
/// a Japanese user sees "米ドル / ユーロ". iOS ships every ISO-4217
/// currency's localized name in every supported locale; we just ask
/// for it. `englishName` remains in the type as a stable audit field
/// and a last-resort fallback if the system returns `nil`.
///
/// **Search.** On iOS 26, applying `.searchable(text:)` to a view inside
/// a `NavigationStack` causes the system to render the search field in a
/// **floating Liquid Glass container at the bottom of the screen** on
/// iPhone (top-trailing on iPad/macOS). This is Apple's default and
/// honors Rule #3 (native-only): we do not specify a `placement:` —
/// the platform decides, and on iPhone iOS 26 the platform's decision is
/// the bottom-floating field the user asked for. Filtering uses
/// `localizedStandardContains` against the locale-resolved name,
/// `englishName`, `code`, and `symbol`, which matches case- and
/// diacritic-insensitively in the current locale — so a French-locale
/// user typing "dollar américain" finds USD.
struct CurrencyPickerView: View {
    @AppStorage(CurrencyPreference.storageKey)
    private var currencyCode: String = CurrencyPreference.defaultCode

    /// The user's currently-effective locale, propagated by the app-root
    /// `.environment(\.locale, …)` binding. Used to resolve each
    /// currency's name via `Locale.localizedString(forCurrencyCode:)`.
    @Environment(\.locale) private var currentLocale

    @State private var searchText: String = ""

    /// Currencies that match the trimmed query against any of: the
    /// user-locale-resolved name, English name, ISO code, glyph. Empty
    /// query returns the full list.
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
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text("Choose currency"))
        .navigationBarTitleDisplayMode(.inline)
        // Native iOS 26 behavior: the system renders this as a floating
        // Liquid Glass search field at the bottom of the screen on iPhone.
        // No `placement:` — the platform owns the decision.
        .searchable(text: $searchText, prompt: Text("Search"))
        .uniHaptic(.selection, trigger: currencyCode)
    }
}

// MARK: - Row

private struct CurrencyRow: View {
    let currency: SupportedCurrency
    /// The currency's name rendered in the user's currently-selected
    /// locale via `Locale.localizedString(forCurrencyCode:)` — e.g.
    /// "Dólar estadounidense" for `USD` when the locale is Spanish.
    /// Falls back to `currency.englishName` if iOS returns `nil`.
    let localizedName: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: UniSpacing.s) {
                // Glyph leads the row at a fixed width so columns align
                // across rows whose symbols vary in glyph width (`$` vs
                // `د.إ` vs `CHF`). The glyph is the visual marker and is
                // not localized — render verbatim.
                Text(verbatim: currency.symbol)
                    .font(UniTypography.body.weight(.semibold))
                    .foregroundStyle(UniColors.Text.primary)
                    .frame(width: 32, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    // Locale-resolved name — flows from `\.locale` set at
                    // the app root. The picker stops showing English to a
                    // user who chose a non-English UI language. No catalog
                    // entries needed; iOS ships every currency name in
                    // every supported locale.
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

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        CurrencyPickerView()
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        CurrencyPickerView()
    }
    .preferredColorScheme(.dark)
}
