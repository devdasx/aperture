import Foundation
import GRDB

final class ChainStateRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    struct ChainStateSnapshot: Sendable {
        let chainRaw: String
        let address: String
        let nativeBalanceRaw: String
        let nativeFiat: Decimal
        let totalFiat: Decimal
        let tokenCount: Int
        let txSentCount: Int
        let txReceivedCount: Int
        let txSelfTransferCount: Int
        let txBridgeCount: Int
        let txFailedCount: Int
        let txPendingCount: Int
        let txTotalCount: Int
        let utxoCount: Int
        let utxoTotalSats: Int64
        let isUsed: Bool
        let hasEncryptedKey: Bool
        let syncStateRaw: String
    }

    struct AddressedUTXO: Sendable {
        let address: String
        let txid: String
        let vout: Int
        let valueSats: Int64
        let scriptHex: String?
        let confirmed: Bool
    }

    struct DiscoveredAddress: Sendable, Hashable {
        let address: String
        let derivationPath: String
        let isUsed: Bool
    }

    @discardableResult
    func rebuild(
        walletId: UUID,
        fiatCurrencyCode: String,
        onlyChains: Set<SupportedChain>? = nil,
        failedChains: Set<SupportedChain> = [],
        interim: Bool = false
    ) throws -> Int {
        try database.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, chain_raw, address, derivation_path, is_used
                FROM wallet_addresses
                WHERE wallet_id = ?
                ORDER BY chain_raw ASC, is_receive_preferred DESC
                """,
                arguments: [walletId.uuidString]
            )
            var rebuiltChains: Set<SupportedChain> = []
            for row in rows {
                guard let chain = SupportedChain(rawValue: row["chain_raw"]) else { continue }
                if rebuiltChains.contains(chain) { continue }
                if let onlyChains, !onlyChains.contains(chain) { continue }
                rebuiltChains.insert(chain)
                let state: ChainSyncState = interim ? .syncing : (failedChains.contains(chain) ? .failed : .synced)
                try recomputeRow(
                    db: db,
                    walletId: walletId,
                    chain: chain,
                    addressId: UUID(uuidString: row["id"]),
                    address: row["address"],
                    derivationPath: row["derivation_path"],
                    isUsed: (row["is_used"] as Int) != 0,
                    fiatCurrencyCode: fiatCurrencyCode,
                    syncState: state
                )
            }
            try upsertWalletPortfolioSummary(db: db, walletId: walletId, fiatCurrencyCode: fiatCurrencyCode)
            return rebuiltChains.count
        }
    }

    private func recomputeRow(
        db: Database,
        walletId: UUID,
        chain: SupportedChain,
        addressId: UUID?,
        address: String,
        derivationPath: String,
        isUsed: Bool,
        fiatCurrencyCode: String,
        syncState: ChainSyncState
    ) throws {
        let chainRaw = chain.rawValue
        let addressRows = try Row.fetchAll(
            db,
            sql: "SELECT id FROM wallet_addresses WHERE wallet_id = ? AND chain_raw = ?",
            arguments: [walletId.uuidString, chainRaw]
        )
        let addressIds = addressRows.compactMap { UUID(uuidString: $0["id"] as String) }
        let idStrings = addressIds.map(\.uuidString)

        let balanceRows = try Row.fetchAll(
            db,
            sql: """
            SELECT b.token_symbol, b.token_contract, b.raw_balance, b.decimals,
                   b.fiat_value_cached, b.fiat_currency_code
            FROM token_balances b
            JOIN wallet_addresses a ON a.id = b.address_id
            WHERE a.wallet_id = ? AND a.chain_raw = ?
            """,
            arguments: [walletId.uuidString, chainRaw]
        )

        var nativeAmount: Decimal = 0
        var nativeFiat: Decimal = 0
        var totalFiat: Decimal = 0
        var tokenCount = 0
        for balance in balanceRows {
            let symbol: String = balance["token_symbol"]
            let contract: String? = balance["token_contract"]
            let rawBalance: String = balance["raw_balance"]
            let decimals: Int = balance["decimals"]
            let fiat = Decimal(string: balance["fiat_value_cached"] as String) ?? 0
            totalFiat += fiat
            let amount = Self.decimalAmount(rawBalance: rawBalance, decimals: decimals) ?? 0
            if symbol.caseInsensitiveCompare(chain.ticker) == .orderedSame && contract == nil {
                nativeAmount += amount
                nativeFiat += fiat
            } else if amount > 0 {
                tokenCount += 1
            }
        }

        let txRows = try Row.fetchAll(
            db,
            sql: """
            SELECT t.direction_raw, t.status_raw, t.kind_raw
            FROM transactions t
            JOIN wallet_addresses a ON a.id = t.address_id
            WHERE a.wallet_id = ? AND a.chain_raw = ?
            """,
            arguments: [walletId.uuidString, chainRaw]
        )
        var sent = 0
        var received = 0
        var selfTransfers = 0
        var bridges = 0
        var failed = 0
        var pending = 0
        for tx in txRows {
            let directionRaw: String = tx["direction_raw"]
            let statusRaw: String = tx["status_raw"]
            let kind = TransactionKind.effectiveKind(kindRaw: tx["kind_raw"], directionRaw: directionRaw)
            if directionRaw == TransactionDirection.outgoing.rawValue { sent += 1 }
            if directionRaw == TransactionDirection.incoming.rawValue { received += 1 }
            if kind == .selfTransfer { selfTransfers += 1 }
            if kind == .bridge { bridges += 1 }
            if statusRaw == TransactionStatus.failed.rawValue { failed += 1 }
            if statusRaw == TransactionStatus.pending.rawValue { pending += 1 }
        }

        let utxoRows = try Row.fetchAll(
            db,
            sql: "SELECT value_sats_raw FROM chain_utxos WHERE wallet_id = ? AND chain_raw = ?",
            arguments: [walletId.uuidString, chainRaw]
        )
        let utxoTotal = utxoRows.reduce(Int64(0)) { partial, row in
            let value = Int64(row["value_sats_raw"] as String) ?? 0
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
        let now = Date.databaseMilliseconds
        try db.execute(
            sql: """
            INSERT INTO chain_states
            (id, wallet_id, chain_raw, address, derivation_path,
             native_balance_raw, native_decimals, native_fiat, native_fiat_numeric,
             total_fiat, total_fiat_numeric, token_count, fiat_currency_code,
             tx_sent_count, tx_received_count, tx_self_transfer_count, tx_bridge_count,
             tx_failed_count, tx_pending_count, tx_total_count, utxo_count, utxo_total_raw,
             is_used, last_synced_at_ms, sync_state_raw)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(wallet_id, chain_raw) DO UPDATE SET
                address = excluded.address,
                derivation_path = excluded.derivation_path,
                native_balance_raw = excluded.native_balance_raw,
                native_fiat = excluded.native_fiat,
                native_fiat_numeric = excluded.native_fiat_numeric,
                total_fiat = excluded.total_fiat,
                total_fiat_numeric = excluded.total_fiat_numeric,
                token_count = excluded.token_count,
                fiat_currency_code = excluded.fiat_currency_code,
                tx_sent_count = excluded.tx_sent_count,
                tx_received_count = excluded.tx_received_count,
                tx_self_transfer_count = excluded.tx_self_transfer_count,
                tx_bridge_count = excluded.tx_bridge_count,
                tx_failed_count = excluded.tx_failed_count,
                tx_pending_count = excluded.tx_pending_count,
                tx_total_count = excluded.tx_total_count,
                utxo_count = excluded.utxo_count,
                utxo_total_raw = excluded.utxo_total_raw,
                is_used = excluded.is_used,
                last_synced_at_ms = excluded.last_synced_at_ms,
                sync_state_raw = excluded.sync_state_raw
            """,
            arguments: [
                UUID().uuidString,
                walletId.uuidString,
                chainRaw,
                address,
                derivationPath,
                Self.decimalString(nativeAmount),
                nativeFiat.databaseText,
                nativeFiat.databaseDouble,
                totalFiat.databaseText,
                totalFiat.databaseDouble,
                tokenCount,
                fiatCurrencyCode.uppercased(),
                sent,
                received,
                selfTransfers,
                bridges,
                failed,
                pending,
                txRows.count,
                utxoRows.count,
                String(utxoTotal),
                isUsed || !idStrings.isEmpty,
                now,
                syncState.rawValue
            ]
        )
        _ = addressId
    }

    @discardableResult
    func replaceUTXOs(
        walletId: UUID,
        chain: SupportedChain,
        address: String,
        utxos: [SelectedUTXO]
    ) throws -> (count: Int, totalSats: Int64) {
        let addressed = utxos.map {
            AddressedUTXO(
                address: address,
                txid: $0.txid,
                vout: $0.vout,
                valueSats: $0.valueSats,
                scriptHex: $0.scriptHex,
                confirmed: $0.confirmed
            )
        }
        return try replaceAddressedUTXOs(walletId: walletId, chain: chain, utxos: addressed)
    }

    @discardableResult
    func replaceAddressedUTXOs(
        walletId: UUID,
        chain: SupportedChain,
        utxos: [AddressedUTXO]
    ) throws -> (count: Int, totalSats: Int64) {
        let chainRaw = chain.rawValue
        return try database.write { db in
            try db.execute(
                sql: "DELETE FROM chain_utxos WHERE wallet_id = ? AND chain_raw = ?",
                arguments: [walletId.uuidString, chainRaw]
            )
            var total: Int64 = 0
            for utxo in utxos {
                let addressId = try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM wallet_addresses
                    WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                    LIMIT 1
                    """,
                    arguments: [walletId.uuidString, chainRaw, utxo.address]
                )
                let (sum, overflow) = total.addingReportingOverflow(utxo.valueSats)
                total = overflow ? Int64.max : sum
                try db.execute(
                    sql: """
                    INSERT INTO chain_utxos
                    (id, wallet_id, address_id, chain_raw, address, txid, vout,
                     value_sats_raw, script_hex, confirmed, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(wallet_id, chain_raw, txid, vout) DO UPDATE SET
                        address_id = excluded.address_id,
                        address = excluded.address,
                        value_sats_raw = excluded.value_sats_raw,
                        script_hex = excluded.script_hex,
                        confirmed = excluded.confirmed,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        UUID().uuidString,
                        walletId.uuidString,
                        addressId,
                        chainRaw,
                        utxo.address,
                        utxo.txid,
                        utxo.vout,
                        String(utxo.valueSats),
                        utxo.scriptHex,
                        utxo.confirmed,
                        Date.databaseMilliseconds
                    ]
                )
            }
            return (utxos.count, total)
        }
    }

    @discardableResult
    func upsertDiscoveredAddresses(
        walletId: UUID,
        chain: SupportedChain,
        addresses: [DiscoveredAddress]
    ) throws -> Int {
        guard !addresses.isEmpty else { return 0 }
        let chainRaw = chain.rawValue
        let scannedAt = Date.databaseMilliseconds
        var seen: Set<String> = []
        return try database.write { db in
            var saved = 0
            for item in addresses where seen.insert(item.address).inserted {
                let isUsed = item.isUsed ? 1 : 0
                let existingId = try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM wallet_addresses
                    WHERE wallet_id = ? AND chain_raw = ? AND address = ?
                    LIMIT 1
                    """,
                    arguments: [walletId.uuidString, chainRaw, item.address]
                )
                if let existingId {
                    try db.execute(
                        sql: """
                        UPDATE wallet_addresses
                        SET derivation_path = CASE WHEN ? <> '' THEN ? ELSE derivation_path END,
                            is_used = CASE WHEN is_used = 1 OR ? = 1 THEN 1 ELSE 0 END,
                            last_scanned_at_ms = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            item.derivationPath,
                            item.derivationPath,
                            isUsed,
                            scannedAt,
                            existingId
                        ]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO wallet_addresses
                        (id, wallet_id, chain_raw, address, derivation_path,
                         is_used, is_receive_preferred, last_scanned_at_ms)
                        VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                        """,
                        arguments: [
                            UUID().uuidString,
                            walletId.uuidString,
                            chainRaw,
                            item.address,
                            item.derivationPath,
                            isUsed,
                            scannedAt
                        ]
                    )
                }
                saved += 1
            }
            return saved
        }
    }

    func utxos(walletId: UUID, chain: SupportedChain) throws -> [SelectedUTXO] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT address, txid, vout, value_sats_raw, script_hex, confirmed
                FROM chain_utxos
                WHERE wallet_id = ? AND chain_raw = ?
                ORDER BY confirmed DESC, LENGTH(value_sats_raw) DESC, value_sats_raw DESC
                """,
                arguments: [walletId.uuidString, chain.rawValue]
            ).compactMap { row in
                guard let value = Int64(row["value_sats_raw"] as String) else { return nil }
                let vout: Int = row["vout"]
                return SelectedUTXO(
                    ownerAddress: row["address"],
                    txid: row["txid"],
                    vout: vout,
                    valueSats: value,
                    scriptHex: row["script_hex"],
                    confirmed: (row["confirmed"] as Int) != 0
                )
            }
        }
    }

    func removeUTXOs(walletId: UUID, chain: SupportedChain, utxos: [SelectedUTXO]) throws {
        guard !utxos.isEmpty else { return }
        try database.write { db in
            for utxo in utxos {
                try db.execute(
                    sql: """
                    DELETE FROM chain_utxos
                    WHERE wallet_id = ? AND chain_raw = ? AND txid = ? AND vout = ?
                    """,
                    arguments: [walletId.uuidString, chain.rawValue, utxo.txid, utxo.vout]
                )
            }
        }
    }

    func storeEncryptedKeys(walletId: UUID, blobs: [SupportedChain: Data]) throws {
        guard !blobs.isEmpty else { return }
        try database.write { db in
            for (chain, blob) in blobs {
                try db.execute(
                    sql: """
                    INSERT INTO chain_states
                    (id, wallet_id, chain_raw, address, encrypted_private_key, key_encryption_scheme)
                    VALUES (?, ?, ?, '', ?, ?)
                    ON CONFLICT(wallet_id, chain_raw) DO UPDATE SET
                        encrypted_private_key = excluded.encrypted_private_key,
                        key_encryption_scheme = excluded.key_encryption_scheme
                    """,
                    arguments: [UUID().uuidString, walletId.uuidString, chain.rawValue, blob, ChainKeyVault.scheme]
                )
            }
        }
    }

    func chainsMissingKey(walletId: UUID, candidates: Set<SupportedChain>) throws -> Set<SupportedChain> {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT chain_raw FROM chain_states WHERE wallet_id = ? AND encrypted_private_key IS NOT NULL",
                arguments: [walletId.uuidString]
            )
            let haveKey = Set(rows.compactMap { SupportedChain(rawValue: $0["chain_raw"] as String) })
            return candidates.subtracting(haveKey)
        }
    }

    func markSyncing(walletId: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE chain_states SET sync_state_raw = ? WHERE wallet_id = ?",
                arguments: [ChainSyncState.syncing.rawValue, walletId.uuidString]
            )
        }
    }

    func chainStates(walletId: UUID) throws -> [ChainStateSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM chain_states WHERE wallet_id = ? ORDER BY chain_raw ASC",
                arguments: [walletId.uuidString]
            ).map(Self.snapshot)
        }
    }

    func chainState(walletId: UUID, chain: SupportedChain) throws -> ChainStateSnapshot? {
        try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM chain_states WHERE wallet_id = ? AND chain_raw = ? LIMIT 1",
                arguments: [walletId.uuidString, chain.rawValue]
            ).map(Self.snapshot)
        }
    }

    private func upsertWalletPortfolioSummary(db: Database, walletId: UUID, fiatCurrencyCode: String) throws {
        let code = fiatCurrencyCode.uppercased()
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT native_balance_raw, total_fiat, token_count FROM chain_states WHERE wallet_id = ? AND fiat_currency_code = ?",
            arguments: [walletId.uuidString, code]
        )
        var totalFiat: Decimal = 0
        var positiveChainCount = 0
        var positiveTokenCount = 0
        var positiveAssetCount = 0
        for row in rows {
            let fiat = Decimal(string: row["total_fiat"] as String) ?? 0
            let tokenCount: Int = row["token_count"]
            totalFiat += fiat
            if fiat > 0 { positiveChainCount += 1 }
            positiveTokenCount += tokenCount
            if (Decimal(string: row["native_balance_raw"] as String) ?? 0) > 0 { positiveAssetCount += 1 }
            positiveAssetCount += tokenCount
        }
        let now = Date.databaseMilliseconds
        let lookupKey = WalletPortfolioSummaryRecord.makeLookupKey(walletId: walletId, currencyCode: code)
        try db.execute(
            sql: """
            INSERT INTO wallet_portfolio_summaries
            (id, lookup_key, wallet_id, currency_code, total_fiat, total_fiat_numeric,
             positive_chain_count, positive_asset_count, positive_token_count, source_chain_count, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(lookup_key) DO UPDATE SET
                total_fiat = excluded.total_fiat,
                total_fiat_numeric = excluded.total_fiat_numeric,
                positive_chain_count = excluded.positive_chain_count,
                positive_asset_count = excluded.positive_asset_count,
                positive_token_count = excluded.positive_token_count,
                source_chain_count = excluded.source_chain_count,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                UUID().uuidString,
                lookupKey,
                walletId.uuidString,
                code,
                totalFiat.databaseText,
                totalFiat.databaseDouble,
                positiveChainCount,
                positiveAssetCount,
                positiveTokenCount,
                rows.count,
                now
            ]
        )
    }

    private static func decimalAmount(rawBalance: String, decimals: Int) -> Decimal? {
        guard let raw = Decimal(string: rawBalance), decimals >= 0 else { return nil }
        guard decimals > 0 else { return raw }
        var divisor: Decimal = 1
        for _ in 0..<decimals { divisor *= 10 }
        return raw / divisor
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func snapshot(from row: Row) -> ChainStateSnapshot {
        ChainStateSnapshot(
            chainRaw: row["chain_raw"],
            address: row["address"],
            nativeBalanceRaw: row["native_balance_raw"],
            nativeFiat: Decimal(string: row["native_fiat"] as String) ?? 0,
            totalFiat: Decimal(string: row["total_fiat"] as String) ?? 0,
            tokenCount: row["token_count"],
            txSentCount: row["tx_sent_count"],
            txReceivedCount: row["tx_received_count"],
            txSelfTransferCount: row["tx_self_transfer_count"],
            txBridgeCount: row["tx_bridge_count"],
            txFailedCount: row["tx_failed_count"],
            txPendingCount: row["tx_pending_count"],
            txTotalCount: row["tx_total_count"],
            utxoCount: row["utxo_count"],
            utxoTotalSats: Int64(row["utxo_total_raw"] as String) ?? 0,
            isUsed: (row["is_used"] as Int) != 0,
            hasEncryptedKey: (row["encrypted_private_key"] as Data?) != nil,
            syncStateRaw: row["sync_state_raw"]
        )
    }
}
