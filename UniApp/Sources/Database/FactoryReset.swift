import Foundation
import SwiftData
import OSLog

// MARK: - FactoryReset

/// The reset executor behind "Reset Aperture" and the optional Erase Data
/// lock-screen wipe.
///
/// **Reset policy (2026-06-25).** Reset is a custody/privacy wipe, not a
/// cache purge. It removes wallets, addresses, balances, transactions,
/// encrypted per-chain key blobs, wallet-scoped chart data, security state,
/// and user-created wallet configuration. It intentionally preserves public
/// / reproducible data: spot-price caches, historical prices, market rows,
/// market charts, the asset catalog, and token-logo bytes. Those records
/// contain no keys, no addresses, and no wallet ids, and keeping them avoids
/// making a reset feel like a cold reinstall with empty markets.
///
/// **Why fetch-and-delete, not `ModelContext.delete(model:)`.** The
/// batch-delete form routes around the context on some store kinds
/// (notably in-memory stores), which would make the wipe untestable
/// against the in-memory containers the test suite uses — and an
/// untestable wipe is exactly how tables get missed. Row-by-row
/// deletion through the context is observable, honest, and the row
/// counts involved are tiny (hundreds, bounded by each table's own
/// pruning rules).
///
/// **One save.** All deletions across all tables commit in a single
/// `save()` so a mid-wipe failure never publishes a half-wiped store
/// from this call — the caller decides whether to retry or surface.
///
/// **Singletons included, deliberately.** `AppMetadataRecord`,
/// `AppSettingsRecord`, and `BiometricEnrollmentRecord` are wiped: their
/// values describe the previous app/security session. `ApertureDatabase`
/// and `SettingsStore` recreate them from the surviving non-sensitive
/// defaults on the next launch / next sync.
///
/// **What the SwiftData helper does NOT cover.** `wipeResettableModels(in:)`
/// is only the database tier. The full staged wipe below also clears Keychain
/// (`SeedVault` / `MnemonicVault` / `PinCodeStorage` / `WalletManifestStore` /
/// `ChainKeyVault`), selected `UserDefaults`, and transient Foundation
/// URL/cookie caches.
/// `ResetCompletenessTests` pins this type's contract.
enum FactoryReset {

    /// The honest deletion stages the Reset-Aperture executor performs, in real
    /// execution order. `.wallets` runs FIRST and is the ONLY one that throws
    /// (the SwiftData custody gate — if it fails, nothing has been destroyed).
    /// The reset flow reports user-facing stages only; network cache cleanup is
    /// intentionally unreported background cleanup.
    enum Stage: CaseIterable, Sendable {
        /// Wallet rows, cascaded wallet history, chart snapshots, and manifest.
        case wallets
        /// Remaining private SwiftData rows and wallet-scoped sync markers.
        case privateData
        /// Per-wallet Keychain seed / mnemonic / private-key material.
        case keys
        /// PIN records and app-wide encryption master keys.
        case security
        /// Foundation-level network residue.
        case networkCache
        /// Resettable UserDefaults / @AppStorage values.
        case settings
    }

    /// Legacy UserDefaults marker consumed by `UniAppApp.init` for devices
    /// that ran an older reset build. Current resets preserve TipKit state as
    /// normal non-wallet app data and no longer set this flag.
    static let tipKitResetFlagKey = "apertureNeedsTipKitReset"

    /// SwiftData tables that must be empty after reset. These are either
    /// wallet-owned, security/session-owned, or user-authored configuration.
    /// Public quote / market / catalog tables are intentionally absent.
    static let resettableSwiftDataModels: [any PersistentModel.Type] = [
        WalletRecord.self,
        WalletSecretRecord.self,
        WalletAddressRecord.self,
        TransactionRecord.self,
        TokenBalanceRecord.self,
        BiometricEnrollmentRecord.self,
        AppMetadataRecord.self,
        CustomTokenRecord.self,
        WalletChartSnapshotRecord.self,
        AppSettingsRecord.self,
        ChainStateRecord.self,
        ChainUTXORecord.self
    ]

    /// Public, reproducible data intentionally retained across reset.
    /// `SyncStatusRecord` is partially retained: only global price/history
    /// freshness rows survive; wallet-scoped rows are deleted.
    static let preservedSwiftDataModels: [any PersistentModel.Type] = [
        CachedPriceRecord.self,
        HistoricalPriceRecord.self,
        PriceSnapshotRecord.self,
        SyncStatusRecord.self,
        ChainRecord.self,
        AssetRecord.self,
        MarketAssetRecord.self,
        MarketChartCacheRecord.self,
        MarketWatchlistRecord.self
    ]

    /// Non-sensitive preferences/cache-version keys that should survive a
    /// reset. Security state, active wallet pointers, deep links, onboarding
    /// state, filter state, and API keys are intentionally not listed.
    private static let preservedUserDefaultsKeys: Set<String> = [
        "themePreference",
        "languagePreference",
        CurrencyPreference.storageKey,
        HapticPreference.storageKey,
        "backgroundBalanceRefresh",
        "walletHomeBalanceHistoryRange",
        "aperture.historicalPriceCacheVersion"
    ]

    /// The **complete** factory wipe — the single routine behind BOTH
    /// "Reset Aperture" (Settings) and "Erase Data" (auto-wipe after repeated
    /// wrong passcodes). Used by the no-progress `AppLockView` path; delegates
    /// to `performStagedWipe` with a no-op reporter so there is exactly ONE
    /// wipe implementation.
    @MainActor
    static func performFullWipe(modelContext: ModelContext) async throws {
        try await performStagedWipe(modelContext: modelContext, onStageComplete: { _ in })
    }

    /// The complete factory wipe, reporting each visible deletion `Stage` as it
    /// finishes so the Reset-Aperture UI's progress ring reflects honest
    /// progress. Network cache cleanup still runs, but is not surfaced as a
    /// user-facing row. After this returns, all custody and wallet-linked state
    /// is gone, while public market / price / asset cache data remains.
    /// `RootGate` observes the wallet count flip to zero and routes back to
    /// onboarding.
    ///
    /// **Order is the safety contract.** The SwiftData wallet deletion runs
    /// FIRST and is the ONLY step that throws — if it fails, NOTHING has been
    /// destroyed (the caller surfaces an error and the user keeps a working
    /// app). Every step after it is best-effort so a single failure never
    /// strands a half-reset device. `onStageComplete` is awaited on the main
    /// actor after each visible stage genuinely finishes.
    @MainActor
    static func performStagedWipe(
        modelContext: ModelContext,
        onStageComplete: (Stage) async -> Void
    ) async throws {
        let log = Logger(subsystem: "com.thuglife.aperture", category: "reset")
        let repo = WalletRepository(modelContainer: modelContext.container)
        // Capture ids up front so Keychain items can be wiped after the
        // SwiftData rows are gone (once the rows go, the ids are lost).
        let walletIds = (try? await repo.allWalletIds()) ?? []

        // STAGE 1 — wallets & wallet-scoped history. The custody gate. `deleteAllWallets()`
        // refuses the in-memory fallback store, drops every wallet (with
        // cascades) plus the primitive-keyed chart snapshots, and clears the
        // Keychain wallet manifest. Throws ⇒ nothing destroyed yet.
        try await repo.deleteAllWallets()
        await onStageComplete(.wallets)

        // STAGE 2 — remaining private SwiftData rows. Best-effort; this
        // structurally catches singleton/security records and wallet-scoped
        // sync markers that do not belong to a `WalletRecord` cascade.
        // Clear every remaining private / wallet-scoped SwiftData table, while
        // preserving public market and price caches.
        do { try wipeResettableModels(in: modelContext) }
        catch { log.error("Reset: resettable model wipe failed: \(String(describing: error), privacy: .public)") }
        await onStageComplete(.privateData)

        // STAGE 3 — keys & phrases (Keychain). Best-effort; idempotent (a
        // missing item is success).
        for id in walletIds {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
            try? MnemonicVault.deletePrivateKey(for: id)
        }
        await onStageComplete(.keys)

        // STAGE 4 — app security state and app-wide encryption keys.
        // Keychain — PIN hash + salt + both failure records.
        PinCodeStorage.clear()
        // Keychain — app-wide key that opens per-chain encrypted key blobs.
        ChainKeyVault.clear()
        // Keychain — app-wide key that opens encrypted SwiftData wallet
        // secret rows. The rows are wiped in stage 1; clearing the key keeps
        // reset's custody wipe complete even if a row deletion was retried.
        WalletSecretCrypto.clearMasterKey()
        await onStageComplete(.security)

        // STAGE 5 — network cache. Best-effort hidden cleanup; this is not
        // reported to the visible reset process list.
        // Foundation-level network residue.
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)

        // STAGE 6 — settings. Best-effort.
        // Wipe @AppStorage / UserDefaults except for non-sensitive display
        // preferences and cache-version keys. Active-wallet pointers, security
        // flags, restoration paths, wallet filters, and onboarding state must
        // not survive.
        let preservedDefaults = snapshotPreservedUserDefaults()
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        restorePreservedUserDefaults(preservedDefaults)
        await onStageComplete(.settings)
        log.notice("Full wipe completed: \(walletIds.count, privacy: .public) wallets purged.")
    }

    /// Empty resettable/private SwiftData tables, preserving public market /
    /// price / catalog caches. Throws if a fetch or final save fails.
    static func wipeResettableModels(in context: ModelContext) throws {
        for model in resettableSwiftDataModels {
            try wipeRows(of: model, in: context)
        }
        try wipeWalletScopedSyncStatusRows(in: context)
        if context.hasChanges {
            try context.save()
        }
    }

    /// Delete every row of one model type. No save — `wipeResettableModels`
    /// batches the commit.
    private static func wipeRows<T: PersistentModel>(
        of type: T.Type,
        in context: ModelContext
    ) throws {
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }

    /// Delete wallet-scoped sync rows while preserving global public cache
    /// freshness (`prices|global`, `historical|global`).
    private static func wipeWalletScopedSyncStatusRows(in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<SyncStatusRecord>()) {
            guard shouldPreserveSyncStatus(row) else {
                context.delete(row)
                continue
            }
        }
    }

    private static func shouldPreserveSyncStatus(_ row: SyncStatusRecord) -> Bool {
        guard row.scopeId == SyncDomain.globalScope,
              let domain = SyncDomain(rawValue: row.domainRaw)
        else { return false }
        return domain == .prices || domain == .historical
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
