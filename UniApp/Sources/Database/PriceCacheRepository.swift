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
}
