import Foundation
import GRDB
import OSLog

enum FactoryReset {
    enum Stage: CaseIterable, Sendable {
        case wallets
        case privateData
        case keys
        case security
        case networkCache
        case settings
    }

    private static let preservedPreferenceKeys: Set<String> = [
        "themePreference",
        "languagePreference",
        CurrencyPreference.storageKey,
        HapticPreference.storageKey,
        "backgroundBalanceRefresh",
        "walletHomeBalanceHistoryRange",
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
            try db.execute(sql: "DELETE FROM wallet_chart_snapshots")
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
            try AppPreferenceStore.upsert(.bool(false), forKey: PinCodePreference.pinEnabledKey, db: db)
            try AppPreferenceStore.upsert(.bool(false), forKey: PinCodePreference.biometricEnabledKey, db: db)
            try AppPreferenceStore.upsert(.bool(true), forKey: PinCodePreference.requireBiometricForSendKey, db: db)
            try AppPreferenceStore.upsert(.bool(false), forKey: "eraseDataAfterFailedAttempts", db: db)
            try AppPreferenceStore.upsert(.bool(false), forKey: "hasUnbackedupWallet", db: db)
            try AppPreferenceStore.upsert(.string(""), forKey: "settingsDeepLink", db: db)
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

        SettingsStore.shared.start(database: database)
        ActiveWalletPointer.set(nil)
        await onStageComplete(.settings)
        log.notice("Full wipe completed.")
    }

    static func wipeResettableModels(database: AppDatabase = .shared) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallets")
            try db.execute(sql: "DELETE FROM wallet_secrets")
            try db.execute(sql: "DELETE FROM biometric_enrollment")
            try db.execute(sql: "DELETE FROM custom_tokens")
            try db.execute(sql: "DELETE FROM wallet_chart_snapshots")
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

    private static func restorePreservedPreferences(_ snapshot: [String: StoredPreferenceValue], db: Database) throws {
        for (key, value) in snapshot {
            try AppPreferenceStore.upsert(value, forKey: key, db: db)
        }
    }
}
