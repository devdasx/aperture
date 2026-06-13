import Foundation
import SwiftData

/// On-disk repository for `HistoricalPriceRecord`. Mirror of
/// `PriceCacheRepository` (which holds the latest spot) but for
/// per-day historical close prices used by
/// `BalanceHistoryReconstructor` to value past holdings at their
/// then-prices.
///
/// **Why this is separate from `PriceCacheRepository`.** Latest
/// spot rotates fast (every refresh overwrites the row); historical
/// close prices are immutable per day. Splitting the actors lets the
/// historical table grow without churn on the spot row, and lets the
/// historical fetcher write through a single owner without
/// interleaving with the live spot writer.
@ModelActor
actor HistoricalPriceRepository {

    /// Upsert one day's close price. Idempotent. The composite key
    /// `"SYMBOL-FIAT-yyyymmdd"` lets duplicate writes collapse to a
    /// fetch-then-update.
    func upsert(symbol: String, fiat: String, dayKey: Int, price: Decimal) throws {
        let upperSymbol = symbol.uppercased()
        let upperFiat = fiat.uppercased()
        let key = "\(upperSymbol)-\(upperFiat)-\(dayKey)"
        var descriptor = FetchDescriptor<HistoricalPriceRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.price = price
            existing.fetchedAt = Date()
        } else {
            let record = HistoricalPriceRecord(
                symbol: upperSymbol,
                fiat: upperFiat,
                dayKey: dayKey,
                price: price
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    /// Bulk upsert. One transaction commit instead of N. Used by
    /// `CoinbaseHistoricalPriceService` to write ~300 daily candles in
    /// one shot after a single network round-trip.
    func upsertMany(_ entries: [(symbol: String, fiat: String, dayKey: Int, price: Decimal)]) throws {
        for entry in entries {
            let upperSymbol = entry.symbol.uppercased()
            let upperFiat = entry.fiat.uppercased()
            let key = "\(upperSymbol)-\(upperFiat)-\(entry.dayKey)"
            var descriptor = FetchDescriptor<HistoricalPriceRecord>(
                predicate: #Predicate { $0.key == key }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                existing.price = entry.price
                existing.fetchedAt = Date()
            } else {
                let record = HistoricalPriceRecord(
                    symbol: upperSymbol,
                    fiat: upperFiat,
                    dayKey: entry.dayKey,
                    price: entry.price
                )
                modelContext.insert(record)
            }
        }
        try modelContext.save()
    }

    /// All historical prices for one symbol in one fiat, keyed by
    /// dayKey. The reconstructor consumes this shape directly —
    /// O(1) per point lookup.
    func priceSeries(symbol: String, fiat: String) throws -> [Int: Decimal] {
        let upperSymbol = symbol.uppercased()
        let upperFiat = fiat.uppercased()
        let descriptor = FetchDescriptor<HistoricalPriceRecord>(
            predicate: #Predicate { $0.symbol == upperSymbol && $0.fiat == upperFiat }
        )
        let rows = try modelContext.fetch(descriptor)
        var out: [Int: Decimal] = [:]
        out.reserveCapacity(rows.count)
        for r in rows { out[r.dayKey] = r.price }
        return out
    }

    /// All historical prices for many symbols in one fiat. Bulk read
    /// for the chart's reconstruction — single fetch, then in-memory
    /// bucketing by symbol.
    func priceSeriesBySymbol(symbols: [String], fiat: String) throws -> [String: [Int: Decimal]] {
        let upperSymbols = Set(symbols.map { $0.uppercased() })
        let upperFiat = fiat.uppercased()
        let descriptor = FetchDescriptor<HistoricalPriceRecord>(
            predicate: #Predicate { upperSymbols.contains($0.symbol) && $0.fiat == upperFiat }
        )
        let rows = try modelContext.fetch(descriptor)
        var out: [String: [Int: Decimal]] = [:]
        for r in rows {
            out[r.symbol, default: [:]][r.dayKey] = r.price
        }
        return out
    }

    /// Range query — useful when the chart's range is short (`.week`)
    /// and we don't need the full series. dayKeys are inclusive on
    /// both ends.
    func priceSeries(
        symbol: String,
        fiat: String,
        fromDay: Int,
        toDay: Int
    ) throws -> [Int: Decimal] {
        let upperSymbol = symbol.uppercased()
        let upperFiat = fiat.uppercased()
        let descriptor = FetchDescriptor<HistoricalPriceRecord>(
            predicate: #Predicate { row in
                row.symbol == upperSymbol
                    && row.fiat == upperFiat
                    && row.dayKey >= fromDay
                    && row.dayKey <= toDay
            }
        )
        let rows = try modelContext.fetch(descriptor)
        var out: [Int: Decimal] = [:]
        for r in rows { out[r.dayKey] = r.price }
        return out
    }

    /// **Latest-close fallback (2026-06-13).** The most recent daily
    /// close per symbol in `fiat` — the price the chart already values
    /// holdings at. Used as a pricing-engine rung so a balance row is
    /// NEVER written "Price unavailable" when we hold a usable close:
    /// the user reported BTC/ETH showing "Price unavailable" on the
    /// asset screen while the chart (which reads this table) clearly
    /// had the price. Returns at most one entry per symbol (highest
    /// `dayKey`).
    func latestClose(symbols: [String], fiat: String) throws -> [String: Decimal] {
        let upperSymbols = Set(symbols.map { $0.uppercased() })
        let upperFiat = fiat.uppercased()
        guard !upperSymbols.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<HistoricalPriceRecord>(
            predicate: #Predicate { upperSymbols.contains($0.symbol) && $0.fiat == upperFiat },
            sortBy: [SortDescriptor(\.dayKey, order: .reverse)]
        )
        descriptor.fetchLimit = upperSymbols.count * 8  // newest few per symbol; first-seen wins
        let rows = try modelContext.fetch(descriptor)
        var out: [String: Decimal] = [:]
        for r in rows where out[r.symbol] == nil && r.price > 0 {
            out[r.symbol] = r.price
        }
        return out
    }

    /// Cross-currency variant of `latestClose` — the most recent close
    /// per symbol in ANY currency, with that close's own `fiat` so the
    /// caller can FX-convert. The final safety net behind
    /// `latestClose(symbols:fiat:)` for a user who only ever had
    /// historical coverage in a different currency.
    func latestCloseAnyCurrency(
        symbols: [String]
    ) throws -> [String: (price: Decimal, fiat: String)] {
        let upperSymbols = Set(symbols.map { $0.uppercased() })
        guard !upperSymbols.isEmpty else { return [:] }
        var descriptor = FetchDescriptor<HistoricalPriceRecord>(
            predicate: #Predicate { upperSymbols.contains($0.symbol) },
            sortBy: [SortDescriptor(\.dayKey, order: .reverse)]
        )
        descriptor.fetchLimit = upperSymbols.count * 16
        let rows = try modelContext.fetch(descriptor)
        var out: [String: (Decimal, String)] = [:]
        for r in rows where out[r.symbol] == nil && r.price > 0 {
            out[r.symbol] = (r.price, r.fiat)
        }
        return out
    }

    /// Wipe every row. Settings → Advanced → Clear price cache
    /// extends to historical too — the next chart render kicks off
    /// re-fetches from Coinbase as needed.
    func clearAll() throws {
        let descriptor = FetchDescriptor<HistoricalPriceRecord>()
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}

// MARK: - Day key helpers

/// Shared `yyyy * 10000 + mm * 100 + dd` integer encoder. Used by
/// `HistoricalPriceRecord` callers AND by
/// `BalanceHistoryReconstructor` so both sides agree on the day-key
/// representation. Reads `Calendar.current.dateComponents([.year,
/// .month, .day], from: date)` once per call.
enum DayKey {

    /// `2026-04-30` → `20260430`.
    static func from(date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return (comps.year ?? 0) * 10_000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
    }
}
