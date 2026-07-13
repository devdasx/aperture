import SwiftUI

/// One row in the wallet-home holdings list: a chain logo, a token
/// ticker + chain name, the native amount, and the fiat equivalent.
///
/// **Visual register (Rule #2):**
/// - Standard circular logo (bundled Trust Wallet asset; initials
///   fallback for chains without a bundled mark). Uses
///   `AssetLogoMetrics.standard`, matching the Markets screen.
/// - Ticker is the loudest text; chain name in `Text.secondary`.
/// - Native amount in `monoBody` (digits align across rows).
/// - Fiat equivalent in `Text.tertiary` — secondary information.
/// - `Price unavailable` rendered in `Text.tertiary` when the fiat
///   value is unknown (Rule #16 §A.5 — never fake `$—`).
///
/// **Layout (Rule #11):** semantic edges only (`leading`/`trailing`).
/// In RTL the chevron flips automatically; the logo+ticker block and
/// the amount block trade positions.
struct AssetRow: View {
    let chain: SupportedChain
    let tokenSymbol: String
    /// Native amount as a `Decimal` (already divided by 10^decimals).
    let nativeAmount: Decimal
    /// Decimal places to render for the native amount.
    let nativeDecimals: Int
    /// Cached fiat-equivalent value. `nil` ⇒ "Price unavailable".
    let fiatValue: Decimal?
    /// Currency code for `fiatValue` rendering.
    let fiatCurrencyCode: String
    /// Optional third line under the ticker (e.g. Solana dual-path
    /// breakdown: `Phantom 1.2 · Trust 0.5`). `nil` for single-path rows.
    let detailCaption: String?
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    init(
        chain: SupportedChain,
        tokenSymbol: String,
        nativeAmount: Decimal,
        nativeDecimals: Int,
        fiatValue: Decimal?,
        fiatCurrencyCode: String,
        detailCaption: String? = nil
    ) {
        self.chain = chain
        self.tokenSymbol = tokenSymbol
        self.nativeAmount = nativeAmount
        self.nativeDecimals = nativeDecimals
        self.fiatValue = fiatValue
        self.fiatCurrencyCode = fiatCurrencyCode
        self.detailCaption = detailCaption
    }

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            logo

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                // 2026-06-17 — full NAME is the title, SHORT NAME (ticker)
                // the subtitle (user direction; matches the asset pickers).
                Text(chain.displayName)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(tokenSymbol)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                if let detailCaption, !detailCaption.isEmpty {
                    Text(verbatim: detailCaption)
                        .font(UniTypography.caption2)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                PrivacySensitiveAmount(
                    text: WalletFormatting.native(nativeAmount, decimals: nativeDecimals),
                    font: UniTypography.monoBody,
                    color: UniColors.Text.primary,
                    isHidden: hideBalances
                )
                PrivacySensitiveAmount(
                    text: WalletFormatting.fiat(fiatValue ?? 0, currencyCode: fiatCurrencyCode),
                    font: UniTypography.footnote,
                    color: UniColors.Text.tertiary,
                    isHidden: hideBalances
                )
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .uniListRowHitTarget()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var logo: some View {
        CoinMark(chain: chain, tokenSymbol: tokenSymbol)
            .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
            .accessibilityHidden(true)
    }
}

// Equatable intentionally omitted: `balancePrivacyEnabled` is environment-
// driven. `.equatable()` would skip body when only privacy flips, so hide
// animation on coins would never run.
