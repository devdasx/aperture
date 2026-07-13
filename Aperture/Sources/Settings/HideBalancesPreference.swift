import SwiftUI

/// Hide-balance preferences. Two orthogonal controls:
///
/// 1. **`hideBalanceOnHome`** — Bool. Historical key name, now treated
///    as the global balance-privacy toggle. When `true`, user-owned
///    balances and transaction values render as bullets across the app.
///
/// 2. **`hideSmallBalancesThreshold`** — Double (fiat units in the
///    user's currency). Holdings whose `fiatValueCached` is strictly
///    below this threshold are hidden from the asset list. Default
///    `0` (don't hide anything). Common values: 0 / 1 / 10 / 100.
enum HideBalancesPreference {
    static let hideBalanceOnHomeKey = "hideBalanceOnHome"
    static let thresholdKey = "hideSmallBalancesThreshold"
    static let defaultThreshold: Double = 0

    /// Picker options for the "hide small balances under …" row.
    enum ThresholdOption: Double, CaseIterable, Identifiable, Sendable {
        case showAll = 0
        case one = 1
        case ten = 10
        case oneHundred = 100

        var id: Double { rawValue }

        /// Label uses the user's currency code at render time so the
        /// row reads "Under €1" for a EUR-preference user.
        ///
        /// Uses `"Under %@"` + `String(format:)` — **not** string
        /// interpolation into `apertureLocalized`. Interpolating
        /// (`"Under \(value)"`) builds a one-off catalog key like
        /// `"Under US$1.00"` that is never translated.
        func label(currencyCode: String) -> String {
            switch self {
            case .showAll:
                return String.apertureLocalized("Show all")
            case .one, .ten, .oneHundred:
                let value = Decimal(rawValue).formatted(
                    .currency(code: currencyCode)
                        .locale(ApertureLocalization.currentLocale)
                )
                return String(
                    format: String.apertureLocalized("Under %@"),
                    locale: ApertureLocalization.currentLocale,
                    value
                )
            }
        }
    }

    static func option(for raw: Double) -> ThresholdOption {
        ThresholdOption(rawValue: raw) ?? .showAll
    }
}

private struct BalancePrivacyEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Global shoulder-surfing protection for visible wallet values.
    /// `ApertureEnvironmentModifier` injects this once per presentation root.
    var balancePrivacyEnabled: Bool {
        get { self[BalancePrivacyEnabledKey.self] }
        set { self[BalancePrivacyEnabledKey.self] = newValue }
    }
}
