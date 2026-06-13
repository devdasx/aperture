import Foundation
import SwiftData

/// On-disk price cache repository. Mirror of `CoinbasePriceService`'s
/// in-memory cache, but disk-backed so cold launches render
/// fiat-equivalent balances instantly (using the last-known price)
/// before the live fetch resolves and updates the row.
///
/// **TTL.** No hard expiry — the wallet screen happily renders a stale
/// price as long as the source label + age footer make the staleness
/// honest (per Rule #16's "name what you don't know"). The live
/// `CoinbasePriceService` write replaces the cached price as it arrives.
@ModelActor
actor PriceCacheRepository {

    /// Upsert a price by `(symbol, fiat)`. Touches `fetchedAt` so the
    /// wallet screen can compute "1m ago" style ages.
    func upsert(symbol: String, fiat: String, price: Decimal, source: String) throws {
        let key = "\(symbol)-\(fiat)"
        var descriptor = FetchDescriptor<CachedPriceRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.price = price
            existing.fetchedAt = Date()
            existing.source = source
        } else {
            let record = CachedPriceRecord(symbol: symbol, fiat: fiat, price: price, source: source)
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    /// Bulk upsert — one fetch + one save for a whole refresh's worth
    /// of live quotes (the `TokenPricingEngine` writes every freshly
    /// resolved `(symbol, currency)` price here so the per-currency
    /// cache rung can answer after a provider failure). Same
    /// fetch-then-update semantics as the single `upsert`, amortized
    /// across one actor hop.
    func upsertMany(_ entries: [(symbol: String, fiat: String, price: Decimal, source: String)]) throws {
        guard !entries.isEmpty else { return }
        let keys = entries.map { "\($0.symbol)-\($0.fiat)" }
        var descriptor = FetchDescriptor<CachedPriceRecord>(
            predicate: #Predicate { keys.contains($0.key) }
        )
        descriptor.fetchLimit = keys.count
        var existingByKey: [String: CachedPriceRecord] = [:]
        for record in try modelContext.fetch(descriptor) {
            existingByKey[record.key] = record
        }
        let now = Date()
        for entry in entries {
            let key = "\(entry.symbol)-\(entry.fiat)"
            if let record = existingByKey[key] {
                record.price = entry.price
                record.fetchedAt = now
                record.source = entry.source
            } else {
                modelContext.insert(CachedPriceRecord(
                    symbol: entry.symbol,
                    fiat: entry.fiat,
                    price: entry.price,
                    fetchedAt: now,
                    source: entry.source
                ))
            }
        }
        try modelContext.save()
    }

    /// Last-known price for a `(symbol, fiat)` pair. Returns `nil` if
    /// never fetched. The wallet screen reads this synchronously on
    /// view-mount for the zero-latency fiat display, then fires a
    /// background refresh via `CoinbasePriceService`.
    func price(symbol: String, fiat: String) throws -> (price: Decimal, fetchedAt: Date)? {
        let key = "\(symbol)-\(fiat)"
        var descriptor = FetchDescriptor<CachedPriceRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return (record.price, record.fetchedAt)
    }

    /// Wipe every cached price row. Settings → Advanced → Clear
    /// price cache. Cheap — the next wallet-home refresh repopulates
    /// from Coinbase.
    func clearAll() throws {
        let descriptor = FetchDescriptor<CachedPriceRecord>()
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Bulk read for the wallet screen's initial render. One database
    /// hit instead of N per-symbol fetches.
    func prices(symbols: [String], fiat: String) throws -> [String: (price: Decimal, fetchedAt: Date)] {
        let keys = symbols.map { "\($0)-\(fiat)" }
        var descriptor = FetchDescriptor<CachedPriceRecord>(
            predicate: #Predicate { keys.contains($0.key) }
        )
        // Keys are unique, so at most one row per requested key — cap
        // the fetch so a degraded in-memory predicate scan stops early.
        descriptor.fetchLimit = keys.count
        let records = try modelContext.fetch(descriptor)
        var out: [String: (Decimal, Date)] = [:]
        for r in records {
            out[r.symbol] = (r.price, r.fetchedAt)
        }
        return out
    }

    /// **Cross-currency fallback (2026-06-13).** For each requested
    /// symbol, the most recently fetched cached price in ANY currency
    /// — the price's own `fiat` is returned alongside so the caller can
    /// FX-convert it to whatever the user is currently displaying.
    ///
    /// This is the "never show Price unavailable for a token we've ever
    /// priced" guarantee: the per-currency cache (`prices(symbols:fiat:)`)
    /// only answers for the active currency, so a user who priced BTC in
    /// JOD then switched to USD — with Coinbase + CoinGecko both failing
    /// — had no BTC/USD cache and saw "Price unavailable". This returns
    /// the BTC/JOD row so the engine can cross it to USD via FX.
    ///
    /// Returns at most one entry per symbol (the newest by `fetchedAt`).
    func latestPriceAnyCurrency(
        symbols: [String]
    ) throws -> [String: (price: Decimal, fiat: String, fetchedAt: Date)] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        // Newest first so the first row seen per symbol is the freshest.
        let descriptor = FetchDescriptor<CachedPriceRecord>(
            sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]
        )
        let records = try modelContext.fetch(descriptor)
        var out: [String: (Decimal, String, Date)] = [:]
        for r in records {
            let upper = r.symbol.uppercased()
            guard wanted.contains(upper), out[upper] == nil, r.price > 0 else { continue }
            out[upper] = (r.price, r.fiat, r.fetchedAt)
            if out.count == wanted.count { break }
        }
        return out
    }
}
