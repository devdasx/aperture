import Foundation

/// Remembers whether the Send amount screen last used **local currency**
/// or **native crypto** entry. Applied when a new compose session opens so
/// the user does not re-toggle every send.
///
/// When fiat is preferred but the asset has no price, the compose model
/// falls back to crypto for that session only — the preference is kept so
/// the next priced send still opens in fiat.
enum SendAmountEntryUnitPreference {
    static let storageKey = "sendAmountEntryInLocalCurrency"
    /// Default: native crypto (historical compose default).
    static let defaultValue = false

    static var prefersFiat: Bool {
        AppPreferenceStore.shared.bool(storageKey, default: defaultValue)
    }

    static func setPrefersFiat(_ value: Bool) {
        AppPreferenceStore.shared.set(value, forKey: storageKey)
    }
}
