import Foundation
import GRDB

final class TransactionRepository {
    private let database: AppDatabase
    private var pendingWrites: [PendingWrite] = []

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    private enum PendingWrite {
        case transaction(TransactionWrite)
        case balance(BalanceWrite)
        case scanComplete(ScanCompleteWrite)
    }

    private struct TransactionWrite {
        let addressId: UUID
        let txHash: String
        let direction: TransactionDirection
        let amountRaw: String
        let tokenSymbol: String
        let tokenContract: String?
        let kind: TransactionKind?
        let blockNumber: Int64?
        let occurredAt: Date
        let status: TransactionStatus
        let counterparty: String
        let feeRaw: String?
        let id: UUID
    }

    private struct BalanceWrite {
        let addressId: UUID
        let tokenSymbol: String
        let tokenContract: String?
        let decimals: Int
        let rawBalance: String
        let fiatValueCached: Decimal?
        let fiatCurrencyCode: String
    }

    private struct ScanCompleteWrite {
        let addressId: UUID
        let isUsed: Bool
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
        let write = TransactionWrite(
            addressId: addressId,
            txHash: txHash,
            direction: direction,
            amountRaw: amountRaw,
            tokenSymbol: tokenSymbol,
            tokenContract: tokenContract,
            kind: kind,
            blockNumber: blockNumber,
            occurredAt: occurredAt,
            status: status,
            counterparty: counterparty,
            feeRaw: feeRaw,
            id: id
        )
        guard save else {
            pendingWrites.append(.transaction(write))
            return
        }
        try database.write { db in
            try performUpsertTransaction(write, in: db)
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

    struct PendingTransactionSnapshot: Sendable, Hashable {
        let id: UUID
        let walletId: UUID
        let addressId: UUID
        let address: String
        let chain: SupportedChain
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

    func pendingTransactions(limit: Int = 100) throws -> [PendingTransactionSnapshot] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT t.*, a.wallet_id, a.address, a.chain_raw
                FROM transactions t
                JOIN wallet_addresses a ON a.id = t.address_id
                WHERE t.status_raw = ?
                ORDER BY t.occurred_at_ms ASC
                LIMIT ?
                """,
                arguments: [TransactionStatus.pending.rawValue, limit]
            )
            return rows.compactMap { row in
                guard
                    let id = UUID(uuidString: row["id"]),
                    let walletId = UUID(uuidString: row["wallet_id"]),
                    let addressId = UUID(uuidString: row["address_id"]),
                    let chain = SupportedChain(rawValue: row["chain_raw"])
                else { return nil }
                let direction = TransactionDirection(rawValue: row["direction_raw"]) ?? .incoming
                return PendingTransactionSnapshot(
                    id: id,
                    walletId: walletId,
                    addressId: addressId,
                    address: row["address"],
                    chain: chain,
                    txHash: row["tx_hash"],
                    direction: direction,
                    kind: TransactionKind.effectiveKind(kindRaw: row["kind_raw"], directionRaw: row["direction_raw"]),
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

    func resolvePendingTransaction(
        _ transaction: PendingTransactionSnapshot,
        status: TransactionStatus,
        blockNumber: Int64?,
        occurredAt: Date?,
        feeRaw: String?
    ) throws {
        guard status != .pending else { return }
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE transactions
                SET status_raw = ?,
                    block_number = COALESCE(?, block_number),
                    occurred_at_ms = COALESCE(?, occurred_at_ms),
                    fee_raw = COALESCE(?, fee_raw)
                WHERE id = ?
                  AND status_raw = ?
                """,
                arguments: [
                    status.rawValue,
                    blockNumber,
                    occurredAt?.databaseMilliseconds,
                    feeRaw,
                    transaction.id.uuidString,
                    TransactionStatus.pending.rawValue
                ]
            )
        }
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
        let write = BalanceWrite(
            addressId: addressId,
            tokenSymbol: tokenSymbol,
            tokenContract: tokenContract,
            decimals: decimals,
            rawBalance: rawBalance,
            fiatValueCached: fiatValueCached,
            fiatCurrencyCode: fiatCurrencyCode
        )
        guard save else {
            pendingWrites.append(.balance(write))
            return
        }
        try database.write { db in
            try performUpsertBalance(write, in: db)
        }
    }

    @discardableResult
    func applyOptimisticOutgoingDebit(
        walletId: UUID,
        chain: SupportedChain,
        tokenSymbol: String,
        tokenContract: String?,
        decimals: Int,
        displayAmount: Decimal
    ) throws -> Bool {
        let rawDebit = rawBaseUnits(displayAmount: displayAmount, decimals: decimals)
        guard rawDebit > 0 else { return false }
        let normalizedContract = chain.family == .evm ? tokenContract?.lowercased() : tokenContract
        let contractPredicate = chain.family == .evm
            ? "LOWER(IFNULL(b.token_contract, '')) = LOWER(IFNULL(?, ''))"
            : "IFNULL(b.token_contract, '') = IFNULL(?, '')"
        let symbolUpper = tokenSymbol.uppercased()

        return try database.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT b.id, b.raw_balance, b.fiat_value_cached, b.fiat_currency_code
                FROM token_balances b
                JOIN wallet_addresses a ON a.id = b.address_id
                WHERE a.wallet_id = ?
                  AND a.chain_raw = ?
                  AND UPPER(b.token_symbol) = ?
                  AND \(contractPredicate)
                ORDER BY LENGTH(b.raw_balance) DESC, b.raw_balance DESC, b.updated_at_ms DESC
                """,
                arguments: [walletId.uuidString, chain.rawValue, symbolUpper, normalizedContract]
            )
            var remaining = rawDebit
            var changed = false
            let now = Date.databaseMilliseconds
            for row in rows where remaining > 0 {
                let id: String = row["id"]
                guard let oldRaw = Decimal(string: row["raw_balance"] as String), oldRaw > 0 else {
                    continue
                }
                let debit = oldRaw < remaining ? oldRaw : remaining
                let nextRaw = oldRaw - debit
                let newRaw: Decimal = nextRaw > 0 ? nextRaw : 0
                let oldFiat = Decimal(string: row["fiat_value_cached"] as String) ?? 0
                let newFiat = oldRaw > 0 ? oldFiat * newRaw / oldRaw : 0
                try db.execute(
                    sql: """
                    UPDATE token_balances
                    SET raw_balance = ?,
                        fiat_value_cached = ?,
                        fiat_value_cached_numeric = ?,
                        updated_at_ms = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        integerDatabaseText(newRaw),
                        newFiat.databaseText,
                        newFiat.databaseDouble,
                        now,
                        id
                    ]
                )
                remaining -= debit
                changed = true
            }
            return changed
        }
    }

    private func rawBaseUnits(displayAmount: Decimal, decimals: Int) -> Decimal {
        guard displayAmount > 0, decimals >= 0 else { return 0 }
        var scaled = displayAmount
        if decimals > 0 {
            for _ in 0..<decimals { scaled *= 10 }
        }
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return rounded > 0 ? rounded : 0
    }

    private func integerDatabaseText(_ value: Decimal) -> String {
        guard value > 0 else { return "0" }
        var mutable = value
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &mutable, 0, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private func performUpsertTransaction(_ write: TransactionWrite, in db: Database) throws {
        let normalizedContract: String?
        if let chainRaw = try String.fetchOne(
            db,
            sql: "SELECT chain_raw FROM wallet_addresses WHERE id = ?",
            arguments: [write.addressId.uuidString]
        ) {
            normalizedContract = SupportedChain(rawValue: chainRaw)?.family == .evm
                ? write.tokenContract?.lowercased()
                : write.tokenContract
        } else {
            normalizedContract = write.tokenContract
        }
        let resolvedKind = write.kind ?? Self.classifyKind(direction: write.direction)
        let occurredAtMs = write.occurredAt.databaseMilliseconds

        if write.direction == .internal {
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
                    write.amountRaw,
                    TransactionKind.selfTransfer.rawValue,
                    write.feeRaw,
                    write.txHash,
                    write.addressId.uuidString,
                    normalizedContract,
                    write.tokenSymbol,
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
            arguments: [
                write.txHash,
                write.addressId.uuidString,
                normalizedContract,
                write.tokenSymbol,
                write.direction.rawValue
            ]
        )

        if let existing {
            let existingID: String = existing["id"]
            let existingKind: String? = existing["kind_raw"]
            let targetKindRaw = write.kind?.rawValue ?? existingKind ?? resolvedKind.rawValue
            let unchanged =
                (existing["status_raw"] as String) == write.status.rawValue
                && (existing["block_number"] as Int64?) == write.blockNumber
                && (existing["fee_raw"] as String?) == write.feeRaw
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
                    arguments: [
                        write.status.rawValue,
                        write.blockNumber,
                        write.feeRaw,
                        targetKindRaw,
                        existingID
                    ]
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
                    write.id.uuidString,
                    write.addressId.uuidString,
                    write.txHash,
                    write.direction.rawValue,
                    write.amountRaw,
                    write.tokenSymbol,
                    normalizedContract,
                    write.blockNumber,
                    occurredAtMs,
                    write.status.rawValue,
                    write.counterparty,
                    write.feeRaw,
                    resolvedKind.rawValue
                ]
            )
        }
    }

    private func performUpsertBalance(_ write: BalanceWrite, in db: Database) throws {
        let addressCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM wallet_addresses WHERE id = ?",
            arguments: [write.addressId.uuidString]
        ) ?? 0
        guard addressCount > 0 else { return }

        let now = Date.databaseMilliseconds
        let existing = try Row.fetchOne(
            db,
            sql: """
            SELECT id, raw_balance, decimals, fiat_value_cached, fiat_currency_code
            FROM token_balances
            WHERE address_id = ?
              AND token_symbol = ?
              AND IFNULL(token_contract, '') = IFNULL(?, '')
            LIMIT 1
            """,
            arguments: [write.addressId.uuidString, write.tokenSymbol, write.tokenContract]
        )

        let resolvedFiat: Decimal
        let resolvedCurrency: String
        if let existing {
            let oldFiat = Decimal(string: existing["fiat_value_cached"] as String) ?? 0
            if let fiatValueCached = write.fiatValueCached {
                resolvedFiat = fiatValueCached
                resolvedCurrency = write.fiatCurrencyCode
            } else {
                resolvedFiat = balanceOnlyFiatFallback(
                    existingRawBalance: existing["raw_balance"],
                    existingDecimals: existing["decimals"],
                    existingFiat: oldFiat,
                    newRawBalance: write.rawBalance,
                    newDecimals: write.decimals
                )
                resolvedCurrency = existing["fiat_currency_code"]
            }
        } else {
            resolvedFiat = write.fiatValueCached ?? 0
            resolvedCurrency = write.fiatCurrencyCode
        }

        var balanceChanged = false
        if let existing {
            let existingID: String = existing["id"]
            let existingFiat = Decimal(string: existing["fiat_value_cached"] as String) ?? 0
            let existingCurrency: String = existing["fiat_currency_code"]
            let unchanged =
                (existing["raw_balance"] as String) == write.rawBalance
                && (existing["decimals"] as Int) == write.decimals
                && existingFiat == resolvedFiat
                && existingCurrency.uppercased() == resolvedCurrency.uppercased()
            if !unchanged {
                balanceChanged = true
                try db.execute(
                    sql: """
                    UPDATE token_balances
                    SET decimals = ?,
                        raw_balance = ?,
                        fiat_value_cached = ?,
                        fiat_value_cached_numeric = ?,
                        fiat_currency_code = ?,
                        updated_at_ms = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        write.decimals,
                        write.rawBalance,
                        resolvedFiat.databaseText,
                        resolvedFiat.databaseDouble,
                        resolvedCurrency,
                        now,
                        existingID
                    ]
                )
            }
        } else {
            balanceChanged = true
            try db.execute(
                sql: """
                INSERT INTO token_balances
                (id, address_id, token_symbol, token_contract, decimals, raw_balance,
                 fiat_value_cached, fiat_value_cached_numeric, fiat_currency_code, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    write.addressId.uuidString,
                    write.tokenSymbol,
                    write.tokenContract,
                    write.decimals,
                    write.rawBalance,
                    resolvedFiat.databaseText,
                    resolvedFiat.databaseDouble,
                    resolvedCurrency,
                    now
                ]
            )
        }

        if balanceChanged {
            try db.execute(
                sql: "UPDATE wallet_addresses SET last_scanned_at_ms = ? WHERE id = ?",
                arguments: [now, write.addressId.uuidString]
            )
        }
    }

    private func performMarkScanComplete(_ write: ScanCompleteWrite, in db: Database) throws {
        let now = Date.databaseMilliseconds
        try db.execute(
            sql: """
            UPDATE wallet_addresses
            SET is_used = ?,
                last_scanned_at_ms = COALESCE(last_scanned_at_ms, ?)
            WHERE id = ?
              AND (is_used != ? OR last_scanned_at_ms IS NULL)
            """,
            arguments: [write.isUsed, now, write.addressId.uuidString, write.isUsed]
        )
    }

    func markScanComplete(addressId: UUID, isUsed: Bool, save: Bool = true) throws {
        let write = ScanCompleteWrite(addressId: addressId, isUsed: isUsed)
        guard save else {
            pendingWrites.append(.scanComplete(write))
            return
        }
        try database.write { db in
            try performMarkScanComplete(write, in: db)
        }
    }

    func flush() throws {
        guard !pendingWrites.isEmpty else { return }
        let writes = pendingWrites
        try database.write { db in
            for write in writes {
                switch write {
                case .transaction(let transaction):
                    try performUpsertTransaction(transaction, in: db)
                case .balance(let balance):
                    try performUpsertBalance(balance, in: db)
                case .scanComplete(let scanComplete):
                    try performMarkScanComplete(scanComplete, in: db)
                }
            }
        }
        pendingWrites.removeAll(keepingCapacity: true)
    }
}
