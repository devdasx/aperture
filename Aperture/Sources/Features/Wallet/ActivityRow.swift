import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One row in the wallet-home "Recent activity" section. Composed
/// from a `TransactionRecord` (production) or `TransactionEvent`
/// (test mode) plus its parent chain so the leading visual is the
/// real token mark.
///
/// **Visual register (Rule #2 + Rule #7):**
/// - Leading is a **44-pt token mark** resolved through the shared
///   Stabro-style `CoinMark` path — the asset itself is the identity.
///   Bumped from 36→44pt on 2026-06-08
///   per user direction, matching the parallel bump on `AssetRow`
///   so Holdings and Activity rows read as one family. A small
///   **18-pt status badge** overlays the bottom-trailing corner
///   carrying the verb: down arrow incoming, up arrow outgoing, paired-arrow
///   glyph internal, clock pending, ✕ failed. The badge wears a
///   `Background.secondary` halo so it reads as a cutout in the mark,
///   not a floating sticker — the same composition iOS Messages uses
///   for presence dots.
/// - Transaction verb + human relative time in the middle.
/// - Native signed amount + local-currency value on the trailing edge.
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
/// Symbol arrows auto-mirror; the internal-transfer glyph reads correctly either
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
    /// Bridged / Self transfer) instead of the bare token
    /// symbol (2026-06-18 user direction).
    let kind: TransactionKind
    /// The leg's value in the user's local currency (amount × current
    /// spot price), or nil when no price is known. Shown by default; the
    /// user can switch to the native token amount in Settings →
    /// Preferences.
    var fiatValue: Decimal? = nil
    var fiatCurrencyCode: String = "USD"
    /// The leg's ERC-20 / SPL contract (or nil for a native coin). Passed
    /// to `CoinMark` so a TOKEN resolves its exact Trust Wallet logo by
    /// contract — without it, token rows fell back to a text chip
    /// (2026-06-19). Sourced from `TransactionRecord.tokenContract`.
    var tokenContract: String? = nil
    /// The on-chain transaction hash — drives the long-press menu (copy
    /// hash, view on explorer). Empty ("") suppresses those entries, e.g.
    /// for a test-mode event with no real hash. (2026-06-20 user direction.)
    var txHash: String = ""

    @Environment(\.openURL) private var openURL
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            leadingMark

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(title)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: timeLine)
                    .font(UniTypography.footnote)
                    .foregroundStyle(timeColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(signedAmount)
                    .font(UniTypography.monoBody)
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(secondaryLine)
                    .font(UniTypography.footnote)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .uniListRowHitTarget()
        .accessibilityElement(children: .combine)
        // Long-press → copy hash / amount / address, or open the explorer
        // (2026-06-20 user direction). Tap still navigates to the tx detail.
        .contextMenu { transactionActions }
    }

    // MARK: - Long-press actions

    @ViewBuilder
    private var transactionActions: some View {
        if !txHash.isEmpty {
            Button { copyToPasteboard(txHash) } label: {
                Label("Copy hash", systemImage: "number")
            }
        }
        Button { copyToPasteboard(copyableAmount) } label: {
            Label("Copy amount", systemImage: "centsign.circle")
        }
        if !counterparty.isEmpty {
            Button { copyToPasteboard(counterparty) } label: {
                Label("Copy address", systemImage: "doc.on.doc")
            }
        }
        if !txHash.isEmpty, let url = TransactionExplorer.url(for: txHash, chain: chain) {
            Button { openURL(url) } label: {
                Label("View on explorer", systemImage: "safari")
            }
        }
    }

    /// The native on-chain amount + symbol, e.g. "1.5 ETH" — what "Copy
    /// amount" puts on the clipboard (the real moved amount, not a fiat
    /// estimate).
    private var copyableAmount: String {
        "\(WalletFormatting.native(amount, decimals: 6)) \(tokenSymbol)"
    }

    private func copyToPasteboard(_ value: String) {
#if canImport(UIKit)
        SafePasteboard.setString(value)
#endif
        UniHapticEngine.shared.play(.success)
    }

    // MARK: - Leading mark + status badge

    /// Standard token mark + 18pt corner badge (with 22pt halo).
    ///
    /// `ZStack` with `.bottomTrailing` alignment is layout-direction
    /// aware — SwiftUI flips to `.bottomLeading` in RTL automatically
    /// (Rule #11 §B). The badge offset uses positive x in LTR and
    /// SwiftUI re-signs it for RTL.
    ///
    /// The 5pt offset keeps the badge
    /// sitting on the corner of the larger mark rather than crowding
    /// into it.
    private var leadingMark: some View {
        ZStack(alignment: .bottomTrailing) {
            CoinMark(chain: chain, tokenSymbol: tokenSymbol, contract: tokenContract)
                .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)

            statusBadge
                .offset(x: 5, y: 5)
        }
        .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var statusBadge: some View {
        ZStack {
            // 2pt halo: the badge's outer ring matches the row's
            // surface so it reads as a cutout in the mark, not a
            // floating chip. Total footprint = 18 + 2*2 = 22pt.
            //
            // Halo matches the list card fill (`List.rowBackground` /
            // `Card.background` — same Midnight token `#212229`) so the
            // badge reads as cut out of the inset card, not ringed
            // against the page color or a system-dark default.
            Circle()
                .fill(UniColors.List.rowBackground)
                .frame(width: 22, height: 22)
            Circle()
                .fill(UniColors.List.rowBackground)
                .frame(width: 18, height: 18)
            Image(systemName: badgeGlyph)
                .font(.system(size: 11, weight: .regular))
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
            case .internal: return "arrow.left.arrow.right"
            }
        }
    }

    private var badgeForeground: Color {
        switch status {
        case .pending: return UniColors.Feedback.Warning.foreground
        case .failed:  return UniColors.Feedback.Error.foreground
        case .confirmed:
            switch direction {
            case .incoming: return UniColors.Feedback.Success.foreground
            case .outgoing: return UniColors.Text.primary
            case .internal: return UniColors.Text.secondary
            }
        }
    }

    // MARK: - Trailing column

    /// Row title — the transaction verb, composed from kind + direction:
    /// Bridged / Self transfer / Received / Sent.
    private var title: LocalizedStringKey {
        switch kind {
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

    /// Left subtitle — time only. Token/network details stay available in
    /// the transaction detail screen; this row keeps the scan path focused
    /// on what happened, when, and how much.
    private var timeLine: String {
        let relative = WalletFormatting.activityRelativeTime(occurredAt)
        switch status {
        case .confirmed:
            return relative
        case .pending:
            return "\(String.apertureLocalized("Pending")) · \(relative)"
        case .failed:
            // P2-006: on-chain failure / revert is "Failed", not user "Canceled".
            return "\(String.apertureLocalized("Failed")) · \(relative)"
        }
    }

    /// Signed amount — always the native on-chain amount. The local-currency
    /// estimate now lives on the trailing subtitle so activity rows show both
    /// values at once.
    private var signedAmount: String {
        "\(amountSign)\(WalletFormatting.native(amount, decimals: 6, hidden: hideBalances)) \(tokenSymbol)"
    }

    private var amountSign: String {
        switch direction {
        case .incoming: return "+"
        case .outgoing: return "−" // U+2212 minus sign (renders better than ASCII hyphen)
        case .internal: return ""
        }
    }

    private var amountColor: Color {
        switch (status, direction) {
        case (.failed, _):   return UniColors.Feedback.Error.foreground
        case (_, .incoming): return UniColors.Crypto.up
        case (_, .outgoing): return UniColors.Text.primary
        case (_, .internal): return UniColors.Text.primary
        }
    }

    private var secondaryLine: String {
        guard let fiatValue else {
            return String.apertureLocalized("Price unavailable")
        }
        return "\(amountSign)\(WalletFormatting.fiat(fiatValue, currencyCode: fiatCurrencyCode, hidden: hideBalances))"
    }

    private var secondaryColor: Color {
        UniColors.Text.tertiary
    }

    private var timeColor: Color {
        switch status {
        case .pending:   return UniColors.Feedback.Warning.foreground
        case .failed:    return UniColors.Feedback.Error.foreground
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
        let normalizedCurrency = currency.uppercased()
        var map: [String: Decimal] = [:]
        for row in prices where row.fiat.uppercased() == normalizedCurrency {
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

    // MARK: - Dust filter

    /// Hide any transaction worth **less than $0.20 USD** on every activity
    /// surface (home recent, full activity, asset activity). **Always USD**,
    /// never the display currency: when the user picks JOD/EUR/etc., we still
    /// price the leg in USD so the gate is identical worldwide. Displayed
    /// fiat amounts keep using the active-currency map (USD×FX from
    /// `TokenPricingEngine`).
    static let usdDustThreshold = Decimal(string: "0.20")!

    /// `true` when the leg must not appear in activity.
    ///
    /// - **No USD price yet** → dust (hide). Prevents sub-$0.20 spam from
    ///   flashing before prices load, then vanishing (P1 #11).
    /// - **USD value known and < $0.20** → dust (hide). Never shown.
    /// - **USD value ≥ $0.20** → keep.
    ///
    /// Seed `usdMap` with `usdPriceMapFromCache` on first frame, then refresh
    /// via `usdPriceMap` so prices are almost always present immediately.
    static func isDust(amountRaw: String, symbol: String, usdMap: [String: Decimal]) -> Bool {
        guard let usd = value(amountRaw: amountRaw, symbol: symbol, map: usdMap) else {
            return true
        }
        return usd < usdDustThreshold
    }

    /// Synchronous USD unit prices from disk cache + stablecoin pegs.
    /// Call before the first activity render so the dust gate never sees an
    /// empty map when the wallet has already priced those symbols.
    static func usdPriceMapFromCache(
        symbols: [String],
        database: AppDatabase = .shared
    ) -> [String: Decimal] {
        let unique = Array(Set(symbols.map { $0.uppercased() }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }

        var map: [String: Decimal] = [:]
        // Known USD-pegged stables are $1 even with a cold price cache.
        for symbol in unique where KnownStablecoins.all.contains(symbol) || symbol == "USDT" {
            map[symbol] = 1
        }

        if let disk = try? PriceCacheRepository(database: database)
            .prices(symbols: unique, fiat: "USD")
        {
            for (symbol, entry) in disk where entry.price > 0 {
                map[symbol] = entry.price
            }
        }

        // Wrapped aliases (WETH → ETH) when the wrapper lacks a direct row.
        for symbol in unique where map[symbol] == nil {
            let underlying = WrappedAssetAliases.resolveSymbol(symbol)
            if underlying != symbol, let price = map[underlying], price > 0 {
                map[symbol] = price
            } else if let disk = try? PriceCacheRepository(database: database)
                .price(symbol: underlying, fiat: "USD"),
                      disk.price > 0
            {
                map[symbol] = disk.price
            }
        }
        return map
    }

    /// USD unit prices for dust filtering: disk/stablecoin seed first, then
    /// live `TokenPricingEngine` (USD storage currency). Display currency is
    /// still `priceMap` / engine with the user's fiat (USD×FX).
    static func usdPriceMap(symbols: [String]) async -> [String: Decimal] {
        let unique = Array(Set(symbols.map { $0.uppercased() }.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }
        var map = usdPriceMapFromCache(symbols: unique)
        let resolved = await TokenPricingEngine.shared.unitPrices(
            symbols: unique,
            currencyCode: "USD"
        )
        for (symbol, price) in resolved where price.amount > 0 {
            map[symbol] = price.amount
        }
        return map
    }
}
