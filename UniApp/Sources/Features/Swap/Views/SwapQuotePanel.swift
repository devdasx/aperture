import SwiftUI

/// The live-quote detail panel — the honest breakdown of a real
/// `SwapQuote`. Renders the route/provider, the rate, price impact (warned
/// when high), the fee lines, the estimated time (foregrounded for bridges),
/// and the minimum received after slippage. Every number is verbatim from
/// the provider (Rule #16 / #26 — no fabrication).
///
/// **Restraint (Rule #2).** A single quiet card of label/value rows; no
/// decorative chrome. The one moment of color is the price-impact warning,
/// in `Status.warningForeground`, only when the impact is genuinely high.
///
/// **Compact mode (compose vs Review).** The compose screen passes
/// `compact: true` to keep itself scannable — just the three rows a user
/// reads while tuning the trade: rate, price impact, minimum received. The
/// FULL breakdown (route/bridge, time, every fee line, the network-fee
/// summary) stays on the Review screen, which is where the user actually
/// signs — so nothing is hidden before commitment (Rule #16). Review is the
/// default (`compact == false`), so the Review caller inherits the full
/// panel without passing anything.
struct SwapQuotePanel: View {
    let quote: SwapQuote
    let isCrossChain: Bool
    let currencyCode: String
    /// When `true`, show only rate · price impact · minimum received. The
    /// compose screen opts in; Review (default) shows everything.
    var compact: Bool = false

    /// Price impact above this fraction reads as a real warning (1%).
    private let highImpactThreshold = Decimal(0.01)

    var body: some View {
        VStack(spacing: 0) {
            rate
            if !compact {
                UniDivider()
                route
            }
            if let impact = quote.priceImpact {
                UniDivider()
                priceImpactRow(impact)
            }
            if !compact {
                UniDivider()
                timeRow
                ForEach(quote.fees) { fee in
                    UniDivider()
                    feeRow(fee)
                }
                if quote.gasCostUSD > 0 && !hasExplicitGasFee {
                    UniDivider()
                    row(label: Text("Network fee"),
                        value: Text(verbatim: "≈ \(WalletFormatting.fiat(quote.gasCostUSD, currencyCode: currencyCode))"))
                }
            }
            UniDivider()
            minReceivedRow
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Material.card)
        )
    }

    // MARK: - Rows

    private var rate: some View {
        row(
            label: Text("Rate"),
            value: Text(verbatim: rateText)
        )
    }

    /// "1 ETH = 3,412.55 USDC" — the human exchange rate.
    private var rateText: String {
        let formatted = WalletFormatting.native(quote.rate, decimals: min(quote.toToken.decimals, 6))
        return "1 \(quote.fromToken.symbol) = \(formatted) \(quote.toToken.symbol)"
    }

    /// Route line — honest about the provider + the underlying tool/bridge.
    /// Swap → "via <tool>"; bridge → "via <bridge> bridge".
    private var route: some View {
        row(
            label: Text(isCrossChain ? "Bridge" : "Route"),
            value: Text(verbatim: routeText)
        )
    }

    private var routeText: String {
        if isCrossChain {
            let name = quote.bridgeName ?? quote.toolName
            return "via \(name.capitalized)"
        }
        return "via \(quote.toolName.capitalized)"
    }

    private func priceImpactRow(_ impact: Decimal) -> some View {
        let isHigh = impact >= highImpactThreshold
        let pct = impact * 100
        return row(
            label: Text("Price impact"),
            value: HStack(spacing: UniSpacing.xxs) {
                if isHigh {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                }
                Text(verbatim: "\(WalletFormatting.native(pct, decimals: 2))%")
            }
            .foregroundStyle(isHigh ? UniColors.Status.warningForeground : UniColors.Text.primary)
        )
    }

    private var timeRow: some View {
        row(
            label: Text(isCrossChain ? "Estimated time" : "Time"),
            value: Text(verbatim: durationText)
        )
    }

    private var durationText: String {
        let seconds = quote.estimatedDurationSeconds
        if seconds < 60 { return "~\(max(seconds, 1))s" }
        let minutes = (seconds + 30) / 60
        return "~\(minutes) min"
    }

    private func feeRow(_ fee: SwapFee) -> some View {
        row(
            label: Text(verbatim: feeLabel(fee)),
            value: Text(verbatim: feeValue(fee))
        )
    }

    private func feeLabel(_ fee: SwapFee) -> String {
        switch fee.kind {
        case .gas:         return "Network fee"
        case .bridge:      return fee.name.isEmpty ? "Bridge fee" : fee.name
        case .protocolFee: return fee.name.isEmpty ? "Protocol fee" : fee.name
        }
    }

    private func feeValue(_ fee: SwapFee) -> String {
        if fee.amountUSD > 0 {
            return "≈ \(WalletFormatting.fiat(fee.amountUSD, currencyCode: currencyCode))"
        }
        // Token-denominated fallback (no USD): show the decimalised amount
        // through the central 8-decimal-truncated helper. When the provider
        // didn't give us the fee token's decimals (amountDecimal == nil),
        // show "—" rather than a raw base-unit number (Rule #16).
        if let human = fee.amountDecimal, human > 0 {
            let suffix = fee.tokenSymbol.isEmpty ? "" : " \(fee.tokenSymbol)"
            return "\(WalletFormatting.native(human, decimals: WalletFormatting.maxDisplayFractionDigits))\(suffix)"
        }
        return "—"
    }

    /// Whether the provider already gave an explicit gas line (so we don't
    /// duplicate the `gasCostUSD` summary row).
    private var hasExplicitGasFee: Bool {
        quote.fees.contains { $0.kind == .gas }
    }

    private var minReceivedRow: some View {
        row(
            label: Text("Minimum received"),
            value: Text(verbatim: "\(WalletFormatting.native(quote.toAmountMin, decimals: quote.toToken.decimals)) \(quote.toToken.symbol)")
        )
    }

    // MARK: - Row primitive

    private func row(label: Text, value: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            label
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            value
                .font(UniTypography.footnote.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, UniSpacing.s)
    }
}
