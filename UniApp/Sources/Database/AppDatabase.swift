import Foundation
import GRDB
import Darwin
import OSLog

final class AppDatabase: @unchecked Sendable {
    static let shared = AppDatabase()

    let pool: DatabasePool
    let storeURL: URL
    /// True when the open store is under a temporary / non-durable path.
    /// **BUG-020 / P0-001:** user-facing writes are refused while this is set.
    let isInMemoryFallback: Bool
    /// Non-nil when this process opened via quarantine/replace or ephemeral fallback.
    let recoveryIncident: DatabaseRecoveryIncident?

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "database")
    private static let transitionWipeMarkerFileName = ".aperture-grdb-transition-v1"

    private init() {
        let opened = Self.openBestEffortStore()
        storeURL = opened.url
        pool = opened.pool
        isInMemoryFallback = opened.isFallback
        recoveryIncident = opened.recoveryIncident

        WalletSecretCrypto.configure(database: self)
        ChainKeyVault.configure(database: self)
        DiagnosticsLogStore.shared.configure(database: self)
        if let recovery = opened.recoveryIncident {
            DiagnosticsLogStore.shared.record(
                .warning,
                category: "database",
                message: "GRDB database recovered — user acknowledgement required",
                metadata: [
                    "store": opened.url.path,
                    "reason": recovery.reason,
                    "kind": recovery.kind.rawValue,
                    "quarantine": recovery.quarantineDirectoryPath ?? "",
                    "fallback": opened.isFallback ? "true" : "false",
                ]
            )
        }
        DiagnosticsLogStore.shared.record(
            .info,
            category: "database",
            message: "GRDB database opened",
            metadata: [
                "store": opened.url.path,
                "fallback": opened.isFallback ? "true" : "false",
                "recoveryPending": opened.recoveryIncident?.needsUserAcknowledgement == true ? "true" : "false",
            ]
        )
    }

    init(testStoreURL url: URL, seedSingletonRows: Bool = true) throws {
        storeURL = url
        isInMemoryFallback = false
        recoveryIncident = nil
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

    /// Test / diagnostics helper: open an existing store URL as an ephemeral
    /// (write-restricted) database without running recovery UI side effects.
    init(ephemeralTestStoreURL url: URL) throws {
        storeURL = url
        isInMemoryFallback = true
        recoveryIncident = DatabaseRecoveryIncident(
            kind: .ephemeralFallback,
            reason: "test-ephemeral",
            quarantineDirectoryPath: nil,
            storePath: url.path,
            createdAtMs: Date.databaseMilliseconds,
            acknowledged: false
        )
        try Self.prepareDirectory(for: url)
        pool = try Self.openPool(at: url)
        try Self.migrator.migrate(pool)
        try pool.write { db in
            try Self.ensureSingletonRows(db)
        }
        WalletSecretCrypto.configure(database: self)
        ChainKeyVault.configure(database: self)
        DiagnosticsLogStore.shared.configure(database: self)
    }

    @MainActor
    func bootstrap() {
        do {
            // Bootstrap may run on an ephemeral store; use unrestricted pool
            // writes so singleton rows exist for preferences. User paths go
            // through `write` and are refused when `isInMemoryFallback`.
            try pool.write { db in
                try AppDatabase.ensureSingletonRows(db)
            }
            WalletSecretCrypto.configure(database: self)
            ChainKeyVault.configure(database: self)
            DiagnosticsLogStore.shared.configure(database: self)
            AppPreferenceStore.shared.configure(database: self)
            ActiveWalletPointer.configure(database: self)
            DatabaseRecoveryGate.shared.refresh(from: self)
            Task(priority: .utility) {
                do {
                    // Seeding catalog on ephemeral is OK (rebuilt next launch).
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

    /// User-data writes. **BUG-020 / P0-001:** refused when the open store is
    /// ephemeral (`isInMemoryFallback`) so wallets are never created on a
    /// temp file that can vanish after reboot.
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try ensureUserWritesAllowed()
        return try pool.write(block)
    }

    /// Whether wallet create/import/secret/sign persistence may proceed.
    var allowsUserWrites: Bool { !isInMemoryFallback }

    func ensureUserWritesAllowed() throws {
        guard allowsUserWrites else {
            throw AppDatabaseError.writesDisabledEphemeralStore
        }
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
        let recoveryIncident: DatabaseRecoveryIncident?
    }

    /// Open the primary store, or recover with an explicit user-facing
    /// incident (never a silent empty launch — BUG-020 / P0-001).
    private static func openBestEffortStore() -> OpenedStore {
        do {
            let url = try defaultStoreURL()
            try prepareDirectory(for: url)
            try runFreshGRDBTransitionWipeIfNeeded(storeURL: url)
            do {
                let pool = try bootstrapPool(at: url)
                // Healthy permanent store — drop stale ephemeral recovery markers.
                DatabaseRecoveryIncident.clearIfPermanentStoreHealthy()
                // Still show UI if a prior quarantine recovery is unacknowledged.
                if let pending = DatabaseRecoveryIncident.loadPending(),
                   pending.needsUserAcknowledgement,
                   pending.kind == .quarantinedAndReplaced {
                    return OpenedStore(url: url, pool: pool, isFallback: false, recoveryIncident: pending)
                }
                return OpenedStore(url: url, pool: pool, isFallback: false, recoveryIncident: nil)
            } catch {
                let reason = String(describing: error)
                let quarantineURL = try? quarantineSQLiteFiles(at: url, reason: reason)
                // Secrets in the quarantined file are no longer addressable from
                // a new empty DB; purge legacy Keychain material so we never
                // mix old keys with a blank store.
                FreshInstallGuard.purgeAllKnownKeychainServicesForDatabaseReplacement()
                let pool = try bootstrapPool(at: url)
                let incident = DatabaseRecoveryIncident(
                    kind: .quarantinedAndReplaced,
                    reason: reason,
                    quarantineDirectoryPath: quarantineURL?.path,
                    storePath: url.path,
                    createdAtMs: Date.databaseMilliseconds,
                    acknowledged: false
                )
                DatabaseRecoveryIncident.record(
                    kind: .quarantinedAndReplaced,
                    reason: reason,
                    quarantineDirectory: quarantineURL,
                    storeURL: url
                )
                return OpenedStore(url: url, pool: pool, isFallback: false, recoveryIncident: incident)
            }
        } catch {
            let fallbackReason = String(describing: error)
            let fallbackURL = fallbackStoreURL()
            do {
                try prepareDirectory(for: fallbackURL)
                let pool = try bootstrapPool(at: fallbackURL)
                let incident = DatabaseRecoveryIncident(
                    kind: .ephemeralFallback,
                    reason: fallbackReason,
                    quarantineDirectoryPath: nil,
                    storePath: fallbackURL.path,
                    createdAtMs: Date.databaseMilliseconds,
                    acknowledged: false
                )
                DatabaseRecoveryIncident.record(
                    kind: .ephemeralFallback,
                    reason: fallbackReason,
                    quarantineDirectory: nil,
                    storeURL: fallbackURL
                )
                return OpenedStore(
                    url: fallbackURL,
                    pool: pool,
                    isFallback: true,
                    recoveryIncident: incident
                )
            } catch {
                let lastResortURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("aperture-last-resort-\(UUID().uuidString).sqlite", isDirectory: false)
                try? prepareDirectory(for: lastResortURL)
                if let pool = try? bootstrapPool(at: lastResortURL) {
                    let combined = "\(fallbackReason); fallback failed: \(String(describing: error))"
                    let incident = DatabaseRecoveryIncident(
                        kind: .ephemeralFallback,
                        reason: combined,
                        quarantineDirectoryPath: nil,
                        storePath: lastResortURL.path,
                        createdAtMs: Date.databaseMilliseconds,
                        acknowledged: false
                    )
                    DatabaseRecoveryIncident.record(
                        kind: .ephemeralFallback,
                        reason: combined,
                        quarantineDirectory: nil,
                        storeURL: lastResortURL
                    )
                    return OpenedStore(
                        url: lastResortURL,
                        pool: pool,
                        isFallback: true,
                        recoveryIncident: incident
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

    /// Move the broken store (+ WAL/SHM/journal) into `CorruptStore-<ms>/`.
    /// Returns the quarantine directory when any file was moved; otherwise nil.
    @discardableResult
    private static func quarantineSQLiteFiles(at url: URL, reason: String) throws -> URL? {
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
            let body = """
            Aperture quarantined this wallet database because it could not be opened safely.

            Technical reason:
            \(reason)

            Do not rename these files. Export this folder from the recovery screen
            and keep it with your recovery phrase if support asks for it.
            """
            try body.write(to: reasonURL, atomically: true, encoding: .utf8)
            return quarantineDirectory
        } else {
            try? fm.removeItem(at: quarantineDirectory)
            return nil
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
        migrator.registerMigration("v6_portfolio_pnl_history") { db in
            try db.execute(sql: portfolioPnLHistorySQL)
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

    nonisolated static let portfolioPnLHistorySQL = """
    CREATE TABLE IF NOT EXISTS portfolio_snapshot_runs (
        id TEXT PRIMARY KEY,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        trigger_raw TEXT NOT NULL,
        refresh_mode_raw TEXT NOT NULL,
        status_raw TEXT NOT NULL,
        started_at_ms INTEGER NOT NULL,
        completed_at_ms INTEGER,
        attempted_chain_count INTEGER NOT NULL DEFAULT 0,
        successful_chain_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_portfolio_snapshot_runs_wallet_time
        ON portfolio_snapshot_runs(wallet_id, started_at_ms DESC);

    CREATE TABLE IF NOT EXISTS portfolio_chain_results (
        run_id TEXT NOT NULL REFERENCES portfolio_snapshot_runs(id) ON DELETE CASCADE,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        status_raw TEXT NOT NULL,
        asset_count INTEGER NOT NULL DEFAULT 0,
        captured_at_ms INTEGER NOT NULL,
        PRIMARY KEY(run_id, chain_raw)
    );
    CREATE INDEX IF NOT EXISTS idx_portfolio_chain_results_wallet_chain_time
        ON portfolio_chain_results(wallet_id, chain_raw, captured_at_ms DESC);

    CREATE TABLE IF NOT EXISTS portfolio_asset_snapshots (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES portfolio_snapshot_runs(id) ON DELETE CASCADE,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        asset_key TEXT NOT NULL,
        token_symbol TEXT NOT NULL,
        token_contract TEXT,
        decimals INTEGER NOT NULL,
        raw_balance TEXT NOT NULL,
        quantity TEXT NOT NULL,
        unit_price_usd TEXT,
        unit_price_usd_numeric REAL,
        usd_value TEXT,
        usd_value_numeric REAL,
        price_source TEXT,
        price_at_ms INTEGER,
        valuation_status_raw TEXT NOT NULL,
        captured_at_ms INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_portfolio_asset_snapshots_wallet_asset_time
        ON portfolio_asset_snapshots(wallet_id, asset_key, captured_at_ms DESC);
    CREATE INDEX IF NOT EXISTS idx_portfolio_asset_snapshots_run
        ON portfolio_asset_snapshots(run_id);

    CREATE TABLE IF NOT EXISTS portfolio_asset_rollups (
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        asset_key TEXT NOT NULL,
        resolution_raw TEXT NOT NULL,
        bucket_start_ms INTEGER NOT NULL,
        token_symbol TEXT NOT NULL,
        token_contract TEXT,
        decimals INTEGER NOT NULL,
        raw_balance TEXT NOT NULL,
        quantity TEXT NOT NULL,
        unit_price_usd TEXT,
        unit_price_usd_numeric REAL,
        usd_value TEXT,
        usd_value_numeric REAL,
        valuation_status_raw TEXT NOT NULL,
        source_captured_at_ms INTEGER NOT NULL,
        PRIMARY KEY(wallet_id, asset_key, resolution_raw, bucket_start_ms)
    );
    CREATE INDEX IF NOT EXISTS idx_portfolio_asset_rollups_wallet_resolution_time
        ON portfolio_asset_rollups(wallet_id, resolution_raw, bucket_start_ms DESC);

    CREATE TABLE IF NOT EXISTS portfolio_flow_valuations (
        transaction_id TEXT PRIMARY KEY REFERENCES transactions(id) ON DELETE CASCADE,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        asset_key TEXT NOT NULL,
        classification_raw TEXT NOT NULL,
        signed_amount TEXT NOT NULL,
        occurred_at_ms INTEGER NOT NULL,
        unit_price_usd TEXT,
        unit_price_usd_numeric REAL,
        signed_value_usd TEXT,
        signed_value_usd_numeric REAL,
        price_source TEXT,
        price_at_ms INTEGER,
        valuation_status_raw TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_portfolio_flow_valuations_wallet_time
        ON portfolio_flow_valuations(wallet_id, occurred_at_ms DESC);

    CREATE TABLE IF NOT EXISTS wallet_pnl_summaries (
        id TEXT PRIMARY KEY,
        lookup_key TEXT NOT NULL UNIQUE,
        wallet_id TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
        display_currency_code TEXT NOT NULL,
        state_raw TEXT NOT NULL,
        change_usd TEXT,
        change_usd_numeric REAL,
        display_change TEXT,
        display_change_numeric REAL,
        return_percent TEXT,
        return_percent_numeric REAL,
        fx_rate_from_usd TEXT,
        as_of_ms INTEGER NOT NULL,
        window_start_ms INTEGER NOT NULL,
        compared_asset_count INTEGER NOT NULL DEFAULT 0,
        relevant_asset_count INTEGER NOT NULL DEFAULT 0,
        missing_chains_json TEXT NOT NULL DEFAULT '[]',
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_wallet_pnl_summaries_wallet_currency
        ON wallet_pnl_summaries(wallet_id, display_currency_code);
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

enum AppDatabaseError: Error, Equatable, Sendable {
    case integrityCheckFailed(String)
    /// BUG-020 / P0-001: open store is temporary — refuse wallet writes.
    case writesDisabledEphemeralStore

    var userMessage: String {
        switch self {
        case .integrityCheckFailed:
            return "Wallet data on this device could not be verified."
        case .writesDisabledEphemeralStore:
            return "Aperture cannot save wallets right now — permanent storage is unavailable. Free disk space, reinstall, or restore from your recovery phrase on a healthy device."
        }
    }
}
