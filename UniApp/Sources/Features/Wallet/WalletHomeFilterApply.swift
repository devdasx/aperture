import Foundation

/// **Pure-function filter + sort applier** for the wallet-home
/// holdings rows. The wallet-home's body calls into this enum with
/// the raw `WalletCoinSupportedRow` / `WalletTokenSupportedDisplayRow`
/// arrays produced by `WalletSupportedRowBuilders` plus the user's
/// preferences (decoded into the `Inputs` struct), and gets back a
/// filtered + sorted array ready to render.
///
/// **Why a separate file (Rule #19-style "pure logic lives outside
/// the view body").** Keeping the filter logic out of the SwiftUI
/// view body has three concrete benefits:
///
/// 1. **Testability.** Each comparator is a one-line pure function;
///    a `@Test` can supply two rows and assert which one wins for
///    every `(sortKey, direction)` combination. The view body
///    cannot — it depends on SwiftUI environment values.
/// 2. **Reusability.** The same applier serves the wallet home,
///    `AllSupportedAssetsView` (once it adopts the same filter), and
///    any future surface that wants to honor the user's filter
///    choice (Send picker, Receive asset list, …).
/// 3. **One auditable code path.** A future bug report ("my sort
///    by value flipped") points to one file, not a buried branch
///    inside `holdingsBody`.
///
/// **Honesty (Rule #2 §A.7).** `apply(coins:with:)` returns the
/// filtered rows; the wallet-home view derives the total + the
/// "found / showing" preview header from the pre- and post-filter
/// counts. The total is the input `count` BEFORE any user filter —
/// so the preview header can say "Showing N of M assets" with a
/// real M, not a post-filter count that would conflate "all assets"
/// with "all visible assets."
///
/// **The 9-step pipeline (each step shrinks the set).**
///
///     1. Search text       — `localizedStandardContains` against
///                            the searchable corpus
///     2. Asset type        — coins-only / tokens-only / both
///     3. Networks intersect — drop if not in selectedNetworks
///                            (when non-empty)
///     4. Hidden chains     — drop if in hiddenChains
///     5. Hidden assets     — drop if in hiddenAssets
///     6. Only with balance — drop zero-amount rows
///     7. Min fiat threshold — drop if `fiatValue ?? 0 < threshold`
///     8. Sort              — per `(sortKey, direction)`
///     9. Pin to top        — pinned IDs leave the sorted body and
///                            render first, in their sorted order
///
/// Pinning is the LAST step so the user's pin choice always wins
/// over the sort — a pinned asset stays at the top whether the
/// user is sorting by value descending OR ascending. The pinned
/// section keeps the same sort comparator for stability so the
/// pinned bucket reads as ordered the same way as the body bucket
/// (just lifted above it).
enum WalletHomeFilterApply {

    /// One decoded snapshot of the user's filter preferences. The
    /// sheet's `@AppStorage` reads write through `WalletHomeFilterPreferences`'s
    /// JSON helpers to produce this shape; the wallet home creates it
    /// once per body evaluation and passes it down.
    struct Inputs {
        let viewMode: WalletHomeFilterPreferences.ViewMode
        let sortKey: WalletHomeFilterPreferences.SortKey
        let direction: WalletHomeFilterPreferences.SortDirection
        let onlyWithBalance: Bool
        let hiddenAssets: Set<String>
        let hiddenChains: Set<String>
        // v2 inputs (2026-06-09)
        let assetType: WalletHomeFilterPreferences.AssetType
        let groupBy: WalletHomeFilterPreferences.GroupBy
        let minFiatThreshold: Decimal
        /// Empty set is the sentinel for "all networks visible".
        let selectedNetworks: Set<String>
        let pinnedAssets: Set<String>
        /// Transient search query. Not a persisted preference —
        /// `WalletHomeView`'s `@State` value.
        let searchText: String

        /// Read every persisted key off `UserDefaults.standard` and
        /// decode the JSON-backed sets to `Set<String>`. The view-
        /// transient `searchText` defaults to empty since this
        /// helper has no view scope; the wallet-home wraps the
        /// produced inputs with its own search-text override.
        static func current() -> Inputs {
            let defaults = UserDefaults.standard
            let viewModeRaw = defaults.string(forKey: WalletHomeFilterPreferences.viewModeKey)
                ?? WalletHomeFilterPreferences.defaultViewMode.rawValue
            let sortKeyRaw = defaults.string(forKey: WalletHomeFilterPreferences.sortKeyKey)
                ?? WalletHomeFilterPreferences.defaultSortKey.rawValue
            let directionRaw = defaults.string(forKey: WalletHomeFilterPreferences.sortDirectionKey)
                ?? WalletHomeFilterPreferences.defaultSortDirection.rawValue
            let onlyWithBalance = defaults.object(forKey: WalletHomeFilterPreferences.onlyWithBalanceKey) as? Bool
                ?? WalletHomeFilterPreferences.defaultOnlyWithBalance
            let hiddenAssetsJSON = defaults.string(forKey: WalletHomeFilterPreferences.hiddenAssetsKey)
                ?? WalletHomeFilterPreferences.defaultHiddenJSON
            let hiddenChainsJSON = defaults.string(forKey: WalletHomeFilterPreferences.hiddenChainsKey)
                ?? WalletHomeFilterPreferences.defaultHiddenJSON
            let assetTypeRaw = defaults.string(forKey: WalletHomeFilterPreferences.assetTypeKey)
                ?? WalletHomeFilterPreferences.defaultAssetType.rawValue
            let groupByRaw = defaults.string(forKey: WalletHomeFilterPreferences.groupByKey)
                ?? WalletHomeFilterPreferences.defaultGroupBy.rawValue
            let minFiatThresholdDouble = defaults.object(forKey: WalletHomeFilterPreferences.minFiatThresholdKey) as? Double
                ?? WalletHomeFilterPreferences.defaultMinFiatThreshold
            let selectedNetworksJSON = defaults.string(forKey: WalletHomeFilterPreferences.selectedNetworksKey)
                ?? WalletHomeFilterPreferences.defaultHiddenJSON
            let pinnedAssetsJSON = defaults.string(forKey: WalletHomeFilterPreferences.pinnedAssetsKey)
                ?? WalletHomeFilterPreferences.defaultHiddenJSON

            return Inputs(
                viewMode: WalletHomeFilterPreferences.ViewMode(rawValue: viewModeRaw)
                    ?? WalletHomeFilterPreferences.defaultViewMode,
                sortKey: WalletHomeFilterPreferences.SortKey(rawValue: sortKeyRaw)
                    ?? WalletHomeFilterPreferences.defaultSortKey,
                direction: WalletHomeFilterPreferences.SortDirection(rawValue: directionRaw)
                    ?? WalletHomeFilterPreferences.defaultSortDirection,
                onlyWithBalance: onlyWithBalance,
                hiddenAssets: WalletHomeFilterPreferences.decode(hiddenAssetsJSON),
                hiddenChains: WalletHomeFilterPreferences.decode(hiddenChainsJSON),
                assetType: WalletHomeFilterPreferences.AssetType(rawValue: assetTypeRaw)
                    ?? WalletHomeFilterPreferences.defaultAssetType,
                groupBy: WalletHomeFilterPreferences.GroupBy(rawValue: groupByRaw)
                    ?? WalletHomeFilterPreferences.defaultGroupBy,
                minFiatThreshold: Decimal(minFiatThresholdDouble),
                selectedNetworks: WalletHomeFilterPreferences.decode(selectedNetworksJSON),
                pinnedAssets: WalletHomeFilterPreferences.decode(pinnedAssetsJSON),
                searchText: ""
            )
        }

        /// Trimmed query, used by the comparator. Whitespace-only
        /// queries collapse to empty so the filter is a no-op for
        /// stray spaces from soft-keyboard auto-suffix.
        var trimmedQuery: String {
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Coins

    /// Apply the 9-step filter pipeline to a `[WalletCoinSupportedRow]`
    /// and sort. Returns the filtered + sorted set with **pinned rows
    /// hoisted to the top** (in their sorted order). The wallet-home
    /// view splits the result into `pinned` and `nonPinned` for
    /// rendering as two sections.
    static func apply(coins: [WalletCoinSupportedRow], with inputs: Inputs) -> [WalletCoinSupportedRow] {
        var rows = coins

        // 1. Search text
        let query = inputs.trimmedQuery
        if !query.isEmpty {
            rows = rows.filter { coinMatchesSearch($0, query: query) }
        }
        // 2. Asset type — coins-only or all
        if inputs.assetType == .tokens {
            return []  // user asked for tokens only; drop every coin row
        }
        // 3. Networks intersect
        if !inputs.selectedNetworks.isEmpty {
            rows = rows.filter { inputs.selectedNetworks.contains($0.chain.rawValue) }
        }
        // 4. Hidden chains
        rows = rows.filter { !inputs.hiddenChains.contains($0.chain.rawValue) }
        // 5. Hidden assets
        rows = rows.filter { !inputs.hiddenAssets.contains(WalletHomeFilterPreferences.assetID(coin: $0)) }
        // 6. Only with balance
        if inputs.onlyWithBalance {
            rows = rows.filter { $0.amount > 0 }
        }
        // 7. Min fiat threshold
        if inputs.minFiatThreshold > 0 {
            rows = rows.filter { ($0.fiatValue ?? .zero) >= inputs.minFiatThreshold }
        }
        // 8. Sort
        rows.sort(by: coinComparator(inputs.sortKey, inputs.direction))
        // 9. Pin (split + reorder; pinned rows first, in sorted order)
        let (pinned, nonPinned) = partitionPinned(coins: rows, pinned: inputs.pinnedAssets)
        return pinned + nonPinned
    }

    /// Split a sorted coin list into `(pinned, nonPinned)` arrays
    /// preserving the pre-existing sort within each bucket. Used by
    /// `apply(coins:with:)` AND by `WalletHomeView`'s rendering so
    /// the view knows where the "Pinned" Section ends.
    static func partitionPinned(
        coins: [WalletCoinSupportedRow],
        pinned: Set<String>
    ) -> (pinned: [WalletCoinSupportedRow], nonPinned: [WalletCoinSupportedRow]) {
        guard !pinned.isEmpty else { return ([], coins) }
        var pinnedRows: [WalletCoinSupportedRow] = []
        var rest: [WalletCoinSupportedRow] = []
        for row in coins {
            if pinned.contains(WalletHomeFilterPreferences.assetID(coin: row)) {
                pinnedRows.append(row)
            } else {
                rest.append(row)
            }
        }
        return (pinnedRows, rest)
    }

    /// `localizedStandardContains` against the coin's searchable
    /// corpus: chain display name, ticker, and rawValue. A query
    /// like "bit" matches "Bitcoin" and "btc" matches the ticker;
    /// "eth" matches Ethereum.
    private static func coinMatchesSearch(_ row: WalletCoinSupportedRow, query: String) -> Bool {
        row.chain.displayName.localizedStandardContains(query)
            || row.chain.ticker.localizedStandardContains(query)
            || row.chain.rawValue.localizedStandardContains(query)
    }

    private static func coinComparator(
        _ key: WalletHomeFilterPreferences.SortKey,
        _ direction: WalletHomeFilterPreferences.SortDirection
    ) -> (WalletCoinSupportedRow, WalletCoinSupportedRow) -> Bool {
        let ascending = direction == .ascending
        switch key {
        case .name:
            return { a, b in
                let order = a.chain.displayName.localizedStandardCompare(b.chain.displayName)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .symbol:
            return { a, b in
                let order = a.chain.ticker.localizedStandardCompare(b.chain.ticker)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .balance:
            return { a, b in
                ascending ? a.amount < b.amount : a.amount > b.amount
            }
        case .value:
            return { a, b in
                let aFiat = a.fiatValue ?? .zero
                let bFiat = b.fiatValue ?? .zero
                if aFiat == bFiat {
                    // Stable tie-breaker: chain canonical order so the
                    // list doesn't shimmer between renders when every
                    // row's fiatValue is nil. Honors the user's chosen
                    // direction like the primary key does.
                    let ai = canonicalIndex(a.chain)
                    let bi = canonicalIndex(b.chain)
                    return ascending ? ai < bi : ai > bi
                }
                return ascending ? aFiat < bFiat : aFiat > bFiat
            }
        case .chain:
            return { a, b in
                let ai = canonicalIndex(a.chain)
                let bi = canonicalIndex(b.chain)
                return ascending ? ai < bi : ai > bi
            }
        }
    }

    // MARK: - Tokens

    /// Apply the 9-step filter pipeline to a
    /// `[WalletTokenSupportedDisplayRow]` and sort. Same shape as
    /// `apply(coins:with:)`.
    static func apply(tokens: [WalletTokenSupportedDisplayRow], with inputs: Inputs) -> [WalletTokenSupportedDisplayRow] {
        var rows = tokens

        // 1. Search text
        let query = inputs.trimmedQuery
        if !query.isEmpty {
            rows = rows.filter { tokenMatchesSearch($0, query: query) }
        }
        // 2. Asset type — tokens-only or all
        if inputs.assetType == .coins {
            return []  // user asked for coins only; drop every token row
        }
        // 3. Networks intersect
        if !inputs.selectedNetworks.isEmpty {
            rows = rows.filter { inputs.selectedNetworks.contains($0.chain.rawValue) }
        }
        // 4. Hidden chains
        rows = rows.filter { !inputs.hiddenChains.contains($0.chain.rawValue) }
        // 5. Hidden assets
        rows = rows.filter { !inputs.hiddenAssets.contains(WalletHomeFilterPreferences.assetID(token: $0)) }
        // 6. Only with balance
        if inputs.onlyWithBalance {
            rows = rows.filter { $0.amount > 0 }
        }
        // 7. Min fiat threshold
        if inputs.minFiatThreshold > 0 {
            rows = rows.filter { ($0.fiatValue ?? .zero) >= inputs.minFiatThreshold }
        }
        // 8. Sort
        rows.sort(by: tokenComparator(inputs.sortKey, inputs.direction))
        // 9. Pin
        let (pinned, nonPinned) = partitionPinned(tokens: rows, pinned: inputs.pinnedAssets)
        return pinned + nonPinned
    }

    /// Split a sorted token list into `(pinned, nonPinned)` arrays.
    /// See `partitionPinned(coins:pinned:)` for rationale.
    static func partitionPinned(
        tokens: [WalletTokenSupportedDisplayRow],
        pinned: Set<String>
    ) -> (pinned: [WalletTokenSupportedDisplayRow], nonPinned: [WalletTokenSupportedDisplayRow]) {
        guard !pinned.isEmpty else { return ([], tokens) }
        var pinnedRows: [WalletTokenSupportedDisplayRow] = []
        var rest: [WalletTokenSupportedDisplayRow] = []
        for row in tokens {
            if pinned.contains(WalletHomeFilterPreferences.assetID(token: row)) {
                pinnedRows.append(row)
            } else {
                rest.append(row)
            }
        }
        return (pinnedRows, rest)
    }

    /// `localizedStandardContains` against the token's searchable
    /// corpus: symbol, name, chain display name, and contract.
    /// Contract is included because a power user pasting a token
    /// address expects to find the matching token in their list.
    private static func tokenMatchesSearch(_ row: WalletTokenSupportedDisplayRow, query: String) -> Bool {
        row.symbol.localizedStandardContains(query)
            || row.name.localizedStandardContains(query)
            || row.chain.displayName.localizedStandardContains(query)
            || row.contract.localizedStandardContains(query)
    }

    private static func tokenComparator(
        _ key: WalletHomeFilterPreferences.SortKey,
        _ direction: WalletHomeFilterPreferences.SortDirection
    ) -> (WalletTokenSupportedDisplayRow, WalletTokenSupportedDisplayRow) -> Bool {
        let ascending = direction == .ascending
        switch key {
        case .name:
            return { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .symbol:
            return { a, b in
                let order = a.symbol.localizedStandardCompare(b.symbol)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case .balance:
            return { a, b in
                ascending ? a.amount < b.amount : a.amount > b.amount
            }
        case .value:
            return { a, b in
                let aFiat = a.fiatValue ?? .zero
                let bFiat = b.fiatValue ?? .zero
                if aFiat == bFiat {
                    // Tie-breakers honor the user's chosen direction
                    // like the primary key does.
                    let symOrder = a.symbol.localizedStandardCompare(b.symbol)
                    if symOrder == .orderedSame {
                        let ai = canonicalIndex(a.chain)
                        let bi = canonicalIndex(b.chain)
                        return ascending ? ai < bi : ai > bi
                    }
                    return ascending
                        ? symOrder == .orderedAscending
                        : symOrder == .orderedDescending
                }
                return ascending ? aFiat < bFiat : aFiat > bFiat
            }
        case .chain:
            return { a, b in
                let ai = canonicalIndex(a.chain)
                let bi = canonicalIndex(b.chain)
                if ai == bi {
                    let symOrder = a.symbol.localizedStandardCompare(b.symbol)
                    return symOrder == .orderedAscending
                }
                return ascending ? ai < bi : ai > bi
            }
        }
    }

    // MARK: - Canonical chain order

    /// Index of a chain in `SupportedChain.allCases`. Used as the
    /// secondary sort key for tie-breaks and as the primary key when
    /// the user picks `SortKey.chain`.
    ///
    /// **2026-06-09 perf.** Was `SupportedChain.allCases.firstIndex(of:)`
    /// — an O(N) linear scan on every sort comparison. With ~400 rows
    /// × ~12 comparisons per row × 26 chains, the sort step alone was
    /// burning ~125k chain comparisons per body render. Memoized into
    /// a static `[chain: index]` dictionary computed once at first
    /// access; every subsequent call is a single hash lookup.
    static func canonicalIndex(_ chain: SupportedChain) -> Int {
        canonicalIndexTable[chain] ?? .max
    }

    private static let canonicalIndexTable: [SupportedChain: Int] = {
        var dict: [SupportedChain: Int] = [:]
        dict.reserveCapacity(SupportedChain.allCases.count)
        for (i, chain) in SupportedChain.allCases.enumerated() {
            dict[chain] = i
        }
        return dict
    }()
}
