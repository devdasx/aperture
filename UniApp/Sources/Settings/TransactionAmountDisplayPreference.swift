import Foundation

/// Controls how transaction-detail headline amounts are displayed.
///
/// When enabled, transaction receipt heroes prefer the user's selected fiat
/// currency. When disabled, they show the native on-chain amount. Fiat display
/// always falls back to the native amount when a price is unavailable, so the
/// app never fabricates a local-currency value. Activity rows show native and
/// local values together and do not depend on this preference.
enum TransactionAmountDisplayPreference {
    static let storageKey = "txAmountsInLocalCurrency"
    static let defaultValue = true

    static func showsLocalCurrency() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else { return defaultValue }
        return defaults.bool(forKey: storageKey)
    }
}
