import SwiftUI

/// Settings → About → Network providers. Per Rule #16 §A.5 ("name
/// what the data source is") and `docs/RPC-ARCHITECTURE.md` §7. Lists
/// every chain's primary + fallback RPC endpoints with their provider
/// names so the user can audit exactly which servers Aperture talks to
/// when refreshing balances.
struct NetworkProvidersView: View {
    private static let chainOrder: [SupportedChain] = [
        .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
        .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm,
        .bitcoin, .bitcoinCash, .litecoin, .dogecoin,
        .solana, .ripple, .stellar, .near, .ton, .tron,
        .polkadot, .aptos, .sui, .kava,
    ]

    var body: some View {
        List {
            Section {
                Text("Aperture has no servers. Every balance and history read goes directly from this iPhone to the public RPC endpoints listed below. The provider sees your IP and your query; Aperture itself records nothing.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            ForEach(Self.chainOrder, id: \.self) { chain in
                Section {
                    let endpoints = RPCRegistry.endpoints(for: chain)
                    if endpoints.isEmpty {
                        Text("Not available on this build")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                            .listRowBackground(UniColors.Background.secondary)
                    } else {
                        ForEach(Array(endpoints.enumerated()), id: \.element.id) { idx, endpoint in
                            providerRow(endpoint: endpoint, index: idx)
                                .listRowBackground(UniColors.Background.secondary)
                        }
                    }
                } header: {
                    Text(verbatim: chain.displayName)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Network providers"))
        .navigationBarTitleDisplayMode(.large)
    }

    private func providerRow(endpoint: RPCEndpoint, index: Int) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            HStack {
                Text(verbatim: endpoint.provider)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                Text(index == 0 ? "Primary" : "Fallback \(index)")
                    .font(UniTypography.caption2.weight(.semibold))
                    .foregroundStyle(UniColors.Text.tertiary)
                    .padding(.horizontal, UniSpacing.xs)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(UniColors.Fill.secondary))
            }
            Text(verbatim: endpoint.url.host ?? endpoint.url.absoluteString)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}
