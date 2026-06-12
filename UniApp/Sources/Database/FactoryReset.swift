import Foundation
import SwiftData

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
