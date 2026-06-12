import SwiftUI
import SwiftData

/// **Per-(asset, network) detail.** Pushed when the user taps a row
/// in `AssetDetailView`'s Networks section.
///
/// **Design intent (Rule #2 §D.1):** show the user what they hold of
/// this asset, on this one network — the balance, the fiat, the
/// receiving address, and every transaction that has moved it on
/// THIS chain.
///
/// **Layout (Rule #15 — pushed-screen contract).** Inherits the
/// wallet-home's `NavigationStack`. Title via `.navigationTitle`. The
/// filter button reopens the same `AssetDetailFilterSheet` but the
/// network filter is auto-intersected to this chain only (the
/// `filterInputs.intersected(network:)` helper on the inputs struct).
struct AssetNetworkDetailView: View {
    let identity: AssetIdentity
    let chain: SupportedChain

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    // Filter — same global preferences. The network filter is
    // overridden to this view's chain only, via `intersected`.
    @AppStorage(AssetDetailFilterPreferences.sortKeyKey)
    private var filterSortKeyRaw: String = AssetDetailFilterPreferences.defaultSortKey.rawValue
    @AppStorage(AssetDetailFilterPreferences.directionKey)
    private var filterDirectionRaw: String = AssetDetailFilterPreferences.defaultDirection.rawValue
    @AppStorage(AssetDetailFilterPreferences.timeRangeKey)
    private var filterTimeRangeRaw: String = AssetDetailFilterPreferences.defaultTimeRange.rawValue

    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    @State private var isShowingFilter: Bool = false

    var body: some View {
        List {
            headerSection
            balanceSection
            addressSection
            activitySection
            footerSection
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
            // The same filter sheet — but the network multi-select is
            // pre-restricted via `availableNetworks: [thisRow]` so the
            // user can't accidentally widen back to the asset-wide
            // view. The other filters (sort, direction, time range)
            // remain global.
            AssetDetailFilterSheet(
                identity: identity,
                availableNetworks: networkRow.map { [$0] } ?? [],
                totalTransactions: assetScopedTransactions.count,
                visibleTransactions: filteredTransactions.count
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Header

    private var navigationTitleText: LocalizedStringKey {
        "\(identity.symbol) on \(chain.displayName)"
    }

    @ViewBuilder
    private var headerSection: some View {
        Section {
            HStack(spacing: UniSpacing.s) {
                CoinMark(
                    chain: chain,
                    tokenSymbol: identity.symbol,
                    contract: networkRow?.contract
                )
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: assetDisplayName)
                        .font(UniTypography.bodyEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(verbatim: chain.displayName)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, UniSpacing.xxs)
        }
    }

    private var assetDisplayName: String {
        switch identity.kind {
        case .nativeCoin(let chain):
            return chain.displayName
        case .token:
            return AssetNameLookup.name(forTokenSymbol: identity.symbol)
                ?? identity.symbol
        }
    }

    // MARK: - Balance section

    @ViewBuilder
    private var balanceSection: some View {
        Section {
            VStack(spacing: 6) {
                if let fiat = networkRow?.fiatValue, fiat > 0 {
                    Text(WalletFormatting.fiat(fiat, currencyCode: networkRow?.fiatCurrencyCode ?? currencyCode))
                        .font(UniTypography.heroBalance)
                        .foregroundStyle(UniColors.Text.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .monospacedDigit()
                } else if let row = networkRow, row.isHeld {
                    Text("Price unavailable")
                        .font(UniTypography.title3)
                        .foregroundStyle(UniColors.Text.tertiary)
                } else {
                    Text("Not held on \(chain.displayName)")
                        .font(UniTypography.title3)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
                Text(rollupText)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.s)
        } header: {
            Text("Balance")
        }
    }

    private var rollupText: String {
        let amount = networkRow?.amount ?? .zero
        let amountText = WalletFormatting.native(amount, decimals: 6)
        return "\(amountText) \(identity.symbol)"
    }

    // MARK: - Address section

    @ViewBuilder
    private var addressSection: some View {
        if let address = walletAddress {
            Section {
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text("Your address")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                    Text(verbatim: address.address)
                        .font(UniTypography.monoBody)
                        .foregroundStyle(UniColors.Text.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, UniSpacing.xxs)
            }
        }
    }

    // MARK: - Activity section

    @ViewBuilder
    private var activitySection: some View {
        let rows = filteredTransactions
        Section {
            if rows.isEmpty {
                UniEmptyState(
                    title: assetScopedTransactions.isEmpty
                        ? "No activity on \(chain.displayName)."
                        : "No activity matches the filter.",
                    detail: assetScopedTransactions.isEmpty
                        ? "Transactions involving \(identity.symbol) on \(chain.displayName) appear here as they confirm on-chain."
                        : "Adjust the filter sheet to see more.",
                    mark: .icon(systemName: "list.bullet.rectangle.portrait")
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } else {
                ForEach(rows, id: \.id) { tx in
                    NavigationLink(value: WalletHomeDestination.transaction(tx.id)) {
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
            }
        } header: {
            Text("Activity")
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

    // MARK: - Derived state

    /// The `AssetNetworkRow` for THIS view's chain, plucked from the
    /// resolver's output. Nil only when the asset isn't supported on
    /// the chain — which the wallet home shouldn't route to, but the
    /// view degrades gracefully when it does.
    private var networkRow: AssetNetworkRow? {
        resolution.networks.first { $0.chain == chain }
    }

    private var resolution: AssetResolution {
        AssetDetailResolver.resolve(
            identity: identity,
            heldRows: allHeldRows,
            fallbackCurrencyCode: currencyCode
        )
    }

    /// Network-scoped filter inputs — the global filter intersected
    /// with this view's chain so the network multi-select is forced
    /// to a single value.
    private var filterInputs: AssetDetailFilterInputs {
        AssetDetailFilterInputs(
            sortKey: AssetDetailFilterPreferences.SortKey(rawValue: filterSortKeyRaw)
                ?? AssetDetailFilterPreferences.defaultSortKey,
            direction: AssetDetailFilterPreferences.TxDirection(rawValue: filterDirectionRaw)
                ?? AssetDetailFilterPreferences.defaultDirection,
            selectedNetworks: [chain.rawValue],
            timeRange: AssetDetailFilterPreferences.TimeRange(rawValue: filterTimeRangeRaw)
                ?? AssetDetailFilterPreferences.defaultTimeRange,
            hideZeroNetworks: false
        )
    }

    private var assetScopedTransactions: [TransactionRecord] {
        AssetDetailFilterApply.scope(transactions: allTransactions, to: identity)
    }

    private var filteredTransactions: [TransactionRecord] {
        AssetDetailFilterApply.apply(
            transactions: assetScopedTransactions,
            with: filterInputs
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

    /// First address on the active wallet whose `chainRaw` matches
    /// this view's chain. The "receiving address" the user would
    /// share — same address `ReceiveView` would show on this chain.
    private var walletAddress: WalletAddressRecord? {
        activeWallet?.addresses.first { $0.chainRaw == chain.rawValue }
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
        return wallet.addresses.flatMap { $0.transactions }
    }
}
