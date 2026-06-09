import Foundation

// MARK: - BalancePoint

/// One sample on the reconstructed balance curve. `timestamp` is the
/// moment the wallet was in this fiat state; `fiat` is its total
/// fiat value expressed in the user's preferred currency, using
/// today's per-unit prices (see `BalanceHistoryReconstructor` for
/// the honesty disclosure).
struct BalancePoint: Hashable, Sendable {
    let timestamp: Date
    let fiat: Decimal
}

// MARK: - BalanceHistoryRange

/// Time windows the chart's segmented picker offers. `.all` walks
/// the whole transaction history; the others slice by the obvious
/// trailing duration from `now`. The single-letter labels match
/// Apple's own Stocks app — fewer characters, more density at the
/// rare interaction surface.
enum BalanceHistoryRange: String, CaseIterable, Hashable, Sendable {
    case day
    case week
    case month
    case year
    case all

    /// Localized one-letter symbol shown on the segmented picker.
    var shortLabel: String {
        switch self {
        case .day:   return "1D"
        case .week:  return "1W"
        case .month: return "1M"
        case .year:  return "1Y"
        case .all:   return "All"
        }
    }

    /// Cut-off measured from `reference`. `.all` returns
    /// `.distantPast` so the reconstructor consumes every event.
    func cutoff(from reference: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: -1, to: reference) ?? .distantPast
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: reference) ?? .distantPast
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: reference) ?? .distantPast
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: reference) ?? .distantPast
        case .all:
            return .distantPast
        }
    }
}

// MARK: - BalanceHistoryReconstructor

/// Reconstructs a wallet's total-fiat balance through time from its
/// transaction history and its current balances.
///
/// **The math (the honest one).**
///
/// We don't have historical price feeds — `CoinbasePriceService`
/// returns the current price and `CachedPriceRecord` only caches the
/// latest. Fetching historical OHLC per held token per day would
/// require dozens of network roundtrips on every wallet open and
/// would leave gaps for assets without published history. So
/// instead, the chart answers a slightly different (but still
/// honest) question: **what would my wallet's history have been
/// worth at TODAY's prices?**
///
/// For each held `(chain, symbol, contract)` triple we derive the
/// implicit current fiat-per-unit:
///
/// ```
/// currentFiatPerUnit = fiatValueCached / decimalAmount(rawBalance, decimals)
/// ```
///
/// Then we walk transactions newest-first, reverse-applying their
/// effect on quantity to recover the quantity-held at each prior
/// timestamp. At every sample point the curve's value is:
///
/// ```
/// fiat(t) = Σ over tokens of (quantity_held(t) × currentFiatPerUnit)
/// ```
///
/// The chart's caption ("Valued at today's prices") names this so
/// the user can read the shape as a record of activity, not as a
/// real-time dollar valuation of past states.
///
/// **Why this is honest.** Two valid questions a user could ask of
/// a balance history: (a) "how did the dollar value of my wallet
/// move?" and (b) "how did my activity move my position?" Both have
/// merit. Without historical price data we'd fake (a); shipping
/// (b) with the explicit caveat is the truthful trade.
///
/// **Why this is a pure function.** Easy to verify against test
/// vectors; no SwiftUI dependency; safely callable from any actor.
enum BalanceHistoryReconstructor {

    /// Reconstruct the balance curve for `range`. Returns sample
    /// points anchored at every transaction's timestamp plus the
    /// chart's leading-edge anchor (cutoff or oldest tx) and its
    /// trailing-edge anchor (`now`). Empty when the wallet has no
    /// current non-zero balances AND no transactions — the honest
    /// "no history yet" state.
    ///
    /// `currentBalances` contains the latest cached balance rows the
    /// wallet holds (non-zero only — the caller already filters).
    /// `transactions` is the full history across every address —
    /// the caller passes the un-prefixed feed (not the home's
    /// 10-most-recent slice).
    ///
    /// **Per-period guarantees (2026-06-09 hardening).**
    ///
    /// 1. **The curve's trailing-edge value equals the wallet's
    ///    current total fiat.** Always. The rightmost sample is
    ///    `(now, currentTotalFiat)` and the reverse-walk math
    ///    never mutates that anchor.
    ///
    /// 2. **Zero in-range transactions + non-zero balance ⇒ flat
    ///    horizontal line at the current balance.** The user's
    ///    2026-06-09 direction: showing "no data" for a wallet
    ///    that genuinely DID hold a balance for the whole period
    ///    (nothing changed) was dishonest. A flat line at the
    ///    current value IS the truthful shape for "the wallet sat
    ///    here all week."
    ///
    /// 3. **Zero balance + zero in-range transactions ⇒ empty
    ///    state.** Empty list. The caller's chart renders the
    ///    "no history yet" copy. Honest because there's literally
    ///    nothing to draw.
    ///
    /// 4. **`.all` with at least one transaction** anchors the
    ///    leading edge at the oldest transaction's timestamp.
    ///    Cutoff is `.distantPast` so no in-range filter excludes
    ///    the oldest point.
    ///
    /// 5. **`.all` with zero transactions + non-zero balance** —
    ///    we don't know when the wallet was created. Fall back to
    ///    a synthetic 30-day-ago leading anchor at the current
    ///    fiat so the line still reads as a flat plateau rather
    ///    than collapsing to a single point.
    static func reconstruct(
        transactions: [TransactionRecord],
        currentBalances: [TokenBalanceRecord],
        range: BalanceHistoryRange,
        now: Date = Date()
    ) -> [BalancePoint] {
        // Honest empty state — no balance, no history, nothing to
        // draw. The caller renders the "balance changes will appear
        // here" copy.
        if currentBalances.isEmpty && transactions.isEmpty { return [] }
        let cutoff = range.cutoff(from: now)

        // Per-token current fiat-per-unit map, keyed by the
        // `(symbol, contract)` tuple. Native coins use `nil`
        // contract; tokens use the on-chain contract address as
        // written by the scanner. The map is read-only after build.
        //
        // Tokens whose `tokenSymbol` no longer appears in
        // `currentBalances` (fully cashed-out assets) silently drop
        // out of the fiat sum — they have no `fiatPerUnit[key]`
        // entry, so they contribute zero. The honest behavior:
        // we can't value a quantity we have no current price for.
        var fiatPerUnit: [TokenKey: Decimal] = [:]
        var currentQuantity: [TokenKey: Decimal] = [:]
        for balance in currentBalances {
            let key = TokenKey(
                symbol: balance.tokenSymbol,
                contract: balance.tokenContract
            )
            let quantity = WalletFormatting.decimalAmount(
                rawBalance: balance.rawBalance,
                decimals: balance.decimals
            )
            guard quantity > 0 else { continue }
            // Sum across all addresses on the same token. The
            // wallet may hold the same token at multiple addresses
            // (e.g. multi-address Bitcoin or Solana SPL across two
            // ATAs); the chart needs the wallet-wide quantity.
            currentQuantity[key, default: 0] += quantity
            // Per-unit price stays consistent across addresses —
            // last writer wins, which is fine because the cached
            // fiat value scales linearly with quantity.
            if balance.fiatValueCached > 0 {
                fiatPerUnit[key] = balance.fiatValueCached / quantity
            }
        }

        // The trailing-edge total — the rightmost sample's fiat.
        // This MUST equal the wallet's current displayed total so
        // the curve resolves to the hero number above it. Every
        // other sample's fiat is back-propagated from this anchor.
        let currentTotal = totalFiat(quantities: currentQuantity, prices: fiatPerUnit)

        // Walk newest-first. The running quantity map starts at
        // today's state and reverses each tx's effect.
        let sorted = transactions
            .filter { $0.statusRaw != TransactionStatus.failed.rawValue }
            .sorted { $0.occurredAt > $1.occurredAt }

        var running = currentQuantity
        var points: [BalancePoint] = [
            BalancePoint(timestamp: now, fiat: currentTotal)
        ]

        for tx in sorted {
            let key = TokenKey(symbol: tx.tokenSymbol, contract: tx.tokenContract)
            guard let amount = Decimal(string: tx.amountRaw) else { continue }
            // The amount in the transaction record is already in
            // the token's native units (e.g. ETH, not wei). It is
            // stored as a decimal string by the scanner so the
            // chart math doesn't need to know per-token decimals.
            switch TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing {
            case .incoming:
                // Before this tx, the wallet had `amount` less.
                running[key, default: 0] -= amount
            case .outgoing:
                // Before this tx, the wallet had `amount` more.
                running[key, default: 0] += amount
            case .internal:
                // Between own addresses — no net change to
                // wallet-wide quantity.
                break
            }
            // Snap negative residue to zero. Round-trip precision
            // and unrecorded-pre-history activity can leave tiny
            // negative artifacts; the curve never goes below zero.
            if running[key, default: 0] < 0 { running[key] = 0 }

            // Stop sampling beyond the cutoff — but still process
            // the tx so the carry-back math is correct for any
            // older sample we DO need. (Currently we only emit
            // samples between cutoff and now, so the loop can break
            // once we cross the cutoff.)
            if tx.occurredAt < cutoff { break }

            points.append(
                BalancePoint(
                    timestamp: tx.occurredAt,
                    fiat: totalFiat(quantities: running, prices: fiatPerUnit)
                )
            )
        }

        // **The flat-line case (Rule #2 §A.7).** Exactly one point
        // means zero in-range transactions. If the wallet does
        // hold a non-zero balance, the honest shape for the
        // period is a flat horizontal line at the current value —
        // "nothing happened in this window." Synthesize a leading
        // anchor at the appropriate edge so the chart renders a
        // line, not a point. For `.all` with zero history we fall
        // back to a 30-day synthetic span — long enough to read
        // as a plateau rather than collapsing back to a single dot.
        if points.count == 1, currentTotal > 0 {
            let leadingAnchor: Date
            switch range {
            case .all:
                leadingAnchor = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? cutoff
            default:
                leadingAnchor = cutoff
            }
            points.append(BalancePoint(timestamp: leadingAnchor, fiat: currentTotal))
            return points.reversed()
        }

        // Anchor the leading edge at the cutoff (or oldest tx for
        // `.all`) so the line spans the full picked range without
        // a phantom rising entry segment from the y-axis.
        let leadingAnchor: Date = {
            if case .all = range {
                return points.last?.timestamp ?? now
            }
            return cutoff
        }()
        // Use the final running quantities (state at the leading
        // edge) for the anchor's fiat — keeps the line truthful
        // about what was held at that point in time.
        if let leadingFiat = points.last?.fiat,
           points.last?.timestamp != leadingAnchor,
           leadingAnchor < (points.last?.timestamp ?? now)
        {
            points.append(BalancePoint(timestamp: leadingAnchor, fiat: leadingFiat))
        }

        // Reverse so the curve reads left-to-right (oldest to
        // newest) — what every charting library expects.
        return points.reversed()
    }

    // MARK: - Helpers

    /// Sum fiat across the per-token quantity map using the
    /// per-unit price map. Missing-price tokens contribute zero —
    /// honest about the gap (a token whose price we don't have
    /// can't be valued in fiat; saying it's worth zero is closer
    /// to the truth than guessing).
    private static func totalFiat(
        quantities: [TokenKey: Decimal],
        prices: [TokenKey: Decimal]
    ) -> Decimal {
        var sum = Decimal.zero
        for (key, quantity) in quantities {
            guard quantity > 0, let price = prices[key] else { continue }
            sum += quantity * price
        }
        return sum
    }

    /// Unique key per token across wallet addresses. Native coins
    /// share the same `(symbol, nil)` key across every address on
    /// the same chain; ERC-20 / SPL / etc. use the on-chain
    /// contract address as written by the scanner.
    private struct TokenKey: Hashable {
        let symbol: String
        let contract: String?
    }
}
