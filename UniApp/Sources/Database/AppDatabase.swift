import Foundation
import GRDB
import OSLog

final class AppDatabase: @unchecked Sendable {
    static let shared = AppDatabase()

    let pool: DatabasePool
    let storeURL: URL
    let isInMemoryFallback = false

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "database")
    private static let transitionWipeMarkerFileName = ".aperture-grdb-transition-v1"

    private init() {
        do {
            let url = try Self.defaultStoreURL()
            storeURL = url
            try Self.prepareDirectory(for: url)
            try Self.runFreshGRDBTransitionWipeIfNeeded(storeURL: url)
            pool = try Self.openPool(at: url)
            try Self.migrator.migrate(pool)
            try Self.validateIntegrity(pool)
            try Self.markExcludedFromBackup(url)
            DiagnosticsLogStore.shared.record(
                .info,
                category: "database",
                message: "GRDB database opened",
                metadata: ["store": url.path]
            )
        } catch {
            fatalError("GRDB database unavailable: \(error)")
        }
    }

    init(testStoreURL url: URL, seedSingletonRows: Bool = true) throws {
        storeURL = url
        try Self.prepareDirectory(for: url)
        try Self.deleteSQLiteFiles(at: url)
        pool = try Self.openPool(at: url)
        try Self.migrator.migrate(pool)
        if seedSingletonRows {
            try pool.write { db in
                try Self.ensureSingletonRows(db)
            }
        }
        try Self.validateIntegrity(pool)
        try Self.markExcludedFromBackup(url)
    }

    @MainActor
    func bootstrap() {
        do {
            try pool.write { db in
                try AppDatabase.ensureSingletonRows(db)
            }
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
        let paths = [
            url.path,
            url.path + "-wal",
            url.path + "-shm",
            url.path + "-journal"
        ]
        for path in paths where fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        let directory = url.deletingLastPathComponent()
        let base = url.lastPathComponent
        if let sidecars = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for sidecar in sidecars where sidecar.lastPathComponent.hasPrefix(base + "-") {
                try fm.removeItem(at: sidecar)
            }
        }
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
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO app_settings
            (id, theme_preference, language_preference, pin_enabled, biometric_enabled,
             auto_lock_seconds, currency_preference, haptic_feedback_enabled,
             background_balance_refresh, wallet_home_balance_history_range,
             selected_tab, active_wallet_id, settings_deep_link,
             has_unbackedup_wallet, hide_import_key_warning, updated_at_ms)
            VALUES ('app-settings-singleton', '', '', 0, 0, 0, '', 1, 1, '', 0, '', '', 0, 0, ?)
            """,
            arguments: [now]
        )
    }
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

    CREATE TABLE wallet_chart_snapshots (
        id TEXT PRIMARY KEY,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        currency_code TEXT NOT NULL,
        fiat_value TEXT NOT NULL,
        fiat_value_numeric REAL NOT NULL DEFAULT 0,
        captured_at_ms INTEGER NOT NULL,
        day_key INTEGER NOT NULL
    );
    CREATE INDEX idx_wallet_chart_snapshots_series ON wallet_chart_snapshots(wallet_id, currency_code, captured_at_ms);

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
        wallet_home_balance_history_range TEXT NOT NULL,
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
