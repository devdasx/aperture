import SwiftUI

/// Shared recent route shortcuts for Send and Receive asset pickers.
///
/// Each row represents an exact wallet-scoped route: native coin on one
/// chain, or token + selected network. The backing store is GRDB, so
/// switching wallets never leaks shortcuts from another wallet.
struct AssetRouteTemplatesSection: View {
    let walletId: UUID?
    let flow: WalletAssetRouteTemplateFlow
    let onSelect: (WalletAssetRouteTemplateRecord) -> Void

    @StateObject private var observation = WalletAssetRouteTemplatesObservation()

    private var scopeKey: String {
        "\(walletId?.uuidString ?? "none")|\(flow.rawValue)"
    }

    var body: some View {
        Group {
            if !observation.templates.isEmpty {
                Section {
                    ForEach(observation.templates) { template in
                        Button {
                            onSelect(template)
                        } label: {
                            AssetRouteTemplateRow(template: template)
                        }
                        .buttonStyle(.uniListRow)
                        .listRowBackground(UniColors.List.rowBackground)
                    }
                } header: {
                    UniCaption(text: "Templates", color: UniColors.Text.tertiary)
                }
            }
        }
        .task(id: scopeKey) {
            observation.setScope(walletId: walletId, flow: flow)
        }
    }
}

private struct AssetRouteTemplateRow: View {
    let template: WalletAssetRouteTemplateRecord

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: template.chain,
                tokenSymbol: template.symbol,
                contract: template.logoContract
            )
            .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: template.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)

                Text(verbatim: template.subtitle)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: UniSpacing.s)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, 4)
        .uniListRowHitTarget()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(template.displayName), \(template.subtitle)"))
    }
}
