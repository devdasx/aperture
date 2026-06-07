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
        // Load the token's real brand mark from trustwallet/assets —
        // M-001's authoritative source. Fall back to a monogram
        // bubble while loading and on miss (some tokens aren't in
        // Trust Wallet's repo yet). Both states keep the same 24pt
        // circular footprint so the row never jumps.
        if let url = TrustWalletAssetURL.tokenLogoURL(chain: token.chain, contract: token.contract) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                case .failure, .empty:
                    monogramFallback
                @unknown default:
                    monogramFallback
                }
            }
            .accessibilityHidden(true)
        } else {
            monogramFallback
        }
    }

    @ViewBuilder
    private var monogramFallback: some View {
        ZStack {
            Circle()
                .fill(UniColors.Fill.secondary)
                .frame(width: 24, height: 24)
            Text(verbatim: String(token.symbol.prefix(2)))
                .font(UniTypography.caption2.weight(.semibold))
                .foregroundStyle(UniColors.Text.secondary)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingColumn: some View {
        VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
            Text(verbatim: nativeAmountText)
                .font(UniTypography.callout.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
            if let fiat = token.fiatBalance {
                Text(verbatim: BalanceFormatter.fiat(fiat, currencyCode: token.fiatCurrencyCode))
                    .font(UniTypography.caption1.monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
            } else {
                Text("Price unavailable")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
    }

    /// "1,234.56 USDC" — 4-decimal floor, locale-aware grouping,
    /// trailing zeros trimmed at the high end (Bitcoin-style native
    /// amounts get more precision; stablecoin amounts get less).
    private var nativeAmountText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 6
        formatter.minimumFractionDigits = 0
        let value = NSDecimalNumber(decimal: token.amount)
        let formatted = formatter.string(from: value) ?? "0"
        return "\(formatted) \(token.symbol)"
    }
}
