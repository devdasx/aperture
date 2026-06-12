import Foundation
import SwiftUI

/// **Asset-detail Filter & Sort preferences.** Mirrors
/// `WalletHomeFilterPreferences` in shape but scoped to the per-asset
/// detail screen.
///
/// **Why a separate namespace, not a sub-key under wallet-home
/// preferences.** The asset-detail screen filters at a different
/// granularity than the wallet home — its concerns are "which
/// networks of this asset?" and "incoming / outgoing / both?", not
/// "coins vs tokens" or "pinned / hidden assets". Keeping the two
/// namespaces apart prevents accidental cross-contamination (a user
/// hiding USDC on the wallet home shouldn't affect what they see in
/// the USDC detail) and keeps each surface's reset isolated.
///
/// **Persisted state shape (five keys, global — not per-asset).** The
/// user's filter preferences apply to *every* asset detail screen they
/// open. This matches the principle the wallet home established: pick
/// once, every surface honors it. Per-asset overrides would surprise
/// the user ("why does my BTC view sort differently from my USDC
/// view?").
///
/// 1. `assetDetailSortKey` — `String` raw of `SortKey`. Default
///    `.newest`. Controls the asset-scoped transaction history sort.
/// 2. `assetDetailDirection` — `String` raw of `TxDirection`. Default
///    `.both`. Filters to incoming-only, outgoing-only, or both.
/// 3. `assetDetailSelectedNetworks` — JSON-encoded `[String]` of
///    `SupportedChain.rawValue` strings. **Empty default is the
///    sentinel for "all networks visible"**, same as the wallet
///    home's `selectedNetworks`.
/// 4. `assetDetailTimeRange` — `String` raw of `TimeRange`. Default
///    `.all`. Filters transactions by recency.
/// 5. `assetDetailHideZeroNetworks` — `Bool`. Default `false`. When
///    `true`, network rows whose `amount == 0` are filtered out of
///    the Networks section. The user can still see "I could move my
///    USDC here" by toggling it off.
///
/// **Reset semantics.** `resetAll()` writes every key back to its
/// default value AND clears every set to empty.
enum AssetDetailFilterPreferences {

    // MARK: - Storage keys

    /// `String` raw of `SortKey`.
    static let sortKeyKey = "assetDetailSortKey"
    /// `String` raw of `TxDirection`.
    static let directionKey = "assetDetailDirection"
    /// JSON-encoded `[String]` of chain raw values. Empty = "all".
    static let selectedNetworksKey = "assetDetailSelectedNetworks"
    /// `String` raw of `TimeRange`.
    static let timeRangeKey = "assetDetailTimeRange"
    /// `Bool`.
    static let hideZeroNetworksKey = "assetDetailHideZeroNetworks"

    // MARK: - Defaults

    static let defaultSortKey: SortKey = .newest
    static let defaultDirection: TxDirection = .both
    static let defaultSelectedNetworksJSON: String = "[]"
    static let defaultTimeRange: TimeRange = .all
    static let defaultHideZeroNetworks: Bool = false

    // MARK: - Enums

    /// Transaction sort comparator.
    enum SortKey: String, CaseIterable, Hashable, Identifiable, Sendable {
        /// Newest occurrence first (default).
        case newest
        /// Largest native amount first.
        case largest
        /// Group by network (alphabetical by chain display name),
        /// then by recency within each chain.
        case network
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .newest:  return "Newest"
            case .largest: return "Largest"
            case .network: return "Network"
            }
        }
    }

    /// Direction filter for the transaction list.
    enum TxDirection: String, CaseIterable, Hashable, Identifiable, Sendable {
        case both
        case incoming
        case outgoing
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .both:     return "Both"
            case .incoming: return "Incoming"
            case .outgoing: return "Outgoing"
            }
        }
    }

    /// Time range filter for the transaction list.
    enum TimeRange: String, CaseIterable, Hashable, Identifiable, Sendable {
        case day
        case week
        case month
        case year
        case all
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .day:   return "1D"
            case .week:  return "1W"
            case .month: return "1M"
            case .year:  return "1Y"
            case .all:   return "All"
            }
        }

        /// Cut-off measured from `reference`. `.all` returns
        /// `.distantPast` so the filter consumes every transaction.
        func cutoff(from reference: Date) -> Date {
            let calendar = Calendar.current
            switch self {
            case .day:   return calendar.date(byAdding: .day, value: -1, to: reference) ?? .distantPast
            case .week:  return calendar.date(byAdding: .day, value: -7, to: reference) ?? .distantPast
            case .month: return calendar.date(byAdding: .month, value: -1, to: reference) ?? .distantPast
            case .year:  return calendar.date(byAdding: .year, value: -1, to: reference) ?? .distantPast
            case .all:   return .distantPast
            }
        }
    }

    // MARK: - JSON ↔ Set<String>

    /// Decode the JSON-encoded `[String]` payload back to a
    /// `Set<String>`. Returns an empty set on parse failure. Same
    /// shape as `WalletHomeFilterPreferences.decode`.
    static func decode(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }

    /// Encode a `Set<String>` back to JSON, sorted for deterministic
    /// output.
    static func encode(_ set: Set<String>) -> String {
        let sorted = Array(set).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8)
        else { return defaultSelectedNetworksJSON }
        return json
    }

    // MARK: - Reset

    /// Wipe every preference key this feature owns. Called by the
    /// "Reset to defaults" CTA in `AssetDetailFilterSheet` after the
    /// user confirms.
    static func resetAll() {
        let defaults = UserDefaults.standard
        defaults.set(defaultSortKey.rawValue, forKey: sortKeyKey)
        defaults.set(defaultDirection.rawValue, forKey: directionKey)
        defaults.set(defaultSelectedNetworksJSON, forKey: selectedNetworksKey)
        defaults.set(defaultTimeRange.rawValue, forKey: timeRangeKey)
        defaults.set(defaultHideZeroNetworks, forKey: hideZeroNetworksKey)
    }
}

// MARK: - Filter inputs snapshot

/// Decoded snapshot of every asset-detail filter preference. Read
/// once per body evaluation; passed to `AssetDetailFilterApply`'s
/// pure functions. Same shape contract as
/// `WalletHomeFilterApply.Inputs`.
struct AssetDetailFilterInputs: Sendable {
    let sortKey: AssetDetailFilterPreferences.SortKey
    let direction: AssetDetailFilterPreferences.TxDirection
    let selectedNetworks: Set<String>
    let timeRange: AssetDetailFilterPreferences.TimeRange
    let hideZeroNetworks: Bool

    /// Compose with an additional network restriction (the per-network
    /// detail screen passes its own chain so the inputs are narrowed
    /// to a single network). When the override is nil, returns self
    /// unchanged.
    func intersected(network chain: SupportedChain?) -> AssetDetailFilterInputs {
        guard let chain else { return self }
        return AssetDetailFilterInputs(
            sortKey: sortKey,
            direction: direction,
            selectedNetworks: [chain.rawValue],
            timeRange: timeRange,
            hideZeroNetworks: hideZeroNetworks
        )
    }
}
