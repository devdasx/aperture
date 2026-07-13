import Foundation
import GRDB
import OSLog

enum FactoryReset {
    enum Stage: CaseIterable, Sendable, Equatable {
        case wallets
        case privateData
        case keys
        case security
        case networkCache
        case settings
    }

    /// Wipe finished the DB transaction but residual secrets remain
    /// (should not happen; fail-closed for lock-screen erase).
    enum WipeIncompleteError: Error, Sendable, Equatable {
        case residualSecrets(wallets: Int, secrets: Int, pinPresent: Bool)
    }

    private static let preservedPreferenceKeys: Set<String> = [
        "themePreference",
        "languagePreference",
        CurrencyPreference.storageKey,
        HapticPreference.storageKey,
        "backgroundBalanceRefresh",
        "aperture.historicalPriceCacheVersion"
    ]

    /// Preference keys mutated during wipe that UI should re-read afterward.
    private static let wipedPreferenceKeys: [String] = [
        PinCodePreference.pinEnabledKey,
        PinCodePreference.biometricEnabledKey,
        PinCodePreference.requireBiometricForSendKey,
        PinCodePreference.forgotPasscodeResetEnabledKey,
        PinCodePreference.forgotPasscodeResetEducationSeenKey,
        "eraseDataAfterFailedAttempts",
        "hasUnbackedupWallet",
        "settingsDeepLink",
        ActiveWalletPointer.storageKey,
        MainTab.storageKey
    ]

    @MainActor
    static func performFullWipe(database: AppDatabase = .shared) async throws {
        try await performStagedWipe(database: database, onStageComplete: { _ in })
    }

    @MainActor
    static func performStagedWipe(
        database: AppDatabase = .shared,
        onStageComplete: (Stage) async -> Void
    ) async throws {
        let log = Logger(subsystem: "com.thuglife.aperture", category: "reset")

        // Run the bulk delete off the MainActor. Calling `database.write` from
        // MainActor while ValueObservation uses `.immediate` scheduling can
        // re-enter GRDB when observers hop back onto the writer queue
        // ("Database methods are not reentrant").
        try await Task.detached(priority: .userInitiated) {
            try database.write { db in
                let preservedPreferences = try snapshotPreservedPreferences(db: db)
                try db.execute(sql: "DELETE FROM wallets")
                try db.execute(sql: "DELETE FROM wallet_secrets")
                try db.execute(sql: "DELETE FROM biometric_enrollment")
                try db.execute(sql: "DELETE FROM custom_tokens")
                try deleteTableIfPresent("wallet_chart_snapshots", db: db)
                try db.execute(sql: "DELETE FROM wallet_portfolio_summaries")
                try db.execute(sql: "DELETE FROM chain_states")
                try db.execute(sql: "DELETE FROM chain_utxos")
                try deleteTableIfPresent("chain_account_states", db: db)
                try db.execute(sql: "DELETE FROM wallet_preferences")
                try db.execute(sql: "DELETE FROM app_preferences")
                try db.execute(sql: "DELETE FROM asset_logo_cache")
                try db.execute(sql: "DELETE FROM wallet_avatar_raster_cache")
                try db.execute(sql: "DELETE FROM generated_documents")
                try db.execute(sql: "DELETE FROM cloudkit_backup_cache")
                try db.execute(sql: "DELETE FROM diagnostic_log_entries")
                try db.execute(sql: "DELETE FROM local_secure_blobs")
                try db.execute(sql: "DELETE FROM sync_statuses WHERE scope_id != ?", arguments: [SyncDomain.globalScope])
                try LocalSecureBlobStore.ensureSecurityKeys(db: db)
                try restorePreservedPreferences(preservedPreferences, db: db)
                try AppPreferenceStore.upsertAndMirror(.bool(false), forKey: PinCodePreference.pinEnabledKey, db: db)
                try AppPreferenceStore.upsertAndMirror(.bool(false), forKey: PinCodePreference.biometricEnabledKey, db: db)
                try AppPreferenceStore.upsertAndMirror(.bool(true), forKey: PinCodePreference.requireBiometricForSendKey, db: db)
                try AppPreferenceStore.upsertAndMirror(.bool(false), forKey: PinCodePreference.forgotPasscodeResetEnabledKey, db: db)
                try AppPreferenceStore.upsertAndMirror(.bool(false), forKey: PinCodePreference.forgotPasscodeResetEducationSeenKey, db: db)
                try AppPreferenceStore.upsertAndMirror(.bool(false), forKey: "eraseDataAfterFailedAttempts", db: db)
                try AppPreferenceStore.upsertAndMirror(.bool(false), forKey: "hasUnbackedupWallet", db: db)
                try AppPreferenceStore.upsertAndMirror(.string(""), forKey: "settingsDeepLink", db: db)
                try AppPreferenceStore.upsertAndMirror(.string(MainTab.wallet.rawValue), forKey: MainTab.storageKey, db: db)
                try ActiveWalletPointer.mirrorSelection(nil, db: db)
                // Seed any remaining defaults inside this same transaction so
                // post-wipe `configure()` is not required (and cannot reenter).
                try AppPreferenceStore.seedDefaultsAndMirror(db: db)
                try db.execute(
                    sql: """
                    UPDATE app_metadata
                    SET requires_biometric_reenrollment = 0,
                        last_opened_at_ms = ?
                    WHERE id = 'app-metadata-singleton'
                    """,
                    arguments: [Date.databaseMilliseconds]
                )
            }
        }.value

        // Let ValueObservation / MainActor onChange handlers drain before any
        // further database access from this task.
        await Task.yield()
        await onStageComplete(.wallets)
        await onStageComplete(.privateData)
        await onStageComplete(.keys)

        PinCodeStorage.clear()
        // Keys were recreated in the wipe transaction — only refresh caches.
        ChainKeyVault.reloadCache(database: database)
        WalletSecretCrypto.reloadCache(database: database)
        await onStageComplete(.security)

        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        await onStageComplete(.networkCache)

        // Bind stores without opening nested writes (DB already consistent).
        SettingsStore.shared.rebind(database: database)
        ActiveWalletPointer.publishMirroredSelection(database: database)
        for key in wipedPreferenceKeys {
            AppPreferenceStore.shared.publishChange(forKey: key)
        }
        await onStageComplete(.settings)
        log.notice("Full wipe completed.")

        // diagnostic_log_entries already wiped in the main transaction.
        // Drop any in-memory pending diagnostics only.
        await DiagnosticsLogStore.shared.markClearedAfterWipe()

        // P1-010: fail-closed verification — residual wallets/secrets mean
        // the wipe must not be treated as success by lock-screen erase.
        if try hasResidualSpendableSecrets(database: database) {
            let snapshot = try residualSecretSnapshot(database: database)
            throw WipeIncompleteError.residualSecrets(
                wallets: snapshot.wallets,
                secrets: snapshot.secrets,
                pinPresent: snapshot.pinPresent
            )
        }
    }

    /// True when wallets, encrypted secrets, or a PIN still exist after a
    /// wipe attempt. Used by lock-screen erase to refuse unlock (P1-010).
    static func hasResidualSpendableSecrets(database: AppDatabase = .shared) throws -> Bool {
        let snapshot = try residualSecretSnapshot(database: database)
        return snapshot.wallets > 0 || snapshot.secrets > 0 || snapshot.pinPresent
    }

    struct ResidualSecretSnapshot: Sendable, Equatable {
        let wallets: Int
        let secrets: Int
        let pinPresent: Bool
    }

    static func residualSecretSnapshot(database: AppDatabase = .shared) throws -> ResidualSecretSnapshot {
        // IMPORTANT: never call `PinCodeStorage.hasPin` *inside* `database.read`.
        // `hasPin` → `LocalSecureBlobStore.read(database:)` → another `pool.read`,
        // which fatals with "Database methods are not reentrant" (stack:
        // ResetApertureFlow wipe → residual check → LocalSecureBlobStore.read).
        let pinPresent = PinCodeStorage.hasPin
        return try database.read { db in
            let wallets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallets") ?? 0
            let secrets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallet_secrets") ?? 0
            return ResidualSecretSnapshot(
                wallets: wallets,
                secrets: secrets,
                pinPresent: pinPresent
            )
        }
    }

    static func wipeResettableModels(database: AppDatabase = .shared) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallets")
            try db.execute(sql: "DELETE FROM wallet_secrets")
            try db.execute(sql: "DELETE FROM biometric_enrollment")
            try db.execute(sql: "DELETE FROM custom_tokens")
            try deleteTableIfPresent("wallet_chart_snapshots", db: db)
            try db.execute(sql: "DELETE FROM wallet_portfolio_summaries")
            try db.execute(sql: "DELETE FROM chain_states")
            try db.execute(sql: "DELETE FROM chain_utxos")
            try db.execute(sql: "DELETE FROM wallet_preferences")
            try db.execute(sql: "DELETE FROM asset_logo_cache")
            try db.execute(sql: "DELETE FROM wallet_avatar_raster_cache")
            try db.execute(sql: "DELETE FROM generated_documents")
            try db.execute(sql: "DELETE FROM cloudkit_backup_cache")
            try db.execute(sql: "DELETE FROM sync_statuses WHERE scope_id != ?", arguments: [SyncDomain.globalScope])
        }
    }

    private static func snapshotPreservedPreferences(db: Database) throws -> [String: StoredPreferenceValue] {
        var snapshot: [String: StoredPreferenceValue] = [:]
        for key in preservedPreferenceKeys {
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT value_type, string_value, int_value, double_value, bool_value, data_value
                FROM app_preferences
                WHERE key = ?
                """,
                arguments: [key]
            ) else { continue }
            snapshot[key] = StoredPreferenceValue(
                valueType: row["value_type"] as String? ?? "",
                stringValue: row["string_value"],
                intValue: row["int_value"] as Int64?,
                doubleValue: row["double_value"] as Double?,
                boolValue: row["bool_value"] as Int?,
                dataValue: row["data_value"] as Data?
            )
        }
        return snapshot
    }

    private static func deleteTableIfPresent(_ table: String, db: Database) throws {
        let exists = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM sqlite_master
                WHERE type = 'table' AND name = ?
            )
            """,
            arguments: [table]
        ) ?? false
        if exists {
            try db.execute(sql: "DELETE FROM \(table)")
        }
    }

    private static func restorePreservedPreferences(_ snapshot: [String: StoredPreferenceValue], db: Database) throws {
        for (key, value) in snapshot {
            try AppPreferenceStore.upsertAndMirror(value, forKey: key, db: db)
        }
    }
}
