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

        try database.write { db in
            let preservedPreferences = try snapshotPreservedPreferences(db: db)
            try db.execute(sql: "DELETE FROM wallets")
            try db.execute(sql: "DELETE FROM wallet_secrets")
            try db.execute(sql: "DELETE FROM biometric_enrollment")
            try db.execute(sql: "DELETE FROM custom_tokens")
            try db.execute(sql: "DELETE FROM wallet_pnl_summaries")
            try db.execute(sql: "DELETE FROM portfolio_flow_valuations")
            try db.execute(sql: "DELETE FROM portfolio_asset_rollups")
            try db.execute(sql: "DELETE FROM portfolio_asset_snapshots")
            try db.execute(sql: "DELETE FROM portfolio_chain_results")
            try db.execute(sql: "DELETE FROM portfolio_snapshot_runs")
            try deleteTableIfPresent("wallet_chart_snapshots", db: db)
            try db.execute(sql: "DELETE FROM wallet_portfolio_summaries")
            try db.execute(sql: "DELETE FROM chain_states")
            try db.execute(sql: "DELETE FROM chain_utxos")
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
            try ActiveWalletPointer.mirrorSelection(nil, db: db)
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
        await onStageComplete(.wallets)
        await onStageComplete(.privateData)
        await onStageComplete(.keys)

        PinCodeStorage.clear()
        ChainKeyVault.configure(database: database)
        WalletSecretCrypto.configure(database: database)
        await onStageComplete(.security)

        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        await onStageComplete(.networkCache)

        SettingsStore.shared.start(database: database)
        ActiveWalletPointer.set(nil)
        await onStageComplete(.settings)
        log.notice("Full wipe completed.")
        // Diagnostics clear is best-effort: secrets are already gone.
        // Failing here must not reverse a successful secret wipe (and must
        // not leave lock-screen erase blocked forever with empty wallets).
        do {
            try await DiagnosticsLogStore.shared.clear(database: database)
        } catch {
            log.error(
                "Diagnostics clear after wipe failed: \(String(describing: error), privacy: .public)"
            )
        }

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
        try database.read { db in
            let wallets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallets") ?? 0
            let secrets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallet_secrets") ?? 0
            return ResidualSecretSnapshot(
                wallets: wallets,
                secrets: secrets,
                pinPresent: PinCodeStorage.hasPin
            )
        }
    }

    static func wipeResettableModels(database: AppDatabase = .shared) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallets")
            try db.execute(sql: "DELETE FROM wallet_secrets")
            try db.execute(sql: "DELETE FROM biometric_enrollment")
            try db.execute(sql: "DELETE FROM custom_tokens")
            try db.execute(sql: "DELETE FROM wallet_pnl_summaries")
            try db.execute(sql: "DELETE FROM portfolio_flow_valuations")
            try db.execute(sql: "DELETE FROM portfolio_asset_rollups")
            try db.execute(sql: "DELETE FROM portfolio_asset_snapshots")
            try db.execute(sql: "DELETE FROM portfolio_chain_results")
            try db.execute(sql: "DELETE FROM portfolio_snapshot_runs")
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
