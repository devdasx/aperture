import Foundation
import GRDB
import Darwin
import OSLog

final class AppDatabase: @unchecked Sendable {
    static let shared = AppDatabase()

    let pool: DatabasePool
    let storeURL: URL
    let isInMemoryFallback: Bool

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "database")
    private static let transitionWipeMarkerFileName = ".aperture-grdb-transition-v1"

    private init() {
        let opened = Self.openBestEffortStore()
        storeURL = opened.url
        pool = opened.pool
        isInMemoryFallback = opened.isFallback

        WalletSecretCrypto.configure(database: self)
        ChainKeyVault.configure(database: self)
        DiagnosticsLogStore.shared.configure(database: self)
        if let recoveryReason = opened.recoveryReason {
            DiagnosticsLogStore.shared.record(
                .warning,
                category: "database",
                message: "GRDB database recovered",
                metadata: ["store": opened.url.path, "reason": recoveryReason]
            )
        }
        DiagnosticsLogStore.shared.record(
            .info,
            category: "database",
            message: "GRDB database opened",
            metadata: ["store": opened.url.path, "fallback": opened.isFallback ? "true" : "false"]
        )
    }

    init(testStoreURL url: URL, seedSingletonRows: Bool = true) throws {
        storeURL = url
        isInMemoryFallback = false
        try Self.prepareDirectory(for: url)
        try Self.deleteSQLiteFiles(at: url)
        pool = try Self.openPool(at: url)
        try Self.migrator.migrate(pool)
        if seedSingletonRows {
            try pool.write { db in
                try Self.ensureSingletonRows(db)
            }
        }
        WalletSecretCrypto.configure(database: self)
        ChainKeyVault.configure(database: self)
        DiagnosticsLogStore.shared.configure(database: self)
        try Self.validateIntegrity(pool)
        try Self.markExcludedFromBackup(url)
    }

    @MainActor
    func bootstrap() {
        do {
        try pool.write { db in
            try AppDatabase.ensureSingletonRows(db)
        }
        WalletSecretCrypto.configure(database: self)
        ChainKeyVault.configure(database: self)
        DiagnosticsLogStore.shared.configure(database: self)
        AppPreferenceStore.shared.configure(database: self)
        ActiveWalletPointer.configure(database: self)
            Task(priority: .utility) {
                do {
                    try AssetCatalogSeeder.seed(database: self)
                    SigningKeyProvider.configure(database: self)
                    DiagnosticsLogStore.shared.record(.debug, category: "database", message: "GRDB bootstrap finished")
                } catch {
                    self.log.error("GRDB bootstrap failed: \(String(describing: error), privacy: .public)")
                    DiagnosticsLogStore.shared.record(
                        .error,
                        category: "database",
                        message: "GRDB bootstrap failed",
                        metadata: ["error": String(describing: error)]
                    )
                }
            }
        } catch {
            log.error("GRDB singleton bootstrap failed: \(String(describing: error), privacy: .public)")
            DiagnosticsLogStore.shared.record(
                .error,
                category: "database",
                message: "GRDB singleton bootstrap failed",
                metadata: ["error": String(describing: error)]
            )
        }
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.write(block)
    }

    func tableCount(_ table: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") ?? 0
        }
    }

    static func resetStoreFiles(at storeURL: URL? = nil) throws {
        let url = try storeURL ?? defaultStoreURL()
        try deleteSQLiteFiles(at: url)
    }

    private static func defaultStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("Aperture", isDirectory: true)
            .appendingPathComponent("aperture.sqlite", isDirectory: false)
    }

    private static func prepareDirectory(for fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private static func openPool(at url: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.label = "Aperture.GRDB"
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        return try DatabasePool(path: url.path, configuration: configuration)
    }

    private struct OpenedStore {
        let url: URL
        let pool: DatabasePool
        let isFallback: Bool
        let recoveryReason: String?
    }

    private static func openBestEffortStore() -> OpenedStore {
        do {
            let url = try defaultStoreURL()
            try prepareDirectory(for: url)
            try runFreshGRDBTransitionWipeIfNeeded(storeURL: url)
            do {
                let pool = try bootstrapPool(at: url)
                return OpenedStore(url: url, pool: pool, isFallback: false, recoveryReason: nil)
            } catch {
                let reason = String(describing: error)
                try? quarantineSQLiteFiles(at: url, reason: reason)
                FreshInstallGuard.purgeAllKnownKeychainServicesForDatabaseReplacement()
                let pool = try bootstrapPool(at: url)
                return OpenedStore(url: url, pool: pool, isFallback: false, recoveryReason: reason)
            }
        } catch {
            let fallbackReason = String(describing: error)
            let fallbackURL = fallbackStoreURL()
            do {
                try prepareDirectory(for: fallbackURL)
                let pool = try bootstrapPool(at: fallbackURL)
                return OpenedStore(url: fallbackURL, pool: pool, isFallback: true, recoveryReason: fallbackReason)
            } catch {
                let lastResortURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aperture-last-resort-\(UUID().uuidString).sqlite", isDirectory: false)
                try? prepareDirectory(for: lastResortURL)
                if let pool = try? bootstrapPool(at: lastResortURL) {
                    return OpenedStore(
                        url: lastResortURL,
                        pool: pool,
                        isFallback: true,
                        recoveryReason: "\(fallbackReason); fallback failed: \(String(describing: error))"
                    )
                }
                Darwin.exit(EXIT_FAILURE)
            }
        }
    }

    private static func bootstrapPool(at url: URL) throws -> DatabasePool {
        let pool = try openPool(at: url)
        try migrator.migrate(pool)
        try pool.write { db in
            try ensureSingletonRows(db)
        }
        try validateIntegrity(pool)
        try markExcludedFromBackup(url)
        return pool
    }

    private static func fallbackStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Aperture", isDirectory: true)
            .appendingPathComponent("aperture-recovered-\(UUID().uuidString).sqlite", isDirectory: false)
    }

    private static func quarantineSQLiteFiles(at url: URL, reason: String) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let quarantineDirectory = directory.appendingPathComponent("CorruptStore-\(timestamp)", isDirectory: true)
        try fm.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)

        let paths = sqliteFileURLs(at: url, includeSidecars: true)
        var movedAnyFile = false
        for source in paths where fm.fileExists(atPath: source.path) {
            let destination = quarantineDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            try fm.moveItem(at: source, to: destination)
            movedAnyFile = true
        }

        if movedAnyFile {
            let reasonURL = quarantineDirectory.appendingPathComponent("reason.txt", isDirectory: false)
            try reason.write(to: reasonURL, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: quarantineDirectory)
        }
    }

    private static func validateIntegrity(_ pool: DatabasePool) throws {
        try pool.read { db in
            guard let result = try String.fetchOne(db, sql: "PRAGMA quick_check"), result == "ok" else {
                throw AppDatabaseError.integrityCheckFailed("quick_check")
            }
            let foreignKeyProblems = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            guard foreignKeyProblems.isEmpty else {
                throw AppDatabaseError.integrityCheckFailed("foreign_key_check")
            }
        }
    }

    private static func runFreshGRDBTransitionWipeIfNeeded(storeURL: URL) throws {
        try runFreshGRDBTransitionWipeIfNeeded(
            storeURL: storeURL,
            markerURL: transitionWipeMarkerURL(for: storeURL),
            purgeKeychain: true
        )
    }

    static func runFreshGRDBTransitionWipeForTesting(
        storeURL: URL,
        markerURL: URL? = nil
    ) throws {
        try runFreshGRDBTransitionWipeIfNeeded(
            storeURL: storeURL,
            markerURL: markerURL ?? transitionWipeMarkerURL(for: storeURL),
            purgeKeychain: false
        )
    }

    private static func runFreshGRDBTransitionWipeIfNeeded(
        storeURL: URL,
        markerURL: URL,
        purgeKeychain: Bool
    ) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: markerURL.path) else { return }
        try deleteSQLiteFiles(at: storeURL)
        if purgeKeychain {
            FreshInstallGuard.purgeAllKnownKeychainServicesForDatabaseReplacement()
        }
        try fm.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: markerURL.path, contents: Data(), attributes: nil)
    }

    private static func deleteSQLiteFiles(at url: URL) throws {
        let fm = FileManager.default
        for fileURL in sqliteFileURLs(at: url, includeSidecars: true) where fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }

    private static func sqliteFileURLs(at url: URL, includeSidecars: Bool) -> [URL] {
        var urls = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm"),
            URL(fileURLWithPath: url.path + "-journal")
        ]
        guard includeSidecars else { return urls }
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        if let sidecars = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for sidecar in sidecars where sidecar.lastPathComponent.hasPrefix(base + "-") {
                urls.append(sidecar)
            }
        }
        return Array(Set(urls))
    }

    private static func transitionWipeMarkerURL(for storeURL: URL) -> URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent(transitionWipeMarkerFileName, isDirectory: false)
    }

    private static func markExcludedFromBackup(_ url: URL) throws {
        var directory = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private static func ensureSingletonRows(_ db: Database) throws {
        let now = Date.databaseMilliseconds
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO app_metadata
            (id, schema_version, first_launch_at_ms, last_opened_at_ms, requires_biometric_reenrollment)
            VALUES ('app-metadata-singleton', 1, ?, ?, 0)
            """,
            arguments: [now, now]
        )
        try db.execute(
            sql: """
            UPDATE app_metadata
            SET last_opened_at_ms = ?
            WHERE id = 'app-metadata-singleton'
            """,
            arguments: [now]
        )
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO active_wallet
            (id, wallet_id, updated_at_ms)
            VALUES ('active-wallet-singleton', NULL, ?)
            """,
            arguments: [now]
        )
        try AppSettingsProjection.ensureSingleton(db, activeWalletId: "", now: now)
        try LocalSecureBlobStore.ensureSecurityKeys(db: db)
    }
}

enum AppSettingsProjection {
    static func ensureSingleton(
        _ db: Database,
        activeWalletId: String,
        now: Int64 = Date.databaseMilliseconds
    ) throws {
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(app_settings)")
            .compactMap(AppSettingsColumn.init(row:))
        guard !columns.isEmpty else { return }

        var arguments: StatementArguments = []
        let names = columns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        for column in columns {
            append(defaultValue(for: column, activeWalletId: activeWalletId, now: now), to: &arguments)
        }

        try db.execute(
            sql: """
            INSERT INTO app_settings (\(names))
            VALUES (\(placeholders))
            ON CONFLICT(id) DO UPDATE SET
                active_wallet_id = excluded.active_wallet_id,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: arguments
        )
    }

    private static func defaultValue(
        for column: AppSettingsColumn,
        activeWalletId: String,
        now: Int64
    ) -> AppSettingsValue {
        switch column.name {
        case "id":
            return .text(AppSettingsRecord.singletonId)
        case "theme_preference":
            return .text(ThemePreference.defaultRaw)
        case "language_preference":
            return .text(LanguagePreference.systemCode)
        case "pin_enabled", "biometric_enabled", "erase_data_after_failed_attempts",
             "hide_balance_on_home", "has_unbackedup_wallet", "hide_import_key_warning":
            return .int(0)
        case "require_biometric_for_send", "haptic_feedback_enabled",
             "background_balance_refresh", "transaction_amount_display":
            return .int(1)
        case "auto_lock_seconds", "selected_tab":
            return .int(0)
        case "currency_preference":
            return .text(CurrencyPreference.defaultForCurrentRegion())
        case "active_wallet_id":
            return .text(activeWalletId)
        case "settings_deep_link", "coin_market_cap_api_key":
            return .text("")
        case "hide_small_balances_threshold":
            return .double(0)
        case "restoration_left_app_at", "restoration_settings_path", "restoration_wallet_home_path":
            return .null
        case "wallet_home_balance_history_range":
            // Older on-device databases may still carry this removed chart
            // preference as TEXT NOT NULL without a SQL default.
            return .text("all")
        case "updated_at_ms":
            return .int64(now)
        default:
            return fallbackValue(for: column)
        }
    }

    private static func fallbackValue(for column: AppSettingsColumn) -> AppSettingsValue {
        guard column.isNotNull else { return .null }
        let type = column.type.uppercased()
        if type.contains("INT") { return .int(0) }
        if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB") { return .double(0) }
        if type.contains("BLOB") { return .data(Data()) }
        return .text("")
    }

    private static func append(_ value: AppSettingsValue, to arguments: inout StatementArguments) {
        switch value {
        case .text(let raw):
            arguments += [raw]
        case .int(let raw):
            arguments += [raw]
        case .int64(let raw):
            arguments += [raw]
        case .double(let raw):
            arguments += [raw]
        case .data(let raw):
            arguments += [raw]
        case .null:
            let null: String? = nil
            arguments += [null]
        }
    }

    private static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct AppSettingsColumn {
    let name: String
    let type: String
    let isNotNull: Bool

    init?(row: Row) {
        guard let name: String = row["name"] else { return nil }
        self.name = name
        self.type = row["type"] as String? ?? ""
        if let raw: Int = row["notnull"] {
            self.isNotNull = raw != 0
        } else if let raw: Int64 = row["notnull"] {
            self.isNotNull = raw != 0
        } else {
            self.isNotNull = false
        }
    }
}

private enum AppSettingsValue {
    case text(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case data(Data)
    case null
}

private extension AppDatabase {
    nonisolated static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: schemaSQL)
        }
        migrator.registerMigration("v2_wallet_manual_backup_defaults") { db in
            try db.execute(sql: "UPDATE wallets SET manual_backup_completed = 0 WHERE manual_backup_completed IS NULL")
        }
        migrator.registerMigration("v3_grdb_preferences") { db in
            try db.execute(sql: preferenceTablesSQL)
            let appSettingsColumns = Set(try db.columns(in: "app_settings").map(\.name))
            for column in appSettingsPreferenceColumns where !appSettingsColumns.contains(column.name) {
                try db.execute(sql: "ALTER TABLE app_settings ADD COLUMN \(column.sql)")
            }
        }
        migrator.registerMigration("v4_grdb_blob_and_security_stores") { db in
            try db.execute(sql: blobAndSecurityTablesSQL)
        }
        migrator.registerMigration("v5_wallet_asset_route_templates") { db in
            try db.execute(sql: walletAssetRouteTemplatesSQL)
        }
        return migrator
    }

    nonisolated static let appSettingsPreferenceColumns: [(name: String, sql: String)] = [
        ("require_biometric_for_send", "require_biometric_for_send INTEGER NOT NULL DEFAULT 1"),
        ("erase_data_after_failed_attempts", "erase_data_after_failed_attempts INTEGER NOT NULL DEFAULT 0"),
        ("hide_balance_on_home", "hide_balance_on_home INTEGER NOT NULL DEFAULT 0"),
        ("hide_small_balances_threshold", "hide_small_balances_threshold REAL NOT NULL DEFAULT 0"),
        ("transaction_amount_display", "transaction_amount_display INTEGER NOT NULL DEFAULT 1"),
        ("coin_market_cap_api_key", "coin_market_cap_api_key TEXT NOT NULL DEFAULT ''"),
        ("restoration_left_app_at", "restoration_left_app_at REAL"),
        ("restoration_settings_path", "restoration_settings_path BLOB"),
        ("restoration_wallet_home_path", "restoration_wallet_home_path BLOB")
    ]

    nonisolated static let preferenceTablesSQL = """
    CREATE TABLE IF NOT EXISTS app_preferences (
        key TEXT PRIMARY KEY,
        value_type TEXT NOT NULL,
        string_value TEXT,
        int_value INTEGER,
        double_value REAL,
        bool_value INTEGER,
        data_value BLOB,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS wallet_preferences (
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value_type TEXT NOT NULL,
        string_value TEXT,
        int_value INTEGER,
        double_value REAL,
        bool_value INTEGER,
        data_value BLOB,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY(wallet_id, key)
    );
    CREATE INDEX IF NOT EXISTS idx_wallet_preferences_wallet ON wallet_preferences(wallet_id);
    """

    nonisolated static let blobAndSecurityTablesSQL = """
    CREATE TABLE IF NOT EXISTS local_secure_blobs (
        key TEXT PRIMARY KEY,
        blob BLOB NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS diagnostic_log_entries (
        id TEXT PRIMARY KEY,
        timestamp_ms INTEGER NOT NULL,
        level_raw TEXT NOT NULL,
        category TEXT NOT NULL,
        message TEXT NOT NULL,
        metadata_json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_diagnostic_log_entries_time
        ON diagnostic_log_entries(timestamp_ms DESC);

    CREATE TABLE IF NOT EXISTS asset_logo_cache (
        cache_key TEXT PRIMARY KEY,
        source_url TEXT NOT NULL UNIQUE,
        png_data BLOB NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS wallet_avatar_raster_cache (
        wallet_id TEXT PRIMARY KEY REFERENCES wallets(id) ON DELETE CASCADE,
        png_data BLOB NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS generated_documents (
        id TEXT PRIMARY KEY,
        kind_raw TEXT NOT NULL,
        file_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        data BLOB NOT NULL,
        created_at_ms INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_generated_documents_created
        ON generated_documents(created_at_ms DESC);

    CREATE TABLE IF NOT EXISTS cloudkit_backup_cache (
        wallet_id TEXT PRIMARY KEY,
        version INTEGER NOT NULL,
        encoded_blob BLOB NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );
    """

    nonisolated static let walletAssetRouteTemplatesSQL = """
    CREATE TABLE IF NOT EXISTS wallet_asset_route_templates (
        id TEXT PRIMARY KEY,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        flow_raw TEXT NOT NULL,
        asset_kind_raw TEXT NOT NULL,
        chain_raw TEXT NOT NULL,
        symbol TEXT NOT NULL,
        name TEXT NOT NULL,
        contract TEXT,
        decimals INTEGER,
        source_raw TEXT,
        dedup_key TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        UNIQUE(wallet_id, flow_raw, dedup_key)
    );
    CREATE INDEX IF NOT EXISTS idx_wallet_asset_route_templates_lookup
        ON wallet_asset_route_templates(wallet_id, flow_raw, updated_at_ms DESC);
    """

    nonisolated static let schemaSQL = """
    CREATE TABLE wallets (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind_raw TEXT NOT NULL,
        mnemonic_word_count INTEGER,
        has_passphrase INTEGER NOT NULL DEFAULT 0,
        color_tag TEXT NOT NULL DEFAULT '',
        icon_symbol TEXT NOT NULL DEFAULT '',
        icon_color_hex TEXT NOT NULL DEFAULT '',
        avatar_gradient TEXT NOT NULL DEFAULT '',
        avatar_symbol_type TEXT NOT NULL DEFAULT '',
        avatar_glyph TEXT,
        avatar_monogram TEXT,
        avatar_custom_svg TEXT,
        avatar_custom_tint TEXT,
        avatar_badge TEXT,
        sort_order INTEGER NOT NULL,
        is_hidden INTEGER NOT NULL DEFAULT 0,
        requires_backup INTEGER NOT NULL DEFAULT 0,
        manual_backup_completed INTEGER DEFAULT 0,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE wallet_addresses (
        id TEXT PRIMARY KEY,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        address TEXT NOT NULL,
        derivation_path TEXT NOT NULL DEFAULT '',
        is_used INTEGER NOT NULL DEFAULT 0,
        is_receive_preferred INTEGER NOT NULL DEFAULT 0,
        last_scanned_at_ms INTEGER,
        UNIQUE(wallet_id, chain_raw, address)
    );
    CREATE INDEX idx_wallet_addresses_wallet ON wallet_addresses(wallet_id);
    CREATE INDEX idx_wallet_addresses_wallet_chain ON wallet_addresses(wallet_id, chain_raw);
    CREATE UNIQUE INDEX idx_wallet_addresses_preferred
        ON wallet_addresses(wallet_id, chain_raw)
        WHERE is_receive_preferred = 1;

    CREATE TABLE wallet_secrets (
        key TEXT PRIMARY KEY,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        kind_raw TEXT NOT NULL,
        cipher_data BLOB NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        UNIQUE(wallet_id, kind_raw)
    );

    CREATE TABLE transactions (
        id TEXT PRIMARY KEY,
        address_id TEXT NOT NULL REFERENCES wallet_addresses(id) ON DELETE CASCADE,
        tx_hash TEXT NOT NULL,
        direction_raw TEXT NOT NULL,
        amount_raw TEXT NOT NULL,
        token_symbol TEXT NOT NULL,
        token_contract TEXT,
        block_number INTEGER,
        occurred_at_ms INTEGER NOT NULL,
        status_raw TEXT NOT NULL,
        counterparty TEXT NOT NULL,
        fee_raw TEXT,
        kind_raw TEXT
    );
    CREATE UNIQUE INDEX idx_transactions_leg
        ON transactions(tx_hash, address_id, IFNULL(token_contract, ''), token_symbol, direction_raw);
    CREATE INDEX idx_transactions_address_time ON transactions(address_id, occurred_at_ms DESC);
    CREATE INDEX idx_transactions_time ON transactions(occurred_at_ms DESC);

    CREATE TABLE token_balances (
        id TEXT PRIMARY KEY,
        address_id TEXT NOT NULL REFERENCES wallet_addresses(id) ON DELETE CASCADE,
        token_symbol TEXT NOT NULL,
        token_contract TEXT,
        decimals INTEGER NOT NULL,
        raw_balance TEXT NOT NULL,
        fiat_value_cached TEXT NOT NULL DEFAULT '0',
        fiat_value_cached_numeric REAL NOT NULL DEFAULT 0,
        fiat_currency_code TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE UNIQUE INDEX idx_token_balances_identity
        ON token_balances(address_id, token_symbol, IFNULL(token_contract, ''));
    CREATE INDEX idx_token_balances_address ON token_balances(address_id);

    CREATE TABLE cached_prices (
        key TEXT PRIMARY KEY,
        symbol TEXT NOT NULL,
        fiat TEXT NOT NULL,
        price TEXT NOT NULL,
        price_numeric REAL NOT NULL DEFAULT 0,
        fetched_at_ms INTEGER NOT NULL,
        source TEXT NOT NULL
    );
    CREATE INDEX idx_cached_prices_fiat ON cached_prices(fiat);
    CREATE INDEX idx_cached_prices_symbol_fiat ON cached_prices(symbol, fiat);

    CREATE TABLE biometric_enrollment (
        id TEXT PRIMARY KEY,
        domain_state_snapshot BLOB,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE app_metadata (
        id TEXT PRIMARY KEY,
        schema_version INTEGER NOT NULL,
        first_launch_at_ms INTEGER NOT NULL,
        last_opened_at_ms INTEGER NOT NULL,
        requires_biometric_reenrollment INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE custom_tokens (
        id TEXT PRIMARY KEY,
        chain_raw TEXT NOT NULL,
        contract TEXT NOT NULL,
        symbol TEXT NOT NULL,
        name TEXT NOT NULL,
        decimals INTEGER NOT NULL,
        icon_url TEXT,
        added_at_ms INTEGER NOT NULL,
        metadata_from_chain INTEGER NOT NULL DEFAULT 1,
        dedup_key TEXT NOT NULL UNIQUE
    );
    CREATE INDEX idx_custom_tokens_chain ON custom_tokens(chain_raw);

    CREATE TABLE historical_prices (
        key TEXT PRIMARY KEY,
        symbol TEXT NOT NULL,
        fiat TEXT NOT NULL,
        day_key INTEGER NOT NULL,
        price TEXT NOT NULL,
        price_numeric REAL NOT NULL DEFAULT 0,
        fetched_at_ms INTEGER NOT NULL
    );
    CREATE INDEX idx_historical_prices_lookup ON historical_prices(symbol, fiat, day_key);

    CREATE TABLE price_snapshots (
        id TEXT PRIMARY KEY,
        symbol TEXT NOT NULL,
        currency_code TEXT NOT NULL,
        price TEXT NOT NULL,
        price_numeric REAL NOT NULL DEFAULT 0,
        fetched_at_ms INTEGER NOT NULL,
        source TEXT NOT NULL,
        day_key INTEGER NOT NULL
    );
    CREATE INDEX idx_price_snapshots_currency_time ON price_snapshots(currency_code, fetched_at_ms);
    CREATE INDEX idx_price_snapshots_symbol_currency_time ON price_snapshots(symbol, currency_code, fetched_at_ms);

    CREATE TABLE wallet_portfolio_summaries (
        id TEXT PRIMARY KEY,
        lookup_key TEXT NOT NULL UNIQUE,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        currency_code TEXT NOT NULL,
        total_fiat TEXT NOT NULL,
        total_fiat_numeric REAL NOT NULL DEFAULT 0,
        positive_chain_count INTEGER NOT NULL DEFAULT 0,
        positive_asset_count INTEGER NOT NULL DEFAULT 0,
        positive_token_count INTEGER NOT NULL DEFAULT 0,
        source_chain_count INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX idx_wallet_portfolio_summaries_wallet ON wallet_portfolio_summaries(wallet_id, currency_code);

    CREATE TABLE sync_statuses (
        key TEXT PRIMARY KEY,
        domain_raw TEXT NOT NULL,
        scope_id TEXT NOT NULL,
        last_synced_at_ms INTEGER,
        last_attempt_at_ms INTEGER,
        is_syncing INTEGER NOT NULL DEFAULT 0,
        last_error_message TEXT,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE chains (
        chain_raw TEXT PRIMARY KEY,
        ticker TEXT NOT NULL,
        display_name TEXT NOT NULL,
        sort_index INTEGER NOT NULL
    );

    CREATE TABLE assets (
        catalog_id TEXT PRIMARY KEY,
        chain_raw TEXT NOT NULL,
        symbol TEXT NOT NULL,
        name TEXT NOT NULL,
        contract TEXT NOT NULL,
        decimals INTEGER NOT NULL
    );
    CREATE INDEX idx_assets_chain ON assets(chain_raw);

    CREATE TABLE app_settings (
        id TEXT PRIMARY KEY,
        theme_preference TEXT NOT NULL,
        language_preference TEXT NOT NULL,
        pin_enabled INTEGER NOT NULL DEFAULT 0,
        biometric_enabled INTEGER NOT NULL DEFAULT 0,
        auto_lock_seconds INTEGER NOT NULL DEFAULT 0,
        currency_preference TEXT NOT NULL,
        haptic_feedback_enabled INTEGER NOT NULL DEFAULT 1,
        background_balance_refresh INTEGER NOT NULL DEFAULT 1,
        selected_tab INTEGER NOT NULL DEFAULT 0,
        active_wallet_id TEXT NOT NULL DEFAULT '',
        settings_deep_link TEXT NOT NULL DEFAULT '',
        has_unbackedup_wallet INTEGER NOT NULL DEFAULT 0,
        hide_import_key_warning INTEGER NOT NULL DEFAULT 0,
        require_biometric_for_send INTEGER NOT NULL DEFAULT 1,
        erase_data_after_failed_attempts INTEGER NOT NULL DEFAULT 0,
        hide_balance_on_home INTEGER NOT NULL DEFAULT 0,
        hide_small_balances_threshold REAL NOT NULL DEFAULT 0,
        transaction_amount_display INTEGER NOT NULL DEFAULT 1,
        coin_market_cap_api_key TEXT NOT NULL DEFAULT '',
        restoration_left_app_at REAL,
        restoration_settings_path BLOB,
        restoration_wallet_home_path BLOB,
        updated_at_ms INTEGER NOT NULL
    );

    \(preferenceTablesSQL)

    CREATE TABLE active_wallet (
        id TEXT PRIMARY KEY,
        wallet_id TEXT REFERENCES wallets(id) ON DELETE SET NULL,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE market_assets (
        symbol TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        rank INTEGER NOT NULL,
        price REAL NOT NULL,
        currency_code TEXT NOT NULL,
        price_change_24h_percent REAL NOT NULL,
        price_change_24h_amount REAL NOT NULL,
        market_cap REAL NOT NULL,
        volume_24h REAL NOT NULL,
        circulating_supply REAL NOT NULL,
        ath REAL NOT NULL,
        high_24h REAL NOT NULL,
        low_24h REAL NOT NULL,
        about TEXT NOT NULL,
        sparkline_json TEXT NOT NULL,
        source TEXT NOT NULL,
        last_updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE market_chart_cache (
        cache_key TEXT PRIMARY KEY,
        symbol TEXT NOT NULL,
        range_raw TEXT NOT NULL,
        currency_code TEXT NOT NULL,
        samples_json TEXT NOT NULL,
        source TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );

    CREATE TABLE market_watchlist (
        symbol TEXT PRIMARY KEY,
        added_at_ms INTEGER NOT NULL
    );

    CREATE TABLE chain_states (
        id TEXT PRIMARY KEY,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        address TEXT NOT NULL,
        derivation_path TEXT NOT NULL DEFAULT '',
        native_balance_raw TEXT NOT NULL DEFAULT '0',
        native_decimals INTEGER NOT NULL DEFAULT 0,
        native_fiat TEXT NOT NULL DEFAULT '0',
        native_fiat_numeric REAL NOT NULL DEFAULT 0,
        total_fiat TEXT NOT NULL DEFAULT '0',
        total_fiat_numeric REAL NOT NULL DEFAULT 0,
        token_count INTEGER NOT NULL DEFAULT 0,
        fiat_currency_code TEXT NOT NULL DEFAULT 'USD',
        tx_sent_count INTEGER NOT NULL DEFAULT 0,
        tx_received_count INTEGER NOT NULL DEFAULT 0,
        tx_self_transfer_count INTEGER NOT NULL DEFAULT 0,
        tx_bridge_count INTEGER NOT NULL DEFAULT 0,
        tx_failed_count INTEGER NOT NULL DEFAULT 0,
        tx_pending_count INTEGER NOT NULL DEFAULT 0,
        tx_total_count INTEGER NOT NULL DEFAULT 0,
        utxo_count INTEGER NOT NULL DEFAULT 0,
        utxo_total_raw TEXT NOT NULL DEFAULT '0',
        is_used INTEGER NOT NULL DEFAULT 0,
        last_synced_at_ms INTEGER,
        sync_state_raw TEXT NOT NULL DEFAULT 'idle',
        encrypted_private_key BLOB,
        key_encryption_scheme TEXT,
        UNIQUE(wallet_id, chain_raw)
    );
    CREATE INDEX idx_chain_states_wallet ON chain_states(wallet_id);

    CREATE TABLE chain_utxos (
        id TEXT PRIMARY KEY,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        address_id TEXT REFERENCES wallet_addresses(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        address TEXT NOT NULL,
        txid TEXT NOT NULL,
        vout INTEGER NOT NULL,
        value_sats_raw TEXT NOT NULL,
        script_hex TEXT,
        confirmed INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL,
        UNIQUE(wallet_id, chain_raw, txid, vout)
    );
    CREATE INDEX idx_chain_utxos_wallet_chain ON chain_utxos(wallet_id, chain_raw);
    CREATE INDEX idx_chain_utxos_address ON chain_utxos(address_id);

    \(blobAndSecurityTablesSQL)

    \(walletAssetRouteTemplatesSQL)
    """
}

extension Date {
    static var databaseMilliseconds: Int64 {
        Date().databaseMilliseconds
    }

    var databaseMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1_000).rounded())
    }

    init(databaseMilliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(databaseMilliseconds) / 1_000)
    }
}

extension Decimal {
    var databaseText: String { description }
    var databaseDouble: Double { NSDecimalNumber(decimal: self).doubleValue }
}

extension String {
    var quotedDatabaseIdentifier: String {
        "\"\(replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private enum AppDatabaseError: Error {
    case integrityCheckFailed(String)
}
