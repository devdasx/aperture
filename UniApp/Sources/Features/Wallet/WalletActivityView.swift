import SwiftUI
import SwiftData

/// **"View all" destination** behind the wallet-home "Recent activity"
/// header's `View all` link. Lists EVERY transaction across EVERY
/// address of the active wallet — newest first — without the five-row
/// cap the home surfaces.
///
/// **Design intent (Rule #2 §D.1):** when the user wants their whole
/// history, give them the same rows they already recognize from the
/// home — the same `ActivityRow` — unbounded and in time order. No new
/// visual vocabulary; the screen is "the home's activity list, longer."
/// This mirrors `AssetActivityView` (the per-asset "View all") so the
/// two histories read as one family.
///
/// **Scope.** This is the wallet-wide counterpart to
/// `AssetActivityView`. That screen is asset-scoped — it carries an
/// `AssetIdentity`, resolves asset networks, and presents an
/// asset-coupled filter sheet. None of that generalizes to "all
/// assets" without rewriting the filter plumbing, so this view ships
/// the clean wallet-wide form: every transaction, sorted, no filter.
/// The core ask — "see ALL transactions" — is met in full. A future
/// turn can add a sort/direction filter here if the user asks for it.
///
/// **Layout (Rule #15 — pushed-screen contract).** Inherits the
/// wallet-home's `NavigationStack`. Title via `.navigationTitle` so
/// the system handles scroll compression natively. Native
/// `List(.insetGrouped)`; rows route to the shared
/// `WalletHomeDestination.transaction(_:)` detail.
///
/// **Wallet truth (matches `WalletHomeView`).** The active wallet is
/// resolved the same hardened store-truth way the home does — the
/// `@Query`-backed `allWallets` lags repository inserts/switches, so a
/// freshly-switched or freshly-imported wallet would otherwise show
/// the *previous* wallet's history for one merge window. Asking the
/// store directly (`modelContext.fetch`) closes that gap, so this
/// screen never shows the wrong wallet's transactions.
struct WalletActivityView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    /// Top-level transaction feed, newest-first at the STORE level (no
    /// per-render sort). The same hardened pattern `WalletHomeView` uses:
    /// filter this by the active wallet's address-id set in ONE in-memory
    /// pass (`addressId` is a stored column — no relationship faulting),
    /// instead of `wallet.addresses.flatMap { $0.transactions }` (which
    /// faults every address's transaction relationship) gated by the
    /// O(all-tx) `WalletDataFingerprint.make` key recomputed every body
    /// pass (2026-06-14 Activity-lag fix).
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse)
    private var allTransactionRecords: [TransactionRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    // Local-currency activity amounts (2026-06-18): spot prices feed
    // `priceMap` (symbol → unit price in `currencyCode`).
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @Query private var cachedPrices: [CachedPriceRecord]

    private var priceMap: [String: Decimal] {
        ActivityFiat.priceMap(cachedPrices, currency: currencyCode)
    }

    // MARK: - Filter & search preferences (Part 2, 2026-06-19)

    @AppStorage(WalletActivityFilterPreferences.sortKeyKey)
    private var sortKeyRaw: String = WalletActivityFilterPreferences.defaultSortKey.rawValue
    @AppStorage(WalletActivityFilterPreferences.directionKey)
    private var directionRaw: String = WalletActivityFilterPreferences.defaultDirection.rawValue
    @AppStorage(WalletActivityFilterPreferences.statusKey)
    private var statusRaw: String = WalletActivityFilterPreferences.defaultStatus.rawValue
    @AppStorage(WalletActivityFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON
    @AppStorage(WalletActivityFilterPreferences.selectedSymbolsKey)
    private var selectedSymbolsJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON
    @AppStorage(WalletActivityFilterPreferences.timeRangeKey)
    private var timeRangeRaw: String = WalletActivityFilterPreferences.defaultTimeRange.rawValue
    @AppStorage(WalletActivityFilterPreferences.customStartKey)
    private var customStart: Double = WalletActivityFilterPreferences.defaultCustomDate
    @AppStorage(WalletActivityFilterPreferences.customEndKey)
    private var customEnd: Double = WalletActivityFilterPreferences.defaultCustomDate
    @AppStorage(WalletActivityFilterPreferences.minFiatKey)
    private var minFiat: String = WalletActivityFilterPreferences.defaultAmount
    @AppStorage(WalletActivityFilterPreferences.maxFiatKey)
    private var maxFiat: String = WalletActivityFilterPreferences.defaultAmount

    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    @State private var isShowingFilter: Bool = false
    @State private var searchText: String = ""

    /// Memoized newest-first feed. Rebuilt only when the feed key
    /// changes (wallet switch or a tx count change) — not per body pass.
    @State private var sortedTransactions: [TransactionRecord] = []

    /// USD unit prices for the feed's symbols, used ONLY for the $0.01-USD
    /// dust gate (see `ActivityFiat.usdPriceMap`). Loaded async after each
    /// rebuild; until it arrives every row shows (we never hide what we
    /// can't yet measure in dollars). Mutating it re-renders, which
    /// re-applies `displayedTransactions`.
    @State private var usdPrices: [String: Decimal] = [:]

    /// Cheap rebuild key — O(1). Replaces the O(all-tx) data fingerprint.
    /// Wallet switch changes `activeWalletIdRaw`; a new/removed tx changes
    /// the @Query count. A status change (pending→confirmed, same count)
    /// doesn't re-key, but the rows read `tx.statusRaw` live off the
    /// shared SwiftData reference, so status still updates without a
    /// feed rebuild.
    private var feedKey: String {
        "\(activeWalletIdRaw)|\(allTransactionRecords.count)"
    }

    /// The honest base feed — the wallet's transactions with sub-$0.01-USD
    /// dust removed (2026-06-19 user direction). This is the "M" in the
    /// preview's "Showing N of M": dust is never part of what the user can
    /// see, so it isn't part of the total either. A leg with no known USD
    /// price is kept (honesty over a guessed hide).
    private var dustFreeTransactions: [TransactionRecord] {
        sortedTransactions.filter { tx in
            !ActivityFiat.isDust(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, usdMap: usdPrices)
        }
    }

    /// The rows actually shown — the dust-free base run through the user's
    /// filter + sort + search (Part 2). Fiat for amount-range filtering and
    /// value sorts is resolved in the active display currency via
    /// `priceMap`, matching the amounts the rows display.
    private var displayedTransactions: [TransactionRecord] {
        WalletActivityFilterApply.apply(
            transactions: dustFreeTransactions,
            with: filterInputs,
            fiatValue: { ActivityFiat.value(amountRaw: $0.amountRaw, symbol: $0.tokenSymbol, map: priceMap) }
        )
    }

    /// Decoded snapshot of the persisted filter preferences plus the
    /// transient search text — the single input to `WalletActivityFilterApply`.
    private var filterInputs: WalletActivityFilterInputs {
        let isCustom = timeRangeRaw == WalletActivityFilterPreferences.TimeRange.custom.rawValue
        return WalletActivityFilterInputs(
            sortKey: WalletActivityFilterPreferences.SortKey(rawValue: sortKeyRaw)
                ?? WalletActivityFilterPreferences.defaultSortKey,
            direction: WalletActivityFilterPreferences.TxDirection(rawValue: directionRaw)
                ?? WalletActivityFilterPreferences.defaultDirection,
            status: WalletActivityFilterPreferences.TxStatus(rawValue: statusRaw)
                ?? WalletActivityFilterPreferences.defaultStatus,
            selectedNetworks: WalletActivityFilterPreferences.decode(selectedNetworksJSON),
            selectedSymbols: WalletActivityFilterPreferences.decode(selectedSymbolsJSON),
            timeRange: WalletActivityFilterPreferences.TimeRange(rawValue: timeRangeRaw)
                ?? WalletActivityFilterPreferences.defaultTimeRange,
            customStart: (isCustom && customStart > 0) ? Date(timeIntervalSince1970: customStart) : nil,
            customEnd: (isCustom && customEnd > 0) ? Date(timeIntervalSince1970: customEnd) : nil,
            minFiat: Self.parseAmount(minFiat),
            maxFiat: Self.parseAmount(maxFiat),
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Parse a user-entered amount string to `Decimal`. Empty → nil.
    /// Accepts both `.` and `,` as the decimal separator so a decimal-pad
    /// entry in any locale parses.
    private static func parseAmount(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Decimal(string: trimmed) { return value }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Distinct chains present in the dust-free feed — the network
    /// multi-select's options (not "every chain Aperture supports").
    private var availableNetworks: [SupportedChain] {
        var seen = Set<String>()
        var result: [SupportedChain] = []
        for tx in dustFreeTransactions {
            guard let raw = tx.address?.chainRaw, !seen.contains(raw),
                  let chain = SupportedChain(rawValue: raw) else { continue }
            seen.insert(raw)
            result.append(chain)
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    /// Distinct token symbols present in the dust-free feed — the asset
    /// multi-select's options, in display casing, sorted.
    private var availableSymbols: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tx in dustFreeTransactions {
            let key = tx.tokenSymbol.uppercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(tx.tokenSymbol)
        }
        return result.sorted { $0.uppercased() < $1.uppercased() }
    }

    /// `true` when any filter, sort, or search is narrowing the list —
    /// drives the toolbar button's active dot.
    private var isFilterActive: Bool {
        WalletActivityFilterPreferences.isActive(
            sortKeyRaw: sortKeyRaw,
            directionRaw: directionRaw,
            statusRaw: statusRaw,
            selectedNetworksJSON: selectedNetworksJSON,
            selectedSymbolsJSON: selectedSymbolsJSON,
            timeRangeRaw: timeRangeRaw,
            minFiat: minFiat,
            maxFiat: maxFiat
        ) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if displayedTransactions.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(displayedTransactions, id: \.id) { tx in
                        if let chain = chainFor(tx) {
                            NavigationLink(value: WalletHomeDestination.transaction(tx.id)) {
                                activityRow(tx, chain: chain)
                            }
                        } else {
                            // The parent address record is missing or
                            // carries an unrecognized chain — render the
                            // row plain, with NO NavigationLink, so the
                            // user is never routed against wrong-chain
                            // data. (Same guard `AssetActivityView`
                            // uses — a silent `.ethereum` fallback once
                            // showed users the wrong chain's detail.)
                            activityRow(tx, chain: .ethereum)
                        }
                    }
                } header: {
                    Text(headerLabel(visible: displayedTransactions.count, total: dustFreeTransactions.count))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text("Search address, asset, or hash")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingFilter = true
                } label: {
                    Image(systemName: isFilterActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease")
                        .accessibilityLabel(Text("Filter and sort"))
                }
                .tint(UniColors.Icon.accent)
            }
        }
        .sheet(isPresented: $isShowingFilter) {
            WalletActivityFilterSheet(
                availableNetworks: availableNetworks,
                availableSymbols: availableSymbols,
                currencyCode: currencyCode,
                totalTransactions: dustFreeTransactions.count,
                visibleTransactions: displayedTransactions.count
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .task(id: feedKey) {
            rebuild()
            await loadDustPrices()
        }
    }

    // MARK: - Empty state

    /// Empty state — two registers. When the dust-free feed itself is
    /// empty, the wallet genuinely has no activity. When it has activity
    /// but the user's filter/search excludes all of it, say so and point
    /// them at the filter, mirroring `AssetActivityView`.
    private var emptyState: some View {
        let hasActivity = !dustFreeTransactions.isEmpty
        return UniEmptyState(
            title: hasActivity ? "No activity matches the filter." : "No activity yet.",
            detail: hasActivity
                ? "Adjust the filter or search to see more of your activity."
                : "Transactions appear here as they confirm on-chain.",
            mark: .icon(systemName: "list.bullet.rectangle.portrait")
        )
    }

    // MARK: - Header

    /// "All N transactions" when nothing is narrowing the list, else
    /// the honest "Showing N of M transactions".
    private func headerLabel(visible: Int, total: Int) -> String {
        if visible == total {
            return String(
                format: String(localized: "All %lld transactions"),
                Int64(total)
            )
        }
        return String(
            format: String(localized: "Showing %lld of %lld transactions"),
            Int64(visible),
            Int64(total)
        )
    }

    // MARK: - Feed

    /// Resolve + flatten + sort once. Newest-first across every
    /// address of the active wallet, reflecting the full history the DB
    /// holds (the adapters paginate to 1,000 txs/chain).
    private func rebuild() {
        guard let wallet = activeWallet else {
            sortedTransactions = []
            return
        }
        let ids = Set(wallet.addresses.map { $0.id })
        guard !ids.isEmpty else {
            sortedTransactions = []
            return
        }
        // One in-memory pass over the store-sorted feed (newest-first
        // already), filtering on the stored `addressId` column — no
        // relationship faulting, no per-render sort.
        sortedTransactions = allTransactionRecords.filter { tx in
            guard let aid = tx.addressId else { return false }
            return ids.contains(aid)
        }
    }

    /// Resolve USD unit prices for the feed's distinct symbols so the
    /// $0.01-USD dust gate can run. Cheap after the first call (the engine
    /// caches), and cancellation-safe — a wallet switch re-keys the task,
    /// cancelling this before it writes a stale wallet's prices.
    private func loadDustPrices() async {
        let symbols = sortedTransactions.map(\.tokenSymbol)
        let map = await ActivityFiat.usdPriceMap(symbols: symbols)
        guard !Task.isCancelled else { return }
        usdPrices = map
    }

    // MARK: - Wallet plumbing (store-truth, matches WalletHomeView)

    /// Active wallet resolved with the same hardened precedence the
    /// wallet-home uses: stored id → `@Query` match → direct store
    /// fetch (covers the `@Query` merge lag) → first existing wallet.
    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw) {
            if let match = allWallets.first(where: { $0.id == uuid }) {
                return match
            }
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == uuid }
            )
            descriptor.fetchLimit = 1
            if let stored = try? modelContext.fetch(descriptor).first {
                return stored
            }
        }
        return allWallets.first(where: { walletExists(id: $0.id) })
    }

    private func walletExists(id: UUID) -> Bool {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Resolves the chain a `TransactionRecord` belongs to. Returns
    /// `nil` when the parent address record is missing or carries an
    /// unrecognized chain — callers must NOT route such a row anywhere
    /// (no silent `.ethereum` fallback for navigation; that showed
    /// users wrong-chain data).
    private func chainFor(_ tx: TransactionRecord) -> SupportedChain? {
        guard let raw = tx.address?.chainRaw,
              let chain = SupportedChain(rawValue: raw) else { return nil }
        return chain
    }

    /// Shared row label for both the navigable and the plain
    /// (unresolvable-chain) activity entries — the same `ActivityRow`
    /// the wallet-home and `AssetActivityView` use.
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
            fiatCurrencyCode: currencyCode
        )
    }
}
