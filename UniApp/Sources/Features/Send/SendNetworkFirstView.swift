import SwiftUI
import SwiftData

/// Send flow for callers that already know the asset.
///
/// Wallet Home still uses `SendView` because it starts with "choose an
/// asset". Asset detail and Markets already know the asset, so this native
/// stack starts at the useful place: recipient for single-network assets,
/// or the network list for multi-network tokens.
struct SendNetworkFirstView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @Query(sort: [SortDescriptor(\CustomTokenRecord.symbol, order: .forward)])
    private var customTokenRecords: [CustomTokenRecord]
    @Query private var assetRecords: [AssetRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    @Binding var navigationPath: NavigationPath

    let assetPrefill: SendView.AssetPrefill
    var preferredChains: [SupportedChain] = []

    @Environment(\.dismiss) private var dismiss

    @State private var holdings: AssetPickerHoldings = .empty
    @State private var recents: RecentRecipientsIndex = .empty
    @State private var searchText: String = ""
    @State private var missingAddressChain: SupportedChain?
    @State private var isShowingMissingAddressAlert: Bool = false

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }

    private var holdingsKey: String {
        guard let wallet = activeWallet else { return "none" }
        var rows = 0
        var newest = Date.distantPast
        for address in wallet.addresses {
            rows += address.balances.count
            for balance in address.balances where balance.updatedAt > newest {
                newest = balance.updatedAt
            }
        }
        return "\(wallet.id.uuidString)|\(rows)|\(newest.timeIntervalSince1970)"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
                .navigationDestination(for: SendDestination.self) { destination in
                    switch destination {
                    case let .networkPicker(asset):
                        SendNetworkPickerView(
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
                    case let .recipient(chain, tokenSymbol, fromAddress, prefillRecipient):
                        recipientView(
                            chain: chain,
                            tokenSymbol: tokenSymbol,
                            fromAddress: fromAddress,
                            prefillRecipient: prefillRecipient
                        )
                    case let .amount(chain, tokenSymbol, fromAddress, recipients):
                        SendAmountView(
                            chain: chain,
                            tokenSymbol: tokenSymbol,
                            fromAddress: fromAddress,
                            recipients: recipients,
                            onReview: { draft in
                                navigationPath.append(SendDestination.review(draft))
                            }
                        )
                    case let .review(draft):
                        SendReviewLoader(
                            draft: draft,
                            walletId: activeWallet?.id ?? UUID(),
                            walletHasPassphrase: activeWallet?.hasPassphrase ?? false,
                            onClose: { dismiss() }
                        )
                    }
                }
        }
        .onChange(of: activeWalletIdRaw) { _, _ in
            navigationPath = NavigationPath()
        }
        .task(id: activeWalletHealKey) {
            healActiveWalletIdIfNeeded()
        }
        .task(id: holdingsKey) {
            holdings = AssetPickerHoldings(wallet: activeWallet)
            recents = RecentRecipientsIndex(wallet: activeWallet)
        }
        .alert(
            Text("No address for this network"),
            isPresented: $isShowingMissingAddressAlert,
            presenting: missingAddressChain
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { chain in
            Text("This wallet has no \(chain.displayName) address yet, so there is nothing to send from on this network. Aperture may still be deriving your accounts; try again in a moment.")
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if let chain = singleChain, let fromAddress = address(for: chain) {
            recipientView(
                chain: chain,
                tokenSymbol: tokenSymbol,
                fromAddress: fromAddress,
                prefillRecipient: nil
            )
        } else {
            networkList
        }
    }

    @ViewBuilder
    private var networkList: some View {
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
    }

    private var networkSection: some View {
        Section {
            ForEach(filteredChains, id: \.self) { chain in
                Button {
                    openNetwork(chain, tokenSymbol: tokenSymbol)
                } label: {
                    AssetPickerNetworkRow(
                        chain: chain,
                        subtitle: "Send on this network",
                        totals: totals(for: chain),
                        currencyCode: currencyCode
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.List.rowBackground)
                .accessibilityLabel(Text(verbatim: chain.displayName))
                .accessibilityHint(Text("Send \(assetPrefill.symbol) on this network"))
            }
        } footer: {
            UniFootnote(
                text: "Send only to a \(assetPrefill.symbol) address on the same network. Sending across networks may result in permanent loss.",
                color: UniColors.Text.tertiary
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, UniSpacing.xs)
        }
    }

    private var emptySection: some View {
        Section {
            ContentUnavailableView(
                "No networks available",
                systemImage: "network.slash",
                description: Text("This wallet does not have a send address for \(assetPrefill.symbol).")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func recipientView(
        chain: SupportedChain,
        tokenSymbol: String?,
        fromAddress: String,
        prefillRecipient: String?
    ) -> some View {
        SendRecipientView(
            chain: chain,
            tokenSymbol: tokenSymbol,
            fromAddress: fromAddress,
            recents: recents,
            initialRecipient: prefillRecipient,
            onContinue: { recipients in
                navigationPath.append(
                    SendDestination.amount(
                        chain: chain,
                        tokenSymbol: tokenSymbol,
                        fromAddress: fromAddress,
                        recipients: recipients
                    )
                )
            }
        )
    }

    // MARK: - Derived

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    private var activeWalletHealKey: String {
        "\(activeWalletIdRaw)|\(allWallets.count)"
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

    private var matchingToken: SendAsset? {
        let symbol = assetPrefill.symbol.uppercased()
        return SendAsset.tokens(
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

    private var singleChain: SupportedChain? {
        sortedChains.count == 1 ? sortedChains.first : nil
    }

    private var filteredChains: [SupportedChain] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedChains }
        return sortedChains.filter {
            $0.displayName.localizedStandardContains(query) || $0.ticker.localizedStandardContains(query)
        }
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
        let resolves = UUID(uuidString: activeWalletIdRaw)
            .map { id in allWallets.contains(where: { $0.id == id }) } ?? false
        if !resolves {
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
            SendDestination.recipient(
                chain: chain,
                tokenSymbol: tokenSymbol,
                fromAddress: address,
                prefillRecipient: nil
            )
        )
    }
}
