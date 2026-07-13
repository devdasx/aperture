import SwiftUI

/// One Phantom/Trust path balance row for asset detail and network detail.
struct SolanaPathBalanceRow: View {
    let line: SolanaPathBalanceLine
    let symbol: String
    let hideBalance: Bool
    @Environment(\.balancePrivacyEnabled) private var privacyEnabled

    private var hidden: Bool { hideBalance || privacyEnabled }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                HStack(spacing: UniSpacing.xs) {
                    Text(verbatim: line.style.title)
                        .font(UniTypography.bodyEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    if line.isPreferred {
                        Text("Selected")
                            .font(UniTypography.caption2.weight(.semibold))
                            .foregroundStyle(UniColors.Text.secondary)
                            .padding(.horizontal, UniSpacing.xs)
                            .padding(.vertical, 2)
                            .background(UniColors.Fill.tertiary, in: Capsule())
                    }
                }
                Text(verbatim: WalletFormatting.shortAddress(line.address, prefix: 6, suffix: 4))
                    .font(UniTypography.caption2.monospaced())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .environment(\.layoutDirection, .leftToRight)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(verbatim: "\(WalletFormatting.native(line.amount, decimals: 6, hidden: hidden)) \(symbol)")
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                Text(WalletFormatting.fiat(line.fiatValue ?? 0, currencyCode: line.fiatCurrencyCode, hidden: hidden))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, UniSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        if line.isPreferred {
            return Text(verbatim: String(format: String.apertureLocalized("%@, selected for send, %@ %@"), line.style.title, WalletFormatting.native(line.amount, decimals: 6, hidden: hidden), symbol))
        }
        return Text(verbatim: String(format: String.apertureLocalized("%@, %@ %@"), line.style.title, WalletFormatting.native(line.amount, decimals: 6, hidden: hidden), symbol))
    }
}
