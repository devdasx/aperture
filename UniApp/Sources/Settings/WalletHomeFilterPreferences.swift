import Foundation
import SwiftUI

/// **Wallet-home Filter & Sort preferences.** The single canonical
/// namespace for the storage keys, enum vocabulary, and defaults the
/// `WalletHomeFilterSheet` writes through `@AppStorage`. Mirrors the
/// shape of `HapticPreference` and `HideBalancesPreference`: one
/// `enum` namespace, one storage key per preference, one default per
/// preference.
///
/// **Why a separate file (Rule #19-style "one canonical primitive"
/// for state).** The eleven storage keys + their five enums are
/// referenced by the filter sheet, the five sub-screens (Hidden
/// assets / Hidden chains / Networks / Min value / Pinned assets),
/// the pure-function filter applier, and the wallet home itself.
/// Lifting them out of any one consumer keeps the contract auditable
/// in one place and removes the temptation to re-declare the same
/// `@AppStorage` key with a typo in the next consumer.
///
/// **Persisted state shape (eleven keys total — six v1, five v2):**
///
/// 1. `walletHomeViewMode` — `String` raw of `ViewMode`. Default
///    `.split`. Controls whether the home renders the Coins/Tokens
///    segmented switcher (`.split`) or a single unified list
///    (`.combined`).
/// 2. `walletHomeSortKey` — `String` raw of `SortKey`. Default
///    `.value`. Picks the comparator for both Coins and Tokens
///    sections.
/// 3. `walletHomeSortDirection` — `String` raw of `SortDirection`.
///    Default `.descending`. Composes with the sort key.
/// 4. `walletHomeOnlyWithBalance` — `Bool`. Default `false`. When
///    `true`, rows whose `amount == 0` are filtered out before
///    sorting.
/// 5. `walletHomeHiddenAssets` — JSON-encoded `[String]` of asset
///    IDs the user has chosen to hide. Empty default. Asset IDs use
///    the schema `"{chainRaw}|{contract or empty}|{symbol}"` so each
///    string round-trips through `@AppStorage`-stored JSON without
///    losing information.
/// 6. `walletHomeHiddenChains` — JSON-encoded `[String]` of
///    `SupportedChain.rawValue` strings the user has chosen to mute
///    at the chain level. Empty default. Useful for muting a whole
///    network (e.g., a watch-only address imported by mistake).
/// 7. `walletHomeAssetType` — `String` raw of `AssetType`. Default
///    `.all`. Restricts the holdings list to coins-only, tokens-
///    only, or both. Independent of `viewMode`.
/// 8. `walletHomeGroupBy` — `String` raw of `GroupBy`. Default
///    `.none`. When `.chain` AND the user is in `combined` view
///    mode, the unified list breaks into per-chain `Section`s
///    sorted alphabetically by chain. The picker is disabled (and
///    a footnote surfaces) in `split` view mode where the
///    Coins/Tokens split IS already a grouping.
/// 9. `walletHomeMinFiatThreshold` — `Double` fiat units in the
///    user's display currency. Default `0.0` (no threshold). Rows
///    whose `fiatValue ?? 0 < threshold` are dropped. **Separate
///    from `HideBalancesPreference.thresholdKey`:** that one is a
///    global Settings preference whose intent is "stop showing dust
///    everywhere"; this one is a per-wallet-home filter the user
///    drives from the Filter sheet ("today I want to look at
///    holdings over $10"). The two compose — both apply.
/// 10. `walletHomeSelectedNetworks` — JSON-encoded `[String]` of
///    `SupportedChain.rawValue` strings. **Empty default is the
///    sentinel for "all networks visible".** When non-empty, rows
///    whose chain is NOT in this set are dropped. Composes with
///    `walletHomeHiddenChains` (a chain must be in
///    `selectedNetworks` AND NOT in `hiddenChains` to render).
/// 11. `walletHomePinnedAssets` — JSON-encoded `[String]` of asset
///    IDs (same `chainRaw|contract|symbol` schema as
///    `hiddenAssets`) the user has pinned to the top of the
///    holdings list. Empty default. Pinned rows render in a
///    dedicated "Pinned" section above the regular holdings,
///    regardless of the sort direction.
///
/// **Why JSON-encoded `[String]` for the sets instead of `Set<String>`
/// directly.** `@AppStorage` natively supports `Bool` / `Int` /
/// `Double` / `String` / `URL` / `Data` and `RawRepresentable` over
/// those primitives. A `Set<String>` isn't directly storable; the
/// canonical Apple pattern is to encode/decode through `String`
/// (JSON) or `Data` (PropertyList). JSON-as-String stays human-
/// readable in `defaults read` output for diagnosis, which is the
/// auditable property we want.
///
/// **Identity (`assetID`).** A hidden / pinned entry needs to
/// survive the lifecycle of a token balance row in SwiftData
/// (which can be re-created on every scan). The identifier is
/// `chainRaw | contract | symbol` — a string the row builder
/// reconstructs deterministically from `WalletCoinSupportedRow` /
/// `WalletTokenSupportedDisplayRow`. A coin's contract slot is
/// empty; a token's `contract` slot carries whatever the registry
/// uses (EVM checksum, SPL mint, Move address, XRPL
/// `currency.issuer`, etc.).
///
/// **Reset semantics.** The Reset to defaults button writes every
/// preference back to its default value AND clears every set to
/// empty. `WalletHomeFilterPreferences.resetAll()` is the
/// implementation; it's the only entry point that writes more than
/// one key at a time.
enum WalletHomeFilterPreferences {

    // MARK: - Storage keys (v1)

    /// `String` raw of `ViewMode`.
    static let viewModeKey = "walletHomeViewMode"
    /// `String` raw of `SortKey`.
    static let sortKeyKey = "walletHomeSortKey"
    /// `String` raw of `SortDirection`.
    static let sortDirectionKey = "walletHomeSortDirection"
    /// `Bool`.
    static let onlyWithBalanceKey = "walletHomeOnlyWithBalance"
    /// JSON-encoded `[String]` of asset IDs.
    static let hiddenAssetsKey = "walletHomeHiddenAssets"
    /// JSON-encoded `[String]` of chain raw values.
    static let hiddenChainsKey = "walletHomeHiddenChains"

    // MARK: - Storage keys (v2 — added 2026-06-09)

    /// `String` raw of `AssetType`.
    static let assetTypeKey = "walletHomeAssetType"
    /// `String` raw of `GroupBy`.
    static let groupByKey = "walletHomeGroupBy"
    /// `Double` — fiat units in the user's display currency.
    static let minFiatThresholdKey = "walletHomeMinFiatThreshold"
    /// JSON-encoded `[String]` of chain raw values. Empty = "show all".
    static let selectedNetworksKey = "walletHomeSelectedNetworks"
    /// JSON-encoded `[String]` of asset IDs the user has pinned.
    static let pinnedAssetsKey = "walletHomePinnedAssets"

    // MARK: - Defaults

    static let defaultViewMode: ViewMode = .split
    static let defaultSortKey: SortKey = .value
    static let defaultSortDirection: SortDirection = .descending
    static let defaultOnlyWithBalance: Bool = false
    static let defaultHiddenJSON: String = "[]"
    static let defaultAssetType: AssetType = .all
    static let defaultGroupBy: GroupBy = .none
    static let defaultMinFiatThreshold: Double = 0.0

    // MARK: - Enums

    /// How the wallet-home renders the holdings region.
    ///
    /// - `.split` — segmented Coins/Tokens switcher in the chrome
    ///   row; only the selected section renders below the action
    ///   region. The pre-2026-06-09 shape.
    /// - `.combined` — the segmented switcher disappears and the
    ///   home renders one unified list with every native + token
    ///   row mixed. Useful for users who think of holdings as one
    ///   portfolio rather than two collections.
    enum ViewMode: String, CaseIterable, Hashable, Identifiable, Sendable {
        case split
        case combined
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .split:    return "Split"
            case .combined: return "Combined"
            }
        }
    }

    /// The comparator key picked by the user. Composes with
    /// `SortDirection` (ascending/descending).
    enum SortKey: String, CaseIterable, Hashable, Identifiable, Sendable {
        /// `chain.displayName` lexicographic.
        case name
        /// Asset ticker / symbol — alphabetical.
        case symbol
        /// Native amount (the on-chain quantity) — numeric.
        case balance
        /// Fiat value at the user's currency — numeric. Default.
        case value
        /// Chain canonical order (the order declared in
        /// `SupportedChain.allCases`). Useful when the user wants to
        /// see all of one chain's holdings together regardless of
        /// fiat.
        case chain
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .name:    return "Name"
            case .symbol:  return "Symbol"
            case .balance: return "Balance"
            case .value:   return "Value"
            case .chain:   return "Chain"
            }
        }
    }

    /// Ascending / descending. Composes with `SortKey`.
    enum SortDirection: String, CaseIterable, Hashable, Identifiable, Sendable {
        case ascending
        case descending
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .ascending:  return "Ascending"
            case .descending: return "Descending"
            }
        }
    }

    /// Which kinds of holdings render. Independent of `ViewMode`.
    ///
    /// - `.all` — both coins and tokens. The default; the wallet
    ///   home reads as one portfolio across both kinds.
    /// - `.coins` — only native chain coins (BTC, ETH, SOL, …).
    ///   In `.split` view, the Tokens tab is still selectable but
    ///   would render empty; in `.combined` view, only coin rows
    ///   appear.
    /// - `.tokens` — only registry tokens (USDC, USDT, DAI, …).
    ///   Sibling of `.coins`.
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
    }

    /// Grouping for the `combined` view mode.
    ///
    /// - `.none` — flat sorted list (the default; the v1 shape).
    /// - `.chain` — rows break into one `Section` per chain,
    ///   sections sorted alphabetically by `chain.displayName`,
    ///   rows within a section sorted per `(SortKey, SortDirection)`.
    ///   Only applies in `combined` view mode — in `split` mode the
    ///   Coins/Tokens split is already a grouping, so the
    ///   `groupBy` picker is disabled with a footnote.
    enum GroupBy: String, CaseIterable, Hashable, Identifiable, Sendable {
        case none
        case chain
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .none:  return "None"
            case .chain: return "Chain"
            }
        }
    }

    // MARK: - Asset identity helpers

    /// Canonical asset identifier for the hidden-assets +
    /// pinned-assets sets. `chainRaw | contract | symbol`. The
    /// contract slot is empty for native coins (`tokenContract ==
    /// nil` upstream). Pure function — the same row produces the
    /// same id forever.
    static func assetID(chainRaw: String, contract: String?, symbol: String) -> String {
        "\(chainRaw)|\(contract ?? "")|\(symbol)"
    }

    /// Helper for the coins-row code path.
    static func assetID(coin row: WalletCoinSupportedRow) -> String {
        assetID(chainRaw: row.chain.rawValue, contract: nil, symbol: row.chain.ticker)
    }

    /// Helper for the tokens-row code path.
    static func assetID(token row: WalletTokenSupportedDisplayRow) -> String {
        assetID(chainRaw: row.chain.rawValue, contract: row.contract, symbol: row.symbol)
    }

    // MARK: - JSON ↔ Set<String>

    /// Decode the JSON-encoded `[String]` payload back to a
    /// `Set<String>`. Returns an empty set on any parse failure so
    /// the call site never has to guard. The set is more useful at
    /// read time than the array because hidden / pinned / selected
    /// lookups are O(1).
    static func decode(_ json: String) -> Set<String> {
        // **2026-06-09 perf.** Memoize last-decoded JSON → set. The
        // wallet-home body reads `decode(hiddenAssetsJSON)`,
        // `decode(hiddenChainsJSON)`, `decode(selectedNetworksJSON)`,
        // `decode(pinnedAssetsJSON)` on EVERY body re-render. The
        // payloads change only when the filter sheet writes them
        // (rarely). Cache by content — string equality is cheap, a
        // JSONDecoder allocation + Data conversion + array decode +
        // Set construction is not. Single-entry cache per call site
        // is sufficient (this is the read API; only the filter sheet
        // writes), keyed by string identity. The lock is a tiny
        // `NSLock` rather than an actor so reads stay synchronous on
        // the main thread — no thread hop, no actor reentrancy cost.
        Self.decodeCache.lookup(json)
    }

    /// Small bounded decode cache. Holds the last 8 distinct JSON
    /// strings we've decoded. Body reads consume ≤4 unique payloads
    /// (hiddenAssets, hiddenChains, selectedNetworks, pinnedAssets) so
    /// 8 entries cover normal traffic with headroom for the previous
    /// values still cached during a write.
    private struct DecodeCache: @unchecked Sendable {
        private var lock = NSLock()
        private var entries: [(json: String, decoded: Set<String>)] = []
        private let capacity = 8

        mutating func lookup(_ json: String) -> Set<String> {
            lock.lock()
            for entry in entries where entry.json == json {
                let cached = entry.decoded
                lock.unlock()
                return cached
            }
            lock.unlock()
            let decoded: Set<String>
            if let data = json.data(using: .utf8),
               let array = try? JSONDecoder().decode([String].self, from: data) {
                decoded = Set(array)
            } else {
                decoded = []
            }
            lock.lock()
            if entries.count >= capacity { entries.removeFirst() }
            entries.append((json, decoded))
            lock.unlock()
            return decoded
        }
    }

    nonisolated(unsafe) private static var decodeCache = DecodeCache()

    /// Encode a `Set<String>` back to JSON. Sorted before encoding
    /// so the produced JSON is deterministic — easier to diff and
    /// audit in `defaults read` output.
    static func encode(_ set: Set<String>) -> String {
        let sorted = Array(set).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8)
        else { return defaultHiddenJSON }
        return json
    }

    // MARK: - Min-value threshold options

    /// Canonical step values for the Min value sub-screen, in fiat
    /// units of the user's display currency. The user picks one of
    /// these or types a custom value. Same shape as
    /// `HideBalancesPreference.ThresholdOption` but with a wider
    /// range — this is the per-session filter, not the global dust
    /// floor.
    enum MinFiatOption: Double, CaseIterable, Identifiable, Sendable {
        case zero        = 0
        case oneCent     = 0.01
        case tenCents    = 0.1
        case one         = 1
        case ten         = 10
        case oneHundred  = 100
        case oneThousand = 1000

        var id: Double { rawValue }

        /// Localized label for the picker row. Uses the user's
        /// display currency so a EUR-preference user reads
        /// "Under €1" instead of "Under $1".
        func label(currencyCode: String) -> String {
            switch self {
            case .zero:
                return String.apertureLocalized("Show all")
            default:
                let value = Decimal(rawValue).formatted(.currency(code: currencyCode))
                return String.apertureLocalized("Under \(value)")
            }
        }
    }

    // MARK: - Reset

    /// Wipe every preference key this feature owns. Called by the
    /// "Reset to defaults" CTA in the sheet after the user confirms.
    /// Writes go through `UserDefaults.standard` directly so the
    /// reset is one transaction; SwiftUI's `@AppStorage` observers
    /// pick the new values up on the next body evaluation.
    static func resetAll() {
        let defaults = UserDefaults.standard
        defaults.set(defaultViewMode.rawValue, forKey: viewModeKey)
        defaults.set(defaultSortKey.rawValue, forKey: sortKeyKey)
        defaults.set(defaultSortDirection.rawValue, forKey: sortDirectionKey)
        defaults.set(defaultOnlyWithBalance, forKey: onlyWithBalanceKey)
        defaults.set(defaultHiddenJSON, forKey: hiddenAssetsKey)
        defaults.set(defaultHiddenJSON, forKey: hiddenChainsKey)
        defaults.set(defaultAssetType.rawValue, forKey: assetTypeKey)
        defaults.set(defaultGroupBy.rawValue, forKey: groupByKey)
        defaults.set(defaultMinFiatThreshold, forKey: minFiatThresholdKey)
        defaults.set(defaultHiddenJSON, forKey: selectedNetworksKey)
        defaults.set(defaultHiddenJSON, forKey: pinnedAssetsKey)
    }
}
