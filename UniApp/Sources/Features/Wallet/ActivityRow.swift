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
    /// Transaction taxonomy — drives the row TITLE (Sent / Received /
    /// Swapped / Bridged / Self transfer) instead of the bare token
    /// symbol (2026-06-18 user direction).
    let kind: TransactionKind
    /// The leg's value in the user's local currency (amount × current
    /// spot price), or nil when no price is known. Shown by default; the
    /// user can switch to the native token amount in Settings →
    /// Preferences.
    var fiatValue: Decimal? = nil
    var fiatCurrencyCode: String = "USD"

    /// Settings → Preferences toggle (default on): show the activity
    /// amount in the user's local currency. Off shows the native token
    /// amount. Read here so every activity surface honors the choice
    /// without threading it through each call site.
    @AppStorage("txAmountsInLocalCurrency") private var showAmountsInFiat: Bool = true

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            leadingMark

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(title)
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

    /// Row title — the transaction verb, composed from kind + direction:
    /// Swapped / Bridged / Self transfer / Received / Sent.
    private var title: LocalizedStringKey {
        switch kind {
        case .swap:         return "Swapped"
        case .bridge:       return "Bridged"
        case .selfTransfer: return "Self transfer"
        case .transfer:
            switch direction {
            case .incoming: return "Received"
            case .outgoing: return "Sent"
            case .internal: return "Self transfer"
            }
        }
    }

    /// Signed amount — the local-currency value by default (Preferences
    /// toggle), falling back to the native token amount when fiat display
    /// is off OR no price is known for the symbol (Rule #16 — never guess
    /// a value, show the real on-chain amount instead).
    private var signedAmount: String {
        let sign: String
        switch direction {
        case .incoming: sign = "+"
        case .outgoing: sign = "−" // U+2212 minus sign (renders better than ASCII hyphen)
        case .internal: sign = ""
        }
        if showAmountsInFiat, let fiat = fiatValue {
            return "\(sign)\(WalletFormatting.fiat(fiat, currencyCode: fiatCurrencyCode))"
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

// MARK: - ActivityFiat

/// Shared fiat valuation for transaction-history rows. The spot-price
/// cache (`CachedPriceRecord`) already stores a price per (symbol, fiat);
/// each activity surface builds a symbol→unit-price map ONCE in its body
/// (filtered to the user's currency) and values each leg against it — so
/// the row stays a dumb value view and we never run an O(N) price scan
/// per row.
///
/// **Honesty (Rule #16):** the value is the leg's amount converted at the
/// CURRENT spot rate — Aperture doesn't persist a fiat-at-time on the
/// ledger. A nil result means there's no price for that symbol in the
/// user's currency yet; the row then shows the native amount, never a
/// fabricated value.
enum ActivityFiat {
    /// symbol (uppercased) → unit price in `currency`, from the spot cache.
    static func priceMap(_ prices: [CachedPriceRecord], currency: String) -> [String: Decimal] {
        var map: [String: Decimal] = [:]
        for row in prices where row.fiat == currency {
            map[row.symbol.uppercased()] = row.price
        }
        return map
    }

    /// Fiat value of a leg's `amountRaw` (decimal string) of `symbol`
    /// against a prebuilt `map`; nil when no positive price is known.
    static func value(amountRaw: String, symbol: String, map: [String: Decimal]) -> Decimal? {
        guard let price = map[symbol.uppercased()], price > 0,
              let amount = Decimal(string: amountRaw) else { return nil }
        return amount * price
    }
}
