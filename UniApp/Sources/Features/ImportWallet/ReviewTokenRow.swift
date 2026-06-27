import SwiftUI

/// Single fungible-token sub-row rendered under its parent chain in
/// the `MnemonicReviewView` list. Visual register is intentionally
/// quieter than the parent `ReviewChainRow`:
/// - indented with a leading "treeline" rule so the user perceives
///   the parent/child relationship at a glance,
/// - the row's leading slot shows a small token symbol bubble
///   instead of a logo (we don't bundle every token's brand asset —
///   Rule #7 honesty about what we don't have),
/// - the name slot uses the token's full name (e.g. "USD Coin")
///   while the amount slot uses the symbol (USDC), so the user can
///   recognize the token without us shipping its logo.
///
/// **Honest fiat (mirrors `ReviewChainRow`).** `fiatBalance == nil`
/// renders "Price unavailable". A `Decimal` (including `0`) renders
/// as `$0.00` or the real converted amount.
struct ReviewTokenRow: View {
    let token: TokenBalance

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            // Indented treeline so the row visually belongs to the
            // chain above it (no extra padding alone is enough —
            // SwiftUI's row spacing erases the cue without an explicit
            // mark).
            Rectangle()
                .fill(UniColors.Fill.tertiary)
                .frame(width: 2)
                .frame(height: 28)
                .padding(.leading, UniSpacing.s)
                .padding(.trailing, UniSpacing.xxs)

            symbolBubble

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: token.name)
                    .font(UniTypography.callout)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: "on \(token.chain.displayName)")
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            Spacer(minLength: UniSpacing.s)
            trailingColumn
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.xs)
    }

    @ViewBuilder
    private var symbolBubble: some View {
        CoinMark(chain: token.chain, tokenSymbol: token.symbol, contract: token.contract)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
            Text(verbatim: nativeAmountText)
                .font(UniTypography.callout.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
            // Unknown price → "US$0.00", never "Price unavailable" (user
            // direction 2026-06-18). Refines as the price batch resolves.
            Text(verbatim: BalanceFormatter.fiat(token.fiatBalance ?? 0, currencyCode: token.fiatCurrencyCode))
                .font(UniTypography.caption1.monospacedDigit())
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }

    /// "1,234.56 USDC" — up-to-6-fraction-digit, locale-aware grouping,
    /// trailing zeros trimmed. Uses the shared `WalletFormatting.native`
    /// (cached base `FormatStyle`) instead of allocating a
    /// `NumberFormatter` per row render (Rule #28 Part C — 2026-06-14).
    private var nativeAmountText: String {
        "\(WalletFormatting.native(token.amount, decimals: 6)) \(token.symbol)"
    }
}
