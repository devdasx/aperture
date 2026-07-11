import SwiftUI

/// Step 2 of the Send sheet — the per-token network picker (twin of
/// `ReceiveNetworkPickerView`). Each network row shows the wallet's real
/// balance of this token ON that network; rows are sorted balance
/// high→low then tx-count high→low. A native search bar filters by
/// network name. Logos go through the cached `CoinMark`.
struct SendNetworkPickerView: View {
    let token: SendAsset
    let holdings: AssetPickerHoldings
    let currencyCode: String
    let onSelectNetwork: (SendTokenDescriptor) -> Void

    @State private var searchText: String = ""

    private var symbol: String {
        if case let .token(symbol, _, _) = token { return symbol }
        return ""
    }

    private var sortedTokens: [SendTokenDescriptor] {
        let descriptors = token.tokenDescriptors
        let sortedChains = AssetPickerSort.networks(
            descriptors.map(\.chain),
            symbol: symbol,
            holdings: holdings
        )
        return sortedChains.compactMap { chain in
            descriptors.first(where: { $0.chain == chain })
        }
    }

    private var filteredTokens: [SendTokenDescriptor] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedTokens }
        return sortedTokens.filter {
            $0.chain.displayName.localizedStandardContains(q)
                || $0.chain.ticker.localizedStandardContains(q)
                || $0.name.localizedStandardContains(q)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredTokens) { descriptor in
                    Button {
                        onSelectNetwork(descriptor)
                    } label: {
                        AssetPickerNetworkRow(
                            chain: descriptor.chain,
                            subtitle: "Send on this network",
                            totals: holdings.perNetwork(symbol: symbol, chain: descriptor.chain),
                            currencyCode: currencyCode
                        )
                    }
                    .buttonStyle(.uniListRow)
                    .listRowBackground(UniColors.List.rowBackground)
                    .accessibilityLabel(Text(verbatim: descriptor.chain.displayName))
                    .accessibilityHint(Text("Send \(symbol) on this network"))
                }
            } footer: {
                UniFootnote(
                    text: "Send only to a \(symbol) address on the same network. Sending across networks may result in permanent loss.",
                    color: UniColors.Text.tertiary
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, UniSpacing.xs)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .searchable(text: $searchText, prompt: Text("Search"))
        .navigationTitle(Text("Choose network for \(symbol)"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
