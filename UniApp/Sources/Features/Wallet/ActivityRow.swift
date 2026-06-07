import SwiftUI

/// One row in the wallet-home "Recent activity" section. Composed
/// from a `TransactionRecord` plus its parent chain (for the leading
/// chain-logo overlay).
///
/// **Visual register:**
/// - Direction glyph (`arrow.down.left` incoming, `arrow.up.right`
///   outgoing, `arrow.triangle.swap` internal) in a circular
///   `Status` background — green for incoming, secondary for
///   outgoing, neutral for internal. Subtle, not loud.
/// - Token symbol + truncated counterparty in middle.
/// - Signed amount + relative time on trailing edge.
/// - Pending status surfaces a quiet "Pending" footnote under the time.
/// - Failed status surfaces "Failed" in `Status.errorForeground`.
struct ActivityRow: View {
    let direction: TransactionDirection
    let amount: Decimal
    let tokenSymbol: String
    let counterparty: String
    let occurredAt: Date
    let status: TransactionStatus

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            directionGlyph

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(tokenSymbol)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(WalletFormatting.shortAddress(counterparty))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(signedAmount)
                    .font(UniTypography.monoBody)
                    .foregroundStyle(amountColor)
                Text(secondaryLine)
                    .font(UniTypography.footnote)
                    .foregroundStyle(secondaryColor)
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var directionGlyph: some View {
        ZStack {
            Circle()
                .fill(glyphBackground)
                .frame(width: 32, height: 32)
            Image(systemName: glyphName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(glyphForeground)
        }
        .accessibilityHidden(true)
    }

    private var glyphName: String {
        switch direction {
        case .incoming: return "arrow.down.left"
        case .outgoing: return "arrow.up.right"
        case .internal: return "arrow.triangle.swap"
        }
    }

    private var glyphBackground: Color {
        switch direction {
        case .incoming: return UniColors.Status.successBackground
        case .outgoing: return UniColors.Fill.secondary
        case .internal: return UniColors.Status.neutralBackground
        }
    }

    private var glyphForeground: Color {
        switch direction {
        case .incoming: return UniColors.Status.successForeground
        case .outgoing: return UniColors.Text.primary
        case .internal: return UniColors.Status.neutralForeground
        }
    }

    private var signedAmount: String {
        let sign: String
        switch direction {
        case .incoming: sign = "+"
        case .outgoing: sign = "−" // U+2212 minus sign (renders better than ASCII hyphen)
        case .internal: sign = ""
        }
        return "\(sign)\(WalletFormatting.native(amount, decimals: 6)) \(tokenSymbol)"
    }

    private var amountColor: Color {
        switch (status, direction) {
        case (.failed, _):   return UniColors.Status.errorForeground
        case (_, .incoming): return UniColors.Crypto.up
        case (_, .outgoing): return UniColors.Text.primary
        case (_, .internal): return UniColors.Text.primary
        }
    }

    private var secondaryLine: String {
        switch status {
        case .pending:
            return String.apertureLocalized("Pending")
        case .failed:
            return String.apertureLocalized("Failed")
        case .confirmed:
            return WalletFormatting.relativeTime(occurredAt)
        }
    }

    private var secondaryColor: Color {
        switch status {
        case .pending:   return UniColors.Status.warningForeground
        case .failed:    return UniColors.Status.errorForeground
        case .confirmed: return UniColors.Text.tertiary
        }
    }
}
