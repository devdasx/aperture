import Foundation

// MARK: - BalancePoint

/// One sample on the reconstructed balance curve. `timestamp` is the
/// moment the wallet was in this state; `fiat` is its total value in the
/// user's preferred currency — valued at the **historical** per-unit price
/// for that instant (Mode C), with the trailing tip at the current spot.
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

/// Reconstructs a wallet's balance curve through time. **Holdings come
/// only from transactions; valuation uses the DB's stored historical
/// prices** (2026-06-19 Mode C — per user direction: make the chart move
/// with the market across the full window, like Coinbase/Zerion).
///
/// **The principle.** Holdings at any instant `T` are a pure function of
/// the transactions up to `T`. The *value* of those holdings is the
/// market value at `T` — so the curve moves every day with the market even
/// when no transaction happened, and a buy/sell shows as a step on top of
/// the moving curve.
///
/// **Step 1 — holdings ledger (100% from transactions, unchanged).**
/// Forward walk oldest-first, `+in / −out / internal-no-op`, negatives
/// clamp to zero, self-transfers net out (the `ownAddresses` filter),
/// failed excluded / pending included, contract casing folded.
///
/// **Step 2 — valuation (Mode C: historical price per instant).** The
/// window `[effectiveCutoff, now]` is sampled on a time grid (daily, capped
/// for render perf; weekly for a multi-year `.all`). Each grid instant is
/// valued `Σ quantity_token(asOf t) × historicalClose(token, UTCday(t))`,
/// reading `HistoricalPriceRecord` closes keyed by the UTC day. A token
/// with no close at `t` **carries the nearest prior close forward** (never
/// zero); spot is the last-resort fallback. Holdings are sampled at one
/// distinct timestamp per grid instant AND per in-window transaction (no
/// zero-width step pair), so a trade shows as a smooth steep RAMP from the
/// prior grid point into its new level — which the monotone-cubic renderer
/// draws curvy and overshoot-free. The trailing **tip at `now` uses the
/// current spot price** so the chart's end equals the live hero balance.
///
/// **Window — trim the empty lead.** `effectiveStart = max(range cutoff,
/// first transaction)`. Where the wallet has a full range of history the
/// ranges differ (1M = a month, 1Y = a year); where a range is longer than
/// the wallet's history it trims to the available data and fills the width,
/// so a very young wallet's 1M/1Y/All converge on the same filled, alive
/// curve rather than showing an empty flat-zero lead.
///
/// **Edge cases.** No transactions → empty (the caller draws the zero
/// baseline). A window with no in-window transactions but held holdings →
/// a curve that still moves with the market (the Mode C point) rather than
/// a flat line.
///
/// **Key normalization.** `TokenKey` folds symbols to uppercase and
/// contracts to lowercase so a transaction (explorer-verbatim contract)
/// and the price/registry reference land under one key.
///
/// **Pure function.** No SwiftUI dependency; the heavy work runs off-main
/// via the snapshot overload.
enum BalanceHistoryReconstructor {

    /// `Sendable` snapshot of the transaction fields the reconstruction
    /// reads — lets the walk run OFF the main actor. The caller copies the
    /// few needed fields from the main-context `@Model` then hands these
    /// value types to a detached task.
    struct HistoryTx: Sendable {
        let occurredAt: Date
        let statusRaw: String
        let tokenSymbol: String
        let tokenContract: String?
        let amountRaw: String
        let directionRaw: String
        /// The other side of the transfer (receiver for `.out`, sender for
        /// `.in`). Used to drop self-transfers.
        let counterparty: String
    }

    /// `@Model` convenience overload — maps the SwiftData records to
    /// `Sendable` snapshots and calls the core. Off-main callers use the
    /// snapshot overload directly.
    static func reconstruct(
        transactions: [TransactionRecord],
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
            priceCache: priceCache,
            priceHistory: priceHistory,
            ownAddresses: ownAddresses,
            range: range,
            now: now
        )
    }

    /// Core reconstruction over `Sendable` snapshots — `nonisolated` so it
    /// can run on a detached background task. Mode C: holdings ledger from
    /// transactions, valued at each instant's historical price (tip at
    /// spot). Returns sample points oldest-to-newest, or `[]` when the
    /// scope has no transactions.
    nonisolated static func reconstruct(
        txSnapshots: [HistoryTx],
        priceCache: [String: Decimal] = [:],
        priceHistory: [String: [Int: Decimal]] = [:],
        ownAddresses: Set<String> = [],
        range: BalanceHistoryRange,
        now: Date = Date()
    ) -> [BalancePoint] {
        let cutoff = range.cutoff(from: now)

        // Non-failed, non-self-transfer transactions, oldest-first.
        let sorted = txSnapshots
            .filter { $0.statusRaw != TransactionStatus.failed.rawValue }
            .filter { tx in
                tx.counterparty.isEmpty
                    || !ownAddresses.contains(tx.counterparty.lowercased())
            }
            .sorted { $0.occurredAt < $1.occurredAt }

        // No transactions → empty (the caller renders the zero baseline).
        guard !sorted.isEmpty else { return [] }

        // Sorted day-keys per symbol for carry-forward (last-known close).
        var sortedDays: [String: [Int]] = [:]
        for (sym, series) in priceHistory { sortedDays[sym] = series.keys.sorted() }

        // Historical close for a symbol on a UTC day, carrying the nearest
        // PRIOR close forward when the exact day is missing (never zero). An
        // instant before the series begins uses the earliest close.
        func historicalClose(_ symbol: String, _ dayKey: Int) -> Decimal? {
            guard let series = priceHistory[symbol],
                  let days = sortedDays[symbol], let first = days.first else { return nil }
            if let exact = series[dayKey] { return exact }
            if dayKey < first { return series[first] }
            var lo = 0, hi = days.count - 1, best = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if days[mid] <= dayKey { best = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return best >= 0 ? series[days[best]] : nil
        }

        // Mode C valuation at an instant — holdings × that day's historical
        // close (carry-forward), spot as the last-resort fallback.
        func histValue(_ quantities: [TokenKey: Decimal], at date: Date) -> Decimal {
            let dayKey = DayKey.from(date: date)
            var sum = Decimal.zero
            for (key, qty) in quantities where qty > 0 {
                let price = historicalClose(key.symbol, dayKey) ?? priceCache[key.symbol]
                if let price { sum += qty * price }
            }
            return sum
        }

        // Spot valuation for the `now` tip so the chart end == the hero.
        func spotValue(_ quantities: [TokenKey: Decimal]) -> Decimal {
            var sum = Decimal.zero
            for (key, qty) in quantities where qty > 0 {
                if let price = priceCache[key.symbol] { sum += qty * price }
            }
            return sum
        }

        // **Window — trim the empty lead (FIX 2).** `effectiveStart =
        // max(range cutoff, first transaction)`. A range longer than the
        // wallet's history trims to the available data and fills the width
        // (a very young wallet's 1M/1Y/All converge on the same filled, alive
        // curve) instead of pinning flat-zero at the bottom for most of the
        // range. `.all`'s `.distantPast` cutoff collapses to the first
        // transaction here too.
        let firstTxDate = sorted[0].occurredAt
        let effectiveStart = max(cutoff, firstTxDate)

        // Pre-window holdings (every transaction strictly before the window).
        var preWindow: [TokenKey: Decimal] = [:]
        var idx = 0
        while idx < sorted.count, sorted[idx].occurredAt < effectiveStart {
            apply(sorted[idx], to: &preWindow)
            idx += 1
        }
        let inWindow = Array(sorted[idx...])

        // **Distinct sample timestamps (FIX 1a — no zero-width step pair).** The
        // market grid (which already includes `effectiveStart` and `now`) plus
        // ONE timestamp per in-window transaction. Every x is distinct and well
        // separated, so the monotone-cubic renderer is well-defined; a
        // transaction shows as a smooth steep RAMP from the prior grid point
        // into its new level, not a vertical riser.
        var timeSet = Set(sampleGrid(from: effectiveStart, to: now, range: range))
        for tx in inWindow where Decimal(string: tx.amountRaw) != nil {
            if tx.occurredAt >= effectiveStart, tx.occurredAt <= now {
                timeSet.insert(tx.occurredAt)
            }
        }
        let times = timeSet.sorted()

        // Forward sweep: at each instant the holdings are the pre-window state
        // plus every in-window transaction at or before it (so a transaction's
        // effect appears from its own timestamp onward). Value historically,
        // except the `now` tip which uses current spot — so the chart's right
        // edge equals the live hero balance.
        var running = preWindow
        var txIdx = 0
        var points: [BalancePoint] = []
        points.reserveCapacity(times.count)
        for t in times {
            while txIdx < inWindow.count, inWindow[txIdx].occurredAt <= t {
                apply(inWindow[txIdx], to: &running)
                txIdx += 1
            }
            let value = (t == now) ? spotValue(running) : histValue(running, at: t)
            points.append(BalancePoint(timestamp: t, fiat: value))
        }
        return points
    }

    // MARK: - Helpers

    /// Evenly-spaced sample instants over `[start, end]` at a per-range
    /// cadence, capped to ~`maxPoints` so a long span stays render-cheap.
    /// Always includes `start` and `end`. Granularity is **daily** (the
    /// finest the `HistoricalPriceRecord` close table supports); sub-day
    /// ranges (1H/1D) therefore collapse to ~2 points at daily closes — we
    /// do NOT fabricate intraday wiggle. `.all` over a multi-year span
    /// steps weekly.
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

    /// Apply one transaction's effect to the running per-token quantities,
    /// forward in time: incoming adds, outgoing subtracts, internal is a
    /// no-op. Negative residue clamps to zero.
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
    /// fold to lowercase; empty contracts collapse to `nil` (native coins).
    /// Internal matching only — stored records keep their verbatim casing.
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
