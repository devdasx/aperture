import Foundation

// MARK: - BalancePoint

/// One sample on the reconstructed balance curve. `timestamp` is a real
/// transaction/range boundary; `fiat` is the cumulative local-currency value
/// produced by the transaction ledger up to that instant.
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

/// Reconstructs a wallet's chart from the transaction ledger only.
///
/// **Source of truth.** Timestamps, event count, direction, and native
/// amounts all come from `TransactionRecord` snapshots. Balance rows,
/// snapshot rows, and market-history grids do not create chart points.
///
/// **Local-currency valuation.** A transaction's native amount is converted
/// to the user's currency using the historical close on the transaction's
/// UTC day, falling back to the current cached local price when a close is
/// not available. That price is used only to translate the transaction
/// amount; it never creates extra market-movement samples between
/// transactions.
///
/// **Window.** Each output contains a range-start point, one point per real
/// transaction timestamp in the window, and a trailing `now` point. If there
/// are no transactions at all, the caller draws the zero baseline. If there
/// are no in-window transactions, the result is a flat line based on the
/// pre-window transaction ledger.
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
    /// can run on a detached background task. Returns sample points
    /// oldest-to-newest, or `[]` when the scope has no transactions.
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

        func localFiatAmount(_ tx: HistoryTx) -> Decimal? {
            guard let amount = Decimal(string: tx.amountRaw) else { return nil }
            let symbol = tx.tokenSymbol.uppercased()
            let dayKey = DayKey.from(date: tx.occurredAt)
            guard let price = historicalClose(symbol, dayKey) ?? priceCache[symbol],
                  price > 0 else {
                return nil
            }
            return amount * price
        }

        func signedLocalFiatChange(_ tx: HistoryTx) -> Decimal? {
            guard let fiat = localFiatAmount(tx) else { return nil }
            switch TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing {
            case .incoming:
                return fiat
            case .outgoing:
                return -fiat
            case .internal:
                return 0
            }
        }

        let firstTxDate = sorted[0].occurredAt
        let effectiveStart = max(cutoff, firstTxDate)

        // Pre-window cumulative value (every transaction strictly before the
        // visible window), computed only from transaction events.
        var running = Decimal.zero
        var idx = 0
        while idx < sorted.count, sorted[idx].occurredAt < effectiveStart {
            if let change = signedLocalFiatChange(sorted[idx]) {
                running += change
                if running < 0 { running = 0 }
            }
            idx += 1
        }

        var points: [BalancePoint] = [
            BalancePoint(timestamp: effectiveStart, fiat: running)
        ]
        points.reserveCapacity(sorted.count - idx + 2)

        // One chart event per real transaction timestamp. Transactions that
        // share a timestamp are applied together so the x-axis stays stable.
        var txIdx = idx
        while txIdx < sorted.count, sorted[txIdx].occurredAt <= now {
            let timestamp = sorted[txIdx].occurredAt
            while txIdx < sorted.count, sorted[txIdx].occurredAt == timestamp {
                if let change = signedLocalFiatChange(sorted[txIdx]) {
                    running += change
                    if running < 0 { running = 0 }
                }
                txIdx += 1
            }
            points.append(BalancePoint(timestamp: timestamp, fiat: running))
        }

        if points.last?.timestamp != now {
            points.append(BalancePoint(timestamp: now, fiat: running))
        }
        return points
    }

    // MARK: - Helpers

    // The chart no longer maintains a per-token holdings dictionary. Each
    // point is the cumulative signed local-currency value of transaction
    // events up to that timestamp.
}
