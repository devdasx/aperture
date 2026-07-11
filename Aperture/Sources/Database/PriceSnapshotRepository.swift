import Foundation
import GRDB

struct TokenPriceChange: Sendable {
    let symbol: String
    let currencyCode: String
    let currentPrice: Decimal
    let currentAt: Date
    let referencePrice: Decimal
    let referenceAt: Date
    let absolute: Decimal
    let percent: Decimal
}

struct PriceObservation: Sendable {
    let symbol: String
    let currencyCode: String
    let price: Decimal
    let fetchedAt: Date
}

final class PriceSnapshotRepository {
    static let rawRetentionWindow: TimeInterval = 48 * 3600
    static let referenceWindowHalfWidth: TimeInterval = 2 * 3600

    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func record(
        _ entries: [(symbol: String, currencyCode: String, price: Decimal, source: String)],
        at now: Date = Date()
    ) throws {
        guard !entries.isEmpty else { return }
        let nowMs = now.databaseMilliseconds
        try database.write { db in
            for entry in entries {
                let symbol = entry.symbol.uppercased()
                let currency = entry.currencyCode.uppercased()
                try db.execute(
                    sql: """
                    INSERT INTO price_snapshots
                    (id, symbol, currency_code, price, price_numeric, fetched_at_ms, source, day_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        symbol,
                        currency,
                        entry.price.databaseText,
                        entry.price.databaseDouble,
                        nowMs,
                        entry.source,
                        DayKey.from(date: now)
                    ]
                )
            }
            try prune(db: db, now: now)
        }
    }

    func latest(symbol: String, currency: String) throws -> (price: Decimal, fetchedAt: Date)? {
        try database.read { db in
            guard let row = try latestRow(db: db, symbol: symbol, currency: currency) else { return nil }
            return (Decimal(string: row["price"] as String) ?? 0, Date(databaseMilliseconds: row["fetched_at_ms"]))
        }
    }

    func nearest(
        symbol: String,
        currency: String,
        to target: Date,
        tolerance: TimeInterval
    ) throws -> (price: Decimal, fetchedAt: Date, source: String)? {
        let start = target.addingTimeInterval(-tolerance)
        let end = target.addingTimeInterval(tolerance)
        return try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT price, fetched_at_ms, source
                FROM price_snapshots
                WHERE symbol = ? AND currency_code = ?
                  AND fetched_at_ms >= ? AND fetched_at_ms <= ?
                  AND price_numeric > 0
                ORDER BY ABS(fetched_at_ms - ?) ASC
                LIMIT 1
                """,
                arguments: [
                    symbol.uppercased(),
                    currency.uppercased(),
                    start.databaseMilliseconds,
                    end.databaseMilliseconds,
                    target.databaseMilliseconds
                ]
            ) else { return nil }
            return (
                Decimal(string: row["price"] as String) ?? 0,
                Date(databaseMilliseconds: row["fetched_at_ms"]),
                row["source"]
            )
        }
    }

    func observations(symbol: String, currency: String) throws -> [(price: Decimal, fetchedAt: Date)] {
        let symbol = symbol.uppercased()
        let currency = currency.uppercased()
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT price, fetched_at_ms FROM price_snapshots
                WHERE symbol = ? AND currency_code = ?
                ORDER BY fetched_at_ms ASC
                """,
                arguments: [symbol, currency]
            ).map { (Decimal(string: $0["price"] as String) ?? 0, Date(databaseMilliseconds: $0["fetched_at_ms"])) }
        }
    }

    func recentObservations(
        symbols: Set<String>,
        currency: String,
        since: Date,
        until: Date = Date()
    ) throws -> [PriceObservation] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [] }
        let currency = currency.uppercased()
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT symbol, currency_code, price, fetched_at_ms
                FROM price_snapshots
                WHERE currency_code = ? AND fetched_at_ms >= ? AND fetched_at_ms <= ? AND price_numeric > 0
                ORDER BY fetched_at_ms ASC
                """,
                arguments: [currency, since.databaseMilliseconds, until.databaseMilliseconds]
            )
            return rows.compactMap { row in
                let symbol: String = row["symbol"]
                guard wanted.contains(symbol) else { return nil }
                return PriceObservation(
                    symbol: symbol,
                    currencyCode: row["currency_code"],
                    price: Decimal(string: row["price"] as String) ?? 0,
                    fetchedAt: Date(databaseMilliseconds: row["fetched_at_ms"])
                )
            }
        }
    }

    func change24h(symbol: String, currency: String, now: Date = Date()) throws -> TokenPriceChange? {
        let symbol = symbol.uppercased()
        let currency = currency.uppercased()
        let windowStart = now.addingTimeInterval(-(24 * 3600 + Self.referenceWindowHalfWidth))
        let windowEnd = now.addingTimeInterval(-(24 * 3600 - Self.referenceWindowHalfWidth))
        return try database.read { db in
            guard
                let current = try latestRow(db: db, symbol: symbol, currency: currency),
                Date(databaseMilliseconds: current["fetched_at_ms"]) > windowEnd
            else { return nil }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT price, fetched_at_ms
                FROM price_snapshots
                WHERE symbol = ? AND currency_code = ? AND fetched_at_ms >= ? AND fetched_at_ms <= ?
                ORDER BY fetched_at_ms ASC
                """,
                arguments: [symbol, currency, windowStart.databaseMilliseconds, windowEnd.databaseMilliseconds]
            )
            let target = now.addingTimeInterval(-24 * 3600)
            var reference: Row?
            var bestDelta: TimeInterval = .infinity
            for row in rows {
                let delta = abs(Date(databaseMilliseconds: row["fetched_at_ms"]).timeIntervalSince(target))
                if delta < bestDelta {
                    bestDelta = delta
                    reference = row
                }
            }
            guard let reference else { return nil }
            let currentPrice = Decimal(string: current["price"] as String) ?? 0
            let referencePrice = Decimal(string: reference["price"] as String) ?? 0
            guard referencePrice > 0 else { return nil }
            let absolute = currentPrice - referencePrice
            return TokenPriceChange(
                symbol: symbol,
                currencyCode: currency,
                currentPrice: currentPrice,
                currentAt: Date(databaseMilliseconds: current["fetched_at_ms"]),
                referencePrice: referencePrice,
                referenceAt: Date(databaseMilliseconds: reference["fetched_at_ms"]),
                absolute: absolute,
                percent: absolute / referencePrice * 100
            )
        }
    }

    func changes24h(symbols: [String], currency: String, now: Date = Date()) throws -> [String: TokenPriceChange] {
        var out: [String: TokenPriceChange] = [:]
        for symbol in Set(symbols.map { $0.uppercased() }) {
            if let change = try change24h(symbol: symbol, currency: currency, now: now) {
                out[symbol] = change
            }
        }
        return out
    }

    func prune(now: Date = Date(), save: Bool = true) throws {
        try database.write { db in
            try prune(db: db, now: now)
        }
    }

    func deleteAll() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM price_snapshots") }
    }

    private func latestRow(db: Database, symbol: String, currency: String) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT price, fetched_at_ms
            FROM price_snapshots
            WHERE symbol = ? AND currency_code = ?
            ORDER BY fetched_at_ms DESC
            LIMIT 1
            """,
            arguments: [symbol.uppercased(), currency.uppercased()]
        )
    }

    private func prune(db: Database, now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.rawRetentionWindow).databaseMilliseconds
        let oldRows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, symbol, currency_code, day_key, fetched_at_ms
            FROM price_snapshots
            WHERE fetched_at_ms < ?
            ORDER BY fetched_at_ms ASC
            """,
            arguments: [cutoff]
        )
        var keeperByGroup: [String: (id: String, fetchedAt: Int64)] = [:]
        for row in oldRows {
            let id: String = row["id"]
            let groupKey = "\(row["symbol"] as String)|\(row["currency_code"] as String)|\(row["day_key"] as Int)"
            let fetchedAt: Int64 = row["fetched_at_ms"]
            if let keeper = keeperByGroup[groupKey] {
                if fetchedAt >= keeper.fetchedAt {
                    try db.execute(sql: "DELETE FROM price_snapshots WHERE id = ?", arguments: [keeper.id])
                    keeperByGroup[groupKey] = (id, fetchedAt)
                } else {
                    try db.execute(sql: "DELETE FROM price_snapshots WHERE id = ?", arguments: [id])
                }
            } else {
                keeperByGroup[groupKey] = (id, fetchedAt)
            }
        }
    }
}
