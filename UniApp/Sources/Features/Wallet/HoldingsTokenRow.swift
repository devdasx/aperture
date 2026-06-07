import SwiftUI

/// Indented token sub-row in the wallet-home "Holdings" card. Sits
/// directly under its parent chain's `AssetRow`; carries a leading
/// treeline (a thin vertical rule) so the parent/child relationship
/// reads at a glance — the same cue established in
/// `ReviewTokenRow` on the Import → Review screen, propagated here
/// so the user feels one app, not two.
///
/// **Visual register (Rule #2):**
/// - Treeline width 2pt, `Fill.tertiary`, height 28pt so it visually
///   spans the row.
/// - 24pt symbol bubble (smaller than the chain's 32pt logo) — the
///   sub-row is a quieter element, not a peer.
/// - Token symbol in `bodyEmphasized`, `Text.primary`. Chain name
///   in `caption2`, `Text.tertiary`.
/// - Native amount in `monoBody`, fiat-equivalent in `footnote`.
/// - `Price unavailable` rendered in `Text.tertiary` when the fiat
///   value isn't cached (Rule #16 §A.5 — never fake `$—`).
///
/// **Layout (Rule #11):** semantic edges only. In RTL the treeline
/// stays leading (which is right in RTL), the token bubble follows
/// the treeline, and the amount column trails.
struct HoldingsTokenRow: View {
    let chain: SupportedChain
    let balance: TokenBalanceRecord

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            treeline

            symbolBubble

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: balance.tokenSymbol)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text("on \(chain.displayName)")
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(WalletFormatting.native(
                    WalletFormatting.decimalAmount(
                        rawBalance: balance.rawBalance,
                        decimals: balance.decimals
                    ),
                    decimals: min(balance.decimals, 8)
                ))
                .font(UniTypography.monoBody)
                .foregroundStyle(UniColors.Text.primary)
                fiatLabel
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var treeline: some View {
        Rectangle()
            .fill(UniColors.Fill.tertiary)
            .frame(width: 2, height: 28)
            .padding(.leading, UniSpacing.xs)
            .padding(.trailing, UniSpacing.xxs)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var symbolBubble: some View {
        // 24pt monogram bubble. We deliberately do NOT fetch token
        // logos from Trust Wallet here (that's an `AsyncImage` per
        // row, and the wallet home is the most-touched surface in
        // the app — every animation frame would re-evaluate the
        // image task). The Asset Detail screen — when it lands — is
        // where the full-color token logo belongs.
        ZStack {
            Circle()
                .fill(UniColors.Fill.secondary)
                .frame(width: 24, height: 24)
            Text(verbatim: monogramLetter)
                .font(UniTypography.caption2)
                .foregroundStyle(UniColors.Text.secondary)
        }
        .accessibilityHidden(true)
    }

    private var monogramLetter: String {
        balance.tokenSymbol.prefix(1).uppercased()
    }

    @ViewBuilder
    private var fiatLabel: some View {
        if balance.fiatValueCached > 0 {
            Text(WalletFormatting.fiat(
                balance.fiatValueCached,
                currencyCode: balance.fiatCurrencyCode
            ))
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
