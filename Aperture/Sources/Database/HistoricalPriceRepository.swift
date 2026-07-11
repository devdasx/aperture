import Foundation
import GRDB

final class HistoricalPriceRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func upsert(symbol: String, fiat: String, dayKey: Int, price: Decimal) throws {
        try upsertMany([(symbol: symbol, fiat: fiat, dayKey: dayKey, price: price)])
    }

    func upsertMany(_ entries: [(symbol: String, fiat: String, dayKey: Int, price: Decimal)]) throws {
        guard !entries.isEmpty else { return }
        let now = Date.databaseMilliseconds
        try database.write { db in
            for entry in entries {
                let symbol = entry.symbol.uppercased()
                let fiat = entry.fiat.uppercased()
                let key = "\(symbol)-\(fiat)-\(entry.dayKey)"
                try db.execute(
                    sql: """
                    INSERT INTO historical_prices
                    (key, symbol, fiat, day_key, price, price_numeric, fetched_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        price = excluded.price,
                        price_numeric = excluded.price_numeric,
                        fetched_at_ms = excluded.fetched_at_ms
                    WHERE historical_prices.price != excluded.price
                    """,
                    arguments: [key, symbol, fiat, entry.dayKey, entry.price.databaseText, entry.price.databaseDouble, now]
                )
            }
        }
    }

    func priceSeries(symbol: String, fiat: String) throws -> [Int: Decimal] {
        try priceSeries(symbol: symbol, fiat: fiat, fromDay: Int.min, toDay: Int.max)
    }

    func priceSeriesBySymbol(symbols: [String], fiat: String) throws -> [String: [Int: Decimal]] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        let fiat = fiat.uppercased()
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT symbol, day_key, price FROM historical_prices WHERE fiat = ?", arguments: [fiat])
            var out: [String: [Int: Decimal]] = [:]
            for row in rows {
                let symbol: String = row["symbol"]
                guard wanted.contains(symbol) else { continue }
                out[symbol, default: [:]][row["day_key"]] = Decimal(string: row["price"] as String) ?? 0
            }
            return out
        }
    }

    func priceSeries(symbol: String, fiat: String, fromDay: Int, toDay: Int) throws -> [Int: Decimal] {
        let symbol = symbol.uppercased()
        let fiat = fiat.uppercased()
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT day_key, price FROM historical_prices
                WHERE symbol = ? AND fiat = ? AND day_key >= ? AND day_key <= ?
                """,
                arguments: [symbol, fiat, fromDay, toDay]
            )
            var out: [Int: Decimal] = [:]
            for row in rows {
                out[row["day_key"]] = Decimal(string: row["price"] as String) ?? 0
            }
            return out
        }
    }

    func latestClose(symbols: [String], fiat: String) throws -> [String: Decimal] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        let fiat = fiat.uppercased()
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT symbol, price FROM historical_prices WHERE fiat = ? ORDER BY day_key DESC",
                arguments: [fiat]
            )
            var out: [String: Decimal] = [:]
            for row in rows {
                let symbol: String = row["symbol"]
                guard wanted.contains(symbol), out[symbol] == nil else { continue }
                let price = Decimal(string: row["price"] as String) ?? 0
                if price > 0 { out[symbol] = price }
            }
            return out
        }
    }

    func latestCloseAnyCurrency(symbols: [String]) throws -> [String: (price: Decimal, fiat: String)] {
        let wanted = Set(symbols.map { $0.uppercased() })
        guard !wanted.isEmpty else { return [:] }
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT symbol, fiat, price FROM historical_prices ORDER BY day_key DESC")
            var out: [String: (Decimal, String)] = [:]
            for row in rows {
                let symbol: String = row["symbol"]
                guard wanted.contains(symbol), out[symbol] == nil else { continue }
                let price = Decimal(string: row["price"] as String) ?? 0
                if price > 0 { out[symbol] = (price, row["fiat"]) }
            }
            return out
        }
    }

    func clearAll() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM historical_prices") }
    }
}

enum DayKey {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func from(date: Date, calendar: Calendar = DayKey.utc) -> Int {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return (comps.year ?? 0) * 10_000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
    }

    static func from(dayString: String) -> Int? {
        let parts = dayString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return year * 10_000 + month * 100 + day
    }
}
