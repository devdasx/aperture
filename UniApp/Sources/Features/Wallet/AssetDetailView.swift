import SwiftUI
import SwiftData

/// **The asset-detail screen.** Pushed onto the wallet-home
/// `NavigationStack` when the user taps any coin or token row.
///
/// **Design intent (one sentence per Rule #2 §D.1):** show the user
/// the calm, undeniable truth of one asset they own — total holding
/// summed across networks, the shape of its history, its presence on
/// every network they could hold it, and every transaction that has
/// moved it — with one filter affordance that scopes everything below
/// the chart.
///
/// **Layers (Rule #2 §B.3):** content layer is opaque (identity hero,
/// hero number, chart, rows); functional layer is the Liquid Glass
/// toolbar chrome only. One layer of glass — the nav bar.
///
/// **Sections (List(.insetGrouped) — same chrome iOS Settings uses).**
///
/// 1. **Identity hero + balance + chart card** — a single Section so
///    iOS draws ONE unified white card around three rows:
///    - 80pt CoinMark + asset name + ticker + "On N networks"
///    - hero fiat number (Σ across networks) + native rollup
///    - `BalanceHistoryChart` (asset-scoped — only this asset's
///      transactions + only this asset's current balances feed the
///      reconstructor)
///
/// 2. **Networks section** — one row per network the asset is on,
///    held first (fiat desc), then supported-but-not-held in
///    canonical chain order. Each row tappable to push the per-
///    network detail.
///
/// 3. **Activity section** — asset-scoped transactions, sorted per
///    the filter, capped at 50 with a "View all" affordance.
///
/// 4. **Footer** — the same boundary statement the wallet home
///    carries, so the screen reads as continuous with the rest of
///    the app.
///
/// **Performance.** Mirrors the wallet-home discipline:
/// - The resolver + filter pipeline runs ONCE per input change into
///   a `@State` memo (`derivedCache`, rebuilt via `.task(id:)`) that
///   the sections all read. No linear scans inside `ForEach`.
/// - Stable `ForEach` IDs (`id: \.id` on every row).
/// - `AssetDetailFilterApply` is pure and called once per section.
/// - The `BalanceHistoryReconstructor` is fed the pre-filtered tx set
///   so it doesn't re-walk the whole wallet's history.
///
/// **Honesty (Rule #16).**
/// - Zero-balance networks render with `0` and `Price unavailable`,
///   never hidden by default. The filter sheet's "Only with balance"
///   toggle is opt-in.
/// - "On N networks" reports the actual count (held + supported), not
///   marketing puffery.
/// - The chart's zero-baseline branch applies when the wallet has no
///   asset transactions yet (Rule #2 §A.7 — calm flat line, not a
///   fake curve).
struct AssetDetailView: View {
    /// The asset to render. Owned by the wallet-home's NavigationPath
    /// — when the user navigates back, the value is discarded and the
    /// detail's @State is rebuilt from scratch on the next visit.
    let identity: AssetIdentity

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    /// On-disk price cache so `BalanceHistoryChart`'s reconstructor
    /// can value past holdings of fully cashed-out tokens. Same
    /// pattern as the wallet home (2026-06-12 — see
    /// `WalletHomeView.priceCacheBySymbol`). Without this map the
    /// USDT detail chart was flat-zero even when the user had
    /// received 747 USDT then sent every unit, because USDT no
    /// longer appeared in `currentBalances`.
    @Query private var cachedPrices: [CachedPriceRecord]
    /// On-disk historical-price cache — drives the
    /// `BalanceHistoryChart`'s per-day pricing so the asset's chart
    /// values past holdings at their then-price (e.g. an asset
    /// that crashed 99% renders the historical peak at its real
    /// then-value, not today's collapsed valuation).
    @Query private var historicalPrices: [HistoricalPriceRecord]
    /// Needed for the historical-price ensure-loop that constructs
    /// `HistoricalPriceRepository(modelContainer:)` to write fetched
    /// candles into the SwiftData store.
    @Environment(\.modelContext) private var modelContext
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var hideBalance: Bool = false

    // MARK: - Filter preferences (Rule #14-class declarative reads)
    //
    // Same pattern as `WalletHomeView`: read every @AppStorage key
    // here so the body invalidates the moment the filter sheet writes
    // a new value. The pure-function applier consumes the snapshot
    // computed once per body via `filterInputs`.

    @AppStorage(AssetDetailFilterPreferences.sortKeyKey)
    private var filterSortKeyRaw: String = AssetDetailFilterPreferences.defaultSortKey.rawValue
    @AppStorage(AssetDetailFilterPreferences.directionKey)
    private var filterDirectionRaw: String = AssetDetailFilterPreferences.defaultDirection.rawValue
    @AppStorage(AssetDetailFilterPreferences.selectedNetworksKey)
    private var filterSelectedNetworksJSON: String = AssetDetailFilterPreferences.defaultSelectedNetworksJSON
    @AppStorage(AssetDetailFilterPreferences.timeRangeKey)
    private var filterTimeRangeRaw: String = AssetDetailFilterPreferences.defaultTimeRange.rawValue
    @AppStorage(AssetDetailFilterPreferences.hideZeroNetworksKey)
    private var filterHideZeroNetworks: Bool = AssetDetailFilterPreferences.defaultHideZeroNetworks

    /// Language code drives the Rule #12 §G direction-only rebuild key
    /// for the filter sheet.
    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    @State private var isShowingFilter: Bool = false

    /// 2026-06-09 — `BalanceHistoryChart` writes the scrubbed point's
    /// fiat here so the hero renders it (animated via
    /// `.contentTransition(.numericText())`). `@Observable` model
    /// (2026-06-13 perf fix) so scrubbing re-renders only the hero, not
    /// the whole detail body. `nil` `fiat` → hero shows `totalFiat`.
    @State private var scrubModel = ChartScrubModel()

    /// Cap on the activity section — same convention the wallet home
    /// uses. When the asset has more than 50 transactions, a "View
    /// all" navigation row appears below the 50 (pushes
    /// `WalletHomeDestination.assetActivity(identity)` — handled by
    /// the wallet home's NavigationStack).
    private let activityDisplayCap: Int = 50

    var body: some View {
        // Memoized derived snapshot (resolver-per-body fix): the
        // 9-registry resolve + filter pipeline runs in `.task(id:)`
        // keyed on the actual inputs and lands in `derivedCache`.
        // The inline fallback covers only the first frame, before
        // the task has fired.
        let derived = derivedCache ?? computeDerived()
        List {
            heroCardSection(derived)
            networksSection(derived)
            activitySection(derived)
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Rule #14 — search uses `.searchable`. The asset detail
            // doesn't carry one — the screen is already scoped to a
            // single asset; filtering by symbol is the URL. Filter is
            // the canonical surface for narrowing further.
            //
            // Rule #19 §C — toolbar items are navigation affordances,
            // not commit CTAs. Bare SF Symbol (no `.circle` per M-003
            // discipline — the same `line.3.horizontal.decrease` glyph
            // the wallet home uses).
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
            // Rule #12 §G direction-only rebuild key +
            // `.uniAppEnvironment()` so theme + locale propagate.
            AssetDetailFilterSheet(
                identity: identity,
                availableNetworks: derived.resolution.networks,
                totalTransactions: derived.assetScopedTransactions.count,
                visibleTransactions: derived.filteredTransactions.count
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .task(id: derivedKey) {
            derivedCache = computeDerived()
        }
        .task(id: historicalEnsureKey) {
            await ensureHistoricalPricesLoaded()
        }
    }

    /// Re-runs when wallet, currency, or asset identity changes.
    private var historicalEnsureKey: String {
        [
            activeWallet?.id.uuidString ?? "",
            currencyCode,
            identity.symbol,
            identity.nativeChain?.rawValue ?? "token"
        ].joined(separator: "|")
    }

    /// Asset-scoped variant of `WalletHomeView.ensureHistoricalPricesLoaded`.
    /// Fetches Coinbase historical closes only for the symbols
    /// involved in THIS asset (the chart on this screen is
    /// asset-scoped, so we don't need history for unrelated
    /// tokens). For native coins that's `chain.ticker`; for token
    /// assets that's `identity.symbol`.
    private func ensureHistoricalPricesLoaded() async {
        let symbol = identity.symbol.uppercased()
        // Already have history for this (symbol, fiat) pair? Skip.
        if historicalPrices.contains(where: {
            $0.symbol.uppercased() == symbol && $0.fiat == currencyCode
        }) {
            return
        }
        let service = CoinbaseHistoricalPriceService()
        let candles = await service.fetchDailyCloses(symbol: symbol, fiat: currencyCode)
        guard !candles.isEmpty else { return }
        let repo = HistoricalPriceRepository(modelContainer: modelContext.container)
        let entries = candles.map {
            (symbol: symbol, fiat: currencyCode, dayKey: $0.dayKey, price: $0.close)
        }
        try? await repo.upsertMany(entries)
    }

    // MARK: - Hero card section
    //
    // Single inset-grouped Section. iOS draws the unified white card
    // around all three rows. Row separators hidden so the rows read as
    // one card, not three stacked cells.

    @ViewBuilder
    private func heroCardSection(_ derived: DerivedState) -> some View {
        Section {
            // Row 1 — identity hero (logo + name + ticker + N-networks
            // caption).
            identityHeroRow(derived)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 24,
                    leading: UniSpacing.m,
                    bottom: 0,
                    trailing: UniSpacing.m
                ))

            // Row 2 — hero fiat number + native rollup beneath.
            balanceHeroRow(derived)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 12,
                    leading: UniSpacing.m,
                    bottom: 0,
                    trailing: UniSpacing.m
                ))

            // Row 3 — the asset-scoped balance history chart.
            BalanceHistoryChart(
                transactions: derived.assetScopedTransactions,
                currentBalances: derived.assetCurrentBalances,
                priceCache: priceCacheBySymbol(for: derived.resolution.fiatCurrencyCode),
                priceHistory: priceHistoryBySymbol(for: derived.resolution.fiatCurrencyCode),
                currencyCode: derived.resolution.fiatCurrencyCode,
                scrubModel: scrubModel
            )
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: UniSpacing.m,
                bottom: 24,
                trailing: UniSpacing.m
            ))
        }
    }

    /// Identity hero — 80pt CoinMark + name + ticker + "On N networks".
    /// For native coins ("BTC on Bitcoin") the caption reads the
    /// chain display name; for tokens ("USDC on N networks") it reads
    /// the network count.
    @ViewBuilder
    private func identityHeroRow(_ derived: DerivedState) -> some View {
        HStack(spacing: UniSpacing.m) {
            heroMark(derived.resolution)
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: derived.displayName)
                    .font(UniTypography.title2)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(verbatim: identity.symbol)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Text(networkCountCaption(derived.resolution))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    /// Resolve the hero mark. For native coins we pass the chain so
    /// `CoinMark` paints the bundled native asset. For tokens we pick
    /// the first network row that has a contract — `CoinMark` will
    /// resolve through bundled stables or Trust Wallet via cache.
    @ViewBuilder
    private func heroMark(_ resolution: AssetResolution) -> some View {
        if let chain = identity.nativeChain {
            CoinMark(chain: chain, tokenSymbol: identity.symbol)
        } else if let row = resolution.networks.first(where: { $0.contract != nil && !($0.contract?.isEmpty ?? true) }) {
            CoinMark(
                chain: row.chain,
                tokenSymbol: identity.symbol,
                contract: row.contract
            )
        } else if let row = resolution.networks.first {
            CoinMark(chain: row.chain, tokenSymbol: identity.symbol)
        } else {
            // Should never happen — every identity resolves to at
            // least one network row. Defensive fallback.
            Circle()
                .fill(UniColors.Material.card)
                .overlay {
                    Text(verbatim: String(identity.symbol.prefix(3)))
                        .font(UniTypography.bodyEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                }
        }
    }

    /// "On Ethereum" for natives; "On N networks" for tokens. When
    /// the user holds the token on M of N networks, the caption
    /// reads "On N networks · held on M" — honest about reach AND
    /// possession.
    private func networkCountCaption(_ resolution: AssetResolution) -> LocalizedStringKey {
        switch identity.kind {
        case .nativeCoin(let chain):
            return "On \(chain.displayName)"
        case .token:
            let total = resolution.supportedNetworkCount
            let held = resolution.heldNetworkCount
            if held > 0 && held < total {
                return "On \(total) networks · held on \(held)"
            }
            if held == total && total > 0 {
                return "Held on all \(total) networks"
            }
            return "On \(total) networks"
        }
    }

    /// Hero number — `scrubbedFiat ?? totalFiat`. Tap reveals when
    /// `hideBalance` is true, same affordance as the wallet home.
    @ViewBuilder
    private func balanceHeroRow(_ derived: DerivedState) -> some View {
        VStack(alignment: .center, spacing: 6) {
            balanceLabel(derived)
            nativeRollup(derived.resolution)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func balanceLabel(_ derived: DerivedState) -> some View {
        let displayedFiat: Decimal? = scrubModel.fiat ?? derived.resolution.totalFiat
        let display: String = {
            if hideBalance { return "••••••" }
            if let fiat = displayedFiat {
                return WalletFormatting.fiat(fiat, currencyCode: derived.resolution.fiatCurrencyCode)
            }
            return String.apertureLocalized("Price unavailable")
        }()
        Text(display)
            .font(UniTypography.heroBalance)
            .foregroundStyle(UniColors.Text.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
            .accessibilityLabel(
                hideBalance
                    ? Text("Balance hidden")
                    : Text("Total \(derived.displayName) balance")
            )
    }

    /// The Σ native amount of the asset across networks, rendered
    /// beneath the fiat hero in `monoBody`. For native coins that's
    /// the one chain's amount; for tokens that's the cross-network
    /// sum. Honest about asset-scoped totals.
    private func nativeRollup(_ resolution: AssetResolution) -> some View {
        let amount = WalletFormatting.native(resolution.totalAmount, decimals: 6)
        return Text(verbatim: "\(amount) \(identity.symbol)")
            .font(UniTypography.subheadline)
            .foregroundStyle(UniColors.Text.secondary)
            .monospacedDigit()
    }

    // MARK: - Networks section
    //
    // One row per `AssetNetworkRow` in `filteredNetworks`. Section
    // header reads "Networks". Each row tappable via
    // `NavigationLink(value: WalletHomeDestination.assetNetworkDetail(...))`
    // — the wallet home's NavigationStack owns the routing.

    @ViewBuilder
    private func networksSection(_ derived: DerivedState) -> some View {
        let networkRows = derived.filteredNetworks
        if !networkRows.isEmpty {
            Section {
                ForEach(networkRows, id: \.id) { row in
                    NavigationLink(value: WalletHomeDestination.assetNetworkDetail(identity, row.chain.rawValue)) {
                        AssetNetworkRowView(
                            row: row,
                            assetSymbol: identity.symbol
                        )
                    }
                }
            } header: {
                Text("Networks")
            } footer: {
                if filterHideZeroNetworks && derived.resolution.heldNetworkCount < derived.resolution.supportedNetworkCount {
                    Text("Networks where you don't hold this asset are hidden. Toggle off Only with balance to see all networks.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            // Filter hid every row. Honest empty state.
            Section {
                UniEmptyState(
                    title: "No networks match the filter.",
                    detail: "Adjust the filter sheet to see this asset's networks.",
                    mark: .icon(systemName: "globe")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Networks")
            }
        }
    }

    // MARK: - Activity section

    @ViewBuilder
    private func activitySection(_ derived: DerivedState) -> some View {
        let rows = derived.filteredTransactions
        let displayed = Array(rows.prefix(activityDisplayCap))
        let hasMore = rows.count > activityDisplayCap

        Section {
            if displayed.isEmpty {
                UniEmptyState(
                    title: derived.assetScopedTransactions.isEmpty
                        ? "No activity yet."
                        : "No activity matches the filter.",
                    detail: derived.assetScopedTransactions.isEmpty
                        ? "Transactions involving this asset appear here as they confirm on-chain."
                        : "Adjust the filter sheet to see more activity.",
                    mark: .icon(systemName: "list.bullet.rectangle.portrait")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } else {
                ForEach(displayed, id: \.id) { tx in
                    if let chain = chainFor(tx) {
                        NavigationLink(value: WalletHomeDestination.transaction(tx.id)) {
                            activityRow(tx, chain: chain)
                        }
                    } else {
                        // The parent address record is missing or
                        // carries an unrecognized chain — render the
                        // row plain, with NO NavigationLink, so the
                        // user is never routed against wrong-chain
                        // data. The mark chain below is a display-only
                        // proxy taken from the asset's own identity.
                        activityRow(tx, chain: displayProxyChain(derived))
                    }
                }
                if hasMore {
                    NavigationLink(value: WalletHomeDestination.assetActivity(identity)) {
                        HStack(spacing: UniSpacing.s) {
                            Text("View all")
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)
                            Spacer(minLength: UniSpacing.s)
                            Text(verbatim: "\(rows.count)")
                                .font(UniTypography.subheadline)
                                .foregroundStyle(UniColors.Text.tertiary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, UniSpacing.xs)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("View all \(rows.count) transactions"))
                }
            }
        } header: {
            Text("Recent activity")
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerSection: some View {
        Section {
            UniFootnote(
                text: "No accounts. No servers. Aperture lives on your iPhone.",
                alignment: .center,
                color: UniColors.Text.tertiary
            )
            .frame(maxWidth: .infinity)
            .padding(.top, UniSpacing.l)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - Derived state (memoized)

    /// One bundle of everything the body derives from the resolver +
    /// filter pipeline. Computed ONCE per input change via
    /// `.task(id: derivedKey)` and cached in `@State` — not once (or
    /// several times) per body pass.
    private struct DerivedState {
        let resolution: AssetResolution
        /// Human-readable hero name — the `AssetNameLookup` registry
        /// walk is part of the memo for the same reason the resolver
        /// is.
        let displayName: String
        /// Network rows after the visibility filter.
        let filteredNetworks: [AssetNetworkRow]
        /// Every wallet transaction involving this asset, pre-filter.
        let assetScopedTransactions: [TransactionRecord]
        /// Asset-scoped transactions AFTER the filter (direction,
        /// time range, networks, sort).
        let filteredTransactions: [TransactionRecord]
        /// Asset-scoped current balances — fed to the
        /// `BalanceHistoryReconstructor` so the chart's "current
        /// total" anchor reflects the asset, not the wallet.
        let assetCurrentBalances: [TokenBalanceRecord]
    }

    /// Cached derived snapshot. `nil` only before the first
    /// `.task(id:)` lands — the body's inline fallback covers that
    /// single first frame.
    @State private var derivedCache: DerivedState?

    /// Full input key for the memo: asset identity + display
    /// currency + every filter preference the pipeline reads + the
    /// active wallet's data fingerprint (so refresh writes and new
    /// transactions invalidate the cache).
    private var derivedKey: String {
        [
            identity.symbol,
            identity.nativeChain?.rawValue ?? "token",
            currencyCode,
            filterSortKeyRaw,
            filterDirectionRaw,
            filterSelectedNetworksJSON,
            filterTimeRangeRaw,
            String(filterHideZeroNetworks),
            WalletDataFingerprint.make(for: activeWallet)
        ].joined(separator: "|")
    }

    private func computeDerived() -> DerivedState {
        let inputs = filterInputs
        let heldRows = allHeldRows
        let resolution = AssetDetailResolver.resolve(
            identity: identity,
            heldRows: heldRows,
            fallbackCurrencyCode: currencyCode
        )
        let scoped = AssetDetailFilterApply.scope(transactions: allTransactions, to: identity)
        return DerivedState(
            resolution: resolution,
            displayName: assetDisplayName,
            filteredNetworks: AssetDetailFilterApply.apply(networks: resolution.networks, with: inputs),
            assetScopedTransactions: scoped,
            filteredTransactions: AssetDetailFilterApply.apply(transactions: scoped, with: inputs),
            assetCurrentBalances: currentBalances(from: heldRows)
        )
    }

    /// Human-readable display name for the hero. Native coins read
    /// the chain's display name ("Bitcoin", "Ethereum"); tokens look
    /// up the registry name ("USD Coin", "Tether USD") and fall back
    /// to the symbol itself when the registry doesn't have one.
    private var assetDisplayName: String {
        switch identity.kind {
        case .nativeCoin(let chain):
            return chain.displayName
        case .token:
            return AssetNameLookup.name(forTokenSymbol: identity.symbol)
                ?? identity.symbol
        }
    }

    /// Filter snapshot — read once per recompute, passed to the pure
    /// appliers.
    private var filterInputs: AssetDetailFilterInputs {
        AssetDetailFilterInputs(
            sortKey: AssetDetailFilterPreferences.SortKey(rawValue: filterSortKeyRaw)
                ?? AssetDetailFilterPreferences.defaultSortKey,
            direction: AssetDetailFilterPreferences.TxDirection(rawValue: filterDirectionRaw)
                ?? AssetDetailFilterPreferences.defaultDirection,
            selectedNetworks: AssetDetailFilterPreferences.decode(filterSelectedNetworksJSON),
            timeRange: AssetDetailFilterPreferences.TimeRange(rawValue: filterTimeRangeRaw)
                ?? AssetDetailFilterPreferences.defaultTimeRange,
            hideZeroNetworks: filterHideZeroNetworks
        )
    }

    /// `[symbol-uppercased: price]` map filtered to `fiat`. Drives
    /// the `BalanceHistoryChart`'s cashed-out fallback so a token
    /// the wallet held in the past but no longer holds gets a
    /// real spot price for the historical valuation. Reads the
    /// `cachedPrices` `@Query` which observes the same rows
    /// `CoinbasePriceService` writes through `PriceCacheRepository`.
    private func priceCacheBySymbol(for fiat: String) -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        for row in cachedPrices where row.fiat == fiat {
            out[row.symbol.uppercased()] = row.price
        }
        return out
    }

    /// `[symbol-uppercased: [yyyymmdd: close]]` map filtered to
    /// `fiat`. Drives the chart's **then-price valuation** — past
    /// holdings of a token render at its day's spot, not today's.
    /// Same shape as `WalletHomeView.priceHistoryBySymbol`.
    private func priceHistoryBySymbol(for fiat: String) -> [String: [Int: Decimal]] {
        var out: [String: [Int: Decimal]] = [:]
        for row in historicalPrices where row.fiat == fiat {
            out[row.symbol.uppercased(), default: [:]][row.dayKey] = row.price
        }
        return out
    }

    private func currentBalances(
        from heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)]
    ) -> [TokenBalanceRecord] {
        switch identity.kind {
        case .nativeCoin(let chain):
            return heldRows
                .filter { entry in
                    entry.chain == chain
                        && entry.balance.tokenContract == nil
                        && entry.balance.tokenSymbol == chain.ticker
                }
                .map { $0.balance }
        case .token:
            let target = identity.symbol.uppercased()
            return heldRows
                .filter { entry in
                    entry.balance.tokenSymbol.uppercased() == target
                        && entry.balance.tokenContract != nil
                        && !(entry.balance.tokenContract?.isEmpty ?? true)
                }
                .map { $0.balance }
        }
    }

    // MARK: - Wallet plumbing (mirrors WalletHomeView)

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    /// All non-zero balance rows on the active wallet. Same shape as
    /// `WalletHomeView.balances` but unfiltered by the dust threshold
    /// — the asset detail respects only its own filters.
    private var allHeldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
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

    /// All transactions across the active wallet's addresses. The
    /// asset-scoping happens via the filter applier, not here.
    private var allTransactions: [TransactionRecord] {
        guard let wallet = activeWallet else { return [] }
        return wallet.addresses.flatMap { $0.transactions }
    }

    /// Resolves the chain a `TransactionRecord` belongs to. Returns
    /// `nil` when the parent address record is missing or carries an
    /// unrecognized chain — callers must NOT route such a row
    /// anywhere (no silent `.ethereum` fallback; that showed users
    /// wrong-chain data).
    private func chainFor(_ tx: TransactionRecord) -> SupportedChain? {
        guard let raw = tx.address?.chainRaw,
              let chain = SupportedChain(rawValue: raw) else { return nil }
        return chain
    }

    /// Display-only chain proxy for activity rows whose parent
    /// address can't be resolved. Drives the row's `CoinMark` ONLY —
    /// never navigation. Prefers the asset's own identity chain, then
    /// its first resolved network.
    private func displayProxyChain(_ derived: DerivedState) -> SupportedChain {
        identity.nativeChain
            ?? derived.resolution.networks.first?.chain
            ?? .ethereum
    }

    /// Shared row label for both the navigable and the plain
    /// (unresolvable-chain) activity entries.
    private func activityRow(_ tx: TransactionRecord, chain: SupportedChain) -> ActivityRow {
        ActivityRow(
            chain: chain,
            direction: TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing,
            amount: Decimal(string: tx.amountRaw) ?? .zero,
            tokenSymbol: tx.tokenSymbol,
            counterparty: tx.counterparty,
            occurredAt: tx.occurredAt,
            status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed
        )
    }
}

// MARK: - AssetNetworkRowView

/// One row in the Networks section. Same layout DNA as `AssetRow` —
/// 44pt mark + 2-line center column + trailing amount/fiat — but the
/// mark is the CHAIN's logo (not the asset's), the title is the
/// network's display name, and the secondary is "X SYMBOL" so the
/// user reads "Ethereum / 0.5 USDC".
///
/// Tappable via the parent's `NavigationLink(value:)` — this view
/// renders the row label only.
private struct AssetNetworkRowView: View {
    let row: AssetNetworkRow
    let assetSymbol: String

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            networkMark
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: row.chain.displayName)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(secondaryLine)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: UniSpacing.s)
            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                fiatLabel
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var networkMark: some View {
        if let asset = row.chain.logoAssetName {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.dashed")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    /// "0.5 USDC" — the per-network balance. The chain's display
    /// name has already taken the top slot, so the bottom slot is
    /// pure asset quantity.
    private var secondaryLine: String {
        let amountText = WalletFormatting.native(row.amount, decimals: 6)
        return "\(amountText) \(assetSymbol)"
    }

    @ViewBuilder
    private var fiatLabel: some View {
        if let fiat = row.fiatValue, fiat > 0 {
            Text(WalletFormatting.fiat(fiat, currencyCode: row.fiatCurrencyCode))
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(UniColors.Text.primary)
                .monospacedDigit()
        } else if row.isHeld {
            Text("Price unavailable")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        } else {
            Text("Not held")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }
}
