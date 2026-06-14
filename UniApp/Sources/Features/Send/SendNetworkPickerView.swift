import SwiftUI

/// Step 2 of the Send sheet — the per-token network picker. The twin of
/// `ReceiveNetworkPickerView`. Reached from a token row tap in
/// `SendAssetListView`; lists every chain the token ships on, filtered to
/// chains the active wallet has a derived address for (so a tap always
/// leads to a network the wallet can actually sign from).
///
/// **Design intent (Rule #2 §D.1):** answer "which network am I sending
/// on?" by showing every option plainly, with the honest one-line
/// reminder that the recipient must be on the same network.
///
/// **Layers (Rule #2 §B.3):** content layer — opaque list rows.
/// Functional layer — system nav bar (parent `NavigationStack`).
struct SendNetworkPickerView: View {
    let token: SendAsset
    let onSelectNetwork: (SupportedChain) -> Void

    private var symbol: String {
        if case let .token(symbol, _, _) = token { return symbol }
        return ""
    }

    private var chains: [SupportedChain] {
        if case let .token(_, _, chains) = token { return chains }
        return []
    }

    var body: some View {
        List {
            Section {
                ForEach(chains, id: \.self) { chain in
                    Button {
                        onSelectNetwork(chain)
                    } label: {
                        SendNetworkRow(chain: chain)
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
        .navigationTitle(Text("Choose network for \(symbol)"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row

private struct SendNetworkRow: View {
    let chain: SupportedChain

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            chainLogo
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text("Send on this network")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var chainLogo: some View {
        if let assetName = chain.logoAssetName {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(UniColors.Background.tertiary)
                .overlay {
                    Text(verbatim: String(chain.ticker.prefix(1)))
                        .font(UniTypography.footnote.weight(.semibold))
                        .foregroundStyle(UniColors.Text.secondary)
                }
        }
    }
}
