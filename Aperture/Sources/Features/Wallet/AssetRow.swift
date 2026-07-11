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
                Text(WalletFormatting.native(nativeAmount, decimals: nativeDecimals, hidden: hideBalances))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                fiatLabel
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

    private var fiatLabel: some View {
        // Zero or unpriced → "US$0.00" (0 units is worth exactly $0.00 —
        // no price needed; never the "Price unavailable" eyesore, user
        // direction 2026-06-18). `fiatCurrencyCode` is always the active
        // currency, even on an unheld row, so the format is correct.
        Text(WalletFormatting.fiat(fiatValue ?? 0, currencyCode: fiatCurrencyCode, hidden: hideBalances))
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Text.tertiary)
            .monospacedDigit()
    }
}

// MARK: - Equatable (2026-06-18, Part 3.5)

/// `AssetRow` is value-typed, so wallet-home renders it via `.equatable()` to
/// skip re-evaluating the row's body (logo + labels) when its inputs are
/// unchanged — i.e. on the many GRDB merges a holdings row doesn't depend
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
            && lhs.detailCaption == rhs.detailCaption
    }
}
