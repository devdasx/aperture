import SwiftUI

/// Step 1 of the Receive sheet — the asset list. Native coins + tokens,
/// each row showing the full name (prominent), the ticker (gray), and the
/// real balance when held. Sorted balance high→low, then transaction-count
/// high→low. A native search bar (`.searchable`, bottom-floating on iPhone
/// per Rule #14) filters by name + ticker. Logos go through the cached
/// `CoinMark`. Shares its rows + sort + holdings with the Send picker so
/// the two flows are identical.
struct ReceiveAssetListView: View {
    let activeWalletId: UUID?
    let availableChains: [SupportedChain]
    let holdings: AssetPickerHoldings
    let currencyCode: String
    let customTokenRecords: [CustomTokenRecord]
    let assetRecords: [AssetRecord]
    let onSelectNative: (SupportedChain) -> Void
    let onSelectToken: (ReceiveAsset) -> Void
    let onSelectTemplate: (WalletAssetRouteTemplateRecord) -> Void
    let onAddCustomToken: () -> Void

    @State private var searchText: String = ""

    private var sortedNatives: [SupportedChain] {
        AssetPickerSort.natives(availableChains, holdings: holdings)
    }

    private var sortedTokens: [ReceiveAsset] {
        let tokens = ReceiveAsset.tokens(
            availableChains: Set(availableChains),
            customTokens: customTokenRecords.map { CustomTokenSnapshot(from: $0) },
            catalogAssets: catalogAssets
        )
        return AssetPickerSort.tokens(tokens, holdings: holdings)
    }

    private var catalogAssets: [CatalogAsset] {
        let seededAssets = AssetCatalog.assets(from: assetRecords)
        return seededAssets.isEmpty ? AssetCatalog.allAssets : seededAssets
    }

    private var customTokenSnapshots: [CustomTokenSnapshot] {
        customTokenRecords.map { CustomTokenSnapshot(from: $0) }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canOfferCustomTokenAdd: Bool {
        !searchQuery.isEmpty && CustomTokenSupport.hasSupportedChain(in: availableChains)
    }

    private var canAttemptContractLookup: Bool {
        ContractTokenDiscovery.canAttemptLookup(query: searchQuery, availableChains: availableChains)
    }

    var body: some View {
        List {
            if availableChains.isEmpty {
                emptySection
            } else {
                let natives = filteredNatives
                let tokens = filteredTokens
                if natives.isEmpty && tokens.isEmpty {
                    noResultsSection
                } else {
                    if searchQuery.isEmpty {
                        AssetRouteTemplatesSection(
                            walletId: activeWalletId,
                            flow: .receive,
                            onSelect: onSelectTemplate
                        )
                    }
                    if !natives.isEmpty { nativeSection(natives) }
                    if !tokens.isEmpty { tokenSection(tokens) }
                }
            }
        }
        .uniListPageChrome()
        .searchable(text: $searchText, prompt: Text(verbatim: String.apertureLocalized("Search")))
    }

    // MARK: - Filtering

    private var filteredNatives: [SupportedChain] {
        let q = searchQuery
        guard !q.isEmpty else { return sortedNatives }
        return sortedNatives.filter {
            $0.displayName.localizedStandardContains(q) || $0.ticker.localizedStandardContains(q)
        }
    }

    private var filteredTokens: [ReceiveAsset] {
        let q = searchQuery
        guard !q.isEmpty else { return sortedTokens }
        return sortedTokens.compactMap { asset in
            guard case let .token(symbol, name, _) = asset else { return nil }
            if name.localizedStandardContains(q) || symbol.localizedStandardContains(q) {
                return asset
            }
            let matchingChains = matchingContractChains(symbol: symbol, asset: asset, query: q)
            guard !matchingChains.isEmpty else { return nil }
            return ReceiveAsset.token(symbol: symbol, name: name, chains: matchingChains)
        }
    }

    private func matchingContractChains(
        symbol: String,
        asset: ReceiveAsset,
        query: String
    ) -> [SupportedChain] {
        guard case let .token(_, _, chains) = asset else { return [] }
        return ContractTokenDiscovery.matchingChains(
            symbol: symbol,
            chains: chains,
            query: query,
            catalogAssets: catalogAssets,
            customTokens: customTokenSnapshots
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private func nativeSection(_ chains: [SupportedChain]) -> some View {
        Section {
            ForEach(chains, id: \.self) { chain in
                Button {
                    onSelectNative(chain)
                } label: {
                    AssetPickerAssetRow(
                        fullName: chain.displayName,
                        ticker: chain.ticker,
                        logoChain: chain,
                        logoContract: nil,
                        totals: holdings.nativeTotals(chain: chain),
                        currencyCode: currencyCode
                    )
                }
                .buttonStyle(.uniListRow)
                .uniListRowSurface()
            }
        } header: {
            UniCaption(text: "Native assets", color: UniColors.Text.tertiary)
        }
    }

    @ViewBuilder
    private func tokenSection(_ tokens: [ReceiveAsset]) -> some View {
        Section {
            ForEach(tokens) { asset in
                if case let .token(symbol, name, chains) = asset {
                    let logoChain = asset.canonicalChainForLogo ?? chains.first ?? .ethereum
                    Button {
                        onSelectToken(asset)
                    } label: {
                        AssetPickerAssetRow(
                            fullName: name,
                            ticker: symbol,
                            logoChain: logoChain,
                            logoContract: asset.logoContract(on: logoChain, customTokens: customTokenSnapshots),
                            totals: holdings.aggregate(symbol: symbol),
                            currencyCode: currencyCode
                        )
                    }
                    .buttonStyle(.uniListRow)
                    .uniListRowSurface()
                }
            }
        } header: {
            UniCaption(text: "Tokens", color: UniColors.Text.tertiary)
        }
    }

    @ViewBuilder
    private var noResultsSection: some View {
        Section {
            VStack(spacing: UniSpacing.m) {
                UniEmptyState(
                    title: "No assets match your search.",
                    detail: canOfferCustomTokenAdd
                        ? "If this is an ERC-20, Solana, or TRON token, add it by contract address."
                        : "Try a coin name, token name, or ticker.",
                    mark: .icon(systemName: "magnifyingglass")
                )

                if canOfferCustomTokenAdd {
                    if canAttemptContractLookup {
                        ContractTokenSearchPrompt(
                            query: searchQuery,
                            availableChains: availableChains,
                            catalogAssets: catalogAssets,
                            customTokens: customTokenSnapshots,
                            onAdded: {}
                        )
                        .padding(.horizontal, UniSpacing.m)
                    } else {
                        UniButton(title: "Add custom token", variant: .secondary, systemImage: "plus") {
                            onAddCustomToken()
                        }
                        .padding(.horizontal, UniSpacing.m)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 300)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            UniListEmptyState(
                title: "No receivable assets yet.",
                detail: "Aperture is still deriving this wallet's accounts. Try again in a moment.",
                mark: .icon(systemName: "wallet.pass"),
                minHeight: 320
            )
        }
    }
}
