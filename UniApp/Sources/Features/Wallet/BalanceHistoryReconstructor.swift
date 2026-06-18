import Foundation

// MARK: - BalancePoint

/// One sample on the reconstructed balance curve. `timestamp` is the
/// moment the wallet was in this state; `fiat` is its total value in the
/// user's preferred currency, valued at **current** per-unit spot prices
/// (Mode B — see `BalanceHistoryReconstructor`).
struct BalancePoint: Hashable, Sendable {
    let timestamp: Date
    let fiat: Decimal
}

// MARK: - BalanceHistoryRange

/// Time windows the chart's segmented picker offers. `.all` walks the
/// whole transaction history; the others slice by the trailing duration
/// from `now`. Single-letter labels match Apple's Stocks app.
enum BalanceHistoryRange: String, CaseIterable, Hashable, Sendable {
    // `CaseIterable` order is the picker order: `1H · 1D · 1W · 1M · 1Y · All`.
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

    /// Cut-off measured from `reference`. `.all` returns `.distantPast` so
    /// the reconstructor consumes every event. `.hour` is a true trailing
    /// 1-hour window (3600 s).
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

/// Reconstructs a wallet's balance curve through time from **its
/// transactions alone** (2026-06-19 rebuild, Mode B — per user direction:
/// rebuild the chart from scratch, transaction-sourced, deterministic,
/// real for every range).
///
/// **The principle.** The balance at any instant `T` is a pure function
/// of the transactions up to `T` — nothing else. No balance snapshots, no
/// fabricated trailing edge, no balance-derived per-unit fallback, no
/// reconciliation to a live total. Same transactions in → same curve out,
/// every time.
///
/// **Step 1 — holdings ledger (100% from transactions).** Sort the
/// scoped, filtered transactions ascending by `occurredAt` and walk them,
/// maintaining `running[tokenKey] += signedAmount` (`+` for incoming, `−`
/// for outgoing, `0` for internal / self-transfers). After processing
/// every transaction with `occurredAt ≤ T`, `running` is the exact
/// quantity of each token held at `T`. Purely amount + timestamp +
/// direction; no prices involved. Negative residue (precision drift or
/// pre-history activity the explorers never reported) clamps to zero.
///
/// **Step 2 — valuation (Mode B: fiat at current spot price).** `y =
/// Σ quantity_token(T) × currentSpot_token`, where the spot comes from
/// `priceCache` (keyed by uppercased symbol — the call sites' canonical
/// storage). Every *movement* in the curve is a transaction; the current
/// price only sets the scale. Deterministic, needs no historical-price
/// series, works on every screen including the multi-asset main total.
/// Accepted caveat: between transactions the line is **flat** (holdings
/// didn't change), and historical points are valued at today's price. A
/// token with no spot price contributes 0 (honest about the gap).
///
/// **Step 3 — curve points (step function).** Over the effective window
/// `[effectiveCutoff, now]` where `effectiveCutoff` is the range's TRUE
/// cutoff (`range.cutoff(now)`) for every finite range — so 1M/1Y/All are
/// genuinely distinct — and the first transaction for `.all` (which has no
/// finite cutoff):
///   1. a **leading point** at `effectiveCutoff` valued from the holdings
///      accumulated over every transaction BEFORE the window — so the line
///      starts at the true balance-as-of-window-start (zero for an account
///      whose first-ever event is a receive; the genuine non-zero
///      one-period-ago balance for an older wallet);
///   2. a **before/after step pair** for every in-window transaction (the
///      before-point 1 ms earlier carries the pre-tx value, drawing a
///      vertical step); and
///   3. a **trailing point at `now`** = the latest running value × current
///      price. NOT snapped to any live balance snapshot.
/// Between transactions there are no points and the value is constant → the
/// renderer draws a correct flat segment.
///
/// **Edge cases.**
///   • No transactions in the window → a flat line at the running balance
///     as of `effectiveCutoff` ("the wallet sat here all week").
///   • No transactions ever → empty; the caller draws the zero baseline.
///   • A window whose first event is an outgoing send keeps its true
///     pre-state; an account whose first-ever event is a receive starts at 0.
///
/// **Key normalization.** Transaction adapters write `tokenContract`
/// verbatim (Etherscan-family lowercases EVM contracts) while other code
/// may use EIP-55 checksummed form; a byte-for-byte key would split the
/// same token into two running buckets. `TokenKey` folds symbols to
/// uppercase and contracts to lowercase at construction. Stored records
/// keep their verbatim casing — folding is internal matching only.
///
/// **Pure function.** No SwiftUI dependency; safely callable from any
/// actor (the heavy work runs off-main via the snapshot overload).
enum BalanceHistoryReconstructor {

    /// `Sendable` snapshot of the transaction fields the reconstruction
    /// reads — lets the walk run OFF the main actor. `TransactionRecord`
    /// is a main-context `@Model` and isn't `Sendable`; the caller copies
    /// the few needed fields on the main actor then hands these value
    /// types to a detached task.
    struct HistoryTx: Sendable {
        let occurredAt: Date
        let statusRaw: String
        let tokenSymbol: String
        let tokenContract: String?
        let amountRaw: String
        let directionRaw: String
        /// The other side of the transfer (receiver for `.out`, sender for
        /// `.in`). Used to drop self-transfers — see the `ownAddresses`
        /// filter in `reconstruct`.
        let counterparty: String
    }

    /// `@Model` convenience overload — maps the SwiftData records to
    /// `Sendable` snapshots and calls the core. Kept so call sites and the
    /// test suite read naturally; off-main callers use the snapshot
    /// overload directly.
    static func reconstruct(
        transactions: [TransactionRecord],
        priceCache: [String: Decimal] = [:],
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
            priceCache: priceCache,
            ownAddresses: ownAddresses,
            range: range,
            now: now
        )
    }

    /// Core reconstruction over `Sendable` snapshots — `nonisolated` so it
    /// can run on a detached background task without touching the main
    /// actor. Mode B: holdings ledger from transactions, valued at current
    /// spot. Returns sample points oldest-to-newest, or `[]` when the
    /// scope has no transactions (the honest "no history yet" state).
    nonisolated static func reconstruct(
        txSnapshots: [HistoryTx],
        priceCache: [String: Decimal] = [:],
        ownAddresses: Set<String> = [],
        range: BalanceHistoryRange,
        now: Date = Date()
    ) -> [BalancePoint] {
        let cutoff = range.cutoff(from: now)

        // The truth source: non-failed, non-self-transfer transactions,
        // oldest-first. Pending count (real intent — they flip to confirmed
        // in place); failed never moved a balance. A self-transfer (to/from
        // one of the wallet's OWN addresses) nets to zero, so dropping it
        // keeps the curve flat across a self-send.
        let sorted = txSnapshots
            .filter { $0.statusRaw != TransactionStatus.failed.rawValue }
            .filter { tx in
                tx.counterparty.isEmpty
                    || !ownAddresses.contains(tx.counterparty.lowercased())
            }
            .sorted { $0.occurredAt < $1.occurredAt }

        // No transactions at all → empty. Mode B is purely
        // transaction-sourced: with no transactions there is no balance to
        // draw (the caller renders the zero baseline). No balance-snapshot
        // plateau, no fabricated history.
        guard !sorted.isEmpty else { return [] }

        // Valuation — Mode B. Σ quantity × current spot. A token with no
        // spot price contributes 0 (honest gap, never a guess).
        func value(_ quantities: [TokenKey: Decimal]) -> Decimal {
            var sum = Decimal.zero
            for (key, qty) in quantities where qty > 0 {
                if let price = priceCache[key.symbol] {
                    sum += qty * price
                }
            }
            return sum
        }

        // Effective window start = the range's TRUE cutoff (2026-06-19 Bug 3
        // fix). The old `max(cutoff, firstTxDate)` clamp collapsed 1M/1Y/All
        // to `[firstTx, now]` whenever activity was recent — making three
        // different ranges draw an identical curve + percent. Using the real
        // cutoff keeps every range distinct: a young wallet's 1Y correctly
        // shows a long flat-zero lead (no holdings a year ago) then the recent
        // shape; an older wallet's 1M leads at its genuine one-month-ago
        // balance. `.all` has no finite cutoff (`.distantPast`), so it — and
        // ONLY it — anchors to the first transaction (no eon-long lead). The
        // pre-window walk below values the lead honestly: 0 before any
        // funding, never fabricated.
        let firstTxDate = sorted[0].occurredAt
        let effectiveCutoff: Date = (range == .all) ? firstTxDate : cutoff

        // Forward walk: accumulate every PRE-window transaction so the
        // leading anchor carries the true balance-as-of-window-start.
        var running: [TokenKey: Decimal] = [:]
        var index = 0
        while index < sorted.count, sorted[index].occurredAt < effectiveCutoff {
            apply(sorted[index], to: &running)
            index += 1
        }
        let inWindow = sorted[index...]

        // No in-window transactions → flat line at the pre-window value
        // across `[effectiveCutoff, now]`. The held quantity didn't change
        // in this window, so under transaction-sourcing the balance is flat
        // ("the wallet sat here all week"). Mode B values both endpoints at
        // the same current spot, so the change pill honestly reads 0%.
        if inWindow.isEmpty {
            let v = value(running)
            return [
                BalancePoint(timestamp: effectiveCutoff, fiat: v),
                BalancePoint(timestamp: now, fiat: v),
            ]
        }

        var points: [BalancePoint] = []
        points.reserveCapacity(inWindow.count * 2 + 2)

        // A 1 ms backstep keeps the step pair's timestamps strictly
        // increasing so the time-proportional renderer draws a vertical step.
        let step: TimeInterval = 0.001

        // Leading anchor at the window start carrying the pre-window value.
        // For a young wallet / `.all` this is `(firstTx, 0)` — the true
        // pre-state (zero) before the first receive; the step pair below
        // then lifts the line to the first held balance.
        points.append(BalancePoint(timestamp: effectiveCutoff, fiat: value(running)))

        for tx in inWindow {
            // An unparseable amount can't change state — skip the pair.
            guard Decimal(string: tx.amountRaw) != nil else { continue }
            let beforeValue = value(running)
            let lastTs = points[points.count - 1].timestamp
            // Before-point just before the tx (the pre-tx value). Clamped so
            // it never precedes the previous point — at the window start the
            // leading anchor already carries this value, so the before-point
            // is simply dropped there.
            let beforeTs = tx.occurredAt.addingTimeInterval(-step)
            if beforeTs > lastTs {
                points.append(BalancePoint(timestamp: beforeTs, fiat: beforeValue))
            }
            apply(tx, to: &running)
            let afterValue = value(running)
            // After-point at the tx instant, nudged strictly past the last
            // point so coincident transactions (e.g. a swap's out+in at one
            // timestamp) and a tx at the window start can't collapse the step.
            let prevTs = points[points.count - 1].timestamp
            let afterTs = tx.occurredAt > prevTs ? tx.occurredAt : prevTs.addingTimeInterval(step)
            points.append(BalancePoint(timestamp: afterTs, fiat: afterValue))
        }

        // Trailing anchor at `now` = the latest transaction-derived value.
        // NEVER snapped to a live balance snapshot (Mode B contract).
        let lastTs = points[points.count - 1].timestamp
        if now > lastTs {
            points.append(BalancePoint(timestamp: now, fiat: value(running)))
        }

        return points
    }

    // MARK: - Helpers

    /// Apply one transaction's effect to the running per-token quantities,
    /// forward in time: incoming adds, outgoing subtracts, internal
    /// (own-address shuffle) is a no-op. Negative residue clamps to zero.
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

    /// Normalized per-token identity. Symbols fold to uppercase; contracts
    /// fold to lowercase; empty contracts collapse to `nil` (native coins)
    /// — so a transaction (explorer-verbatim lowercase contract) and a
    /// registry-cased reference land under one key. Folding is internal
    /// matching only — stored records keep their verbatim casing.
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
