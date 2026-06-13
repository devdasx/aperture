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
/// For the selected range `[cutoff, now]` the emitted series is:
///
/// 1. **Leading anchor at `cutoff`**, valued from the state
///    accumulated over ALL transactions BEFORE the cutoff — so the
///    line starts at the true balance-as-of-window-start, not at
///    zero. (`.all` has no separate leading anchor: the oldest
///    transaction's before-step at state zero IS the leading edge.)
/// 2. **A before/after step pair for EVERY in-window transaction** at
///    its exact timestamp. The before-point sits 1 ms earlier so the
///    chart plots a vertical step; both halves are valued at the same
///    day's price. Every receive is a visible up-step, every send a
///    visible down-step — no transaction is ever smoothed away.
/// 3. **Trailing anchor at `now`** with the final cumulative state,
///    valued at current prices.
///
/// **Valuation ladder (unchanged from the 2026-06-12 design).** Each
/// point's fiat is `Σ quantity × price` where price resolves, per
/// token, through:
///
///   `priceHistory[symbol][dayKey(t)]` (the honest then-price)
///   → `priceCache[symbol]` (today's spot)
///   → `fiatPerUnit[key]` (balance-derived per-unit fallback).
///
/// `currentBalances` feeds ONLY that last valuation rung (fiat ÷
/// quantity per held token) — it never shapes the curve.
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
/// **Honesty disclosure (Rule #2 §A.7).** With transactions as the
/// only truth source, the trailing edge equals the
/// **cumulative-transaction total**, which can differ from the hero
/// balance above the chart when history is incomplete for some chain
/// (an explorer that returns balances but not transfers, pagination
/// gaps, pre-import activity). That divergence is the user's explicit
/// choice — the chart tells the story the transactions tell, and the
/// hero tells the story the balance scan tells. We do not silently
/// re-anchor one to the other.
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
/// 3. **Zero IN-window transactions + accumulated pre-window state ⇒
///    flat line at that state's value across the window** ("the
///    wallet sat here all week"). Both endpoints value through the
///    ladder at their own timestamps, so with historical price
///    coverage the segment honestly tracks price movement.
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
                    directionRaw: $0.directionRaw
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

        // **Forward cumulative walk.** Quantities start at ZERO and
        // accumulate every pre-window transaction so the leading
        // anchor carries the true balance-as-of-window-start.
        var running: [TokenKey: Decimal] = [:]
        var index = 0
        while index < sorted.count, sorted[index].occurredAt < cutoff {
            apply(sorted[index], to: &running)
            index += 1
        }
        let inWindow = sorted[index...]

        // **Zero in-window transactions.** Flat window at the
        // pre-window cumulative state — "the wallet sat here all
        // week." Each endpoint values at its own timestamp through
        // the ladder. (`.all` never reaches this branch: its cutoff
        // is `.distantPast`, so every transaction is in-window.)
        if inWindow.isEmpty {
            let leadingFiat = totalFiatAt(
                quantities: running, timestamp: cutoff,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            let trailingFiat = totalFiatAt(
                quantities: running, timestamp: now,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            return [
                BalancePoint(timestamp: cutoff, fiat: leadingFiat),
                BalancePoint(timestamp: now, fiat: trailingFiat),
            ]
        }

        var points: [BalancePoint] = []
        points.reserveCapacity(inWindow.count * 2 + 2)

        // **Leading anchor.** Finite ranges anchor at the cutoff with
        // the pre-window state so the line spans the full picked
        // range. `.all` skips it — the first transaction's
        // before-step (state zero, 1 ms earlier) IS the leading edge,
        // which encodes "state zero before the oldest transaction".
        if range != .all {
            let leadingFiat = totalFiatAt(
                quantities: running, timestamp: cutoff,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            points.append(BalancePoint(timestamp: cutoff, fiat: leadingFiat))
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
        for tx in inWindow {
            // An unparseable amount can't change state — skip the
            // pair entirely rather than emitting a phantom flat step.
            guard Decimal(string: tx.amountRaw) != nil else { continue }
            let beforeFiat = totalFiatAt(
                quantities: running, timestamp: tx.occurredAt,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            points.append(
                BalancePoint(
                    timestamp: tx.occurredAt.addingTimeInterval(-0.001),
                    fiat: beforeFiat
                )
            )
            apply(tx, to: &running)
            let afterFiat = totalFiatAt(
                quantities: running, timestamp: tx.occurredAt,
                priceHistory: priceHistory, priceCache: priceCache,
                fiatPerUnit: fiatPerUnit
            )
            points.append(BalancePoint(timestamp: tx.occurredAt, fiat: afterFiat))
        }

        // **Trailing anchor at `now`** with the final cumulative
        // state, valued at current prices (today's dayKey resolves
        // today's close when present, then spot, then the
        // balance-derived rung). NOTE the honesty disclosure in the
        // type doc: this equals the cumulative-TRANSACTION total and
        // can legitimately differ from the hero balance when some
        // chain's history is incomplete — the user's explicit
        // "transactions as the only truth source" trade.
        let trailingFiat = totalFiatAt(
            quantities: running, timestamp: now,
            priceHistory: priceHistory, priceCache: priceCache,
            fiatPerUnit: fiatPerUnit
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
