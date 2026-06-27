import SwiftUI
import SwiftData

/// "All supported assets" destination — the screen behind the
/// "Show all" rows in the wallet home's Coins and Tokens sections.
///
/// **Design intent (Rule #2 §D.1):** show the user every asset
/// Aperture supports — every native coin (26), every fungible token
/// from the curated registries — with their current balance against
/// the active wallet rendered honestly (zero is "0", never `—` and
/// never hidden). The user opens this surface to answer two
/// questions at once: "what does this app support?" and "what do I
/// hold of each?". One screen, both answers.
///
/// **Layout (Rule #15 §A).** Sheet-shaped destination pushed onto
/// the wallet-home `NavigationStack`. Inherits the parent nav bar
/// (no nested NavigationStack — M-004). Title rendered via
/// `.navigationTitle` so the system handles scroll-compression
/// behaviour. Two sections at root: **Coins** then **Tokens**,
/// matching the home screen's vocabulary.
///
/// **Search (Rule #14).** `.searchable(text:)` with no `placement:`
/// argument so iOS 26 owns the placement (bottom-floating Liquid
/// Glass on iPhone, top-trailing on iPad/Mac). Filter uses
/// `String.localizedStandardContains(_:)` against every
/// human-readable field: ticker, display name, and the chain name
/// for tokens.
///
/// **Honesty (Rule #16).** Zero-balance rows are rendered with `0`
/// and `Price unavailable` — never "Coming soon" (we already
/// support them) and never hidden (the user wants to see what's
/// possible). When the user holds a coin or token, the cached fiat
/// value joins the row.
///
/// **Rule #4.** Every color through `UniColors`. Every metric
/// through `UniSpacing` / `UniRadius` / `UniTypography`.
///
/// **Rule #7.** Coin, token, and network marks resolve through the
/// shared Stabro-style `CoinMark` view — local `token_*`, `coin_*`,
/// and `network_*` assets first, then a cached Trust Wallet URL, then
/// an honest initials chip. Never a fabricated brand mark.
struct AllSupportedAssetsView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var searchText: String = ""
    @State private var isShowingFilter: Bool = false

    // Filter & Sort preferences (Rule shared with the home / asset-detail
    // filters): the user picks once, the list honors it every visit.
    @AppStorage(AllSupportedFilterPreferences.sortKeyKey)
    private var sortKeyRaw: String = AllSupportedFilterPreferences.defaultSortKey.rawValue
    @AppStorage(AllSupportedFilterPreferences.assetTypeKey)
    private var assetTypeRaw: String = AllSupportedFilterPreferences.defaultAssetType.rawValue
    @AppStorage(AllSupportedFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = AllSupportedFilterPreferences.defaultSelectedNetworksJSON
    @AppStorage(AllSupportedFilterPreferences.onlyWithBalanceKey)
    private var onlyWithBalance: Bool = AllSupportedFilterPreferences.defaultOnlyWithBalance

    private var sortKey: AllSupportedFilterPreferences.SortKey {
        AllSupportedFilterPreferences.SortKey(rawValue: sortKeyRaw) ?? AllSupportedFilterPreferences.defaultSortKey
    }
    private var assetType: AllSupportedFilterPreferences.AssetType {
        AllSupportedFilterPreferences.AssetType(rawValue: assetTypeRaw) ?? AllSupportedFilterPreferences.defaultAssetType
    }
    private var selectedNetworks: Set<String> {
        AllSupportedFilterPreferences.decode(selectedNetworksJSON)
    }

    var body: some View {
        // Build the supported-asset rows ONCE per body pass and reuse them
        // for the sections, the empty-state, and the filter sheet's counts.
        // Lookups go through the shared O(1) `WalletSupportedRowBuilders`
        // (HeldRowIndex) — the same path the home + asset-detail screens use
        // — so we never re-scan held balances per token or recompute the
        // full list mid-render.
        let held = heldRows
        let allCoins = WalletSupportedRowBuilders.coinRows(heldRows: held, currencyCode: currencyCode)
        // One row per token symbol (USDT once, not per network) — the network
        // breakdown lives in the asset detail (2026-06-18).
        let allTokens = WalletSupportedRowBuilders.collapseBySymbol(
            WalletSupportedRowBuilders.tokenRows(heldRows: held, currencyCode: currencyCode),
            currencyCode: currencyCode
        )
        let coinRows = visibleCoins(allCoins)
        let tokenRows = visibleTokens(allTokens)
        let isEmpty = !((assetType.showsCoins && !coinRows.isEmpty)
            || (assetType.showsTokens && !tokenRows.isEmpty))
        let totalCount = allCoins.count + allTokens.count
        let visibleCount = coinRows.count + tokenRows.count

        return List {
            if assetType.showsCoins { coinsSection(coinRows) }
            if assetType.showsTokens { tokensSection(tokenRows) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .overlay {
            if isEmpty {
                ContentUnavailableView {
                    Label("No assets", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text("No supported assets match your filter.")
                }
            }
        }
        .navigationTitle("Coins & tokens")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("Search"))
        .toolbar {
            // Bare `line.3.horizontal.decrease` glyph — the same filter
            // affordance the wallet home and asset-detail screens use.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingFilter = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .accessibilityLabel(Text("Filter and sort"))
                }
            }
        }
        .sheet(isPresented: $isShowingFilter) {
            AllSupportedAssetsFilterSheet(
                totalAssets: totalCount,
                visibleAssets: visibleCount
            )
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Sections

    /// Coins section — supported chains, already filtered + sorted by the
    /// caller. Hidden entirely when no coin matches the active filter.
    @ViewBuilder
    private func coinsSection(_ rows: [CoinSupportedRow]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.chain) { row in
                    NavigationLink(value: WalletHomeDestination.assetDetail(.nativeCoin(row.chain))) {
                        AssetRow(
                            chain: row.chain,
                            tokenSymbol: row.chain.ticker,
                            nativeAmount: row.amount,
                            nativeDecimals: min(row.chain.nativeDecimals, 8),
                            fiatValue: row.fiatValue,
                            fiatCurrencyCode: row.fiatCurrencyCode
                        )
                    }
                    .accessibilityLabel(Text("\(row.chain.displayName) details"))
                }
            } header: {
                Text("Coins")
            }
        }
    }

    /// Tokens section — one row per `(symbol, chain)` across the curated
    /// registries, already filtered + sorted by the caller. Hidden when no
    /// token matches the active filter.
    @ViewBuilder
    private func tokensSection(_ rows: [TokenSupportedDisplayRow]) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.id) { row in
                    NavigationLink(value: WalletHomeDestination.assetDetail(.token(symbol: row.symbol))) {
                        TokenSupportedRow(row: row)
                    }
                    .accessibilityLabel(Text("\(row.symbol) details"))
                }
            } header: {
                Text("Tokens")
            }
        }
    }

    // MARK: - Row models
    //
    // These types were lifted from `private` to file-internal so the
    // main `WalletHomeView` can compose against the same shapes when
    // it enumerates ALL supported coins / tokens on the home screen
    // (with held-first, zero-balance-shown ordering). One canonical
    // row shape, two consumers.

    typealias CoinSupportedRow = WalletCoinSupportedRow
    typealias TokenSupportedDisplayRow = WalletTokenSupportedDisplayRow

    // MARK: - Active wallet + balance lookup

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    /// All `(chain, TokenBalanceRecord)` rows the active wallet has
    /// non-empty balances for. Same source the wallet home uses.
    private var heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        guard let wallet = activeWallet else { return [] }
        var result: [(SupportedChain, TokenBalanceRecord)] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for balance in address.balances where !balance.rawBalance.isEmpty {
                result.append((chain, balance))
            }
        }
        return result
    }

    // MARK: - Coins rows

    /// Coins rows after applying the active filter (networks +
    /// only-with-balance + search) and the chosen sort, over the full set
    /// built once in `body`. Search matches display name and ticker.
    private func visibleCoins(_ all: [CoinSupportedRow]) -> [CoinSupportedRow] {
        let networks = selectedNetworks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = all.filter { row in
            networks.isEmpty || networks.contains(row.chain.rawValue)
        }
        if onlyWithBalance {
            rows = rows.filter { ($0.fiatValue ?? 0) > 0 || $0.amount > 0 }
        }
        if !query.isEmpty {
            rows = rows.filter { row in
                row.chain.displayName.localizedStandardContains(query)
                    || row.chain.ticker.localizedStandardContains(query)
            }
        }
        return sortCoins(rows)
    }

    /// Coins sorted per the active `sortKey`. `.balance` puts held coins
    /// first (largest fiat → smallest), then the rest alphabetically;
    /// `.name` sorts every coin alphabetically by display name.
    private func sortCoins(_ rows: [CoinSupportedRow]) -> [CoinSupportedRow] {
        switch sortKey {
        case .balance:
            return rows.sorted { a, b in
                let aHeld = (a.fiatValue ?? 0) > 0 || a.amount > 0
                let bHeld = (b.fiatValue ?? 0) > 0 || b.amount > 0
                if aHeld != bHeld { return aHeld && !bHeld }
                if aHeld && bHeld { return (a.fiatValue ?? 0) > (b.fiatValue ?? 0) }
                return a.chain.displayName.localizedStandardCompare(b.chain.displayName) == .orderedAscending
            }
        case .name:
            return rows.sorted {
                $0.chain.displayName.localizedStandardCompare($1.chain.displayName) == .orderedAscending
            }
        }
    }

    // MARK: - Tokens rows

    /// Token rows after applying the active filter (networks +
    /// only-with-balance + search) and the chosen sort, over the full set
    /// built once in `body`. Search matches symbol, full registry name,
    /// and the chain's display name (so searching "Polygon" surfaces every
    /// token on Polygon).
    private func visibleTokens(_ all: [TokenSupportedDisplayRow]) -> [TokenSupportedDisplayRow] {
        let networks = selectedNetworks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = all.filter { row in
            networks.isEmpty || networks.contains(row.chain.rawValue)
        }
        if onlyWithBalance {
            rows = rows.filter { ($0.fiatValue ?? 0) > 0 || $0.amount > 0 }
        }
        if !query.isEmpty {
            rows = rows.filter { row in
                row.symbol.localizedStandardContains(query)
                    || row.name.localizedStandardContains(query)
                    || row.chain.displayName.localizedStandardContains(query)
            }
        }
        return sortTokens(rows)
    }

    /// Tokens sorted per the active `sortKey`. `.balance` puts held
    /// tokens first (largest fiat → smallest), then the rest
    /// alphabetically by `(symbol, chain)`; `.name` sorts every token by
    /// its full registry name.
    private func sortTokens(_ rows: [TokenSupportedDisplayRow]) -> [TokenSupportedDisplayRow] {
        switch sortKey {
        case .balance:
            return rows.sorted { a, b in
                let aHeld = (a.fiatValue ?? 0) > 0 || a.amount > 0
                let bHeld = (b.fiatValue ?? 0) > 0 || b.amount > 0
                if aHeld != bHeld { return aHeld && !bHeld }
                if aHeld && bHeld { return (a.fiatValue ?? 0) > (b.fiatValue ?? 0) }
                if a.symbol != b.symbol { return a.symbol < b.symbol }
                return a.chain.displayName < b.chain.displayName
            }
        case .name:
            return rows.sorted { a, b in
                let byName = a.name.localizedStandardCompare(b.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return a.chain.displayName < b.chain.displayName
            }
        }
    }
}

// MARK: - TokenSupportedRow

/// One row in `AllSupportedAssetsView`'s Tokens section. Mirrors
/// `TokenHoldingRow`'s anatomy (44pt mark + ticker + chain + amount
/// + fiat) so the visual register stays consistent between the
/// home screen's "Tokens" section and the "Show all" destination.
///
/// **Why an internal type and not `TokenHoldingRow`.** The display
/// row's `name` field can be longer than the bare `tokenSymbol`
/// (e.g. "Wrapped Bitcoin" vs "WBTC"). Surfacing the name as the
/// title — with the symbol-on-chain as the subtitle — gives the
/// user the right "what is this thing?" answer on a discovery
/// screen. On the home screen they already know they hold it, so
/// the symbol leads. Same anatomy, different emphasis.
private struct TokenSupportedRow: View {
    let row: AllSupportedAssetsView.TokenSupportedDisplayRow

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(chain: row.chain, tokenSymbol: row.symbol, contract: row.contract)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                // Full NAME is the title, SYMBOL the subtitle. The chain
                // is intentionally dropped (2026-06-19 user direction) —
                // a token can live on many networks, so naming one here is
                // misleading; the per-network breakdown lives in the asset
                // detail.
                Text(verbatim: row.name)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(verbatim: row.symbol)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(WalletFormatting.native(row.amount, decimals: 6))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                fiatLabel
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(row.symbol), \(row.name), on \(row.chain.displayName)"))
    }

    private var fiatLabel: some View {
        // Zero/unheld → "US$0.00", never "Price unavailable" (user
        // direction 2026-06-18). `row.fiatCurrencyCode` carries the active
        // currency even for an unheld supported asset.
        Text(WalletFormatting.fiat(row.fiatValue ?? 0, currencyCode: row.fiatCurrencyCode))
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Text.tertiary)
            .monospacedDigit()
    }
}
