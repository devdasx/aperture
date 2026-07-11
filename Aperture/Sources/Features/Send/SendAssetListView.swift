import SwiftUI

/// Step 1 of the Send sheet — the asset list (twin of
/// `ReceiveAssetListView`). Native coins + tokens, each row showing the
/// full name (prominent), the ticker (gray), and the real balance when
/// held. Sorted balance high→low, then transaction-count high→low. A
/// native search bar (`.searchable`, bottom-floating on iPhone per
/// Rule #14) filters by name + ticker. Logos go through the cached
/// `CoinMark`.
struct SendAssetListView: View {
    let activeWalletId: UUID?
    let availableChains: [SupportedChain]
    let holdings: AssetPickerHoldings
    let currencyCode: String
    let customTokenRecords: [CustomTokenRecord]
    let assetRecords: [AssetRecord]
    let onSelectNative: (SupportedChain) -> Void
    let onSelectToken: (SendAsset) -> Void
    let onSelectTemplate: (WalletAssetRouteTemplateRecord) -> Void
    let onAddCustomToken: (SupportedChain?) -> Void

    /// Memoized, balance-sorted rows — rebuilt only when the chains, the
    /// custom-token set, the seeded catalog, or the holdings change.
    @State private var sortedNatives: [SupportedChain] = []
    @State private var sortedTokens: [SendAsset] = []
    @State private var searchText: String = ""

    private var rowsKey: String {
        "\(availableChains.map(\.rawValue).joined(separator: ","))|\(customTokenRecords.count)|\(assetRecords.count)|\(holdings.fingerprint)"
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var catalogAssets: [CatalogAsset] {
        let seededAssets = AssetCatalog.assets(from: assetRecords)
        return seededAssets.isEmpty ? AssetCatalog.allAssets : seededAssets
    }

    private var customTokenSnapshots: [CustomTokenSnapshot] {
        customTokenRecords.map { CustomTokenSnapshot(from: $0) }
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
                            flow: .send,
                            onSelect: onSelectTemplate
                        )
                    }
                    if !natives.isEmpty { nativeSection(natives) }
                    if !tokens.isEmpty { tokenSection(tokens) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .searchable(text: $searchText, prompt: Text("Search"))
        .task(id: rowsKey) {
            let tokens = SendAsset.tokens(
                availableChains: Set(availableChains),
                customTokens: customTokenSnapshots,
                catalogAssets: catalogAssets
            )
            sortedTokens = AssetPickerSort.tokens(tokens, holdings: holdings)
            sortedNatives = AssetPickerSort.natives(availableChains, holdings: holdings)
        }
    }

    // MARK: - Filtering

    private var filteredNatives: [SupportedChain] {
        let q = searchQuery
        guard !q.isEmpty else { return sortedNatives }
        return sortedNatives.filter {
            $0.displayName.localizedStandardContains(q) || $0.ticker.localizedStandardContains(q)
        }
    }

    private var filteredTokens: [SendAsset] {
        let q = searchQuery
        guard !q.isEmpty else { return sortedTokens }
        return sortedTokens.compactMap { asset in
            guard case let .token(symbol, name, descriptors) = asset else { return nil }
            if name.localizedStandardContains(q) || symbol.localizedStandardContains(q) {
                return asset
            }
            let matchingDescriptors = descriptors.filter {
                ContractTokenDiscovery.contractMatches($0.contract, chain: $0.chain, query: q)
            }
            guard !matchingDescriptors.isEmpty else { return nil }
            return SendAsset.token(symbol: symbol, name: name, tokens: matchingDescriptors)
        }
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
                .listRowBackground(UniColors.List.rowBackground)
            }
        } header: {
            UniCaption(text: "Native assets", color: UniColors.Text.tertiary)
        }
    }

    @ViewBuilder
    private func tokenSection(_ tokens: [SendAsset]) -> some View {
        Section {
            ForEach(tokens) { asset in
                if case let .token(symbol, name, descriptors) = asset {
                    Button {
                        onSelectToken(asset)
                    } label: {
                        AssetPickerAssetRow(
                            fullName: name,
                            ticker: symbol,
                            logoChain: asset.canonicalChainForLogo ?? descriptors.first?.chain ?? .ethereum,
                            logoContract: asset.canonicalContract,
                            totals: holdings.aggregate(symbol: symbol),
                            currencyCode: currencyCode
                        )
                    }
                    .buttonStyle(.uniListRow)
                    .listRowBackground(UniColors.List.rowBackground)
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

                if canOfferCustomTokenAdd, canAttemptContractLookup {
                    ContractTokenSearchPrompt(
                        query: searchQuery,
                        availableChains: availableChains,
                        catalogAssets: catalogAssets,
                        customTokens: customTokenSnapshots,
                        onAdded: {}
                    )
                    .padding(.horizontal, UniSpacing.m)
                }

                if canOfferCustomTokenAdd {
                    UniButton(title: "Add custom token", variant: .secondary, systemImage: "plus") {
                        onAddCustomToken(nil)
                    }
                    .padding(.horizontal, UniSpacing.m)
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
                title: "No sendable assets yet.",
                detail: "Aperture is still deriving this wallet's accounts. Try again in a moment.",
                mark: .icon(systemName: "wallet.pass"),
                minHeight: 320
            )
        }
    }
}
