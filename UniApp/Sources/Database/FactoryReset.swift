import Foundation
import SwiftData
import OSLog
// WebKit + TipKit are imported ONLY for `performFullWipe`: the dApp browser
// persists cookies/storage in the default `WKWebsiteDataStore`, and TipKit
// persists "shown once" counters in its own datastore — both must go for a
// reset to equal a first install.
import WebKit
import TipKit

// MARK: - FactoryReset

/// The single structural SwiftData wipe behind "Reset Aperture"
/// (Settings → Advanced → `AdvancedSettingsView.resetAll()`).
///
/// **The contract (user direction 2026-06-13, verbatim):** *"when
/// resetting the app everything in the app should be removed like
/// we've installed the app now for the first time."* For the SwiftData
/// tier, "everything" is defined structurally: every model type listed
/// in `ApertureSchemaV1.models` gets its table emptied. A table added
/// to the schema tomorrow is covered automatically — there is no
/// per-table call site to forget (the bug class this type retires:
/// `PriceSnapshotRecord`, `WalletChartSnapshotRecord`, and
/// `HistoricalPriceRecord` had shipped without a reset wipe).
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
/// **Singletons included, deliberately.** `AppMetadataRecord` and
/// `BiometricEnrollmentRecord` are wiped too: their values
/// (`firstLaunchAt`, the enrollment snapshot) describe the *previous*
/// owner. `ApertureDatabase.bootstrap()` recreates both on the next
/// launch with first-install values, and every in-session consumer
/// tolerates their absence (`AdvancedSettingsView` reads the metadata
/// row optionally; `BiometricEnrollmentTracker.fetchOrCreate`
/// self-heals a missing row).
///
/// **What this type does NOT cover** (owned by `resetAll()` directly):
/// Keychain (`SeedVault` / `MnemonicVault` / `PinCodeStorage` /
/// `WalletManifestStore`), `UserDefaults`, the WKWebView website data
/// store, the TipKit datastore, and the `CoinMarkCache` disk cache.
/// `ResetCompletenessTests` pins this type's contract.
enum FactoryReset {

    /// The **complete** factory wipe — the single routine behind BOTH
    /// "Reset Aperture" (Settings) and "Erase Data" (auto-wipe after
    /// repeated wrong passcodes). After it returns, the app's persistent
    /// state is indistinguishable from a first install: every SwiftData
    /// table empty, every Aperture Keychain item gone, the full
    /// `UserDefaults` domain removed, the dApp browser's website data
    /// cleared, the TipKit datastore reset, and the token-logo disk cache
    /// deleted. `RootGate` observes the wallet count flip to zero and routes
    /// back to onboarding.
    ///
    /// **Order is the safety contract.** The SwiftData wallet deletion runs
    /// FIRST and is the ONLY step that throws — if it fails, NOTHING has been
    /// destroyed (the caller surfaces an error and the user keeps a working
    /// app). Every step after it is best-effort so a single failure never
    /// strands a half-reset device.
    @MainActor
    static func performFullWipe(modelContext: ModelContext) async throws {
        let log = Logger(subsystem: "com.thuglife.aperture", category: "reset")
        let repo = WalletRepository(modelContainer: modelContext.container)
        // Capture ids up front so Keychain items can be wiped after the
        // SwiftData rows are gone (once the rows go, the ids are lost).
        let walletIds = (try? await repo.allWalletIds()) ?? []
        // Database first — the custody gate. `deleteAllWallets()` refuses the
        // in-memory fallback store, drops every wallet (with cascades) plus
        // the primitive-keyed chart snapshots, and clears the Keychain wallet
        // manifest. Throws ⇒ nothing destroyed yet.
        try await repo.deleteAllWallets()
        // Structural wipe of EVERY model in `ApertureSchemaV1.models`.
        do { try wipeAllModels(in: modelContext) }
        catch { log.error("Full wipe: structural model wipe failed: \(String(describing: error), privacy: .public)") }
        // Per-wallet Keychain material. Idempotent: missing items are success.
        for id in walletIds {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
            try? MnemonicVault.deletePrivateKey(for: id)
        }
        // Keychain — PIN hash + salt + both failure records.
        PinCodeStorage.clear()
        // dApp-browser website data: cookies, local/session storage, caches.
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        // Foundation-level network residue outside WKWebView.
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        // Token-logo disk cache (Caches/AperturePaint/CoinMarks).
        await CoinMarkCache.shared.clearAll()
        // TipKit datastore — best-effort reset + reconfigure.
        do {
            try Tips.resetDatastore()
            try Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
        } catch {
            log.error("Full wipe: TipKit datastore reset failed: \(String(describing: error), privacy: .public)")
        }
        // Wipe every @AppStorage key (active-wallet pointer, tab, theme/
        // language/currency, pin/biometric/erase flags, restoration stamps,
        // and the fresh-install marker — so the NEXT launch re-runs the
        // fresh-install Keychain purge as a second idempotent sweep).
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        log.notice("Full wipe completed: \(walletIds.count, privacy: .public) wallets purged.")
    }

    /// Empty every table named by `ApertureSchemaV1.models`, committing
    /// all deletions in one save. Throws if a fetch or the final save
    /// fails — nothing is committed in that case.
    static func wipeAllModels(in context: ModelContext) throws {
        for model in ApertureSchemaV1.models {
            try wipeRows(of: model, in: context)
        }
        if context.hasChanges {
            try context.save()
        }
    }

    /// Delete every row of one model type. No save — `wipeAllModels`
    /// batches the commit. (The `any PersistentModel.Type` existential
    /// from the schema list is opened into the generic here, SE-0352.)
    private static func wipeRows<T: PersistentModel>(
        of type: T.Type,
        in context: ModelContext
    ) throws {
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }
}
