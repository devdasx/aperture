import Foundation
import GRDB

final class PriceCacheRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func upsert(symbol: String, fiat: String, price: Decimal, source: String) throws {
        try upsertMany([(symbol: symbol, fiat: fiat, price: price, source: source)])
    }

    func upsertMany(_ entries: [(symbol: String, fiat: String, price: Decimal, source: String)]) throws {
        guard !entries.isEmpty else { return }
        let now = Date.databaseMilliseconds
        try database.write { db in
            for entry in entries {
                let symbol = entry.symbol.uppercased()
                let fiat = entry.fiat.uppercased()
                let key = "\(symbol)-\(fiat)"
                try db.execute(
                    sql: """
                    INSERT INTO cached_prices
                    (key, symbol, fiat, price, price_numeric, fetched_at_ms, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        price = excluded.price,
                        price_numeric = excluded.price_numeric,
                        fetched_at_ms = excluded.fetched_at_ms,
                        source = excluded.source
                    WHERE cached_prices.price != excluded.price
                       OR cached_prices.source != excluded.source
                    """,
                    arguments: [
                        key,
                        symbol,
                        fiat,
                        entry.price.databaseText,
                        entry.price.databaseDouble,
                        now,
                        entry.source
                    ]
                )
            }
        }
    }

    func price(symbol: String, fiat: String) throws -> (price: Decimal, fetchedAt: Date)? {
        let key = "\(symbol.uppercased())-\(fiat.uppercased())"
        return try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT price, fetched_at_ms FROM cached_prices WHERE key = ?", arguments: [key]) else {
                return nil
            }
            return (Decimal(string: row["price"] as String) ?? 0, Date(databaseMilliseconds: row["fetched_at_ms"]))
        }
    }

    func clearAll() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM cached_prices") }
    }

    func prices(symbols: [String], fiat: String) throws -> [String: (price: Decimal, fetchedAt: Date)] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        let fiat = fiat.uppercased()
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT symbol, price, fetched_at_ms FROM cached_prices WHERE fiat = ?", arguments: [fiat])
            var out: [String: (Decimal, Date)] = [:]
            for row in rows {
                let symbol: String = row["symbol"]
                guard wanted.contains(symbol) else { continue }
                out[symbol] = (Decimal(string: row["price"] as String) ?? 0, Date(databaseMilliseconds: row["fetched_at_ms"]))
            }
            return out
        }
    }

    func latestPriceAnyCurrency(symbols: [String]) throws -> [String: (price: Decimal, fiat: String, fetchedAt: Date)] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT symbol, fiat, price, fetched_at_ms FROM cached_prices ORDER BY fetched_at_ms DESC"
            )
            var out: [String: (Decimal, String, Date)] = [:]
            for row in rows {
                let symbol: String = row["symbol"]
                guard wanted.contains(symbol), out[symbol] == nil else { continue }
                let price = Decimal(string: row["price"] as String) ?? 0
                guard price > 0 else { continue }
                out[symbol] = (price, row["fiat"], Date(databaseMilliseconds: row["fetched_at_ms"]))
            }
            return out
        }
    }
}
