import SwiftUI

/// Shared rows for the Receive & Send pickers, so both flows render
/// identically (the user's "same as receive 100%"). All logos go through
/// `CoinMark` (the cached, off-main-decoded mark view) so they download
/// at most once per token, ever. Colors + type are `UniColors` /
/// `UniTypography` only.

// MARK: - Asset row (Step 1: native coins + tokens)

/// One row in the asset list. Full name is the prominent label; the
/// short ticker sits below in gray; the real balance (when held) is
/// trailing.
struct AssetPickerAssetRow: View {
    /// Prominent label — the FULL name ("USD Coin", "Ethereum").
    let fullName: String
    /// Gray secondary label — the short ticker ("USDC", "ETH").
    let ticker: String
    /// Logo resolution: the chain to fetch the mark from + the token
    /// contract (nil for native coins → bundled chain mark).
    let logoChain: SupportedChain
    let logoContract: String?
    let totals: AssetPickerHoldings.Totals
    let currencyCode: String

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(chain: logoChain, tokenSymbol: ticker, contract: logoContract)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: fullName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(verbatim: ticker)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer(minLength: UniSpacing.s)
            AssetPickerBalanceColumn(totals: totals, currencyCode: currencyCode)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(fullName), \(ticker)"))
    }
}

// MARK: - Network row (Step 2: per-network)

/// One row in the network picker. The chain is the prominent label; a
/// gray reminder sits below; the per-network real balance is trailing.
struct AssetPickerNetworkRow: View {
    let chain: SupportedChain
    let subtitle: LocalizedStringKey
    let totals: AssetPickerHoldings.Totals
    let currencyCode: String

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(chain: chain, tokenSymbol: chain.ticker)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UniSpacing.s)
            AssetPickerBalanceColumn(totals: totals, currencyCode: currencyCode)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Trailing balance column

/// The trailing native + fiat balance, shown only when the wallet holds
/// a positive amount (no "0" noise for un-held assets). LTR-locked so
/// the number reads correctly in RTL locales.
private struct AssetPickerBalanceColumn: View {
    let totals: AssetPickerHoldings.Totals
    let currencyCode: String

    var body: some View {
        if totals.hasBalance {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: WalletFormatting.native(totals.native, decimals: 8))
                    .font(UniTypography.subheadlineEmphasized)
                    .monospacedDigit()
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                if totals.fiat > 0 {
                    Text(verbatim: WalletFormatting.fiat(totals.fiat, currencyCode: currencyCode))
                        .font(UniTypography.footnote)
                        .monospacedDigit()
                        .foregroundStyle(UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }
}
