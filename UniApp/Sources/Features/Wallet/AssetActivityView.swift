import SwiftUI

/// **"View all" destination** behind `AssetDetailView`'s activity
/// section's `View all` row. Lists every transaction for the asset
/// — same filter applied — without the 50-row cap.
///
/// **Design intent (Rule #2 §D.1):** when the user wants the full
/// history of one asset, give them the same list, longer.
///
/// **Layout (Rule #15 — pushed-screen contract).** Inherits the
/// wallet-home's `NavigationStack`. Title via `.navigationTitle` so
/// the system handles scroll compression. The filter button lives in
/// the toolbar — taps re-present the same `AssetDetailFilterSheet`
/// the parent uses, so the user can re-tune the filter without
/// backing out.
struct AssetActivityView: View {
    let identity: AssetIdentity

    @StateObject private var databaseSnapshot = DatabaseSnapshotObservation()
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    private var allWallets: [WalletRecord] {
        databaseSnapshot.wallets
    }

    private var allTransactionRecords: [TransactionRecord] {
        databaseSnapshot.transactions.sorted { $0.occurredAt > $1.occurredAt }
    }

    private var cachedPrices: [CachedPriceRecord] {
        databaseSnapshot.cachedPrices
    }

    private var customTokenRecords: [CustomTokenRecord] {
        databaseSnapshot.customTokenRecords
    }

    private var priceMap: [String: Decimal] {
        ActivityFiat.priceMap(cachedPrices, currency: currencyCode)
    }

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

    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    @State private var isShowingFilter: Bool = false

    /// USD unit prices for the asset's symbols, used ONLY for the $0.01-USD
    /// dust gate (2026-06-19 user direction). Loaded async after each
    /// `computeDerived()`; until it arrives every row shows.
    @State private var usdPrices: [String: Decimal] = [:]

    var body: some View {
        // Memoized derived snapshot (resolver-per-body fix): resolve
        // + scope + filter run ONCE per input change via
        // `.task(id:)`, and the filtered list is evaluated once —
        // not separately for the list and the filter sheet.
        let derived = derivedCache ?? computeDerived()
        // Sub-$0.01-USD dust removed on top of the asset filter — a
        // cheap render-time pass over the already-filtered set, so the
        // list, header, and filter-sheet count all agree (2026-06-19).
        let rows = derived.filteredTransactions.filter { tx in
            !ActivityFiat.isDust(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, usdMap: usdPrices)
        }
        let sections = ActivityDateGrouper.sections(for: rows, date: \.occurredAt)
        List {
            if rows.isEmpty {
                Section {
                    UniListEmptyState(
                        title: "No activity matches the filter.",
                        detail: "Adjust the filter sheet to see more activity for this asset.",
                        mark: .icon(systemName: "list.bullet.rectangle.portrait"),
                        minHeight: 320
                    )
                }
            } else {
                Section {
                    Text(headerLabel(
                        count: rows.count,
                        total: derived.assetScopedTransactions.count
                    ))
                    .font(UniTypography.footnote.weight(.semibold))
                    .foregroundStyle(UniColors.Text.secondary)
                    .listRowBackground(Color.clear)
                }
                ForEach(sections) { daySection in
                    Section {
                        ForEach(daySection.items, id: \.id) { tx in
                            if let chain = chainFor(tx) {
                                NavigationLink(value: WalletHomeDestination.transaction(tx.id)) {
                                    activityRow(tx, chain: chain)
                                }
                            } else {
                                // The parent address record is missing or
                                // carries an unrecognized chain — render
                                // the row plain, with NO NavigationLink,
                                // so the user is never routed against
                                // wrong-chain data. The mark chain is a
                                // display-only proxy from the asset's own
                                // identity.
                                activityRow(tx, chain: displayProxyChain(derived))
                            }
                        }
                    } header: {
                        Text(ActivityDateGrouper.title(for: daySection.day))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            AssetDetailFilterSheet(
                identity: identity,
                availableNetworks: derived.resolution.networks,
                totalTransactions: derived.assetScopedTransactions.count,
                visibleTransactions: rows.count
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .task(id: derivedKey) {
            let computed = computeDerived()
            derivedCache = computed
            await loadDustPrices(symbols: computed.assetScopedTransactions.map(\.tokenSymbol))
        }
    }

    /// Resolve USD unit prices for the asset's symbols so the $0.01-USD
    /// dust gate can run. Cheap after the first call (engine-cached) and
    /// cancellation-safe — a re-key cancels this before a stale write.
    private func loadDustPrices(symbols: [String]) async {
        let map = await ActivityFiat.usdPriceMap(symbols: symbols)
        guard !Task.isCancelled else { return }
        usdPrices = map
    }

    // MARK: - Title

    private var navigationTitleText: LocalizedStringKey {
        switch identity.kind {
        case .nativeCoin(let chain):
            return "\(chain.ticker) activity"
        case .token:
            return "\(identity.symbol) activity"
        }
    }

    private func headerLabel(count: Int, total: Int) -> String {
        if count == total {
            return String(
                format: String(localized: "All %lld transactions"),
                Int64(total)
            )
        }
        return String(
            format: String(localized: "Showing %lld of %lld"),
            Int64(count),
            Int64(total)
        )
    }

    // MARK: - Derived state (memoized)

    /// Resolver + filter output, computed ONCE per input change via
    /// `.task(id: derivedKey)` — not per body pass.
    private struct DerivedState {
        let resolution: AssetResolution
        let assetScopedTransactions: [TransactionRecord]
        let filteredTransactions: [TransactionRecord]
    }

    /// Cached derived snapshot. `nil` only before the first
    /// `.task(id:)` lands — the body's inline fallback covers that
    /// single first frame.
    @State private var derivedCache: DerivedState?

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
            // Cheap data-change signal — O(1) — replacing the O(all-tx)
            // WalletDataFingerprint.make that ran on every body pass.
            activeWalletIdRaw,
            String(allTransactionRecords.count),
            String(customTokenRecords.count)
        ].joined(separator: "|")
    }

    /// User-added custom tokens as snapshots (known-chain only) — fed to
    /// the resolver so this asset's network filter lists every network
    /// the user added it on (2026-06-19).
    private var customTokenSnapshots: [CustomTokenSnapshot] {
        customTokenRecords
            .filter { $0.hasKnownChain }
            .map { CustomTokenSnapshot(from: $0) }
    }

    private func computeDerived() -> DerivedState {
        let inputs = filterInputs
        let resolution = AssetDetailResolver.resolve(
            identity: identity,
            heldRows: allHeldRows,
            fallbackCurrencyCode: currencyCode,
            customTokens: customTokenSnapshots
        )
        let scoped = AssetDetailFilterApply.scope(transactions: allTransactions, to: identity)
        return DerivedState(
            resolution: resolution,
            assetScopedTransactions: scoped,
            filteredTransactions: AssetDetailFilterApply.apply(transactions: scoped, with: inputs)
        )
    }

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

    // MARK: - Wallet plumbing

    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(rawID: activeWalletIdRaw, wallets: allWallets)
    }

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

    private var allTransactions: [TransactionRecord] {
        guard let wallet = activeWallet else { return [] }
        let ids = Set(wallet.addresses.map { $0.id })
        guard !ids.isEmpty else { return [] }
        // In-memory filter on the stored `addressId` column (no
        // relationship faulting). Only read inside `computeDerived()`,
        // which runs on a `derivedKey` change — not per body pass.
        return allTransactionRecords.filter { tx in
            guard let aid = tx.addressId else { return false }
            return ids.contains(aid)
        }
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

    /// Display-only chain proxy for rows whose parent address can't
    /// be resolved. Drives the row's `CoinMark` ONLY — never
    /// navigation.
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
            status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed,
            kind: tx.kind,
            fiatValue: ActivityFiat.value(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, map: priceMap),
            fiatCurrencyCode: currencyCode,
            tokenContract: tx.tokenContract,
            txHash: tx.txHash
        )
    }
}
