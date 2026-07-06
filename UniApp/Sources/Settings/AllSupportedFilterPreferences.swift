import Foundation
import SwiftUI

/// **All-Supported-Assets Filter & Sort preferences.** Mirrors
/// `AssetDetailFilterPreferences` / `WalletHomeFilterPreferences` in
/// shape, scoped to the "All supported assets" discovery screen behind
/// the wallet-home "Show all" rows.
///
/// **Why its own namespace.** This screen filters at a different
/// granularity than the home or the asset detail — its concerns are
/// "coins or tokens?", "which networks?", "only what I hold?", and "by
/// balance or by name?". Keeping the namespace separate keeps each
/// surface's reset isolated and prevents a choice here from leaking into
/// the home's holdings list.
///
/// **Persisted state (four keys, global).** The user picks once; every
/// time they open the screen it honors the choice — the same principle
/// the rest of the app's filters follow.
///
/// 1. `allAssetsSortKey` — `String` raw of `SortKey`. Default
///    `.balance` (held first, largest fiat → smallest, then the rest).
/// 2. `allAssetsType` — `String` raw of `AssetType`. Default `.all`
///    (both the Coins and Tokens sections visible).
/// 3. `allAssetsSelectedNetworks` — JSON-encoded `[String]` of
///    `SupportedChain.rawValue`. **Empty default = "all networks".**
/// 4. `allAssetsOnlyWithBalance` — `Bool`. Default `false`. When `true`,
///    only assets the active wallet actually holds are shown.
enum AllSupportedFilterPreferences {

    // MARK: - Storage keys

    /// `String` raw of `SortKey`.
    static let sortKeyKey = "allAssetsSortKey"
    /// `String` raw of `AssetType`.
    static let assetTypeKey = "allAssetsType"
    /// JSON-encoded `[String]` of chain raw values. Empty = "all".
    static let selectedNetworksKey = "allAssetsSelectedNetworks"
    /// `Bool`.
    static let onlyWithBalanceKey = "allAssetsOnlyWithBalance"

    // MARK: - Defaults

    static let defaultSortKey: SortKey = .balance
    static let defaultAssetType: AssetType = .all
    static let defaultSelectedNetworksJSON: String = "[]"
    static let defaultOnlyWithBalance: Bool = false

    // MARK: - Enums

    /// Row sort comparator.
    enum SortKey: String, CaseIterable, Hashable, Identifiable, Sendable {
        /// Held first by largest fiat value, then the rest by name.
        case balance
        /// Alphabetical by display name / ticker, regardless of holdings.
        case name
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .balance: return "Balance"
            case .name:    return "Name"
            }
        }
    }

    /// Which sections the screen shows.
    enum AssetType: String, CaseIterable, Hashable, Identifiable, Sendable {
        case all
        case coins
        case tokens
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .all:    return "All"
            case .coins:  return "Coins"
            case .tokens: return "Tokens"
            }
        }

        var showsCoins: Bool { self == .all || self == .coins }
        var showsTokens: Bool { self == .all || self == .tokens }
    }

    // MARK: - JSON ↔ Set<String>

    /// Decode the JSON-encoded `[String]` payload to a `Set<String>`.
    /// Returns an empty set on parse failure.
    static func decode(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }

    /// Encode a `Set<String>` to JSON, sorted for deterministic output.
    static func encode(_ set: Set<String>) -> String {
        let sorted = Array(set).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8)
        else { return defaultSelectedNetworksJSON }
        return json
    }

    // MARK: - Reset

    /// Wipe every preference key this feature owns. Called by the
    /// toolbar Reset action after the user confirms.
    static func resetAll() {
        let store = AppPreferenceStore.shared
        store.set(defaultSortKey.rawValue, forKey: sortKeyKey)
        store.set(defaultAssetType.rawValue, forKey: assetTypeKey)
        store.set(defaultSelectedNetworksJSON, forKey: selectedNetworksKey)
        store.set(defaultOnlyWithBalance, forKey: onlyWithBalanceKey)
    }
}
