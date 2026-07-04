import Combine
import Foundation
import GRDB
import OSLog

struct WalletListRowDTO: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let kind: WalletKind
    let avatarGradient: String
    let avatarSymbolType: String
    let avatarGlyph: String?
    let avatarMonogram: String?
    let avatarCustomSvg: String?
    let avatarCustomTint: String?
    let avatarBadge: String?
    let sortOrder: Int

    var avatarSpec: WalletAvatarSpec {
        WalletAvatarSpec.hydrate(
            gradient: avatarGradient,
            symbolType: avatarSymbolType,
            glyph: avatarGlyph,
            monogram: avatarMonogram,
            customSvg: avatarCustomSvg,
            customTint: avatarCustomTint,
            badge: avatarBadge,
            walletName: name,
            walletKind: kind
        )
    }

    fileprivate init(row: Row) {
        let idRaw: String = row["id"]
        id = UUID(uuidString: idRaw) ?? UUID()
        name = row["name"]
        kind = WalletKind(rawValue: row["kind_raw"]) ?? .created
        avatarGradient = row["avatar_gradient"]
        avatarSymbolType = row["avatar_symbol_type"]
        avatarGlyph = row["avatar_glyph"]
        avatarMonogram = row["avatar_monogram"]
        avatarCustomSvg = row["avatar_custom_svg"]
        avatarCustomTint = row["avatar_custom_tint"]
        avatarBadge = row["avatar_badge"]
        sortOrder = row["sort_order"]
    }
}

@MainActor
final class WalletListObservation: ObservableObject {
    @Published private(set) var wallets: [WalletListRowDTO] = []
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "wallet-observation")
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
        start()
    }

    deinit {
        cancellable?.cancel()
    }

    func activeWallet(rawID: String) -> WalletListRowDTO? {
        guard let id = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return wallets.first
        }
        return wallets.first { $0.id == id }
    }

    private func start() {
        let observation = ValueObservation.tracking { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, name, kind_raw, avatar_gradient, avatar_symbol_type,
                       avatar_glyph, avatar_monogram, avatar_custom_svg,
                       avatar_custom_tint, avatar_badge, sort_order
                FROM wallets
                WHERE is_hidden = 0
                ORDER BY sort_order ASC, created_at_ms ASC
                """
            ).map(WalletListRowDTO.init(row:))
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
                self?.log.error("Wallet observation failed: \(String(describing: error), privacy: .public)")
            },
            onChange: { [weak self] rows in
                self?.lastError = nil
                self?.wallets = rows
            }
        )
    }
}

struct WalletHomeSummaryDTO: Equatable, Sendable {
    let walletId: UUID
    let currencyCode: String
    let totalFiat: Decimal
    let balanceRowCount: Int
    let positiveBalanceRowCount: Int
    let transactionCount: Int
    let updatedAt: Date?
}

struct WalletActivityRowDTO: Identifiable, Equatable, Sendable {
    let id: UUID
    let addressId: UUID
    let chain: SupportedChain?
    let address: String
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

    fileprivate init?(row: Row) {
        guard
            let id = UUID(uuidString: row["id"]),
            let addressId = UUID(uuidString: row["address_id"])
        else { return nil }
        let directionRaw: String = row["direction_raw"]
        self.id = id
        self.addressId = addressId
        chain = SupportedChain(rawValue: row["chain_raw"] as String)
        address = row["address"]
        txHash = row["tx_hash"]
        direction = TransactionDirection(rawValue: directionRaw) ?? .incoming
        kind = TransactionKind.effectiveKind(kindRaw: row["kind_raw"], directionRaw: directionRaw)
        status = TransactionStatus(rawValue: row["status_raw"]) ?? .pending
        amountRaw = row["amount_raw"]
        tokenSymbol = row["token_symbol"]
        tokenContract = row["token_contract"]
        blockNumber = row["block_number"]
        occurredAt = Date(databaseMilliseconds: row["occurred_at_ms"])
        counterparty = row["counterparty"]
        feeRaw = row["fee_raw"]
    }
}

enum WalletHomeProjection {
    static func summary(db: Database, walletId: UUID, currencyCode: String) throws -> WalletHomeSummaryDTO {
        let code = currencyCode.uppercased()
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                COALESCE(SUM(CASE WHEN b.fiat_currency_code = ? THEN b.fiat_value_cached_numeric ELSE 0 END), 0) AS total_fiat,
                COUNT(b.id) AS balance_count,
                COALESCE(SUM(CASE WHEN b.raw_balance != '0' THEN 1 ELSE 0 END), 0) AS positive_balance_count,
                MAX(b.updated_at_ms) AS updated_at_ms
            FROM wallet_addresses a
            LEFT JOIN token_balances b ON b.address_id = a.id
            WHERE a.wallet_id = ?
            """,
            arguments: [code, walletId.uuidString]
        )
        let transactionCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM transactions t
            JOIN wallet_addresses a ON a.id = t.address_id
            WHERE a.wallet_id = ?
            """,
            arguments: [walletId.uuidString]
        ) ?? 0
        let totalFiatDouble = (row?["total_fiat"] as Double?) ?? 0
        let updatedAt = (row?["updated_at_ms"] as Int64?).map(Date.init(databaseMilliseconds:))
        return WalletHomeSummaryDTO(
            walletId: walletId,
            currencyCode: code,
            totalFiat: Decimal(totalFiatDouble),
            balanceRowCount: row?["balance_count"] ?? 0,
            positiveBalanceRowCount: row?["positive_balance_count"] ?? 0,
            transactionCount: transactionCount,
            updatedAt: updatedAt
        )
    }
}

enum WalletActivityProjection {
    static func rows(
        db: Database,
        walletId: UUID,
        limit: Int,
        offset: Int = 0
    ) throws -> [WalletActivityRowDTO] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT t.*, a.chain_raw, a.address
            FROM transactions t
            JOIN wallet_addresses a ON a.id = t.address_id
            WHERE a.wallet_id = ?
            ORDER BY t.occurred_at_ms DESC
            LIMIT ? OFFSET ?
            """,
            arguments: [walletId.uuidString, max(limit, 0), max(offset, 0)]
        ).compactMap(WalletActivityRowDTO.init(row:))
    }
}

@MainActor
final class WalletHomeSummaryObservation: ObservableObject {
    @Published private(set) var summary: WalletHomeSummaryDTO?
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private let walletId: UUID
    private let currencyCode: String
    private var cancellable: AnyDatabaseCancellable?

    init(walletId: UUID, currencyCode: String, database: AppDatabase = .shared) {
        self.walletId = walletId
        self.currencyCode = currencyCode
        self.database = database
        start()
    }

    deinit {
        cancellable?.cancel()
    }

    private func start() {
        let observation = ValueObservation.tracking { db in
            try WalletHomeProjection.summary(db: db, walletId: self.walletId, currencyCode: self.currencyCode)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
            },
            onChange: { [weak self] summary in
                self?.lastError = nil
                self?.summary = summary
            }
        )
    }
}

@MainActor
final class WalletActivityPageObservation: ObservableObject {
    @Published private(set) var rows: [WalletActivityRowDTO] = []
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private let walletId: UUID
    private let limit: Int
    private let offset: Int
    private var cancellable: AnyDatabaseCancellable?

    init(walletId: UUID, limit: Int, offset: Int = 0, database: AppDatabase = .shared) {
        self.walletId = walletId
        self.limit = limit
        self.offset = offset
        self.database = database
        start()
    }

    deinit {
        cancellable?.cancel()
    }

    private func start() {
        let observation = ValueObservation.tracking { db in
            try WalletActivityProjection.rows(db: db, walletId: self.walletId, limit: self.limit, offset: self.offset)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
            },
            onChange: { [weak self] rows in
                self?.lastError = nil
                self?.rows = rows
            }
        )
    }
}

@MainActor
final class DatabaseSnapshotObservation: ObservableObject {
    @Published private(set) var wallets: [WalletRecord] = []
    @Published private(set) var metadataRows: [AppMetadataRecord] = []
    @Published private(set) var historicalPrices: [HistoricalPriceRecord] = []
    @Published private(set) var chainRecords: [ChainRecord] = []
    @Published private(set) var assetRecords: [AssetRecord] = []
    @Published private(set) var customTokenRecords: [CustomTokenRecord] = []
    @Published private(set) var transactions: [TransactionRecord] = []
    @Published private(set) var balances: [TokenBalanceRecord] = []
    @Published private(set) var chainStates: [ChainStateRecord] = []
    @Published private(set) var portfolioSummaries: [WalletPortfolioSummaryRecord] = []
    @Published private(set) var syncStatuses: [SyncStatusRecord] = []
    @Published private(set) var cachedPrices: [CachedPriceRecord] = []
    @Published private(set) var walletAddresses: [WalletAddressRecord] = []
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "database-snapshot")
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
        start()
    }

    deinit {
        cancellable?.cancel()
    }

    private func start() {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
                self?.log.error("Database snapshot observation failed: \(String(describing: error), privacy: .public)")
            },
            onChange: { [weak self] snapshot in
                self?.lastError = nil
                self?.wallets = snapshot.wallets
                self?.metadataRows = snapshot.metadataRows
                self?.historicalPrices = snapshot.historicalPrices
                self?.chainRecords = snapshot.chainRecords
                self?.assetRecords = snapshot.assetRecords
                self?.customTokenRecords = snapshot.customTokenRecords
                self?.transactions = snapshot.transactions
                self?.balances = snapshot.balances
                self?.chainStates = snapshot.chainStates
                self?.portfolioSummaries = snapshot.portfolioSummaries
                self?.syncStatuses = snapshot.syncStatuses
                self?.cachedPrices = snapshot.cachedPrices
                self?.walletAddresses = snapshot.walletAddresses
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        var wallets: [WalletRecord]
        var metadataRows: [AppMetadataRecord]
        var historicalPrices: [HistoricalPriceRecord]
        var chainRecords: [ChainRecord]
        var assetRecords: [AssetRecord]
        var customTokenRecords: [CustomTokenRecord]
        var transactions: [TransactionRecord]
        var balances: [TokenBalanceRecord]
        var chainStates: [ChainStateRecord]
        var portfolioSummaries: [WalletPortfolioSummaryRecord]
        var syncStatuses: [SyncStatusRecord]
        var cachedPrices: [CachedPriceRecord]
        var walletAddresses: [WalletAddressRecord]

        static func load(_ db: Database) throws -> Snapshot {
            let wallets = try Row.fetchAll(db, sql: "SELECT * FROM wallets ORDER BY sort_order ASC, created_at_ms ASC")
                .compactMap(Self.wallet)
            let addresses = try Row.fetchAll(db, sql: "SELECT * FROM wallet_addresses ORDER BY chain_raw ASC, is_receive_preferred DESC")
                .compactMap(Self.address)
            var walletById = Dictionary(uniqueKeysWithValues: wallets.map { ($0.id, $0) })
            var addressById = Dictionary(uniqueKeysWithValues: addresses.map { ($0.id, $0) })
            for address in addresses {
                guard let walletId = address.walletId, let wallet = walletById[walletId] else { continue }
                address.wallet = wallet
                wallet.addresses.append(address)
            }

            let transactions = try Row.fetchAll(db, sql: "SELECT * FROM transactions ORDER BY occurred_at_ms DESC")
                .compactMap { row -> TransactionRecord? in
                    guard let tx = Self.transaction(row) else { return nil }
                    if let addressId = tx.addressId, let address = addressById[addressId] {
                        tx.address = address
                        address.transactions.append(tx)
                    }
                    return tx
                }
            let balances = try Row.fetchAll(db, sql: "SELECT * FROM token_balances")
                .compactMap { row -> TokenBalanceRecord? in
                    guard let balance = Self.balance(row) else { return nil }
                    if let addressId = balance.addressId, let address = addressById[addressId] {
                        balance.address = address
                        address.balances.append(balance)
                    }
                    return balance
                }

            return Snapshot(
                wallets: wallets,
                metadataRows: try Row.fetchAll(db, sql: "SELECT * FROM app_metadata").compactMap(Self.metadata),
                historicalPrices: try Row.fetchAll(db, sql: "SELECT * FROM historical_prices").map(Self.historicalPrice),
                chainRecords: try Row.fetchAll(db, sql: "SELECT * FROM chains ORDER BY sort_index ASC").map(Self.chainRecord),
                assetRecords: try Row.fetchAll(db, sql: "SELECT * FROM assets").map(Self.assetRecord),
                customTokenRecords: try Row.fetchAll(db, sql: "SELECT * FROM custom_tokens").compactMap(Self.customToken),
                transactions: transactions,
                balances: balances,
                chainStates: try Row.fetchAll(db, sql: "SELECT * FROM chain_states").compactMap(Self.chainState),
                portfolioSummaries: try Row.fetchAll(db, sql: "SELECT * FROM wallet_portfolio_summaries").compactMap(Self.portfolioSummary),
                syncStatuses: try Row.fetchAll(db, sql: "SELECT * FROM sync_statuses").map(Self.syncStatus),
                cachedPrices: try Row.fetchAll(db, sql: "SELECT * FROM cached_prices").map(Self.cachedPrice),
                walletAddresses: addresses
            )
        }

        private static func wallet(_ row: Row) -> WalletRecord? {
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return WalletRecord(
                id: id,
                name: row["name"],
                kind: WalletKind(rawValue: row["kind_raw"]) ?? .watchOnly,
                mnemonicWordCount: row["mnemonic_word_count"],
                hasPassphrase: (row["has_passphrase"] as Int) != 0,
                colorTag: row["color_tag"],
                sortOrder: row["sort_order"],
                requiresBackup: (row["requires_backup"] as Int) != 0,
                manualBackupCompleted: row["manual_backup_completed"],
                iconSymbol: row["icon_symbol"],
                iconColorHex: row["icon_color_hex"],
                avatarGradient: row["avatar_gradient"],
                avatarSymbolType: row["avatar_symbol_type"],
                avatarGlyph: row["avatar_glyph"],
                avatarMonogram: row["avatar_monogram"],
                avatarCustomSvg: row["avatar_custom_svg"],
                avatarCustomTint: row["avatar_custom_tint"],
                avatarBadge: row["avatar_badge"],
                createdAt: Date(databaseMilliseconds: row["created_at_ms"]),
                updatedAt: Date(databaseMilliseconds: row["updated_at_ms"])
            )
        }

        private static func address(_ row: Row) -> WalletAddressRecord? {
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return WalletAddressRecord(
                id: id,
                walletId: UUID(uuidString: row["wallet_id"] as String),
                chainRaw: row["chain_raw"],
                address: row["address"],
                derivationPath: row["derivation_path"],
                isUsed: (row["is_used"] as Int) != 0,
                isReceivePreferred: (row["is_receive_preferred"] as Int) != 0,
                lastScannedAt: (row["last_scanned_at_ms"] as Int64?).map(Date.init(databaseMilliseconds:))
            )
        }

        private static func transaction(_ row: Row) -> TransactionRecord? {
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return TransactionRecord(
                id: id,
                txHash: row["tx_hash"],
                direction: TransactionDirection(rawValue: row["direction_raw"]) ?? .outgoing,
                amountRaw: row["amount_raw"],
                tokenSymbol: row["token_symbol"],
                tokenContract: row["token_contract"],
                blockNumber: row["block_number"],
                occurredAt: Date(databaseMilliseconds: row["occurred_at_ms"]),
                status: TransactionStatus(rawValue: row["status_raw"]) ?? .confirmed,
                counterparty: row["counterparty"],
                feeRaw: row["fee_raw"],
                addressId: UUID(uuidString: row["address_id"] as String),
                kindRaw: row["kind_raw"]
            )
        }

        private static func balance(_ row: Row) -> TokenBalanceRecord? {
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return TokenBalanceRecord(
                id: id,
                tokenSymbol: row["token_symbol"],
                tokenContract: row["token_contract"],
                decimals: row["decimals"],
                rawBalance: row["raw_balance"],
                fiatValueCached: Decimal(string: row["fiat_value_cached"] as String) ?? 0,
                fiatCurrencyCode: row["fiat_currency_code"],
                updatedAt: Date(databaseMilliseconds: row["updated_at_ms"]),
                addressId: UUID(uuidString: row["address_id"] as String)
            )
        }

        private static func metadata(_ row: Row) -> AppMetadataRecord? {
            AppMetadataRecord(
                id: UUID(uuidString: row["id"] as String) ?? UUID(),
                schemaVersion: row["schema_version"],
                firstLaunchAt: Date(databaseMilliseconds: row["first_launch_at_ms"]),
                lastOpenedAt: Date(databaseMilliseconds: row["last_opened_at_ms"]),
                requiresBiometricReenrollment: (row["requires_biometric_reenrollment"] as Int) != 0
            )
        }

        private static func historicalPrice(_ row: Row) -> HistoricalPriceRecord {
            HistoricalPriceRecord(
                symbol: row["symbol"],
                fiat: row["fiat"],
                dayKey: row["day_key"],
                price: Decimal(string: row["price"] as String) ?? 0,
                fetchedAt: Date(databaseMilliseconds: row["fetched_at_ms"])
            )
        }

        private static func chainRecord(_ row: Row) -> ChainRecord {
            ChainRecord(chainRaw: row["chain_raw"], ticker: row["ticker"], displayName: row["display_name"], sortIndex: row["sort_index"])
        }

        private static func assetRecord(_ row: Row) -> AssetRecord {
            AssetRecord(catalogId: row["catalog_id"], chainRaw: row["chain_raw"], symbol: row["symbol"], name: row["name"], contract: row["contract"], decimals: row["decimals"])
        }

        private static func customToken(_ row: Row) -> CustomTokenRecord? {
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return CustomTokenRecord(
                id: id,
                chainRaw: row["chain_raw"],
                contract: row["contract"],
                symbol: row["symbol"],
                name: row["name"],
                decimals: row["decimals"],
                iconURL: row["icon_url"],
                addedAt: Date(databaseMilliseconds: row["added_at_ms"]),
                metadataFromChain: (row["metadata_from_chain"] as Int) != 0
            )
        }

        private static func chainState(_ row: Row) -> ChainStateRecord? {
            guard let id = UUID(uuidString: row["id"]),
                  let walletId = UUID(uuidString: row["wallet_id"]) else { return nil }
            return ChainStateRecord(
                id: id,
                walletId: walletId,
                chainRaw: row["chain_raw"],
                address: row["address"],
                derivationPath: row["derivation_path"],
                nativeBalanceRaw: row["native_balance_raw"],
                nativeDecimals: row["native_decimals"],
                nativeFiat: Decimal(string: row["native_fiat"] as String) ?? 0,
                totalFiat: Decimal(string: row["total_fiat"] as String) ?? 0,
                tokenCount: row["token_count"],
                fiatCurrencyCode: row["fiat_currency_code"],
                txSentCount: row["tx_sent_count"],
                txReceivedCount: row["tx_received_count"],
                txSelfTransferCount: row["tx_self_transfer_count"],
                txBridgeCount: row["tx_bridge_count"],
                txFailedCount: row["tx_failed_count"],
                txPendingCount: row["tx_pending_count"],
                txTotalCount: row["tx_total_count"],
                utxoCount: row["utxo_count"],
                utxoTotalRaw: row["utxo_total_raw"],
                isUsed: (row["is_used"] as Int) != 0,
                lastSyncedAt: (row["last_synced_at_ms"] as Int64?).map(Date.init(databaseMilliseconds:)),
                syncState: ChainSyncState(rawValue: row["sync_state_raw"]) ?? .idle,
                encryptedPrivateKey: row["encrypted_private_key"],
                keyEncryptionScheme: row["key_encryption_scheme"]
            )
        }

        private static func portfolioSummary(_ row: Row) -> WalletPortfolioSummaryRecord? {
            guard let id = UUID(uuidString: row["id"]),
                  let walletId = UUID(uuidString: row["wallet_id"]) else { return nil }
            return WalletPortfolioSummaryRecord(
                id: id,
                walletId: walletId,
                currencyCode: row["currency_code"],
                totalFiat: Decimal(string: row["total_fiat"] as String) ?? 0,
                positiveChainCount: row["positive_chain_count"],
                positiveAssetCount: row["positive_asset_count"],
                positiveTokenCount: row["positive_token_count"],
                sourceChainCount: row["source_chain_count"],
                updatedAt: Date(databaseMilliseconds: row["updated_at_ms"])
            )
        }

        private static func syncStatus(_ row: Row) -> SyncStatusRecord {
            SyncStatusRecord(
                key: row["key"],
                domainRaw: row["domain_raw"],
                scopeId: row["scope_id"],
                lastSyncedAt: (row["last_synced_at_ms"] as Int64?).map(Date.init(databaseMilliseconds:)),
                lastAttemptAt: (row["last_attempt_at_ms"] as Int64?).map(Date.init(databaseMilliseconds:)),
                isSyncing: (row["is_syncing"] as Int) != 0,
                lastErrorMessage: row["last_error_message"],
                updatedAt: Date(databaseMilliseconds: row["updated_at_ms"])
            )
        }

        private static func cachedPrice(_ row: Row) -> CachedPriceRecord {
            CachedPriceRecord(
                symbol: row["symbol"],
                fiat: row["fiat"],
                price: Decimal(string: row["price"] as String) ?? 0,
                fetchedAt: Date(databaseMilliseconds: row["fetched_at_ms"]),
                source: row["source"]
            )
        }
    }
}
