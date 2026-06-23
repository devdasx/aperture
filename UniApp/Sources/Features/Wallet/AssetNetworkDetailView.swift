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
    // Local-currency activity amounts (2026-06-18).
    @Query private var cachedPrices: [CachedPriceRecord]
    /// On-disk historical closes — drives the chart's then-price valuation
    /// (same source the symbol-level screen + wallet home use).
    @Query private var historicalPrices: [HistoricalPriceRecord]

    private var priceMap: [String: Decimal] {
        ActivityFiat.priceMap(cachedPrices, currency: currencyCode)
    }

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

    // Action flows — the token + network are ALREADY chosen on this screen,
    // so each opens pre-filled (2026-06-18). Send/Receive seed the flow's own
    // NavigationPath.
    @State private var isShowingSend = false
    @State private var isShowingReceive = false
    @State private var sendPath = NavigationPath()
    @State private var receivePath = NavigationPath()

    /// Chart scrub → hero override, same as the symbol-level screen: while the
    /// user drags the chart, the hero shows the touched point's value.
    @State private var scrubModel = ChartScrubModel()

    /// USD unit prices for this (asset, network)'s symbol, used ONLY for
    /// the $0.01-USD dust gate (2026-06-19 user direction). Loaded async
    /// on appear; until it arrives every row shows.
    @State private var usdPrices: [String: Decimal] = [:]

    var body: some View {
        List {
            heroCardSection
            actionsSection
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
                visibleTransactions: visibleRows.count
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        // Send — pre-seeded to the recipient step for THIS token + network.
        .sheet(isPresented: $isShowingSend, onDismiss: { sendPath = NavigationPath() }) {
            SendView(navigationPath: $sendPath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        // Receive — pre-seeded to the QR/address screen for THIS network.
        .sheet(isPresented: $isShowingReceive, onDismiss: { receivePath = NavigationPath() }) {
            ReceiveView(navigationPath: $receivePath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        .task(id: identity.symbol) {
            // USD prices for the $0.01-USD dust gate — engine-cached,
            // off-body, re-keyed if the asset identity changes (2026-06-19).
            await loadDustPrices()
        }
    }

    // MARK: - Actions (token + network already chosen → pre-filled flows)

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            WalletActionRegion(
                canSend: activeWallet?.kind != .watchOnly,
                onSend: { presentSend() },
                onReceive: { presentReceive() }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: UniSpacing.s, leading: 0, bottom: UniSpacing.s, trailing: 0))
        }
    }

    /// Token symbol to carry into Send/Receive — `nil` for a native coin
    /// (the chain IS the asset), the symbol for a token.
    private var sendTokenSymbol: String? {
        identity.isNativeCoin ? nil : identity.symbol
    }

    private func presentSend() {
        guard let address = walletAddress?.address else { return }
        var path = NavigationPath()
        path.append(SendDestination.recipient(
            chain: chain,
            tokenSymbol: sendTokenSymbol,
            fromAddress: address
        ))
        sendPath = path
        isShowingSend = true
    }

    private func presentReceive() {
        guard let address = walletAddress?.address else { return }
        var path = NavigationPath()
        path.append(ReceiveDestination.qr(
            chain: chain,
            tokenSymbol: sendTokenSymbol,
            address: address
        ))
        receivePath = path
        isShowingReceive = true
    }

    // MARK: - Header

    private var navigationTitleText: LocalizedStringKey {
        "\(identity.symbol) on \(chain.displayName)"
    }

    /// Flagship hero card — identity + scrub-aware balance + the
    /// network-scoped balance-history chart, matching the symbol-level
    /// `AssetDetailView.heroCardSection` layout (one inset-grouped card).
    /// Everything here is scoped to THIS network: the balance, the chart's
    /// transactions, and the held balance it reconstructs from.
    @ViewBuilder
    private var heroCardSection: some View {
        Section {
            // Row 1 — identity (80pt mark + name + ticker + this network).
            HStack(spacing: UniSpacing.m) {
                CoinMark(
                    chain: chain,
                    tokenSymbol: identity.symbol,
                    contract: networkRow?.contract
                )
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: assetDisplayName)
                        .font(UniTypography.title2)
                        .foregroundStyle(UniColors.Text.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(verbatim: identity.symbol)
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                    Text(verbatim: chain.displayName)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, UniSpacing.xxs)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 24, leading: UniSpacing.m, bottom: 0, trailing: UniSpacing.m))

            // Row 2 — hero fiat (scrub-aware) + native rollup.
            VStack(spacing: 6) {
                balanceHeroLabel
                Text(rollupText)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 12, leading: UniSpacing.m, bottom: 0, trailing: UniSpacing.m))

            // Row 3 — the NETWORK-scoped balance history chart (+ period pills).
            BalanceHistoryChart(
                transactions: assetScopedTransactions,
                currentBalances: networkBalances,
                ownAddresses: Set(walletAddress.map { [$0.address.lowercased()] } ?? []),
                priceCache: priceCacheBySymbol(for: currencyCode),
                priceHistory: priceHistoryBySymbol(for: currencyCode),
                currencyCode: currencyCode,
                scrubModel: scrubModel
            )
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: UniSpacing.m, bottom: 24, trailing: UniSpacing.m))
        }
    }

    /// Hero fiat label — shows the scrubbed point's value while dragging the
    /// chart, otherwise this network's balance (honest fallbacks: "Price
    /// unavailable" for a held-but-unpriced row, "Not held on …" otherwise).
    @ViewBuilder
    private var balanceHeroLabel: some View {
        if let scrubbed = scrubModel.fiat {
            Text(WalletFormatting.fiat(scrubbed, currencyCode: currencyCode))
                .font(UniTypography.heroBalance)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()
                .contentTransition(.numericText())
                .environment(\.layoutDirection, .leftToRight)
        } else if let fiat = networkRow?.fiatValue, fiat > 0 {
            Text(WalletFormatting.fiat(fiat, currencyCode: networkRow?.fiatCurrencyCode ?? currencyCode))
                .font(UniTypography.heroBalance)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
        } else if let row = networkRow, row.isHeld {
            // Held on this network but the value rounds to / is zero →
            // "US$0.00", never "Price unavailable" (user direction 2026-06-18).
            Text(WalletFormatting.fiat(row.fiatValue ?? 0, currencyCode: row.fiatCurrencyCode))
                .font(UniTypography.heroBalance)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
        } else {
            Text("Not held on \(chain.displayName)")
                .font(UniTypography.title3)
                .foregroundStyle(UniColors.Text.tertiary)
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

    // MARK: - Chart data (network-scoped)

    /// The held balance row(s) for THIS token on THIS network — the chart's
    /// `currentBalances`. Native coins match the chain's ticker with no
    /// contract; tokens match the symbol with a non-nil contract.
    private var networkBalances: [TokenBalanceRecord] {
        guard let balances = walletAddress?.balances else { return [] }
        if identity.isNativeCoin {
            return balances.filter {
                $0.tokenContract == nil
                    && $0.tokenSymbol.caseInsensitiveCompare(identity.symbol) == .orderedSame
            }
        }
        return balances.filter {
            $0.tokenContract != nil
                && $0.tokenSymbol.caseInsensitiveCompare(identity.symbol) == .orderedSame
        }
    }

    /// `[symbol-uppercased: price]` for `fiat` — the chart's cashed-out
    /// fallback. Same shape as the symbol-level screen.
    private func priceCacheBySymbol(for fiat: String) -> [String: Decimal] {
        var out: [String: Decimal] = [:]
        for row in cachedPrices where row.fiat == fiat {
            out[row.symbol.uppercased()] = row.price
        }
        return out
    }

    /// `[symbol-uppercased: [yyyymmdd: close]]` for `fiat` — then-price
    /// valuation for the chart.
    private func priceHistoryBySymbol(for fiat: String) -> [String: [Int: Decimal]] {
        var out: [String: [Int: Decimal]] = [:]
        for row in historicalPrices where row.fiat == fiat {
            out[row.symbol.uppercased(), default: [:]][row.dayKey] = row.price
        }
        return out
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
        let rows = visibleRows
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
                            status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed,
                            kind: tx.kind,
                            fiatValue: ActivityFiat.value(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, map: priceMap),
                            fiatCurrencyCode: currencyCode,
                            tokenContract: tx.tokenContract,
                            txHash: tx.txHash
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

    /// `filteredTransactions` with sub-$0.01-USD dust removed (2026-06-19
    /// user direction). The single source for the activity list and the
    /// filter sheet's "visible" tally, so they agree.
    private var visibleRows: [TransactionRecord] {
        filteredTransactions.filter { tx in
            !ActivityFiat.isDust(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, usdMap: usdPrices)
        }
    }

    /// Resolve USD unit prices for this asset's symbol so the $0.01-USD
    /// dust gate can run. Engine-cached and cancellation-safe.
    private func loadDustPrices() async {
        let map = await ActivityFiat.usdPriceMap(symbols: assetScopedTransactions.map(\.tokenSymbol))
        guard !Task.isCancelled else { return }
        usdPrices = map
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
