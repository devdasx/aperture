import Foundation
import GRDB

struct WalletChartPoint: Sendable {
    let capturedAt: Date
    let fiatValue: Decimal
}

final class WalletChartSnapshotRepository {
    static let captureThrottle: TimeInterval = 10 * 60
    static let rawRetentionWindow: TimeInterval = 48 * 3600
    static let defaultHardCap = 2_000

    private let database: AppDatabase
    private var hardCapOverrideForTesting: Int?
    private var hardCap: Int { hardCapOverrideForTesting ?? Self.defaultHardCap }

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func _setHardCapForTesting(_ cap: Int) {
        hardCapOverrideForTesting = cap
    }

    @discardableResult
    func capture(walletId: UUID, currencyCode: String, fiatValue: Decimal, now: Date = Date()) throws -> Bool {
        let code = currencyCode.uppercased()
        return try database.write { db in
            if let newestMs = try Int64.fetchOne(
                db,
                sql: """
                SELECT captured_at_ms FROM wallet_chart_snapshots
                WHERE wallet_id = ? AND currency_code = ?
                ORDER BY captured_at_ms DESC
                LIMIT 1
                """,
                arguments: [walletId.uuidString, code]
            ), now.timeIntervalSince(Date(databaseMilliseconds: newestMs)) < Self.captureThrottle {
                return false
            }
            try record(db: db, walletId: walletId, currencyCode: code, fiatValue: fiatValue, capturedAt: now)
            try prune(db: db, walletId: walletId, currencyCode: code, now: now)
            return true
        }
    }

    func record(walletId: UUID, currencyCode: String, fiatValue: Decimal, capturedAt: Date, save: Bool = true) throws {
        try database.write { db in
            try record(db: db, walletId: walletId, currencyCode: currencyCode.uppercased(), fiatValue: fiatValue, capturedAt: capturedAt)
        }
    }

    @discardableResult
    func captureFromPersistedBalances(walletId: UUID, currencyCode: String, now: Date = Date()) throws -> Bool {
        let code = currencyCode.uppercased()
        let total = try database.read { db -> (total: Decimal, totalRows: Int, matchingRows: Int) in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT b.fiat_value_cached, b.fiat_currency_code
                FROM token_balances b
                JOIN wallet_addresses a ON a.id = b.address_id
                WHERE a.wallet_id = ?
                """,
                arguments: [walletId.uuidString]
            )
            var total: Decimal = 0
            var matching = 0
            for row in rows where (row["fiat_currency_code"] as String).uppercased() == code {
                matching += 1
                total += Decimal(string: row["fiat_value_cached"] as String) ?? 0
            }
            return (total, rows.count, matching)
        }
        if total.totalRows > 0 && total.matchingRows == 0 { return false }
        return try capture(walletId: walletId, currencyCode: code, fiatValue: total.total, now: now)
    }

    func series(walletId: UUID, currencyCode: String, from: Date? = nil) throws -> [WalletChartPoint] {
        let code = currencyCode.uppercased()
        let lowerBound = (from ?? Date.distantPast).databaseMilliseconds
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT fiat_value, captured_at_ms
                FROM wallet_chart_snapshots
                WHERE wallet_id = ? AND currency_code = ? AND captured_at_ms >= ?
                ORDER BY captured_at_ms ASC
                """,
                arguments: [walletId.uuidString, code, lowerBound]
            ).map {
                WalletChartPoint(
                    capturedAt: Date(databaseMilliseconds: $0["captured_at_ms"]),
                    fiatValue: Decimal(string: $0["fiat_value"] as String) ?? 0
                )
            }
        }
    }

    func deleteAll(walletId: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallet_chart_snapshots WHERE wallet_id = ?", arguments: [walletId.uuidString])
        }
    }

    func deleteAll() throws {
        try database.write { db in try db.execute(sql: "DELETE FROM wallet_chart_snapshots") }
    }

    func prune(walletId: UUID, currencyCode: String, now: Date = Date(), save: Bool = true) throws {
        try database.write { db in
            try prune(db: db, walletId: walletId, currencyCode: currencyCode.uppercased(), now: now)
        }
    }

    private func record(db: Database, walletId: UUID, currencyCode: String, fiatValue: Decimal, capturedAt: Date) throws {
        try db.execute(
            sql: """
            INSERT INTO wallet_chart_snapshots
            (id, wallet_id, currency_code, fiat_value, fiat_value_numeric, captured_at_ms, day_key)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString,
                walletId.uuidString,
                currencyCode.uppercased(),
                fiatValue.databaseText,
                fiatValue.databaseDouble,
                capturedAt.databaseMilliseconds,
                DayKey.from(date: capturedAt)
            ]
        )
    }

    private func prune(db: Database, walletId: UUID, currencyCode: String, now: Date) throws {
        let code = currencyCode.uppercased()
        let cutoff = now.addingTimeInterval(-Self.rawRetentionWindow).databaseMilliseconds
        let oldRows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, day_key, captured_at_ms
            FROM wallet_chart_snapshots
            WHERE wallet_id = ? AND currency_code = ? AND captured_at_ms < ?
            ORDER BY captured_at_ms ASC
            """,
            arguments: [walletId.uuidString, code, cutoff]
        )
        var keeperByDay: [Int: (id: String, capturedAt: Int64)] = [:]
        for row in oldRows {
            let id: String = row["id"]
            let day: Int = row["day_key"]
            let capturedAt: Int64 = row["captured_at_ms"]
            if let keeper = keeperByDay[day] {
                if capturedAt >= keeper.capturedAt {
                    try db.execute(sql: "DELETE FROM wallet_chart_snapshots WHERE id = ?", arguments: [keeper.id])
                    keeperByDay[day] = (id, capturedAt)
                } else {
                    try db.execute(sql: "DELETE FROM wallet_chart_snapshots WHERE id = ?", arguments: [id])
                }
            } else {
                keeperByDay[day] = (id, capturedAt)
            }
        }

        let allRows = try Row.fetchAll(
            db,
            sql: """
            SELECT id FROM wallet_chart_snapshots
            WHERE wallet_id = ? AND currency_code = ?
            ORDER BY captured_at_ms ASC
            """,
            arguments: [walletId.uuidString, code]
        )
        let overflow = allRows.count - hardCap
        guard overflow > 0 else { return }
        for row in allRows.prefix(overflow) {
            try db.execute(sql: "DELETE FROM wallet_chart_snapshots WHERE id = ?", arguments: [row["id"] as String])
        }
    }
}
