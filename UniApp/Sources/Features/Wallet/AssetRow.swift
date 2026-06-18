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
                // 2026-06-17 — full NAME is the title, SHORT NAME (ticker)
                // the subtitle (user direction; matches the asset pickers).
                Text(chain.displayName)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(tokenSymbol)
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

    private var fiatLabel: some View {
        // Zero or unpriced → "US$0.00" (0 units is worth exactly $0.00 —
        // no price needed; never the "Price unavailable" eyesore, user
        // direction 2026-06-18). `fiatCurrencyCode` is always the active
        // currency, even on an unheld row, so the format is correct.
        Text(WalletFormatting.fiat(fiatValue ?? 0, currencyCode: fiatCurrencyCode))
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Text.tertiary)
            .monospacedDigit()
    }
}

// MARK: - Equatable (2026-06-18, Part 3.5)

/// `AssetRow` is value-typed, so wallet-home renders it via `.equatable()` to
/// skip re-evaluating the row's body (logo + labels) when its inputs are
/// unchanged — i.e. on the many SwiftData merges a holdings row doesn't depend
/// on. `nonisolated` because `Equatable.==` is a nonisolated requirement while
/// a SwiftUI `View` is main-actor-isolated under Swift 6; it reads only the
/// row's Sendable value inputs.
extension AssetRow: Equatable {
    nonisolated static func == (lhs: AssetRow, rhs: AssetRow) -> Bool {
        lhs.chain == rhs.chain
            && lhs.tokenSymbol == rhs.tokenSymbol
            && lhs.nativeAmount == rhs.nativeAmount
            && lhs.nativeDecimals == rhs.nativeDecimals
            && lhs.fiatValue == rhs.fiatValue
            && lhs.fiatCurrencyCode == rhs.fiatCurrencyCode
    }
}
