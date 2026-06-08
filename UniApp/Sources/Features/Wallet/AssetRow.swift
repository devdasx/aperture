import SwiftUI

/// One row in the wallet-home holdings list: a chain logo, a token
/// ticker + chain name, the native amount, and the fiat equivalent.
///
/// **Visual register (Rule #2):**
/// - 44-pt circular logo (bundled Trust Wallet asset; `circle.dashed`
///   fallback for chains without a bundled mark). Bumped from 32→44pt
///   on 2026-06-08 per user direction — the larger size makes the
///   asset identity announce itself at a glance and matches the
///   iOS list-row leading-visual rhythm of Mail / Photos / Health
///   (44pt is also the iOS standard touch-target floor).
/// - Ticker is the loudest text; chain name in `Text.secondary`.
/// - Native amount in `monoBody` (digits align across rows).
/// - Fiat equivalent in `Text.tertiary` — secondary information.
/// - `Price unavailable` rendered in `Text.tertiary` when the fiat
///   value is unknown (Rule #16 §A.5 — never fake `$—`).
///
/// **Layout (Rule #11):** semantic edges only (`leading`/`trailing`).
/// In RTL the chevron flips automatically; the logo+ticker block and
/// the amount block swap positions.
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

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            logo

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(tokenSymbol)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(chain.displayName)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(WalletFormatting.native(nativeAmount, decimals: nativeDecimals))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                fiatLabel
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var logo: some View {
        if let asset = chain.logoAssetName {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle.dashed")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var fiatLabel: some View {
        if let fiatValue, fiatValue > 0 {
            Text(WalletFormatting.fiat(fiatValue, currencyCode: fiatCurrencyCode))
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .monospacedDigit()
        } else {
            Text("Price unavailable")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }
}
