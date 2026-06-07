import SwiftUI

/// Step 2 of the Receive sheet — the per-token network picker. Reached
/// from a token row tap in `ReceiveAssetListView`. Lists every chain
/// the token ships on (filtered to chains the active wallet has a
/// derived address for, so a tap is always followed by a real QR).
///
/// **Design intent (Rule #2 §D.1):** answer "which network should I
/// tell the sender to use?" by showing the user every option, plainly,
/// with the honest one-line reminder that the sender's network choice
/// must match.
///
/// **Layers (Rule #2 §B.3):** content layer — opaque list rows.
/// Functional layer — system nav bar (parent `NavigationStack`).
struct ReceiveNetworkPickerView: View {
    let token: ReceiveAsset
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
                        NetworkRow(chain: chain)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                    .accessibilityLabel(Text(verbatim: chain.displayName))
                    .accessibilityHint(Text("Receive \(symbol) on this network"))
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Choose network for \(symbol)"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row

private struct NetworkRow: View {
    let chain: SupportedChain

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            chainLogo
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text("Make sure the sender uses this network")
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
