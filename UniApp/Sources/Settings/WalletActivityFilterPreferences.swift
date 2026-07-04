import Foundation
import SwiftUI

/// **Wallet-wide Activity Filter & Sort preferences.** The richest of
/// the three transaction-filter namespaces (the others are
/// `WalletHomeFilterPreferences` for the home's coin/token lists and
/// `AssetDetailFilterPreferences` for a single asset). This one shapes
/// the wallet-wide Activity screen — EVERY transaction across EVERY
/// asset and network — so it carries the full professional vocabulary:
/// direction, status, network multi-select, asset multi-select, a time
/// range (presets + a custom from/to window), a fiat amount range, and
/// the sort comparator.
///
/// **Why a separate namespace.** The Activity screen filters at the
/// wallet level (all assets, all networks). The home filters coin-vs-
/// token visibility; the asset detail filters one symbol. Mixing the
/// three keys would let a choice on one surface silently reshape
/// another. Keeping them apart keeps each surface's reset isolated and
/// each user mental model clean — the principle the home established.
///
/// **Persisted state shape (global — not per-wallet).** The user's
/// Activity filter applies to whichever wallet is active; switching
/// wallets keeps the lens. This matches the home/asset precedent: pick
/// once, every surface honors it.
///
/// **Sentinels.** Empty network/symbol sets mean "all" (no narrowing).
/// `0` custom dates and empty amount strings mean "unset". This lets a
/// single key encode both "no constraint" and a concrete value without
/// a second boolean.
///
/// **Reset semantics.** `resetAll()` writes every key back to its
/// default AND clears every set/range to its unset sentinel.
enum WalletActivityFilterPreferences {

    // MARK: - Storage keys

    /// `String` raw of `SortKey`.
    static let sortKeyKey = "walletActivitySortKey"
    /// `String` raw of `TxDirection`.
    static let directionKey = "walletActivityDirection"
    /// `String` raw of `TxStatus`.
    static let statusKey = "walletActivityStatus"
    /// `String` raw of `TxKind`.
    static let kindKey = "walletActivityKind"
    /// `String` raw of `AssetClass`.
    static let assetClassKey = "walletActivityAssetClass"
    /// JSON-encoded `[String]` of `SupportedChain.rawValue`. Empty = "all".
    static let selectedNetworksKey = "walletActivitySelectedNetworks"
    /// JSON-encoded `[String]` of UPPERCASED token symbols. Empty = "all".
    static let selectedSymbolsKey = "walletActivitySelectedSymbols"
    /// `String` raw of `TimeRange`.
    static let timeRangeKey = "walletActivityTimeRange"
    /// `Double` (`timeIntervalSince1970`). `0` = unset. Only consulted
    /// when `timeRange == .custom`.
    static let customStartKey = "walletActivityCustomStart"
    /// `Double` (`timeIntervalSince1970`). `0` = unset. Only consulted
    /// when `timeRange == .custom`.
    static let customEndKey = "walletActivityCustomEnd"
    /// `String` decimal of the minimum fiat value (display currency).
    /// Empty = unset.
    static let minFiatKey = "walletActivityMinFiat"
    /// `String` decimal of the maximum fiat value (display currency).
    /// Empty = unset.
    static let maxFiatKey = "walletActivityMaxFiat"

    // MARK: - Defaults

    static let defaultSortKey: SortKey = .newest
    static let defaultDirection: TxDirection = .all
    static let defaultStatus: TxStatus = .all
    static let defaultKind: TxKind = .all
    static let defaultAssetClass: AssetClass = .all
    static let defaultSelectedJSON: String = "[]"
    static let defaultTimeRange: TimeRange = .all
    static let defaultCustomDate: Double = 0
    static let defaultAmount: String = ""

    // MARK: - Enums

    /// Transaction sort comparator. `largest` / `smallest` order by the
    /// row's FIAT value (display currency), resolved by the caller — a
    /// cross-asset list can't be ordered by native amount (1 BTC vs
    /// 1,000 SHIB is meaningless), so value is the only honest unit.
    enum SortKey: String, CaseIterable, Hashable, Identifiable, Sendable {
        /// Newest occurrence first (default).
        case newest
        /// Oldest occurrence first.
        case oldest
        /// Largest fiat value first.
        case largest
        /// Smallest fiat value first.
        case smallest
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .newest:   return "Newest"
            case .oldest:   return "Oldest"
            case .largest:  return "Largest"
            case .smallest: return "Smallest"
            }
        }
    }

    /// Direction filter. `all` keeps every row (incoming, outgoing, and
    /// internal moves); the explicit cases narrow to one direction.
    enum TxDirection: String, CaseIterable, Hashable, Identifiable, Sendable {
        case all
        case incoming
        case outgoing
        case `internal`
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .all:      return "All"
            case .incoming: return "Received"
            case .outgoing: return "Sent"
            case .internal: return "Internal"
            }
        }
    }

    /// Confirmation-status filter. Raw values for the explicit cases
    /// match `TransactionStatus` so `apply` can compare directly.
    enum TxStatus: String, CaseIterable, Hashable, Identifiable, Sendable {
        case all
        case confirmed
        case pending
        case failed
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .all:       return "All"
            case .confirmed: return "Confirmed"
            case .pending:   return "Pending"
            case .failed:    return "Failed"
            }
        }
    }

    /// Transaction-kind filter. This is the taxonomy axis (`transfer`,
    /// `selfTransfer`, `bridge`) rather than value direction.
    enum TxKind: String, CaseIterable, Hashable, Identifiable, Sendable {
        case all
        case transfer
        case selfTransfer
        case bridge
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .all:          return "All"
            case .transfer:     return "Transfers"
            case .selfTransfer: return "Self"
            case .bridge:       return "Bridge"
            }
        }
    }

    /// Asset class filter. Native coin rows have `tokenContract == nil`;
    /// token rows carry a contract, mint, issuer, or denom.
    enum AssetClass: String, CaseIterable, Hashable, Identifiable, Sendable {
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
    }

    /// Time range filter. The presets are relative to "now"; `custom`
    /// switches to the explicit `customStart…customEnd` window.
    enum TimeRange: String, CaseIterable, Hashable, Identifiable, Sendable {
        case day
        case week
        case month
        case year
        case all
        case custom
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .day:    return "24h"
            case .week:   return "7d"
            case .month:  return "30d"
            case .year:   return "1y"
            case .all:    return "All"
            case .custom: return "Custom"
            }
        }

        /// Cut-off measured from `reference` for the PRESET ranges.
        /// `.all` and `.custom` return `.distantPast` (custom is handled
        /// by the explicit window in `apply`, not this cutoff).
        func cutoff(from reference: Date) -> Date {
            let calendar = Calendar.current
            switch self {
            case .day:    return calendar.date(byAdding: .day, value: -1, to: reference) ?? .distantPast
            case .week:   return calendar.date(byAdding: .day, value: -7, to: reference) ?? .distantPast
            case .month:  return calendar.date(byAdding: .day, value: -30, to: reference) ?? .distantPast
            case .year:   return calendar.date(byAdding: .year, value: -1, to: reference) ?? .distantPast
            case .all, .custom: return .distantPast
            }
        }
    }

    // MARK: - JSON ↔ Set<String>

    /// Decode a JSON-encoded `[String]` payload to a `Set<String>`.
    /// Empty set on parse failure (same contract as the sibling
    /// namespaces).
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
        else { return defaultSelectedJSON }
        return json
    }

    // MARK: - Active-filter test

    /// `true` when ANY constraint is set to something other than its
    /// default — drives the toolbar button's "active" dot so the user
    /// can see at a glance that a filter is narrowing the list.
    static func isActive(
        sortKeyRaw: String,
        directionRaw: String,
        statusRaw: String,
        kindRaw: String,
        assetClassRaw: String,
        selectedNetworksJSON: String,
        selectedSymbolsJSON: String,
        timeRangeRaw: String,
        minFiat: String,
        maxFiat: String
    ) -> Bool {
        directionRaw != defaultDirection.rawValue
            || statusRaw != defaultStatus.rawValue
            || kindRaw != defaultKind.rawValue
            || assetClassRaw != defaultAssetClass.rawValue
            || !decode(selectedNetworksJSON).isEmpty
            || !decode(selectedSymbolsJSON).isEmpty
            || timeRangeRaw != defaultTimeRange.rawValue
            || !minFiat.isEmpty
            || !maxFiat.isEmpty
            // Sort isn't a "filter" but a non-default sort is still a
            // lens the user chose — surface it too.
            || sortKeyRaw != defaultSortKey.rawValue
    }

    // MARK: - Reset

    /// Wipe every preference key this feature owns. Called by the
    /// "Reset to defaults" CTA after the user confirms.
    static func resetAll() {
        let store = AppPreferenceStore.shared
        store.set(defaultSortKey.rawValue, forKey: sortKeyKey)
        store.set(defaultDirection.rawValue, forKey: directionKey)
        store.set(defaultStatus.rawValue, forKey: statusKey)
        store.set(defaultKind.rawValue, forKey: kindKey)
        store.set(defaultAssetClass.rawValue, forKey: assetClassKey)
        store.set(defaultSelectedJSON, forKey: selectedNetworksKey)
        store.set(defaultSelectedJSON, forKey: selectedSymbolsKey)
        store.set(defaultTimeRange.rawValue, forKey: timeRangeKey)
        store.set(defaultCustomDate, forKey: customStartKey)
        store.set(defaultCustomDate, forKey: customEndKey)
        store.set(defaultAmount, forKey: minFiatKey)
        store.set(defaultAmount, forKey: maxFiatKey)
    }
}

// MARK: - Filter inputs snapshot

/// Decoded snapshot of every Activity filter preference. Built once per
/// filter pass and handed to `WalletActivityFilterApply`'s pure
/// function. Same shape contract as the sibling `*FilterInputs` types.
struct WalletActivityFilterInputs: Sendable {
    let sortKey: WalletActivityFilterPreferences.SortKey
    let direction: WalletActivityFilterPreferences.TxDirection
    let status: WalletActivityFilterPreferences.TxStatus
    let kind: WalletActivityFilterPreferences.TxKind
    let assetClass: WalletActivityFilterPreferences.AssetClass
    let selectedNetworks: Set<String>
    /// Uppercased token symbols. Empty = "all".
    let selectedSymbols: Set<String>
    let timeRange: WalletActivityFilterPreferences.TimeRange
    /// Custom window start; `nil` unless `timeRange == .custom` AND set.
    let customStart: Date?
    /// Custom window end; `nil` unless `timeRange == .custom` AND set.
    let customEnd: Date?
    /// Minimum fiat value (display currency); `nil` = no lower bound.
    let minFiat: Decimal?
    /// Maximum fiat value (display currency); `nil` = no upper bound.
    let maxFiat: Decimal?
    /// Free-text search (counterparty / symbol / tx hash), lowercased;
    /// empty = no search. Lives in transient view state, not
    /// `@GRDBStorage`, but rides along here so `apply` is the single code
    /// path that shapes the list.
    let searchText: String

    /// `true` when an amount bound is active — drives the "drop
    /// unmeasurable-fiat rows" decision in `apply` (a row whose fiat we
    /// can't compute can't be proven to satisfy "≥ $X").
    var hasAmountBound: Bool { minFiat != nil || maxFiat != nil }
}
