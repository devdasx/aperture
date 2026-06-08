import SwiftUI

/// One row in the wallet-home "Recent activity" section. Composed
/// from a `TransactionRecord` (production) or `TransactionEvent`
/// (test mode) plus its parent chain so the leading visual is the
/// real token mark.
///
/// **Visual register (Rule #2 + Rule #7):**
/// - Leading is a **36-pt token mark** (the bundled `Crypto/<ticker>`
///   asset — `Crypto/eth`, `Crypto/btc`, `Crypto/usdc`, …) — the
///   asset itself is the identity. A small **14-pt status badge**
///   overlays the bottom-trailing corner carrying the verb: down
///   arrow incoming, up arrow outgoing, swap glyph internal, clock
///   pending, ✕ failed. The badge wears a `Background.primary` halo
///   so it reads as a cutout in the mark, not a floating sticker —
///   the same composition iOS Messages uses for presence dots.
/// - Token symbol + truncated counterparty in middle.
/// - Signed amount + relative time on trailing edge.
/// - Pending status surfaces "Pending" under the time;
///   failed surfaces "Failed" in `Status.errorForeground`.
///
/// **Color discipline (Rule #4):**
/// - Incoming badge glyph: `Status.successForeground` (green).
/// - Outgoing badge glyph: `Text.primary` (graphite — NOT red;
///   sending is a deliberate user action, never a problem).
/// - Internal badge glyph: `Text.secondary`.
/// - Pending badge glyph: `Status.warningForeground` (orange — "in
///   progress, watch it" beats gray "nothing").
/// - Failed badge glyph: `Status.errorForeground` (the one case where
///   red is the truth — the action did not succeed).
///
/// **Layout (Rule #11):** semantic edges only. The badge follows the
/// mark to the bottom-trailing in LTR and bottom-leading in RTL —
/// the verb stays anchored to the token in either direction. SF
/// Symbol arrows auto-mirror; the swap glyph reads correctly either
/// way.
struct ActivityRow: View {
    let chain: SupportedChain
    let direction: TransactionDirection
    let amount: Decimal
    let tokenSymbol: String
    let counterparty: String
    let occurredAt: Date
    let status: TransactionStatus

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            leadingMark

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

    // MARK: - Leading mark + status badge

    /// 36pt token mark + 14pt corner badge.
    ///
    /// `ZStack` with `.bottomTrailing` alignment is layout-direction
    /// aware — SwiftUI flips to `.bottomLeading` in RTL automatically
    /// (Rule #11 §B). The badge offset uses positive x in LTR and
    /// SwiftUI re-signs it for RTL.
    private var leadingMark: some View {
        ZStack(alignment: .bottomTrailing) {
            CoinMark(chain: chain, tokenSymbol: tokenSymbol)
                .frame(width: 36, height: 36)

            statusBadge
                // Outset the badge ~4pt beyond the mark's circumference
                // so it sits on the corner rather than inside it.
                .offset(x: 4, y: 4)
        }
        .frame(width: 36, height: 36, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var statusBadge: some View {
        ZStack {
            // 2pt halo: the badge's outer ring matches the row's
            // surface so it reads as a cutout in the mark, not a
            // floating chip. Total footprint = 14 + 2*2 = 18pt.
            Circle()
                .fill(UniColors.Background.primary)
                .frame(width: 18, height: 18)
            Circle()
                .fill(UniColors.Material.card)
                .frame(width: 14, height: 14)
            Image(systemName: badgeGlyph)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(badgeForeground)
        }
    }

    private var badgeGlyph: String {
        switch status {
        case .pending: return "clock.fill"
        case .failed:  return "xmark"
        case .confirmed:
            switch direction {
            case .incoming: return "arrow.down"
            case .outgoing: return "arrow.up"
            case .internal: return "arrow.triangle.swap"
            }
        }
    }

    private var badgeForeground: Color {
        switch status {
        case .pending: return UniColors.Status.warningForeground
        case .failed:  return UniColors.Status.errorForeground
        case .confirmed:
            switch direction {
            case .incoming: return UniColors.Status.successForeground
            case .outgoing: return UniColors.Text.primary
            case .internal: return UniColors.Text.secondary
            }
        }
    }

    // MARK: - Trailing column

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

// MARK: - CoinMark

/// Resolves a `(chain, tokenSymbol)` pair to a bundled coin mark and
/// renders it at the caller's frame. Native sends fall through to the
/// chain's own logo (`chain.logoAssetName`); known stablecoin
/// transfers (USDC, USDT) route to the bundled token marks. Anything
/// else — DAI, random ERC-20s, on-chain tokens we haven't bundled —
/// falls back to an honest initials chip on `Material.card`.
///
/// **Honesty (Rule #7).** The fallback chip names the token by its
/// ticker, never invents a brand mark. A user who sees "DAI" on a
/// neutral chip knows we don't ship a logo for it; a user who sees a
/// fabricated yellow circle with a "D" inside would be lied to.
private struct CoinMark: View {
    let chain: SupportedChain
    let tokenSymbol: String

    var body: some View {
        if let assetName = resolvedAssetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .clipShape(Circle())
        } else {
            initialsChip
        }
    }

    /// The bundled asset name for this `(chain, symbol)` pair, or nil
    /// if the symbol is a token we don't ship a mark for.
    private var resolvedAssetName: String? {
        // Native sends: the symbol matches the chain's native ticker.
        // Compare uppercased to match the chain.ticker convention.
        if tokenSymbol.uppercased() == chain.ticker.uppercased() {
            return chain.logoAssetName
        }
        // Token transfers — only stablecoins we explicitly ship.
        switch tokenSymbol.uppercased() {
        case "USDC": return "Crypto/usdc"
        case "USDT": return "Crypto/usdt"
        default:     return nil
        }
    }

    /// Up-to-3-letter initials chip. Renders the ticker on a neutral
    /// `Material.card` disk — the same disk color as the surrounding
    /// activity card, so the chip reads as restrained, not loud.
    private var initialsChip: some View {
        Circle()
            .fill(UniColors.Material.card)
            .overlay {
                Text(initials)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            }
    }

    private var initials: String {
        let trimmed = tokenSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "—" }
        // Cap at 3 chars; longer tickers (e.g. wstETH) compress to the
        // first three letters which still read as the asset's family.
        return String(trimmed.prefix(3)).uppercased()
    }
}
