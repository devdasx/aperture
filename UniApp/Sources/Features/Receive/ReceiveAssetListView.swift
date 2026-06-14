import SwiftUI
import SwiftData

/// Step 1 of the Receive sheet — the asset list. Native coins + tokens,
/// each row showing the full name (prominent), the ticker (gray), and the
/// real balance when held. Sorted balance high→low, then transaction-count
/// high→low. A native search bar (`.searchable`, bottom-floating on iPhone
/// per Rule #14) filters by name + ticker. Logos go through the cached
/// `CoinMark`. Shares its rows + sort + holdings with the Send picker so
/// the two flows are identical.
struct ReceiveAssetListView: View {
    let availableChains: [SupportedChain]
    let holdings: AssetPickerHoldings
    let currencyCode: String
    let onSelectNative: (SupportedChain) -> Void
    let onSelectToken: (ReceiveAsset) -> Void

    @Query(sort: [SortDescriptor(\CustomTokenRecord.symbol, order: .forward)])
    private var customTokenRecords: [CustomTokenRecord]
    @Query private var assetRecords: [AssetRecord]

    @State private var sortedNatives: [SupportedChain] = []
    @State private var sortedTokens: [ReceiveAsset] = []
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
            let tokens = ReceiveAsset.tokens(
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

    private var filteredTokens: [ReceiveAsset] {
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
                .listRowBackground(UniColors.Background.secondary)
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
                    .listRowBackground(UniColors.Background.secondary)
                }
            }
        } header: {
            UniCaption(text: "Tokens", color: UniColors.Text.tertiary)
        }
    }

    @ViewBuilder
    private var noResultsSection: some View {
        Section {
            UniBody(
                text: "No assets match your search.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xl)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            VStack(spacing: UniSpacing.s) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(UniColors.Icon.tertiary)
                UniBody(
                    text: "No addresses available for this wallet yet.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                UniFootnote(
                    text: "Aperture is still deriving your accounts. Try again in a moment.",
                    alignment: .center,
                    color: UniColors.Text.tertiary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xxl)
            .listRowBackground(Color.clear)
        }
    }
}
