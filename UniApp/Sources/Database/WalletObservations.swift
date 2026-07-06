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

private enum WalletObservationMapping {
    static func wallet(_ row: Row) -> WalletRecord? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let wallet = WalletRecord(
            id: id,
            name: row["name"],
            kind: WalletKind(rawValue: row["kind_raw"]) ?? .watchOnly,
            mnemonicWordCount: row["mnemonic_word_count"],
            hasPassphrase: (row["has_passphrase"] as Int) != 0,
            colorTag: row["color_tag"],
            sortOrder: row["sort_order"],
            requiresBackup: (row["requires_backup"] as Int) != 0,
            manualBackupCompleted: ((row["manual_backup_completed"] as Int?) ?? 0) != 0,
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
        wallet.isHidden = ((row["is_hidden"] as Int?) ?? 0) != 0
        return wallet
    }

    static func address(_ row: Row) -> WalletAddressRecord? {
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

    static func transaction(_ row: Row) -> TransactionRecord? {
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

    static func balance(_ row: Row) -> TokenBalanceRecord? {
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

    static func metadata(_ row: Row) -> AppMetadataRecord? {
        AppMetadataRecord(
            id: UUID(uuidString: row["id"] as String) ?? UUID(),
            schemaVersion: row["schema_version"],
            firstLaunchAt: Date(databaseMilliseconds: row["first_launch_at_ms"]),
            lastOpenedAt: Date(databaseMilliseconds: row["last_opened_at_ms"]),
            requiresBiometricReenrollment: (row["requires_biometric_reenrollment"] as Int) != 0
        )
    }

    static func chainRecord(_ row: Row) -> ChainRecord {
        ChainRecord(
            chainRaw: row["chain_raw"],
            ticker: row["ticker"],
            displayName: row["display_name"],
            sortIndex: row["sort_index"]
        )
    }

    static func assetRecord(_ row: Row) -> AssetRecord {
        AssetRecord(
            catalogId: row["catalog_id"],
            chainRaw: row["chain_raw"],
            symbol: row["symbol"],
            name: row["name"],
            contract: row["contract"],
            decimals: row["decimals"]
        )
    }

    static func customToken(_ row: Row) -> CustomTokenRecord? {
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

    static func historicalPrice(_ row: Row) -> HistoricalPriceRecord {
        HistoricalPriceRecord(
            symbol: row["symbol"],
            fiat: row["fiat"],
            dayKey: row["day_key"],
            price: Decimal(string: row["price"] as String) ?? 0,
            fetchedAt: Date(databaseMilliseconds: row["fetched_at_ms"])
        )
    }

    static func cachedPrice(_ row: Row) -> CachedPriceRecord {
        CachedPriceRecord(
            symbol: row["symbol"],
            fiat: row["fiat"],
            price: Decimal(string: row["price"] as String) ?? 0,
            fetchedAt: Date(databaseMilliseconds: row["fetched_at_ms"]),
            source: row["source"]
        )
    }

    static func chainState(_ row: Row) -> ChainStateRecord? {
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

    static func portfolioSummary(_ row: Row) -> WalletPortfolioSummaryRecord? {
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

    static func syncStatus(_ row: Row) -> SyncStatusRecord {
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
}

@MainActor
final class WalletRecordsObservation: ObservableObject {
    @Published private(set) var wallets: [WalletRecord] = []
    @Published private(set) var revision: String = "empty"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
        start()
    }

    deinit { cancellable?.cancel() }

    private func start() {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
            },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                wallets = snapshot.wallets
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let wallets: [WalletRecord]
        let revision: String

        static func load(_ db: Database) throws -> Snapshot {
            let wallets = try Row.fetchAll(
                db,
                sql: "SELECT * FROM wallets ORDER BY sort_order ASC, created_at_ms ASC"
            ).compactMap(WalletObservationMapping.wallet)
            let addresses = try Row.fetchAll(
                db,
                sql: "SELECT * FROM wallet_addresses ORDER BY wallet_id ASC, chain_raw ASC, is_receive_preferred DESC"
            ).compactMap(WalletObservationMapping.address)

            let walletById = Dictionary(uniqueKeysWithValues: wallets.map { ($0.id, $0) })
            for address in addresses {
                guard let walletId = address.walletId, let wallet = walletById[walletId] else { continue }
                address.wallet = wallet
                wallet.addresses.append(address)
            }

            var hasher = Hasher()
            hasher.combine(wallets.count)
            hasher.combine(addresses.count)
            for wallet in wallets {
                hasher.combine(wallet.id)
                hasher.combine(wallet.name)
                hasher.combine(wallet.kindRaw)
                hasher.combine(wallet.sortOrder)
                hasher.combine(wallet.isHidden)
                hasher.combine(wallet.requiresBackup)
                hasher.combine(wallet.manualBackupCompleted)
                hasher.combine(wallet.avatarGradient)
                hasher.combine(wallet.avatarSymbolType)
                hasher.combine(wallet.avatarGlyph)
                hasher.combine(wallet.avatarMonogram)
                hasher.combine(wallet.avatarCustomSvg)
                hasher.combine(wallet.avatarCustomTint)
                hasher.combine(wallet.avatarBadge)
                hasher.combine(wallet.updatedAt)
            }
            for address in addresses {
                hasher.combine(address.id)
                hasher.combine(address.walletId)
                hasher.combine(address.chainRaw)
                hasher.combine(address.address)
                hasher.combine(address.derivationPath)
                hasher.combine(address.isUsed)
                hasher.combine(address.isReceivePreferred)
                hasher.combine(address.lastScannedAt)
            }
            return Snapshot(wallets: wallets, revision: String(hasher.finalize()))
        }
    }
}

@MainActor
final class ActiveWalletBalancesObservation: ObservableObject {
    @Published private(set) var balances: [TokenBalanceRecord] = []
    @Published private(set) var revision: String = "none"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var walletId: UUID?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit { cancellable?.cancel() }

    func setWalletId(_ newWalletId: UUID?) {
        guard walletId != newWalletId else { return }
        walletId = newWalletId
        cancellable?.cancel()
        guard let newWalletId else {
            balances = []
            revision = "none"
            return
        }
        start(walletId: newWalletId)
    }

    private func start(walletId: UUID) {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db, walletId: walletId)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
            },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                balances = snapshot.balances
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let balances: [TokenBalanceRecord]
        let revision: String

        static func load(_ db: Database, walletId: UUID) throws -> Snapshot {
            let addresses = try Row.fetchAll(
                db,
                sql: "SELECT * FROM wallet_addresses WHERE wallet_id = ? ORDER BY chain_raw ASC",
                arguments: [walletId.uuidString]
            ).compactMap(WalletObservationMapping.address)
            let addressById = Dictionary(uniqueKeysWithValues: addresses.map { ($0.id, $0) })
            let balances = try Row.fetchAll(
                db,
                sql: """
                SELECT b.*
                FROM token_balances b
                JOIN wallet_addresses a ON a.id = b.address_id
                WHERE a.wallet_id = ?
                ORDER BY b.updated_at_ms DESC, b.token_symbol ASC
                """,
                arguments: [walletId.uuidString]
            ).compactMap { row -> TokenBalanceRecord? in
                guard let balance = WalletObservationMapping.balance(row) else { return nil }
                if let addressId = balance.addressId, let address = addressById[addressId] {
                    balance.address = address
                    address.balances.append(balance)
                }
                return balance
            }

            var hasher = Hasher()
            hasher.combine(walletId)
            hasher.combine(balances.count)
            for balance in balances {
                hasher.combine(balance.id)
                hasher.combine(balance.addressId)
                hasher.combine(balance.tokenSymbol.uppercased())
                hasher.combine(balance.tokenContract?.lowercased())
                hasher.combine(balance.decimals)
                hasher.combine(balance.rawBalance)
                hasher.combine(balance.fiatValueCached)
                hasher.combine(balance.fiatCurrencyCode.uppercased())
                hasher.combine(balance.updatedAt)
            }
            return Snapshot(balances: balances, revision: String(hasher.finalize()))
        }
    }
}

@MainActor
final class ActiveWalletTransactionsObservation: ObservableObject {
    @Published private(set) var transactions: [TransactionRecord] = []
    @Published private(set) var revision: String = "none"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var walletId: UUID?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit { cancellable?.cancel() }

    func setWalletId(_ newWalletId: UUID?) {
        guard walletId != newWalletId else { return }
        walletId = newWalletId
        cancellable?.cancel()
        guard let newWalletId else {
            transactions = []
            revision = "none"
            return
        }
        start(walletId: newWalletId)
    }

    private func start(walletId: UUID) {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db, walletId: walletId)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
            },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                transactions = snapshot.transactions
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let transactions: [TransactionRecord]
        let revision: String

        static func load(_ db: Database, walletId: UUID) throws -> Snapshot {
            let addresses = try Row.fetchAll(
                db,
                sql: "SELECT * FROM wallet_addresses WHERE wallet_id = ? ORDER BY chain_raw ASC",
                arguments: [walletId.uuidString]
            ).compactMap(WalletObservationMapping.address)
            let addressById = Dictionary(uniqueKeysWithValues: addresses.map { ($0.id, $0) })
            let transactions = try Row.fetchAll(
                db,
                sql: """
                SELECT t.*
                FROM transactions t
                JOIN wallet_addresses a ON a.id = t.address_id
                WHERE a.wallet_id = ?
                ORDER BY t.occurred_at_ms DESC
                """,
                arguments: [walletId.uuidString]
            ).compactMap { row -> TransactionRecord? in
                guard let tx = WalletObservationMapping.transaction(row) else { return nil }
                if let addressId = tx.addressId, let address = addressById[addressId] {
                    tx.address = address
                    address.transactions.append(tx)
                }
                return tx
            }

            var hasher = Hasher()
            hasher.combine(walletId)
            hasher.combine(transactions.count)
            for tx in transactions {
                hasher.combine(tx.id)
                hasher.combine(tx.addressId)
                hasher.combine(tx.txHash)
                hasher.combine(tx.directionRaw)
                hasher.combine(tx.amountRaw)
                hasher.combine(tx.tokenSymbol.uppercased())
                hasher.combine(tx.tokenContract?.lowercased())
                hasher.combine(tx.blockNumber)
                hasher.combine(tx.occurredAt)
                hasher.combine(tx.statusRaw)
                hasher.combine(tx.counterparty)
                hasher.combine(tx.feeRaw)
                hasher.combine(tx.kindRaw)
            }
            return Snapshot(transactions: transactions, revision: String(hasher.finalize()))
        }
    }
}

@MainActor
final class TransactionRecordObservation: ObservableObject {
    @Published private(set) var transaction: TransactionRecord?
    @Published private(set) var revision: String = "none"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var transactionId: UUID?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit { cancellable?.cancel() }

    func setTransactionId(_ newTransactionId: UUID?) {
        guard transactionId != newTransactionId else { return }
        transactionId = newTransactionId
        cancellable?.cancel()
        guard let newTransactionId else {
            transaction = nil
            revision = "none"
            return
        }
        start(transactionId: newTransactionId)
    }

    private func start(transactionId: UUID) {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db, transactionId: transactionId)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
            },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                transaction = snapshot.transaction
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let transaction: TransactionRecord?
        let revision: String

        static func load(_ db: Database, transactionId: UUID) throws -> Snapshot {
            guard let txRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM transactions WHERE id = ? LIMIT 1",
                arguments: [transactionId.uuidString]
            ),
                let tx = WalletObservationMapping.transaction(txRow)
            else {
                return Snapshot(transaction: nil, revision: "missing|\(transactionId.uuidString)")
            }

            if let addressId = tx.addressId,
               let addressRow = try Row.fetchOne(
                   db,
                   sql: "SELECT * FROM wallet_addresses WHERE id = ? LIMIT 1",
                   arguments: [addressId.uuidString]
               ),
               let address = WalletObservationMapping.address(addressRow) {
                tx.address = address
                address.transactions.append(tx)
            }

            var hasher = Hasher()
            hasher.combine(tx.id)
            hasher.combine(tx.addressId)
            hasher.combine(tx.txHash)
            hasher.combine(tx.directionRaw)
            hasher.combine(tx.amountRaw)
            hasher.combine(tx.tokenSymbol.uppercased())
            hasher.combine(tx.tokenContract?.lowercased())
            hasher.combine(tx.blockNumber)
            hasher.combine(tx.occurredAt)
            hasher.combine(tx.statusRaw)
            hasher.combine(tx.counterparty)
            hasher.combine(tx.feeRaw)
            hasher.combine(tx.kindRaw)
            hasher.combine(tx.address?.chainRaw)
            hasher.combine(tx.address?.address)
            return Snapshot(transaction: tx, revision: String(hasher.finalize()))
        }
    }
}

@MainActor
final class AppMetadataObservation: ObservableObject {
    @Published private(set) var metadataRows: [AppMetadataRecord] = []
    @Published private(set) var revision: String = "empty"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
        start()
    }

    deinit { cancellable?.cancel() }

    private func start() {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error },
            onChange: { [weak self] snapshot in
                self?.lastError = nil
                self?.metadataRows = snapshot.rows
                self?.revision = snapshot.revision
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let rows: [AppMetadataRecord]
        let revision: String

        static func load(_ db: Database) throws -> Snapshot {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM app_metadata")
                .compactMap(WalletObservationMapping.metadata)
            let revision = "\(rows.count)|\(rows.first?.lastOpenedAt.timeIntervalSince1970 ?? 0)|\(rows.first?.requiresBiometricReenrollment ?? false)"
            return Snapshot(rows: rows, revision: revision)
        }
    }
}

@MainActor
final class AssetCatalogObservation: ObservableObject {
    @Published private(set) var chainRecords: [ChainRecord] = []
    @Published private(set) var assetRecords: [AssetRecord] = []
    @Published private(set) var customTokenRecords: [CustomTokenRecord] = []
    @Published private(set) var revision: String = "empty"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
        start()
    }

    deinit { cancellable?.cancel() }

    private func start() {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                chainRecords = snapshot.chainRecords
                assetRecords = snapshot.assetRecords
                customTokenRecords = snapshot.customTokenRecords
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let chainRecords: [ChainRecord]
        let assetRecords: [AssetRecord]
        let customTokenRecords: [CustomTokenRecord]
        let revision: String

        static func load(_ db: Database) throws -> Snapshot {
            let chains = try Row.fetchAll(
                db,
                sql: "SELECT * FROM chains ORDER BY sort_index ASC"
            ).map(WalletObservationMapping.chainRecord)
            let assets = try Row.fetchAll(
                db,
                sql: "SELECT * FROM assets ORDER BY symbol ASC, chain_raw ASC"
            ).map(WalletObservationMapping.assetRecord)
            let custom = try Row.fetchAll(
                db,
                sql: "SELECT * FROM custom_tokens ORDER BY symbol ASC, chain_raw ASC"
            ).compactMap(WalletObservationMapping.customToken)
            var hasher = Hasher()
            hasher.combine(chains.count)
            hasher.combine(assets.count)
            hasher.combine(custom.count)
            for token in custom {
                hasher.combine(token.id)
                hasher.combine(token.chainRaw)
                hasher.combine(token.contract.lowercased())
                hasher.combine(token.symbol.uppercased())
                hasher.combine(token.name)
                hasher.combine(token.decimals)
                hasher.combine(token.iconURL)
            }
            return Snapshot(
                chainRecords: chains,
                assetRecords: assets,
                customTokenRecords: custom,
                revision: String(hasher.finalize())
            )
        }
    }
}

@MainActor
final class HistoricalPricesObservation: ObservableObject {
    @Published private(set) var prices: [HistoricalPriceRecord] = []
    @Published private(set) var revision: String = "none"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var currencyCode: String?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit { cancellable?.cancel() }

    func setCurrencyCode(_ newCode: String) {
        let normalized = newCode.uppercased()
        guard currencyCode != normalized else { return }
        currencyCode = normalized
        cancellable?.cancel()
        start(currencyCode: normalized)
    }

    private func start(currencyCode: String) {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db, currencyCode: currencyCode)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                prices = snapshot.prices
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let prices: [HistoricalPriceRecord]
        let revision: String

        static func load(_ db: Database, currencyCode: String) throws -> Snapshot {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM historical_prices WHERE fiat = ? ORDER BY symbol ASC, day_key ASC",
                arguments: [currencyCode]
            ).map(WalletObservationMapping.historicalPrice)
            var hasher = Hasher()
            hasher.combine(currencyCode)
            hasher.combine(rows.count)
            for row in rows {
                hasher.combine(row.key)
                hasher.combine(row.price)
                hasher.combine(row.fetchedAt)
            }
            return Snapshot(prices: rows, revision: String(hasher.finalize()))
        }
    }
}

@MainActor
final class CachedPricesObservation: ObservableObject {
    @Published private(set) var prices: [CachedPriceRecord] = []
    @Published private(set) var priceMap: [String: Decimal] = [:]
    @Published private(set) var revision: String = "none"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var currencyCode: String?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit { cancellable?.cancel() }

    func setCurrencyCode(_ newCode: String) {
        let normalized = newCode.uppercased()
        guard currencyCode != normalized else { return }
        currencyCode = normalized
        cancellable?.cancel()
        start(currencyCode: normalized)
    }

    private func start(currencyCode: String) {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db, currencyCode: currencyCode)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                prices = snapshot.prices
                priceMap = snapshot.priceMap
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let prices: [CachedPriceRecord]
        let priceMap: [String: Decimal]
        let revision: String

        static func load(_ db: Database, currencyCode: String) throws -> Snapshot {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM cached_prices WHERE fiat = ? ORDER BY symbol ASC",
                arguments: [currencyCode]
            ).map(WalletObservationMapping.cachedPrice)
            var map: [String: Decimal] = [:]
            var hasher = Hasher()
            hasher.combine(currencyCode)
            hasher.combine(rows.count)
            for row in rows {
                let symbol = row.symbol.uppercased()
                map[symbol] = row.price
                hasher.combine(symbol)
                hasher.combine(row.price)
                hasher.combine(row.fetchedAt)
                hasher.combine(row.source)
            }
            return Snapshot(prices: rows, priceMap: map, revision: String(hasher.finalize()))
        }
    }
}

@MainActor
final class WalletBalanceCardObservation: ObservableObject {
    @Published private(set) var chainStates: [ChainStateRecord] = []
    @Published private(set) var portfolioSummaries: [WalletPortfolioSummaryRecord] = []
    @Published private(set) var syncStatuses: [SyncStatusRecord] = []
    @Published private(set) var cachedPrices: [CachedPriceRecord] = []
    @Published private(set) var priceMap: [String: Decimal] = [:]
    @Published private(set) var revision: String = "none"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var scope: Scope?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit { cancellable?.cancel() }

    func setScope(walletId: UUID?, currencyCode: String) {
        let newScope = walletId.map { Scope(walletId: $0, currencyCode: currencyCode.uppercased()) }
        guard scope != newScope else { return }
        scope = newScope
        cancellable?.cancel()
        guard let newScope else {
            chainStates = []
            portfolioSummaries = []
            syncStatuses = []
            cachedPrices = []
            priceMap = [:]
            revision = "none"
            return
        }
        start(scope: newScope)
    }

    private func start(scope: Scope) {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db, scope: scope)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                chainStates = snapshot.chainStates
                portfolioSummaries = snapshot.portfolioSummaries
                syncStatuses = snapshot.syncStatuses
                cachedPrices = snapshot.cachedPrices
                priceMap = snapshot.priceMap
            }
        )
    }

    private struct Scope: Equatable {
        let walletId: UUID
        let currencyCode: String
    }

    private struct Snapshot: @unchecked Sendable {
        let chainStates: [ChainStateRecord]
        let portfolioSummaries: [WalletPortfolioSummaryRecord]
        let syncStatuses: [SyncStatusRecord]
        let cachedPrices: [CachedPriceRecord]
        let priceMap: [String: Decimal]
        let revision: String

        static func load(_ db: Database, scope: Scope) throws -> Snapshot {
            let chainStates = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM chain_states
                WHERE wallet_id = ? AND fiat_currency_code = ?
                ORDER BY chain_raw ASC
                """,
                arguments: [scope.walletId.uuidString, scope.currencyCode]
            ).compactMap(WalletObservationMapping.chainState)
            let summaries = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM wallet_portfolio_summaries
                WHERE wallet_id = ? AND currency_code = ?
                """,
                arguments: [scope.walletId.uuidString, scope.currencyCode]
            ).compactMap(WalletObservationMapping.portfolioSummary)
            let syncStatuses = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM sync_statuses
                WHERE scope_id = ?
                  AND domain_raw IN (?, ?)
                ORDER BY domain_raw ASC
                """,
                arguments: [
                    scope.walletId.uuidString,
                    SyncDomain.balances.rawValue,
                    SyncDomain.transactions.rawValue
                ]
            ).map(WalletObservationMapping.syncStatus)
            let cachedPrices = try Row.fetchAll(
                db,
                sql: "SELECT * FROM cached_prices WHERE fiat = ? ORDER BY symbol ASC",
                arguments: [scope.currencyCode]
            ).map(WalletObservationMapping.cachedPrice)
            var priceMap: [String: Decimal] = [:]
            var hasher = Hasher()
            hasher.combine(scope.walletId)
            hasher.combine(scope.currencyCode)
            for row in summaries {
                hasher.combine(row.lookupKey)
                hasher.combine(row.totalFiat)
                hasher.combine(row.updatedAt)
            }
            for row in chainStates {
                hasher.combine(row.id)
                hasher.combine(row.chainRaw)
                hasher.combine(row.nativeBalanceRaw)
                hasher.combine(row.nativeFiat)
                hasher.combine(row.totalFiat)
                hasher.combine(row.tokenCount)
                hasher.combine(row.txTotalCount)
                hasher.combine(row.utxoCount)
                hasher.combine(row.utxoTotalRaw)
                hasher.combine(row.lastSyncedAt)
                hasher.combine(row.syncStateRaw)
            }
            for row in syncStatuses {
                hasher.combine(row.key)
                hasher.combine(row.lastSyncedAt)
                hasher.combine(row.lastAttemptAt)
                hasher.combine(row.isSyncing)
                hasher.combine(row.lastErrorMessage)
                hasher.combine(row.updatedAt)
            }
            for row in cachedPrices {
                let symbol = row.symbol.uppercased()
                priceMap[symbol] = row.price
                hasher.combine(symbol)
                hasher.combine(row.price)
                hasher.combine(row.fetchedAt)
            }
            return Snapshot(
                chainStates: chainStates,
                portfolioSummaries: summaries,
                syncStatuses: syncStatuses,
                cachedPrices: cachedPrices,
                priceMap: priceMap,
                revision: String(hasher.finalize())
            )
        }
    }
}

@MainActor
final class WalletPortfolioSummariesObservation: ObservableObject {
    @Published private(set) var summaries: [WalletPortfolioSummaryRecord] = []
    @Published private(set) var revision: String = "none"
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private var currencyCode: String?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit { cancellable?.cancel() }

    func setCurrencyCode(_ newCode: String) {
        let normalized = newCode.uppercased()
        guard currencyCode != normalized else { return }
        currencyCode = normalized
        cancellable?.cancel()
        start(currencyCode: normalized)
    }

    private func start(currencyCode: String) {
        let observation = ValueObservation.tracking { db in
            try Snapshot.load(db, currencyCode: currencyCode)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in self?.lastError = error },
            onChange: { [weak self] snapshot in
                guard let self else { return }
                guard snapshot.revision != revision else {
                    lastError = nil
                    return
                }
                lastError = nil
                revision = snapshot.revision
                summaries = snapshot.summaries
            }
        )
    }

    private struct Snapshot: @unchecked Sendable {
        let summaries: [WalletPortfolioSummaryRecord]
        let revision: String

        static func load(_ db: Database, currencyCode: String) throws -> Snapshot {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM wallet_portfolio_summaries WHERE currency_code = ?",
                arguments: [currencyCode]
            ).compactMap(WalletObservationMapping.portfolioSummary)
            var hasher = Hasher()
            hasher.combine(currencyCode)
            hasher.combine(rows.count)
            for row in rows {
                hasher.combine(row.lookupKey)
                hasher.combine(row.totalFiat)
                hasher.combine(row.updatedAt)
            }
            return Snapshot(summaries: rows, revision: String(hasher.finalize()))
        }
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
                manualBackupCompleted: ((row["manual_backup_completed"] as Int?) ?? 0) != 0,
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
