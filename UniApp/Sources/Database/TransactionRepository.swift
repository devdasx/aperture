import Foundation
import GRDB

final class TransactionRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    private func balanceOnlyFiatFallback(
        existingRawBalance: String,
        existingDecimals: Int,
        existingFiat: Decimal,
        newRawBalance: String,
        newDecimals: Int
    ) -> Decimal {
        if isZeroRawBalance(newRawBalance) { return 0 }
        guard
            existingFiat > 0,
            let previousAmount = decimalAmount(rawBalance: existingRawBalance, decimals: existingDecimals),
            let nextAmount = decimalAmount(rawBalance: newRawBalance, decimals: newDecimals),
            previousAmount > 0,
            nextAmount >= 0
        else {
            return existingFiat
        }
        return existingFiat * nextAmount / previousAmount
    }

    private func isZeroRawBalance(_ rawBalance: String) -> Bool {
        guard let value = Decimal(string: rawBalance) else { return false }
        return value == 0
    }

    private func decimalAmount(rawBalance: String, decimals: Int) -> Decimal? {
        guard let integer = Decimal(string: rawBalance), decimals >= 0 else { return nil }
        guard decimals > 0 else { return integer }
        var scale: Decimal = 1
        for _ in 0..<decimals { scale *= 10 }
        return integer / scale
    }

    func upsertTransaction(
        addressId: UUID,
        txHash: String,
        direction: TransactionDirection,
        amountRaw: String,
        tokenSymbol: String,
        tokenContract: String? = nil,
        kind: TransactionKind? = nil,
        blockNumber: Int64?,
        occurredAt: Date,
        status: TransactionStatus,
        counterparty: String,
        feeRaw: String?,
        id: UUID = UUID(),
        save: Bool = true
    ) throws {
        let normalizedContract = try database.read { db -> String? in
            guard let chainRaw = try String.fetchOne(
                db,
                sql: "SELECT chain_raw FROM wallet_addresses WHERE id = ?",
                arguments: [addressId.uuidString]
            ) else { return tokenContract }
            return SupportedChain(rawValue: chainRaw)?.family == .evm ? tokenContract?.lowercased() : tokenContract
        }
        let resolvedKind = kind ?? Self.classifyKind(direction: direction)
        let occurredAtMs = occurredAt.databaseMilliseconds

        try database.write { db in
            if direction == .internal {
                try db.execute(
                    sql: """
                    UPDATE transactions
                    SET direction_raw = ?,
                        amount_raw = ?,
                        counterparty = '',
                        kind_raw = ?,
                        fee_raw = ?
                    WHERE tx_hash = ?
                      AND address_id = ?
                      AND IFNULL(token_contract, '') = IFNULL(?, '')
                      AND token_symbol = ?
                      AND direction_raw != ?
                    """,
                    arguments: [
                        TransactionDirection.internal.rawValue,
                        amountRaw,
                        TransactionKind.selfTransfer.rawValue,
                        feeRaw,
                        txHash,
                        addressId.uuidString,
                        normalizedContract,
                        tokenSymbol,
                        TransactionDirection.internal.rawValue
                    ]
                )
            }

            let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT id, status_raw, block_number, fee_raw, kind_raw
                FROM transactions
                WHERE tx_hash = ?
                  AND address_id = ?
                  AND IFNULL(token_contract, '') = IFNULL(?, '')
                  AND token_symbol = ?
                  AND direction_raw = ?
                LIMIT 1
                """,
                arguments: [txHash, addressId.uuidString, normalizedContract, tokenSymbol, direction.rawValue]
            )

            if let existing {
                let existingID: String = existing["id"]
                let existingKind: String? = existing["kind_raw"]
                let targetKindRaw = kind?.rawValue ?? existingKind ?? resolvedKind.rawValue
                let unchanged =
                    (existing["status_raw"] as String) == status.rawValue
                    && (existing["block_number"] as Int64?) == blockNumber
                    && (existing["fee_raw"] as String?) == feeRaw
                    && existingKind == targetKindRaw
                if !unchanged {
                    try db.execute(
                        sql: """
                        UPDATE transactions
                        SET status_raw = ?,
                            block_number = ?,
                            fee_raw = ?,
                            kind_raw = ?
                        WHERE id = ?
                        """,
                        arguments: [status.rawValue, blockNumber, feeRaw, targetKindRaw, existingID]
                    )
                }
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO transactions
                    (id, address_id, tx_hash, direction_raw, amount_raw,
                     token_symbol, token_contract, block_number, occurred_at_ms,
                     status_raw, counterparty, fee_raw, kind_raw)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(tx_hash, address_id, IFNULL(token_contract, ''), token_symbol, direction_raw)
                    DO UPDATE SET
                        status_raw = excluded.status_raw,
                        block_number = excluded.block_number,
                        fee_raw = excluded.fee_raw,
                        kind_raw = COALESCE(excluded.kind_raw, transactions.kind_raw)
                    """,
                    arguments: [
                        id.uuidString,
                        addressId.uuidString,
                        txHash,
                        direction.rawValue,
                        amountRaw,
                        tokenSymbol,
                        normalizedContract,
                        blockNumber,
                        occurredAtMs,
                        status.rawValue,
                        counterparty,
                        feeRaw,
                        resolvedKind.rawValue
                    ]
                )
            }
        }
    }

    static func classifyKind(direction: TransactionDirection) -> TransactionKind {
        TransactionKind.defaultKind(for: direction)
    }

    struct TransactionSnapshot: Sendable {
        let id: UUID
        let addressId: UUID
        let txHash: String
        let direction: TransactionDirection
        let kind: TransactionKind
        let status: TransactionStatus
        let amountRaw: String
        let tokenSymbol: String
        let tokenContract: String?
        let blockNumber: Int64?
        let occurredAt: Date
        let counterparty: String
        let feeRaw: String?
    }

    func transactions(
        walletId: UUID,
        kind: TransactionKind? = nil,
        status: TransactionStatus? = nil,
        direction: TransactionDirection? = nil,
        limit: Int = 0
    ) throws -> [TransactionSnapshot] {
        try database.read { db in
            var sql = """
            SELECT t.*
            FROM transactions t
            JOIN wallet_addresses a ON a.id = t.address_id
            WHERE a.wallet_id = ?
            """
            var arguments: StatementArguments = [walletId.uuidString]
            if let status {
                sql += " AND t.status_raw = ?"
                arguments += [status.rawValue]
            }
            if let direction {
                sql += " AND t.direction_raw = ?"
                arguments += [direction.rawValue]
            }
            sql += " ORDER BY t.occurred_at_ms DESC"
            if limit > 0 {
                sql += " LIMIT ?"
                arguments += [limit]
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                guard
                    let id = UUID(uuidString: row["id"]),
                    let addressId = UUID(uuidString: row["address_id"])
                else { return nil }
                let direction = TransactionDirection(rawValue: row["direction_raw"]) ?? .incoming
                let effectiveKind = TransactionKind.effectiveKind(kindRaw: row["kind_raw"], directionRaw: row["direction_raw"])
                if let kind, kind != effectiveKind { return nil }
                return TransactionSnapshot(
                    id: id,
                    addressId: addressId,
                    txHash: row["tx_hash"],
                    direction: direction,
                    kind: effectiveKind,
                    status: TransactionStatus(rawValue: row["status_raw"]) ?? .pending,
                    amountRaw: row["amount_raw"],
                    tokenSymbol: row["token_symbol"],
                    tokenContract: row["token_contract"],
                    blockNumber: row["block_number"],
                    occurredAt: Date(databaseMilliseconds: row["occurred_at_ms"]),
                    counterparty: row["counterparty"],
                    feeRaw: row["fee_raw"]
                )
            }
        }
    }

    func failedTransactions(walletId: UUID, limit: Int = 0) throws -> [TransactionSnapshot] {
        try transactions(walletId: walletId, status: .failed, limit: limit)
    }

    func clearTransactions(for addressId: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM transactions WHERE address_id = ?", arguments: [addressId.uuidString])
        }
    }

    func upsertBalance(
        addressId: UUID,
        tokenSymbol: String,
        tokenContract: String?,
        decimals: Int,
        rawBalance: String,
        fiatValueCached: Decimal?,
        fiatCurrencyCode: String,
        save: Bool = true
    ) throws {
        try database.write { db in
            let addressCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM wallet_addresses WHERE id = ?",
                arguments: [addressId.uuidString]
            ) ?? 0
            guard addressCount > 0 else { return }

            let now = Date.databaseMilliseconds
            let existing = try Row.fetchOne(
                db,
                sql: """
                SELECT raw_balance, decimals, fiat_value_cached, fiat_currency_code
                FROM token_balances
                WHERE address_id = ?
                  AND token_symbol = ?
                  AND IFNULL(token_contract, '') = IFNULL(?, '')
                LIMIT 1
                """,
                arguments: [addressId.uuidString, tokenSymbol, tokenContract]
            )
            let resolvedFiat: Decimal
            let resolvedCurrency: String
            if let existing {
                let oldFiat = Decimal(string: existing["fiat_value_cached"] as String) ?? 0
                if let fiatValueCached {
                    resolvedFiat = fiatValueCached
                    resolvedCurrency = fiatCurrencyCode
                } else {
                    resolvedFiat = balanceOnlyFiatFallback(
                        existingRawBalance: existing["raw_balance"],
                        existingDecimals: existing["decimals"],
                        existingFiat: oldFiat,
                        newRawBalance: rawBalance,
                        newDecimals: decimals
                    )
                    resolvedCurrency = existing["fiat_currency_code"]
                }
            } else {
                resolvedFiat = fiatValueCached ?? 0
                resolvedCurrency = fiatCurrencyCode
            }

            try db.execute(
                sql: """
                INSERT INTO token_balances
                (id, address_id, token_symbol, token_contract, decimals, raw_balance,
                 fiat_value_cached, fiat_value_cached_numeric, fiat_currency_code, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(address_id, token_symbol, IFNULL(token_contract, ''))
                DO UPDATE SET
                    decimals = excluded.decimals,
                    raw_balance = excluded.raw_balance,
                    fiat_value_cached = excluded.fiat_value_cached,
                    fiat_value_cached_numeric = excluded.fiat_value_cached_numeric,
                    fiat_currency_code = excluded.fiat_currency_code,
                    updated_at_ms = excluded.updated_at_ms
                WHERE token_balances.raw_balance != excluded.raw_balance
                   OR token_balances.decimals != excluded.decimals
                   OR token_balances.fiat_value_cached != excluded.fiat_value_cached
                   OR token_balances.fiat_currency_code != excluded.fiat_currency_code
                """,
                arguments: [
                    UUID().uuidString,
                    addressId.uuidString,
                    tokenSymbol,
                    tokenContract,
                    decimals,
                    rawBalance,
                    resolvedFiat.databaseText,
                    resolvedFiat.databaseDouble,
                    resolvedCurrency,
                    now
                ]
            )
            try db.execute(
                sql: "UPDATE wallet_addresses SET last_scanned_at_ms = ? WHERE id = ?",
                arguments: [now, addressId.uuidString]
            )
        }
    }

    func markScanComplete(addressId: UUID, isUsed: Bool, save: Bool = true) throws {
        try database.write { db in
            let now = Date.databaseMilliseconds
            try db.execute(
                sql: """
                UPDATE wallet_addresses
                SET is_used = ?,
                    last_scanned_at_ms = COALESCE(last_scanned_at_ms, ?)
                WHERE id = ?
                  AND (is_used != ? OR last_scanned_at_ms IS NULL)
                """,
                arguments: [isUsed, now, addressId.uuidString, isUsed]
            )
        }
    }

    func flush() throws {}
}
