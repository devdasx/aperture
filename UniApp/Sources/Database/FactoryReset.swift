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

    static let tipKitResetFlagKey = "apertureNeedsTipKitReset"

    private static let preservedUserDefaultsKeys: Set<String> = [
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
        let walletIds = try WalletRepository(database: database).allWalletIds()

        try database.write { db in
            try db.execute(sql: "DELETE FROM wallets")
            try db.execute(sql: "DELETE FROM wallet_secrets")
            try db.execute(sql: "DELETE FROM biometric_enrollment")
            try db.execute(sql: "DELETE FROM custom_tokens")
            try db.execute(sql: "DELETE FROM wallet_chart_snapshots")
            try db.execute(sql: "DELETE FROM wallet_portfolio_summaries")
            try db.execute(sql: "DELETE FROM chain_states")
            try db.execute(sql: "DELETE FROM chain_utxos")
            try db.execute(sql: "DELETE FROM sync_statuses WHERE scope_id != ?", arguments: [SyncDomain.globalScope])
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

        for id in walletIds {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
            try? MnemonicVault.deletePrivateKey(for: id)
        }
        await onStageComplete(.keys)

        PinCodeStorage.clear()
        ChainKeyVault.clear()
        WalletSecretCrypto.clearMasterKey()
        await onStageComplete(.security)

        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        let preservedDefaults = snapshotPreservedUserDefaults()
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        restorePreservedUserDefaults(preservedDefaults)
        SettingsStore.shared.syncFromAppStorage()
        ActiveWalletPointer.set(nil)
        await onStageComplete(.settings)
        log.notice("Full wipe completed: \(walletIds.count, privacy: .public) wallets purged.")
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
            try db.execute(sql: "DELETE FROM sync_statuses WHERE scope_id != ?", arguments: [SyncDomain.globalScope])
        }
    }

    private static func snapshotPreservedUserDefaults() -> [String: Any] {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in preservedUserDefaultsKeys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }
        return snapshot
    }

    private static func restorePreservedUserDefaults(_ snapshot: [String: Any]) {
        let defaults = UserDefaults.standard
        for (key, value) in snapshot {
            defaults.set(value, forKey: key)
        }
    }
}
