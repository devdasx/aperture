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
    // `CaseIterable` order is the picker order: `.hour` FIRST so the
    // segmented selector reads `1H · 1D · 1W · 1M · 1Y · All` left→right.
    case hour
    case day
    case week
    case month
    case year
    case all

    /// Localized one-letter symbol shown on the segmented picker.
    var shortLabel: String {
        switch self {
        case .hour:  return "1H"
        case .day:   return "1D"
        case .week:  return "1W"
        case .month: return "1M"
        case .year:  return "1Y"
        case .all:   return "All"
        }
    }

    /// Cut-off measured from `reference`. `.all` returns
    /// `.distantPast` so the reconstructor consumes every event.
    /// `.hour` is a true trailing 1-hour window (3600 s) — the user
    /// lists 1H as a real range (2026-06-16), so it is NOT folded to
    /// `.day`. The common case (no transactions in the last hour)
    /// reconstructs an honest flat line at the current balance with 0%
    /// change — see `reconstruct`'s "zero in-window transactions"
    /// branch.
    func cutoff(from reference: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .hour:
            return reference.addingTimeInterval(-3_600)
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
/// transaction history. **Transactions are the only truth source for
/// the curve's SHAPE** (2026-06-13 rebuild, per explicit user
/// direction: *"we'll update the chart to use transactions as real
/// and truth source only, and each transaction should appear in the
/// chart"*).
///
/// **The math (the forward walk).**
///
/// Sort every non-failed transaction oldest-first. Per-token running
/// quantities start at **zero** and accumulate each transaction's
/// effect in chronological order: incoming adds, outgoing subtracts,
/// internal (between the wallet's own addresses) is a no-op. Negative
/// residue — precision drift or pre-history activity the explorers
/// never reported — clamps to zero; quantities never go below zero.
///
/// For the selected range the emitted series is built over an
/// **effective window** `[effectiveCutoff, now]` where
/// `effectiveCutoff = max(range.cutoff, firstTransactionDate)` — the
/// window start is clamped to the wallet's first transaction so the
/// curve never draws a flat-0 lead from a cutoff that predates any
/// activity (2026-06-16 fix; see the body for the full rationale):
///
/// 1. **Leading anchor at `effectiveCutoff`**, valued from the state
///    accumulated over ALL transactions BEFORE the effective cutoff —
///    so the line starts at the true balance-as-of-window-start, never
///    at a padded zero. Emitted only when `effectiveCutoff` is strictly
///    before the first in-window transaction (an older wallet's 1M/1Y,
///    where the raw cutoff wins, so the anchor carries a genuine
///    non-zero one-period-ago balance). When the window start clamps to
///    the first transaction itself (a young wallet's 1M/1Y, and EVERY
///    `.all`), no separate leading anchor is emitted — and the wallet's
///    first-ever in-window transaction's leading **$0** before-step (its
///    pre-history state) is DROPPED, so the curve begins at that
///    transaction's AFTER value: the first real balance the wallet held
///    (2026-06-16 user direction — "start the line at the first balance
///    the wallet actually held"). The result is that `points.first` is a
///    non-zero held balance on every range, so the visible line and the
///    change-pill percent agree (a line starting at $0 with a negative
///    percent pill would be a contradiction). The drop is surgical (first
///    in-window tx, no leading anchor, before-value 0); the degenerate
///    case of a first tx that's an OUTGOING send keeps its $0 start.
/// 2. **A before/after step pair for EVERY in-window transaction** at
///    its exact timestamp. The before-point sits 1 ms earlier so the
///    chart plots a vertical step; both halves are valued at the same
///    day's price. Every receive is a visible up-step, every send a
///    visible down-step — no transaction is ever smoothed away.
/// 3. **Trailing anchor at `now`** — anchored to the wallet's REAL
///    current balance fiat (`Σ currentBalances.fiatValueCached`, the
///    exact figure the hero shows) when that is available, so the
///    chart's RIGHT EDGE equals the hero number and the change pill
///    (which reads `points.last − points.first`) measures from the
///    transaction-driven range-start to the real current balance. When
///    no real balance fiat exists yet (offline before the first scan),
///    it falls back to the cumulative-transaction state valued at
///    current prices. The SHAPE before `now` is still 100%
///    transaction-driven; only this final endpoint is reconciled to
///    the hero (2026-06-16 user direction: "the hero balance and the
///    chart's right edge must agree").
///
/// **Valuation ladder (unchanged from the 2026-06-12 design).** Each
/// HISTORICAL point's fiat is `Σ quantity × price` where price
/// resolves, per token, through:
///
///   `priceHistory[symbol][dayKey(t)]` (the honest then-price)
///   → `priceCache[symbol]` (today's spot)
///   → `fiatPerUnit[key]` (balance-derived per-unit fallback).
///
/// `currentBalances` feeds the last valuation rung (fiat ÷ quantity
/// per held token) AND the trailing-edge anchor above — it never
/// shapes the curve's interior, only the final point's level.
///
/// **Key normalization (2026-06-13 — the invisible-transactions
/// fix).** Transaction rows and balance rows are written by DIFFERENT
/// code: explorer adapters write `tokenContract` verbatim from the
/// API response (Etherscan-family returns **lowercased** EVM
/// contracts — `EVMTransactionAdapter` line ~603), while the balance
/// scanner writes the registry's **EIP-55 checksummed** form
/// (`WalletRefreshCoordinator` line ~378 ← `EVMTokenRegistry`).
/// The old `(symbol, contract)` key compared those byte-for-byte, so
/// a USDT receive (`0xdac1…`) and the USDT balance row (`0xdAC1…`)
/// landed under DIFFERENT keys — the walk's quantity deltas were
/// unpriceable, every step contributed zero, and the chart drew a
/// flat line through real activity (the 2026-06-13 user report:
/// received 12 → 10 → 500 → 300 USDT, chart never moved). `TokenKey`
/// now folds case at construction — symbols uppercased, contracts
/// lowercased — and every lookup goes through the normalized key.
/// The stored records stay verbatim (schema rule: contract addresses
/// are case-sensitive on some chains and are never rewritten);
/// normalization is internal matching only.
///
/// **Honesty disclosure (Rule #2 §A.7).** Transactions are the only
/// truth source for the curve's SHAPE — every receive is a visible
/// up-step, every send a down-step, self-transfers move nothing. The
/// trailing edge is reconciled to the real current balance (above) so
/// the card stays honest (chart end == hero). When transaction history
/// is incomplete (an explorer that returns balances but not transfers,
/// pagination gaps, pre-import activity), the reconciliation means the
/// final step from the last in-window transaction to `now` absorbs the
/// difference — an honest "the wallet ended here" edge rather than a
/// fabricated interior movement. The interior is never re-anchored;
/// only the endpoint meets the hero.
///
/// **Preserved edge-case behaviors.**
///
/// 1. **Zero transactions ever + zero balances ⇒ empty.** The caller
///    renders the zero baseline ("no history yet").
/// 2. **Zero transactions ever + non-zero balances ⇒ flat line at the
///    balance-derived current total.** The one place balances still
///    pick the level: a wallet that demonstrably holds funds but has
///    no fetched history yet would otherwise draw a dishonest flat
///    zero. For `.all` the synthetic leading anchor sits 30 days back
///    so the plateau reads as a line, not a dot.
/// 3. **Zero IN-window transactions ⇒ flat line at the pre-window
///    state's value across the window** ("the wallet sat here all
///    week"). This is the truthful flat: a range that contains no
///    transactions correctly draws a flat line, because the held
///    quantity didn't change in that window — movement on a range
///    comes ONLY from trades within it, never from market-price drift
///    (current-price valuation is applied uniformly to every point).
///    The flat spans `[effectiveCutoff, now]` and both endpoints take
///    the hero-reconciled level so the change pill honestly reads 0%.
///
/// **Why this is a pure function.** Easy to verify against test
/// vectors; no SwiftUI dependency; safely callable from any actor.
enum BalanceHistoryReconstructor {

    /// Reconstruct the balance curve for `range`. Returns sample
    /// points oldest-to-newest: the leading-edge anchor, a
    /// before/after pair per in-window transaction, and the
    /// trailing-edge anchor at `now`. Empty when the wallet has no
    /// transactions AND no current balance fiat — the honest "no
    /// history yet" state.
    ///
    /// - `transactions`: the FULL history across every address — the
    ///   caller passes the un-prefixed feed (not the home's
    ///   10-most-recent slice). Failed transactions are ignored.
    /// - `currentBalances`: the latest cached balance rows. Used ONLY
    ///   to derive the per-unit valuation fallback and the
    ///   no-history-yet plateau level — never the curve's shape.
    /// - `priceCache`: per-symbol last-known spot price keyed by
    ///   **uppercased symbol** (the call sites' canonical storage).
    /// - `priceHistory`: `[symbol-uppercased: [yyyymmdd: close]]`
    ///   historical closes; the first valuation rung.
    /// `Sendable` snapshot of the transaction fields the reconstruction
    /// reads — lets the heavy reconstruction run OFF the main actor
    /// (2026-06-13 perf fix). `TransactionRecord` is a main-context
    /// `@Model` and isn't `Sendable`; the caller copies the few needed
    /// fields on the main actor (cheap, no Decimal math) then hands
    /// these value types to a detached task.
    struct HistoryTx: Sendable {
        let occurredAt: Date
        let statusRaw: String
        let tokenSymbol: String
        let tokenContract: String?
        let amountRaw: String
        let directionRaw: String
        /// The other side of the transfer (receiver for `.out`, sender for
        /// `.in`). Used to drop self-transfers from the chart — see the
        /// `ownAddresses` filter in `reconstruct`.
        let counterparty: String
    }

    /// `Sendable` snapshot of the balance fields the reconstruction
    /// reads — see `HistoryTx`.
    struct HistoryBalance: Sendable {
        let tokenSymbol: String
        let tokenContract: String?
        let rawBalance: String
        let decimals: Int
        let fiatValueCached: Decimal
    }

    /// `@Model` convenience overload — maps the SwiftData records to
    /// `Sendable` snapshots and calls the core. Kept so existing call
    /// sites (and the test suite) compile unchanged. Off-main callers
    /// use the snapshot overload directly.
    static func reconstruct(
        transactions: [TransactionRecord],
        currentBalances: [TokenBalanceRecord],
        priceCache: [String: Decimal] = [:],
        priceHistory: [String: [Int: Decimal]] = [:],
        ownAddresses: Set<String> = [],
        range: BalanceHistoryRange,
        now: Date = Date()
    ) -> [BalancePoint] {
        reconstruct(
            txSnapshots: transactions.map {
                HistoryTx(
                    occurredAt: $0.occurredAt,
                    statusRaw: $0.statusRaw,
                    tokenSymbol: $0.tokenSymbol,
                    tokenContract: $0.tokenContract,
                    amountRaw: $0.amountRaw,
                    directionRaw: $0.directionRaw,
                    counterparty: $0.counterparty
                )
            },
            balanceSnapshots: currentBalances.map {
                HistoryBalance(
                    tokenSymbol: $0.tokenSymbol,
                    tokenContract: $0.tokenContract,
                    rawBalance: $0.rawBalance,
                    decimals: $0.decimals,
                    fiatValueCached: $0.fiatValueCached
                )
            },
            priceCache: priceCache,
            priceHistory: priceHistory,
            ownAddresses: ownAddresses,
            range: range,
            now: now
        )
    }

    /// Core reconstruction over `Sendable` snapshots — `nonisolated` so
    /// it can run on a detached background task without touching the
    /// main actor (2026-06-13 perf fix; the Decimal math over a deep
    /// history was freezing the wallet home on unlock / navigation).
    /// Distinct argument labels (`txSnapshots:`/`balanceSnapshots:`)
    /// keep it unambiguous against the `@Model` overload above.
    nonisolated static func reconstruct(
        txSnapshots: [HistoryTx],
        balanceSnapshots: [HistoryBalance],
        priceCache: [String: Decimal] = [:],
        priceHistory: [String: [Int: Decimal]] = [:],
        ownAddresses: Set<String> = [],
        range: BalanceHistoryRange,
        now: Date = Date()
    ) -> [BalancePoint] {
        // Local aliases so the original body reads unchanged.
        let transactions = txSnapshots
        let currentBalances = balanceSnapshots
        let cutoff = range.cutoff(from: now)

        // Chronological, non-failed feed — the truth source. Pending
        // transactions count (they're real intent, and they flip to
        // confirmed in place); failed ones never moved a balance.
        let sorted = transactions
            .filter { $0.statusRaw != TransactionStatus.failed.rawValue }
            // Drop self-transfers — a send to / receive from one of the
            // wallet's OWN addresses nets to zero on the balance, so it must
            // not move the chart. Excluding it drops BOTH legs (the out and
            // any matching in), so the curve stays flat across a self-send.
            // Only transfers to/from a DIFFERENT address count (user direction
            // 2026-06-16). Empty-counterparty events are left to `apply`'s
            // direction logic (internal already contributes no delta).
            .filter { tx in
                tx.counterparty.isEmpty
                    || !ownAddresses.contains(tx.counterparty.lowercased())
            }
            .sorted { $0.occurredAt < $1.occurredAt }

        // Balance-derived per-unit prices — the LAST valuation rung.
        // Wallet-wide fiat ÷ wallet-wide quantity per normalized key
        // (the same token can sit at multiple addresses). Also sum
        // the cached fiat total for the no-history plateau below.
        var fiatTotals: [TokenKey: Decimal] = [:]
        var balanceQuantity: [TokenKey: Decimal] = [:]
        var currentBalanceFiat = Decimal.zero
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
            balanceQuantity[key, default: 0] += quantity
            if balance.fiatValueCached > 0 {
                fiatTotals[key, default: 0] += balance.fiatValueCached
                currentBalanceFiat += balance.fiatValueCached
            }
        }
        var fiatPerUnit: [TokenKey: Decimal] = [:]
        fiatPerUnit.reserveCapacity(fiatTotals.count)
        for (key, fiatTotal) in fiatTotals {
            guard let quantity = balanceQuantity[key], quantity > 0 else { continue }
            fiatPerUnit[key] = fiatTotal / quantity
        }

        // **No transactions at all.** Preserved honest behaviors:
        // a wallet with cached balance fiat gets a flat plateau at
        // that level (we know WHAT it holds, just not WHEN it
        // arrived); a wallet with nothing gets the empty state and
        // the caller renders the zero baseline.
        if sorted.isEmpty {
            guard currentBalanceFiat > 0 else { return [] }
            let leadingAnchor: Date
            if case .all = range {
                // No oldest transaction to anchor on — synthesize a
                // 30-day span so the plateau reads as a line.
                leadingAnchor = Calendar.current.date(byAdding: .day, value: -30, to: now)
                    ?? now.addingTimeInterval(-86_400 * 30)
            } else {
                leadingAnchor = cutoff
            }
            return [
                BalancePoint(timestamp: leadingAnchor, fiat: currentBalanceFiat),
                BalancePoint(timestamp: now, fiat: currentBalanceFiat),
            ]
        }

        // **Effective window start — clamp the cutoff to the wallet's
        // FIRST transaction (2026-06-16 flat-0-lead fix).** When the
        // selected range's raw cutoff predates the wallet's first
        // (non-failed, non-self) transaction, anchoring the line at the
        // raw cutoff draws a long flat-0 run from the cutoff until that
        // first transaction — on a 1Y/All view that's most of the width,
        // squishing the real shape into a sliver at the right edge so the
        // curve reads "straight" and the change pill reads "no change".
        //
        // Clamping the effective window start to `firstTxDate` instead
        // fills the range with the REAL transaction shape:
        //   • A young/active wallet's 1M/1Y/All all converge to the full
        //     real history (the curve starts where the user's history
        //     actually starts), and the leading point becomes the first
        //     transaction's pre-step at the genuine pre-history state
        //     (zero for an account whose first-ever event is a receive).
        //   • An older wallet's 1M still anchors at its real, NON-zero
        //     one-month-ago balance (its first transaction is older than
        //     the 1-month cutoff, so `max` keeps the raw cutoff) and
        //     shows the in-window trades.
        //
        // `max(cutoff, firstTxDate)` is correct for EVERY range including
        // `.all` (whose raw cutoff is `.distantPast`, so the effective
        // start collapses to the first transaction). The forward walk and
        // the leading anchor both key off `effectiveCutoff`, never the
        // raw `cutoff`, below.
        let firstTxDate = sorted[0].occurredAt
        let effectiveCutoff = max(cutoff, firstTxDate)

        // **Forward cumulative walk.** Quantities start at ZERO and
        // accumulate every pre-(effective-window) transaction so the
        // leading anchor carries the true balance-as-of-window-start.
        var running: [TokenKey: Decimal] = [:]
        var index = 0
        while index < sorted.count, sorted[index].occurredAt < effectiveCutoff {
            apply(sorted[index], to: &running)
            index += 1
        }
        let inWindow = sorted[index...]

        // **Zero in-window transactions.** Flat window at the
        // pre-window cumulative state — "the wallet sat here all
        // week." Each endpoint values at its own timestamp through
        // the ladder. (`.all` never reaches this branch: its effective
        // cutoff collapses to the first transaction, which is therefore
        // always in-window.) The flat line spans `[effectiveCutoff, now]`
        // — for a finite range whose cutoff predates the first tx but
        // whose only tx is itself pre-window, `effectiveCutoff` is the
        // raw cutoff (the tx is before the window), so this is the honest
        // "the wallet sat at its pre-window level across this window".
        if inWindow.isEmpty {
            let trailingFiat = trailingAnchorFiat(
                quantities: running, now: now,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit, currentBalanceFiat: currentBalanceFiat
            )

            // **Sub-day ranges stay flat (1H/1D).** Daily-close price data can't
            // show intraday shape (the documented data-availability limit), and
            // the 2026-06-16 direction is an honest flat line at the hero with
            // 0% change for a window with no transaction — keep exactly that.
            switch range {
            case .hour, .day:
                return [
                    BalancePoint(timestamp: effectiveCutoff, fiat: trailingFiat),
                    BalancePoint(timestamp: now, fiat: trailingFiat),
                ]
            case .week, .month, .year, .all:
                break   // fall through to the dense market grid below
            }

            // **2026-06-19 — market-movement fix (root cause #2), multi-day
            // ranges.** The wallet held a CONSTANT position across the window
            // (no in-window trades), but the price of what it holds still moved.
            // The old code drew a flat 2-point line — a wallet holding BTC all
            // year showed a straight line even as BTC swung. Sample the window
            // on a daily grid and value the constant `running` holdings at EACH
            // day's historical close, so the curve follows the market. Holdings
            // still come ONLY from the transaction walk (`running`); only the
            // valuation moves. When no historical prices exist for the held
            // symbols, every grid point degrades to today's spot via
            // `totalFiatAt`'s ladder → the same flat line as before (honest: no
            // data, no fabricated wiggle). The endpoint reconciles to the hero
            // so the right edge + change pill stay consistent (2026-06-16).
            // Daily grid points are evenly time-spaced, so this renders
            // correctly even under the current index-spaced sparkline.
            let grid = sampleGrid(from: effectiveCutoff, to: now, range: range)
            guard grid.count >= 2 else {
                return [
                    BalancePoint(timestamp: effectiveCutoff, fiat: trailingFiat),
                    BalancePoint(timestamp: now, fiat: trailingFiat),
                ]
            }
            var marketPoints: [BalancePoint] = []
            marketPoints.reserveCapacity(grid.count)
            for (i, instant) in grid.enumerated() {
                let isLast = i == grid.count - 1
                let fiat = isLast
                    ? trailingFiat   // right edge == hero (existing contract)
                    : totalFiatAt(
                        quantities: running, timestamp: instant,
                        priceHistory: priceHistory, priceCache: priceCache,
                        fiatPerUnit: fiatPerUnit
                    )
                marketPoints.append(BalancePoint(timestamp: instant, fiat: fiat))
            }
            return marketPoints
        }

        var points: [BalancePoint] = []
        points.reserveCapacity(inWindow.count * 2 + 2)

        // **Leading anchor.** Anchored at `effectiveCutoff` (the clamped
        // window start) carrying the pre-window cumulative state, so the
        // line spans the picked range starting at the wallet's REAL
        // history — never a padded flat-0 lead. Emitted ONLY when the
        // effective cutoff is strictly before the first in-window
        // transaction's before-step:
        //   • Older wallet's 1M/1Y: `effectiveCutoff` == the raw cutoff
        //     (earlier than the first in-window tx) → a distinct leading
        //     anchor at the genuine one-period-ago balance.
        //   • Young wallet's 1M/1Y AND every `.all`: `effectiveCutoff` ==
        //     `firstTxDate` == the first in-window tx's timestamp, so the
        //     guard is false and we DON'T emit a separate anchor — see the
        //     start-at-first-HELD-balance rule in the loop below.
        let emittedLeadingAnchor = effectiveCutoff < inWindow[inWindow.startIndex].occurredAt
        if emittedLeadingAnchor {
            let leadingFiat = totalFiatAt(
                quantities: running, timestamp: effectiveCutoff,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            points.append(BalancePoint(timestamp: effectiveCutoff, fiat: leadingFiat))
        }

        // **One step pair per in-window transaction.** The
        // before-point captures the holdings in the interval since
        // the previous transaction; the after-point captures the
        // instantaneous change. The 1 ms backstep keeps timestamps
        // unique so the sparkline plots a vertical step. (A
        // transaction within 1 ms of the cutoff can place its
        // before-point a hair before the anchor — cosmetically
        // invisible under the chart's index-spaced x.) Both halves
        // share the transaction day's price.
        //
        // **Start at the first HELD balance, not at $0 (2026-06-16 user
        // direction).** For a wallet whose first-ever in-window event is a
        // receive — no leading anchor emitted AND the running state is
        // empty so the first before-step computes to 0 — that leading $0
        // before-step is DROPPED, so the curve begins at the transaction's
        // AFTER value (the first real balance the wallet held). This makes
        // `points.first` a non-zero held balance on every range (young
        // wallet 1M/1Y AND every `.all`), so the visible line and the pill
        // percent agree — a line starting at $0 with a "−37.95%" pill would
        // be a contradiction. The skip is surgical: ONLY the first
        // in-window transaction, ONLY when no leading anchor exists, ONLY
        // when its before-value is 0 (genuine pre-history). Older wallets
        // (a non-zero leading anchor) and any first tx with a non-zero
        // before-value keep their step pair unchanged.
        // **Part 4.2 — market movement BETWEEN trades.** On multi-day ranges,
        // after each trade the holdings are CONSTANT until the next event, so we
        // value that gap on a daily grid (the curve follows the market across a
        // "bought then held" segment instead of drawing a straight line to the
        // next trade). Sub-day ranges (1H/1D) add nothing — a daily grid over a
        // sub-day gap has no interior instants — so they stay pure step pairs.
        let interleaveMarket: Bool = {
            switch range {
            case .hour, .day: return false
            case .week, .month, .year, .all: return true
            }
        }()
        var isFirstInWindow = true
        let inWindowArray = Array(inWindow)
        for i in inWindowArray.indices {
            let tx = inWindowArray[i]
            // An unparseable amount can't change state — skip the
            // pair entirely rather than emitting a phantom flat step.
            guard Decimal(string: tx.amountRaw) != nil else { continue }
            let beforeFiat = totalFiatAt(
                quantities: running, timestamp: tx.occurredAt,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            // Drop the leading $0 pre-history before-step for the wallet's
            // first-ever in-window transaction (see the comment above).
            let skipLeadingZeroBefore =
                isFirstInWindow && !emittedLeadingAnchor && beforeFiat == 0
            if !skipLeadingZeroBefore {
                points.append(
                    BalancePoint(
                        timestamp: tx.occurredAt.addingTimeInterval(-0.001),
                        fiat: beforeFiat
                    )
                )
            }
            apply(tx, to: &running)
            let afterFiat = totalFiatAt(
                quantities: running, timestamp: tx.occurredAt,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            points.append(BalancePoint(timestamp: tx.occurredAt, fiat: afterFiat))
            isFirstInWindow = false

            // Fill the gap to the next event (next tx, or `now`) with daily
            // market points at the now-constant holdings.
            if interleaveMarket {
                let gapEnd = (i + 1 < inWindowArray.count) ? inWindowArray[i + 1].occurredAt : now
                guard gapEnd > tx.occurredAt else { continue }
                for instant in sampleGrid(from: tx.occurredAt, to: gapEnd, range: range).dropFirst().dropLast()
                where instant > tx.occurredAt && instant < gapEnd {
                    let fiat = totalFiatAt(
                        quantities: running, timestamp: instant,
                        priceHistory: priceHistory, priceCache: priceCache,
                        fiatPerUnit: fiatPerUnit
                    )
                    points.append(BalancePoint(timestamp: instant, fiat: fiat))
                }
            }
        }

        // **Trailing anchor at `now`** — reconciled to the wallet's
        // REAL current balance fiat (the exact hero figure) when one
        // exists, so the chart's right edge == the hero and the change
        // pill (which reads `points.last − points.first`) is consistent
        // with the line the user sees (2026-06-16). Falls back to the
        // cumulative-transaction state valued at current prices when no
        // real balance is available yet (offline before the first scan).
        // The interior steps above stay 100% transaction-driven; only
        // this endpoint meets the hero.
        let trailingFiat = trailingAnchorFiat(
            quantities: running, now: now,
            priceHistory: priceHistory, priceCache: priceCache,
            fiatPerUnit: fiatPerUnit, currentBalanceFiat: currentBalanceFiat
        )
        points.append(BalancePoint(timestamp: now, fiat: trailingFiat))

        return points
    }

    // MARK: - Helpers

    /// Apply one transaction's effect to the running per-token
    /// quantities, forward in time: incoming adds, outgoing
    /// subtracts, internal (own-address shuffle) is a wallet-wide
    /// no-op. Negative residue clamps to zero — round-trip precision
    /// and unrecorded pre-history activity can leave tiny negative
    /// artifacts; the curve never goes below zero.
    private static func apply(
        _ tx: HistoryTx,
        to running: inout [TokenKey: Decimal]
    ) {
        guard let amount = Decimal(string: tx.amountRaw) else { return }
        let key = TokenKey(symbol: tx.tokenSymbol, contract: tx.tokenContract)
        switch TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing {
        case .incoming:
            running[key, default: 0] += amount
        case .outgoing:
            running[key, default: 0] -= amount
        case .internal:
            break
        }
        if running[key, default: 0] < 0 { running[key] = 0 }
    }

    /// Evenly-spaced sample instants over `[start, end]` at a per-range cadence,
    /// capped to ~`maxPoints` so a long span stays render-cheap. Always includes
    /// `end`. Used to value a constant-held position across a no-trade window so
    /// the curve follows the MARKET (root cause #2, 2026-06-19).
    ///
    /// **Granularity = daily** (the finest the `HistoricalPriceRecord` table
    /// supports — UTC-day closes). Sub-day ranges (1H/1D) therefore render at
    /// daily granularity: with daily-only price data we deliberately do NOT
    /// fabricate intraday wiggle (a short window collapses to ~2 points at one
    /// day's close — honest). `.all` over a multi-year span steps weekly.
    nonisolated static func sampleGrid(
        from start: Date, to end: Date, range: BalanceHistoryRange
    ) -> [Date] {
        guard end > start else { return [end] }
        let span = end.timeIntervalSince(start)
        let day: TimeInterval = 86_400
        let rawStep: TimeInterval
        switch range {
        case .hour, .day, .week, .month, .year:
            rawStep = day
        case .all:
            rawStep = span > day * 400 ? day * 7 : day   // weekly once it's multi-year
        }
        // Cap the point count so a huge span stays cheap to value + render.
        let maxPoints = 420
        let step = max(rawStep, span / Double(maxPoints))
        var grid: [Date] = []
        var instant = start
        while instant < end {
            grid.append(instant)
            instant = instant.addingTimeInterval(step)
        }
        grid.append(end)
        return grid
    }

    /// Timestamp-aware fiat sum. For each token quantity, the price
    /// resolves through the ladder:
    ///   1. **Historical close** — `priceHistory[symbol][dayKey]`.
    ///      The honest then-price; 1000 tokens received at $4 render
    ///      as $4000 even if today's price is $0.05.
    ///   2. **Today's spot** — `priceCache[symbol]`.
    ///   3. **Balance-derived per-unit** — `fiatPerUnit[key]`, from
    ///      the held-balance row's `fiatValueCached / quantity`.
    ///
    /// Each missing rung silently degrades to the next; a token with
    /// no price source at all contributes zero (honest about the gap
    /// — saying "we can't value this" via zero beats guessing).
    /// `key.symbol` is uppercased by `TokenKey`'s construction, so
    /// the symbol-keyed maps (which the call sites store uppercased)
    /// hit without re-folding.
    private static func totalFiatAt(
        quantities: [TokenKey: Decimal],
        timestamp: Date,
        priceHistory: [String: [Int: Decimal]],
        priceCache: [String: Decimal],
        fiatPerUnit: [TokenKey: Decimal]
    ) -> Decimal {
        let dayKey = DayKey.from(date: timestamp)
        var sum = Decimal.zero
        for (key, quantity) in quantities {
            guard quantity > 0 else { continue }
            let price = priceHistory[key.symbol]?[dayKey]
                ?? priceCache[key.symbol]
                ?? fiatPerUnit[key]
            if let price {
                sum += quantity * price
            }
        }
        return sum
    }

    /// The fiat level for the trailing point at `now`. **Reconciliation
    /// to the hero (2026-06-16).** When the wallet has a real current
    /// balance fiat (`Σ currentBalances.fiatValueCached`, the exact
    /// figure the hero renders), the trailing point takes that level so
    /// the chart's right edge == the hero number and the change pill,
    /// computed as `points.last − points.first`, agrees with the line.
    /// When no real balance fiat is available yet (offline before the
    /// first scan returns `currentBalanceFiat == 0`), it falls back to
    /// the cumulative-transaction state valued at current prices via
    /// `totalFiatAt` — so an offline wallet still draws an honest
    /// transaction-derived edge instead of collapsing to zero.
    private static func trailingAnchorFiat(
        quantities: [TokenKey: Decimal],
        now: Date,
        priceHistory: [String: [Int: Decimal]],
        priceCache: [String: Decimal],
        fiatPerUnit: [TokenKey: Decimal],
        currentBalanceFiat: Decimal
    ) -> Decimal {
        if currentBalanceFiat > 0 { return currentBalanceFiat }
        return totalFiatAt(
            quantities: quantities, timestamp: now,
            priceHistory: priceHistory, priceCache: priceCache,
            fiatPerUnit: fiatPerUnit
        )
    }

    /// Normalized per-token identity. **Symbols fold to uppercase;
    /// contracts fold to lowercase; empty contracts collapse to
    /// `nil`** (native coins) — because transaction adapters and the
    /// balance scanner disagree on casing (explorer-verbatim
    /// lowercase vs registry EIP-55 checksummed) and a byte-for-byte
    /// key split the same token into two unpriceable buckets (the
    /// 2026-06-13 invisible-USDT-receipts bug). Folding is internal
    /// matching only — stored records keep their verbatim casing.
    /// Base58/case-sensitive chains (Tron, Solana) fold consistently
    /// on both sides, and two real contracts differing only by case
    /// are not a practical concern.
    private struct TokenKey: Hashable {
        let symbol: String
        let contract: String?

        init(symbol: String, contract: String?) {
            self.symbol = symbol.uppercased()
            if let contract, !contract.isEmpty {
                self.contract = contract.lowercased()
            } else {
                self.contract = nil
            }
        }
    }
}
