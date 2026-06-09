import SwiftUI

/// One row in the wallet-home "Tokens" section — a flat token row,
/// not nested under a chain group. Mirrors `AssetRow`'s anatomy so
/// the Coins section and the Tokens section read as one family of
/// row, distinguished only by what they represent.
///
/// **Why a distinct row (not `HoldingsTokenRow`).** The older
/// `HoldingsTokenRow` carries a treeline because it sits nested under
/// its parent chain's `AssetRow` (the prior Holdings layout). The
/// new layout splits Coins and Tokens into sibling top-level
/// sections — tokens are no longer visually subordinate to a chain.
/// A treeline on a top-level row would read as a navigation cue with
/// no parent to point at; it would mislead. This row is honest about
/// the new flat hierarchy.
///
/// **Visual register (Rule #2 + Rule #7):**
/// - 44pt circular `CoinMark` — same as `AssetRow`. Native sends
///   resolve to the chain's mark; USDC / USDT resolve to bundled
///   stablecoin marks; everything else falls back to an honest
///   3-letter initials chip on `Material.card` (never a fabricated
///   brand mark).
/// - Token symbol in `bodyEmphasized`, `Text.primary` — the
///   loudest text.
/// - "on `<chain.displayName>`" in `footnote`, `Text.secondary` —
///   the network is part of the asset's identity (USDC on Polygon
///   is not USDC on Ethereum — different contracts, different
///   bridges, different costs). Always state it.
/// - Native amount in `monoBody`, `Text.primary` — digits align
///   across rows.
/// - Fiat equivalent in `footnote`, `Text.tertiary` — secondary
///   information.
/// - `Price unavailable` rendered in `Text.tertiary` when the fiat
///   value isn't cached (Rule #16 §A.5 — never fake `$—`).
///
/// **Layout (Rule #11):** semantic edges only. SwiftUI flips the
/// `HStack` automatically in RTL — the mark + symbol block ends up
/// trailing, the amount block ends up leading.
struct TokenHoldingRow: View {
    let chain: SupportedChain
    let balance: TokenBalanceRecord

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: chain,
                tokenSymbol: balance.tokenSymbol,
                contract: balance.tokenContract
            )
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: balance.tokenSymbol)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text("on \(chain.displayName)")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
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
