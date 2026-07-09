import SwiftUI

/// Receive flow for callers that already know the asset.
///
/// This view intentionally starts at the network step. It avoids the
/// asset-first Receive sheet's prefill task, which otherwise renders the
/// token list for a frame and then pushes the network picker.
struct ReceiveNetworkFirstView: View {
    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @StateObject private var assetCatalogObservation = AssetCatalogObservation()
    @StateObject private var activeBalancesObservation = ActiveWalletBalancesObservation()
    @StateObject private var activeTransactionsObservation = ActiveWalletTransactionsObservation()
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    @Binding var navigationPath: NavigationPath

    let assetPrefill: ReceiveView.AssetPrefill
    var preferredChains: [SupportedChain] = []

    @State private var holdings: AssetPickerHoldings = .empty
    @State private var searchText: String = ""
    @State private var missingAddressChain: SupportedChain?
    @State private var isShowingMissingAddressAlert: Bool = false

    private var currencyCode: String {
        AppPreferenceStore.shared.string(CurrencyPreference.storageKey, default: CurrencyPreference.defaultCode)
    }

    private var allWallets: [WalletRecord] {
        walletRecordsObservation.wallets
    }

    private var customTokenRecords: [CustomTokenRecord] {
        assetCatalogObservation.customTokenRecords.sorted {
            $0.symbol.localizedStandardCompare($1.symbol) == .orderedAscending
        }
    }

    private var assetRecords: [AssetRecord] {
        assetCatalogObservation.assetRecords
    }

    private var holdingsKey: String {
        guard let wallet = activeWallet else { return "none" }
        return [
            wallet.id.uuidString,
            activeBalancesObservation.revision,
            activeTransactionsObservation.revision
        ].joined(separator: "|")
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if filteredChains.isEmpty {
                    emptySection
                } else {
                    networkSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .searchable(text: $searchText, prompt: Text("Search"))
            .navigationTitle(Text("Choose network for \(assetPrefill.symbol)"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ReceiveDestination.self) { destination in
                switch destination {
                case let .networkPicker(asset):
                    ReceiveNetworkPickerView(
                        token: asset,
                        holdings: holdings,
                        currencyCode: currencyCode,
                        onSelectNetwork: { chain in
                            let symbol: String? = {
                                if case let .token(symbol, _, _) = asset { return symbol }
                                return nil
                            }()
                            openNetwork(chain, tokenSymbol: symbol)
                        }
                    )
                case let .qr(chain, tokenSymbol, address):
                    ReceiveQRDetailView(
                        chain: chain,
                        tokenSymbol: tokenSymbol,
                        address: address
                    )
                case .customTokens:
                    CustomTokensListView(initialChainForAdd: firstSupportedCustomTokenChain)
                }
            }
        }
        .onChange(of: activeWalletIdRaw) { _, _ in
            navigationPath = NavigationPath()
        }
        .task(id: activeWalletHealKey) {
            healActiveWalletIdIfNeeded()
        }
        .task(id: activeWalletScopeKey) {
            syncObservationScopes()
        }
        .task(id: holdingsKey) {
            holdings = AssetPickerHoldings(
                wallet: activeWallet,
                balances: activeBalancesObservation.balances,
                transactions: activeTransactionsObservation.transactions
            )
        }
        .alert(
            Text("No address for this network"),
            isPresented: $isShowingMissingAddressAlert,
            presenting: missingAddressChain
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { chain in
            Text("This wallet has no \(chain.displayName) address yet, so there is nothing to receive to on this network. Aperture may still be deriving your accounts; try again in a moment.")
        }
    }

    // MARK: - Sections

    private var networkSection: some View {
        Section {
            ForEach(filteredChains, id: \.self) { chain in
                Button {
                    openNetwork(chain, tokenSymbol: tokenSymbol)
                } label: {
                    AssetPickerNetworkRow(
                        chain: chain,
                        subtitle: "Receive on this network",
                        totals: totals(for: chain),
                        currencyCode: currencyCode
                    )
                }
                .buttonStyle(.uniListRow)
                .listRowBackground(UniColors.List.rowBackground)
                .accessibilityLabel(Text(verbatim: chain.displayName))
                .accessibilityHint(Text("Receive \(assetPrefill.symbol) on this network"))
            }
        } footer: {
            UniFootnote(
                text: "Make sure the sender uses the same network you pick. Sending across networks may result in permanent loss.",
                color: UniColors.Text.tertiary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, UniSpacing.xs)
        }
    }

    private var emptySection: some View {
        Section {
            UniListEmptyState(
                title: "No networks available.",
                detail: receiveNetworkEmptyDetail,
                mark: .icon(systemName: "network.slash"),
                minHeight: 300
            )
        }
    }

    private var receiveNetworkEmptyDetail: LocalizedStringKey {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "Try a different network name or ticker."
        }
        return "This wallet does not have a receive address for this asset yet."
    }

    // MARK: - Derived

    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(rawID: activeWalletIdRaw, wallets: allWallets)
    }

    private var activeWalletHealKey: String {
        "\(activeWalletIdRaw)|\(allWallets.count)"
    }

    private var activeWalletScopeKey: String {
        "\(activeWalletIdRaw)|\(walletRecordsObservation.revision)"
    }

    private func syncObservationScopes() {
        let scopedWalletId = activeWallet?.id ?? UUID(uuidString: activeWalletIdRaw)
        activeBalancesObservation.setWalletId(scopedWalletId)
        activeTransactionsObservation.setWalletId(scopedWalletId)
    }

    private var availableChains: [SupportedChain] {
        guard let wallet = activeWallet else { return [] }
        let chains: [SupportedChain] = wallet.addresses.compactMap { record in
            guard !record.address.isEmpty else { return nil }
            return SupportedChain(rawValue: record.chainRaw)
        }
        let set = Set(chains)
        return SupportedChain.allCases.filter { set.contains($0) }
    }

    private var catalogAssets: [CatalogAsset] {
        let seededAssets = AssetCatalog.assets(from: assetRecords)
        return seededAssets.isEmpty ? AssetCatalog.allAssets : seededAssets
    }

    private var matchingToken: ReceiveAsset? {
        let symbol = assetPrefill.symbol.uppercased()
        return ReceiveAsset.tokens(
            availableChains: Set(availableChains),
            customTokens: customTokenRecords.map { CustomTokenSnapshot(from: $0) },
            catalogAssets: catalogAssets
        )
        .first { asset in
            guard case let .token(tokenSymbol, _, _) = asset else { return false }
            return tokenSymbol.uppercased() == symbol
        }
    }

    private var tokenSymbol: String? {
        assetPrefill.nativeChain == nil ? assetPrefill.symbol : nil
    }

    private var sortedChains: [SupportedChain] {
        if let chain = assetPrefill.nativeChain {
            return availableChains.contains(chain) ? [chain] : []
        }

        let chains: [SupportedChain]
        if !preferredChains.isEmpty {
            chains = preferredChains
        } else if case let .token(_, _, tokenChains) = matchingToken {
            chains = tokenChains
        } else {
            chains = []
        }

        let availableSet = Set(availableChains)
        let uniqueChains = SupportedChain.allCases.filter {
            availableSet.contains($0) && chains.contains($0)
        }
        return AssetPickerSort.networks(uniqueChains, symbol: assetPrefill.symbol, holdings: holdings)
    }

    private var filteredChains: [SupportedChain] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedChains }
        return sortedChains.filter {
            $0.displayName.localizedStandardContains(query) || $0.ticker.localizedStandardContains(query)
        }
    }

    private var firstSupportedCustomTokenChain: SupportedChain {
        CustomTokenSupport.preferredInitialChain(availableChains: availableChains)
    }

    private func totals(for chain: SupportedChain) -> AssetPickerHoldings.Totals {
        if assetPrefill.nativeChain != nil {
            return holdings.nativeTotals(chain: chain)
        }
        return holdings.perNetwork(symbol: assetPrefill.symbol, chain: chain)
    }

    // MARK: - Actions

    private func healActiveWalletIdIfNeeded() {
        guard let first = allWallets.first else { return }
        if ActiveWalletResolver.shouldHeal(rawID: activeWalletIdRaw, wallets: allWallets) {
            ActiveWalletPointer.set(first.id)
        }
    }

    private func address(for chain: SupportedChain) -> String? {
        guard let wallet = activeWallet else { return nil }
        return wallet.addresses.first(where: {
            $0.chainRaw == chain.rawValue && !$0.address.isEmpty
        })?.address
    }

    private func openNetwork(_ chain: SupportedChain, tokenSymbol: String?) {
        guard let address = address(for: chain) else {
            missingAddressChain = chain
            isShowingMissingAddressAlert = true
            return
        }
        navigationPath.append(
            ReceiveDestination.qr(chain: chain, tokenSymbol: tokenSymbol, address: address)
        )
    }
}
