import SwiftUI
import SwiftData

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

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    /// Top-level transaction feed (store-sorted newest-first). Filtered
    /// in-memory by the active wallet's address ids — no relationship
    /// faulting, and a cheap `.count` replaces the O(all-tx)
    /// `WalletDataFingerprint` in `derivedKey` (2026-06-14 Activity-lag fix).
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse)
    private var allTransactionRecords: [TransactionRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

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

    var body: some View {
        // Memoized derived snapshot (resolver-per-body fix): resolve
        // + scope + filter run ONCE per input change via
        // `.task(id:)`, and the filtered list is evaluated once —
        // not separately for the list and the filter sheet.
        let derived = derivedCache ?? computeDerived()
        List {
            let rows = derived.filteredTransactions
            if rows.isEmpty {
                Section {
                    UniEmptyState(
                        title: "No activity matches the filter.",
                        detail: "Adjust the filter sheet to see more activity for this asset.",
                        mark: .icon(systemName: "list.bullet.rectangle.portrait")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    ForEach(rows, id: \.id) { tx in
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
                    Text(headerLabel(
                        count: rows.count,
                        total: derived.assetScopedTransactions.count
                    ))
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
            String(allTransactionRecords.count)
        ].joined(separator: "|")
    }

    private func computeDerived() -> DerivedState {
        let inputs = filterInputs
        let resolution = AssetDetailResolver.resolve(
            identity: identity,
            heldRows: allHeldRows,
            fallbackCurrencyCode: currencyCode
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
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
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
            status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed
        )
    }
}
