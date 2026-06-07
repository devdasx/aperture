import SwiftUI
import SwiftData

/// Step 1 of the Receive sheet — the asset list. Two sections:
///
/// - **Native assets** — one row per `SupportedChain` the active
///   wallet has a derived address for. Tapping routes directly to
///   the QR step (the network IS the chain).
/// - **Tokens** — one row per unique token symbol curated across
///   `EVMTokenRegistry` ∪ `SolanaTokenRegistry`, filtered to symbols
///   whose chains the wallet actually has addresses for. Tapping
///   routes to the network picker (Step 2).
///
/// **Design intent (Rule #2 §D.1):** show the user every kind of
/// thing they can receive, ordered by likelihood, with the network
/// honesty baked into the row subtitle ("On 13 networks") so they
/// know the next tap is a network choice.
///
/// **Layers (Rule #2 §B.3):** content layer — opaque list rows on a
/// `UniColors.Background.primary` surface. Functional layer — the
/// system nav bar (rendered by the parent `NavigationStack` in the
/// sheet root).
struct ReceiveAssetListView: View {
    let availableChains: [SupportedChain]
    let onSelectNative: (SupportedChain) -> Void
    let onSelectToken: (ReceiveAsset) -> Void

    private var tokenRows: [ReceiveAsset] {
        ReceiveAsset.tokens(availableChains: Set(availableChains))
    }

    var body: some View {
        List {
            if availableChains.isEmpty {
                emptySection
            } else {
                nativeSection
                if !tokenRows.isEmpty {
                    tokenSection
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
    }

    // MARK: - Sections

    @ViewBuilder
    private var nativeSection: some View {
        Section {
            ForEach(availableChains, id: \.self) { chain in
                Button {
                    onSelectNative(chain)
                } label: {
                    NativeAssetRow(chain: chain)
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
                .accessibilityLabel(Text(verbatim: "\(chain.displayName) — \(chain.ticker)"))
            }
        } header: {
            UniCaption(
                text: "Native assets",
                color: UniColors.Text.tertiary
            )
        }
    }

    @ViewBuilder
    private var tokenSection: some View {
        Section {
            ForEach(tokenRows) { asset in
                Button {
                    onSelectToken(asset)
                } label: {
                    TokenAssetRow(asset: asset)
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            }
        } header: {
            UniCaption(
                text: "Tokens",
                color: UniColors.Text.tertiary
            )
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

// MARK: - Native row

private struct NativeAssetRow: View {
    let chain: SupportedChain

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            chainLogo
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: chain.ticker)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
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

// MARK: - Token row

private struct TokenAssetRow: View {
    let asset: ReceiveAsset

    private var symbol: String {
        if case let .token(symbol, _, _) = asset { return symbol }
        return ""
    }

    private var name: String {
        if case let .token(_, name, _) = asset { return name }
        return ""
    }

    private var networkCount: Int {
        if case let .token(_, _, chains) = asset { return chains.count }
        return 0
    }

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            tokenLogo
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: symbol)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                if networkCount == 1 {
                    Text("On 1 network")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                } else {
                    Text("On \(networkCount) networks")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(symbol), \(name)"))
        .accessibilityHint(Text("Choose a network to receive on"))
    }

    @ViewBuilder
    private var tokenLogo: some View {
        if let chain = asset.canonicalChainForLogo,
           let contract = asset.canonicalContract,
           let url = TrustWalletAssetURL.tokenLogoURL(chain: chain, contract: contract) {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .empty, .failure:
                    monogramFallback
                @unknown default:
                    monogramFallback
                }
            }
        } else {
            monogramFallback
        }
    }

    @ViewBuilder
    private var monogramFallback: some View {
        Circle()
            .fill(UniColors.Background.tertiary)
            .overlay {
                Text(verbatim: String(symbol.prefix(1)))
                    .font(UniTypography.footnote.weight(.semibold))
                    .foregroundStyle(UniColors.Text.secondary)
            }
    }
}
