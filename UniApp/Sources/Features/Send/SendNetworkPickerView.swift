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
    let onSelectNetwork: (SupportedChain) -> Void

    @State private var searchText: String = ""

    private var symbol: String {
        if case let .token(symbol, _, _) = token { return symbol }
        return ""
    }

    private var sortedChains: [SupportedChain] {
        guard case let .token(_, _, chains) = token else { return [] }
        return AssetPickerSort.networks(chains, symbol: symbol, holdings: holdings)
    }

    private var filteredChains: [SupportedChain] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedChains }
        return sortedChains.filter {
            $0.displayName.localizedStandardContains(q) || $0.ticker.localizedStandardContains(q)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredChains, id: \.self) { chain in
                    Button {
                        onSelectNetwork(chain)
                    } label: {
                        AssetPickerNetworkRow(
                            chain: chain,
                            subtitle: "Send on this network",
                            totals: holdings.perNetwork(symbol: symbol, chain: chain),
                            currencyCode: currencyCode
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                    .accessibilityLabel(Text(verbatim: chain.displayName))
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
