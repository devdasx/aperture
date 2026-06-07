import Foundation

/// Hide-balance preferences. Two orthogonal toggles:
///
/// 1. **`hideBalanceOnHome`** — Bool. When `true`, the wallet-home
///    hero number renders as `••••` until the user taps to reveal.
///    Shoulder-surfing protection for public spaces. Default `false`
///    (most users want to see their number on open).
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
        func label(currencyCode: String) -> String {
            switch self {
            case .showAll:
                return String.apertureLocalized("Show all")
            case .one, .ten, .oneHundred:
                let value = Decimal(rawValue).formatted(.currency(code: currencyCode))
                return String.apertureLocalized("Under \(value)")
            }
        }
    }

    static func option(for raw: Double) -> ThresholdOption {
        ThresholdOption(rawValue: raw) ?? .showAll
    }
}
