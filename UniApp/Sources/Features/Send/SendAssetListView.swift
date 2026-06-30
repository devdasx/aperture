import SwiftUI
import SwiftData

/// Step 1 of the Send sheet — the asset list (twin of
/// `ReceiveAssetListView`). Native coins + tokens, each row showing the
/// full name (prominent), the ticker (gray), and the real balance when
/// held. Sorted balance high→low, then transaction-count high→low. A
/// native search bar (`.searchable`, bottom-floating on iPhone per
/// Rule #14) filters by name + ticker. Logos go through the cached
/// `CoinMark`.
struct SendAssetListView: View {
    let availableChains: [SupportedChain]
    let holdings: AssetPickerHoldings
    let currencyCode: String
    let onSelectNative: (SupportedChain) -> Void
    let onSelectToken: (SendAsset) -> Void

    @Query(sort: [SortDescriptor(\CustomTokenRecord.symbol, order: .forward)])
    private var customTokenRecords: [CustomTokenRecord]
    @Query private var assetRecords: [AssetRecord]

    /// Memoized, balance-sorted rows — rebuilt only when the chains, the
    /// custom-token set, the seeded catalog, or the holdings change.
    @State private var sortedNatives: [SupportedChain] = []
    @State private var sortedTokens: [SendAsset] = []
    @State private var searchText: String = ""

    private var rowsKey: String {
        "\(availableChains.map(\.rawValue).joined(separator: ","))|\(customTokenRecords.count)|\(assetRecords.count)|\(holdings.fingerprint)"
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
                customTokens: customTokenRecords.map { CustomTokenSnapshot(from: $0) },
                catalogAssets: AssetCatalog.assets(from: assetRecords)
            )
            sortedTokens = AssetPickerSort.tokens(tokens, holdings: holdings)
            sortedNatives = AssetPickerSort.natives(availableChains, holdings: holdings)
        }
    }

    // MARK: - Filtering

    private var filteredNatives: [SupportedChain] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedNatives }
        return sortedNatives.filter {
            $0.displayName.localizedStandardContains(q) || $0.ticker.localizedStandardContains(q)
        }
    }

    private var filteredTokens: [SendAsset] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedTokens }
        return sortedTokens.filter { asset in
            guard case let .token(symbol, name, _) = asset else { return false }
            return name.localizedStandardContains(q) || symbol.localizedStandardContains(q)
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
                .buttonStyle(.plain)
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
                if case let .token(symbol, name, chains) = asset {
                    Button {
                        onSelectToken(asset)
                    } label: {
                        AssetPickerAssetRow(
                            fullName: name,
                            ticker: symbol,
                            logoChain: asset.canonicalChainForLogo ?? chains.first ?? .ethereum,
                            logoContract: asset.canonicalContract,
                            totals: holdings.aggregate(symbol: symbol),
                            currencyCode: currencyCode
                        )
                    }
                    .buttonStyle(.plain)
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
            UniListEmptyState(
                title: "No assets match your search.",
                detail: "Try a coin name, token name, or ticker.",
                mark: .icon(systemName: "magnifyingglass"),
                minHeight: 260
            )
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
