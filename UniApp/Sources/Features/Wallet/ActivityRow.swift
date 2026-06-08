import SwiftUI

/// One row in the wallet-home "Recent activity" section. Composed
/// from a `TransactionRecord` (production) or `TransactionEvent`
/// (test mode) plus its parent chain so the leading visual is the
/// real token mark.
///
/// **Visual register (Rule #2 + Rule #7):**
/// - Leading is a **44-pt token mark** (the bundled `Crypto/<ticker>`
///   asset — `Crypto/eth`, `Crypto/btc`, `Crypto/usdc`, …) — the
///   asset itself is the identity. Bumped from 36→44pt on 2026-06-08
///   per user direction, matching the parallel bump on `AssetRow`
///   so Holdings and Activity rows read as one family. A small
///   **18-pt status badge** overlays the bottom-trailing corner
///   carrying the verb: down arrow incoming, up arrow outgoing, swap
///   glyph internal, clock pending, ✕ failed. The badge wears a
///   `Background.secondary` halo so it reads as a cutout in the mark,
///   not a floating sticker — the same composition iOS Messages uses
///   for presence dots.
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

    /// 44pt token mark + 18pt corner badge (with 22pt halo).
    ///
    /// `ZStack` with `.bottomTrailing` alignment is layout-direction
    /// aware — SwiftUI flips to `.bottomLeading` in RTL automatically
    /// (Rule #11 §B). The badge offset uses positive x in LTR and
    /// SwiftUI re-signs it for RTL.
    ///
    /// The 5pt offset (was 4pt at the 36pt mark size) keeps the badge
    /// sitting on the corner of the larger mark rather than crowding
    /// into it.
    private var leadingMark: some View {
        ZStack(alignment: .bottomTrailing) {
            CoinMark(chain: chain, tokenSymbol: tokenSymbol)
                .frame(width: 44, height: 44)

            statusBadge
                .offset(x: 5, y: 5)
        }
        .frame(width: 44, height: 44, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var statusBadge: some View {
        ZStack {
            // 2pt halo: the badge's outer ring matches the row's
            // surface so it reads as a cutout in the mark, not a
            // floating chip. Total footprint = 18 + 2*2 = 22pt.
            //
            // Halo color is `Background.secondary` because the row
            // now lives inside `List(.insetGrouped)`, whose row chrome
            // is the secondary-grouped-background tone. The badge
            // reads as cut out of the white inset card; if the halo
            // were `Background.primary` (the page color), the user
            // would see a thin gray ring around the badge.
            Circle()
                .fill(UniColors.Background.secondary)
                .frame(width: 22, height: 22)
            Circle()
                .fill(UniColors.Material.card)
                .frame(width: 18, height: 18)
            Image(systemName: badgeGlyph)
                .font(.system(size: 11, weight: .bold))
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

// `CoinMark` (the `(chain, tokenSymbol)` → bundled-mark-or-honest-chip
// view) lives in `CoinMark.swift` so both `ActivityRow` and
// `TokenHoldingRow` can compose against the same resolution. Promoted
// to internal 2026-06-08 with the Coins / Tokens split.
