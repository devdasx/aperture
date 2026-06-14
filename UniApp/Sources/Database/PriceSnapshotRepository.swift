import Foundation
import SwiftData

// MARK: - TokenPriceChange

/// One token's 24-hour price movement in one currency, computed
/// entirely from locally persisted `PriceSnapshotRecord` observations
/// — no network. Produced by
/// `PriceSnapshotRepository.change24h(symbol:currency:now:)`.
struct TokenPriceChange: Sendable {
    /// Uppercased ticker the change describes.
    let symbol: String
    /// Uppercased fiat code both prices are denominated in.
    let currencyCode: String
    /// The newest persisted price (the "now" side of the comparison).
    let currentPrice: Decimal
    /// When `currentPrice` was fetched.
    let currentAt: Date
    /// The ~24h-ago reference price (nearest-neighbor — see
    /// `change24h`'s rule).
    let referencePrice: Decimal
    /// When `referencePrice` was fetched.
    let referenceAt: Date
    /// `currentPrice - referencePrice`. Positive = price went up.
    let absolute: Decimal
    /// `absolute / referencePrice × 100`. Exact `Decimal` math.
    let percent: Decimal
}

// MARK: - PriceSnapshotRepository

/// Actor-isolated owner of the append-only `PriceSnapshotRecord`
/// table. Three jobs:
///
/// 1. **Record** — `record(_:at:)` batch-appends every live quote the
///    `TokenPricingEngine` resolves, then prunes.
/// 2. **Answer** — `latest(symbol:currency:)` and
///    `change24h(symbol:currency:now:)` serve the 24h-change surface
///    from local observations only.
/// 3. **Bound** — `prune(now:)` enforces the documented growth bound:
///    everything ≤ 48 h old kept verbatim; older rows decimated to one
///    per `(symbol, currency, day)` — the last observation of the day.
///
/// Per `CLAUDE.md` Rule #2 §C (actor-isolated repositories).
@ModelActor
actor PriceSnapshotRepository {

    /// Raw-retention window: snapshots younger than this are never
    /// decimated.
    static let rawRetentionWindow: TimeInterval = 48 * 3600

    /// Half-width of the reference window around the −24 h target used
    /// by `change24h` — i.e. candidates between 22 h and 26 h old.
    static let referenceWindowHalfWidth: TimeInterval = 2 * 3600

    // MARK: - Record

    /// Batch-append one observation per entry, all stamped `now`, then
    /// prune. One save for the whole batch (one batch per pricing-
    /// ladder run — the `PriceCacheRepository.upsertMany` precedent).
    ///
    /// Symbols and currency codes are uppercased by the record's init;
    /// callers may pass any casing.
    func record(
        _ entries: [(symbol: String, currencyCode: String, price: Decimal, source: String)],
        at now: Date = Date()
    ) throws {
        guard !entries.isEmpty else { return }
        for entry in entries {
            modelContext.insert(PriceSnapshotRecord(
                symbol: entry.symbol,
                currencyCode: entry.currencyCode,
                price: entry.price,
                fetchedAt: now,
                source: entry.source
            ))
        }
        // Rule #28: stage the inserts AND the prune deletions, then commit
        // in ONE save (was two — insert-save + prune-save).
        try prune(now: now, save: false)
        try modelContext.save()
    }

    // MARK: - Latest

    /// Newest persisted observation for `(symbol, currency)`, or `nil`
    /// when the pair has never been fetched live.
    func latest(symbol: String, currency: String) throws -> (price: Decimal, fetchedAt: Date)? {
        guard let record = try latestRecord(symbol: symbol, currency: currency) else { return nil }
        return (record.price, record.fetchedAt)
    }

    private func latestRecord(symbol: String, currency: String) throws -> PriceSnapshotRecord? {
        let upperSymbol = symbol.uppercased()
        let upperCurrency = currency.uppercased()
        var descriptor = FetchDescriptor<PriceSnapshotRecord>(
            predicate: #Predicate { $0.symbol == upperSymbol && $0.currencyCode == upperCurrency },
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Every persisted observation for `(symbol, currency)`, oldest
    /// first. Powers diagnostics, the pruning tests, and any future
    /// local price sparkline.
    func observations(symbol: String, currency: String) throws -> [(price: Decimal, fetchedAt: Date)] {
        let upperSymbol = symbol.uppercased()
        let upperCurrency = currency.uppercased()
        let descriptor = FetchDescriptor<PriceSnapshotRecord>(
            predicate: #Predicate { $0.symbol == upperSymbol && $0.currencyCode == upperCurrency },
            sortBy: [SortDescriptor(\.fetchedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map { ($0.price, $0.fetchedAt) }
    }

    // MARK: - 24h change

    /// Price movement over the last ~24 hours for `(symbol, currency)`.
    ///
    /// **Nearest-neighbor rule.** The reference is the snapshot whose
    /// `fetchedAt` is closest to `now − 24h`, considering ONLY
    /// snapshots inside the `[now − 26h, now − 24h ± 2h … now − 22h]`
    /// window (±2 h around the target). Ties — two candidates equally
    /// distant from the target — resolve to the EARLIER snapshot (the
    /// ascending scan only replaces the best candidate on a strictly
    /// smaller delta).
    ///
    /// Returns `nil` when the change cannot be stated honestly:
    /// - no snapshot exists in the ±2 h reference window (the app
    ///   hasn't been observing prices for ~24 h yet), or
    /// - the newest snapshot is itself older than 22 h (a "current"
    ///   price that stale would make the comparison meaningless —
    ///   refresh prices first), or
    /// - the reference price is non-positive (cannot divide; corrupt
    ///   or zero observation).
    func change24h(
        symbol: String,
        currency: String,
        now: Date = Date()
    ) throws -> TokenPriceChange? {
        let upperSymbol = symbol.uppercased()
        let upperCurrency = currency.uppercased()

        let windowStart = now.addingTimeInterval(-(24 * 3600 + Self.referenceWindowHalfWidth))
        let windowEnd = now.addingTimeInterval(-(24 * 3600 - Self.referenceWindowHalfWidth))

        guard
            let current = try latestRecord(symbol: upperSymbol, currency: upperCurrency),
            current.fetchedAt > windowEnd
        else {
            return nil
        }

        let descriptor = FetchDescriptor<PriceSnapshotRecord>(
            predicate: #Predicate { row in
                row.symbol == upperSymbol
                    && row.currencyCode == upperCurrency
                    && row.fetchedAt >= windowStart
                    && row.fetchedAt <= windowEnd
            },
            sortBy: [SortDescriptor(\.fetchedAt, order: .forward)]
        )
        let candidates = try modelContext.fetch(descriptor)

        let target = now.addingTimeInterval(-24 * 3600)
        var reference: PriceSnapshotRecord?
        var bestDelta: TimeInterval = .infinity
        for row in candidates {
            let delta = abs(row.fetchedAt.timeIntervalSince(target))
            if delta < bestDelta {
                bestDelta = delta
                reference = row
            }
        }

        guard let reference, reference.price > 0 else { return nil }

        let absolute = current.price - reference.price
        let percent = absolute / reference.price * 100
        return TokenPriceChange(
            symbol: upperSymbol,
            currencyCode: upperCurrency,
            currentPrice: current.price,
            currentAt: current.fetchedAt,
            referencePrice: reference.price,
            referenceAt: reference.fetchedAt,
            absolute: absolute,
            percent: percent
        )
    }

    /// Bulk variant for list surfaces — one repository hop for a whole
    /// token list. Symbols absent from the result had no honest 24h
    /// answer (see `change24h`'s nil conditions).
    func changes24h(
        symbols: [String],
        currency: String,
        now: Date = Date()
    ) throws -> [String: TokenPriceChange] {
        var out: [String: TokenPriceChange] = [:]
        for symbol in Set(symbols.map { $0.uppercased() }) {
            if let change = try change24h(symbol: symbol, currency: currency, now: now) {
                out[symbol] = change
            }
        }
        return out
    }

    // MARK: - Prune

    /// Enforce the growth bound: keep every snapshot ≤ 48 h old;
    /// beyond 48 h decimate to one row per `(symbol, currency, day)` —
    /// the LAST observation of the day (the `HistoricalPriceRecord`
    /// daily-close convention). Idempotent; runs after every
    /// `record(_:at:)` batch.
    func prune(now: Date = Date(), save: Bool = true) throws {
        let cutoff = now.addingTimeInterval(-Self.rawRetentionWindow)
        let descriptor = FetchDescriptor<PriceSnapshotRecord>(
            predicate: #Predicate { $0.fetchedAt < cutoff },
            sortBy: [SortDescriptor(\.fetchedAt, order: .forward)]
        )
        let oldRows = try modelContext.fetch(descriptor)
        guard !oldRows.isEmpty else { return }

        // Keep the latest row per (symbol, currency, day); delete the
        // rest. The ascending scan means a later row in the same group
        // replaces the current keeper (and deletes it).
        var keeperByGroup: [String: PriceSnapshotRecord] = [:]
        for row in oldRows {
            let groupKey = "\(row.symbol)|\(row.currencyCode)|\(row.dayKey)"
            if let keeper = keeperByGroup[groupKey] {
                if row.fetchedAt >= keeper.fetchedAt {
                    modelContext.delete(keeper)
                    keeperByGroup[groupKey] = row
                } else {
                    modelContext.delete(row)
                }
            } else {
                keeperByGroup[groupKey] = row
            }
        }
        if save && modelContext.hasChanges {
            try modelContext.save()
        }
    }

    // MARK: - Reset

    /// Wipe every snapshot row. Settings → Advanced "clear price
    /// cache" class of reset, and the wallet-reset flow, extend to
    /// this table (see the reset-coverage note in the build report).
    func deleteAll() throws {
        let descriptor = FetchDescriptor<PriceSnapshotRecord>()
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
