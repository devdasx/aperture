import Foundation
import SwiftData
import OSLog
// TipKit's own datastore ("shown once" counters) can only be reset BEFORE
// `Tips.configure()` runs — which already happened at launch — so that reset
// is deferred to the next launch via `tipKitResetFlagKey` (see `UniAppApp`),
// not attempted mid-session.

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
/// `WalletManifestStore`), `UserDefaults`, the TipKit datastore, and
/// the `CoinMarkCache` disk cache.
/// `ResetCompletenessTests` pins this type's contract.
enum FactoryReset {

    /// The three honest deletion stages the Reset-Aperture UI reports, in REAL
    /// execution order. `.wallets` runs FIRST and is the ONLY one that throws
    /// (the SwiftData custody gate — if it fails, nothing has been destroyed).
    /// The reset flow's progress ring fills one third per stage as each
    /// genuinely completes (handoff rule #4 — honest progress, not a timer).
    enum Stage: CaseIterable, Sendable {
        /// SwiftData wallets + every model table. The failable custody gate.
        case wallets
        /// Keychain seed / mnemonic / private-key material + the PIN records.
        case keys
        /// Web data, URL/cookie caches, token-logo cache, UserDefaults.
        case settings
    }

    /// UserDefaults marker that asks the NEXT launch to reset TipKit's "seen"
    /// datastore before it configures TipKit — the only valid moment to reset
    /// it. Set during the wipe AFTER the UserDefaults domain is cleared (so it
    /// survives), and consumed once in `UniAppApp.init`.
    static let tipKitResetFlagKey = "apertureNeedsTipKitReset"

    /// The **complete** factory wipe — the single routine behind BOTH
    /// "Reset Aperture" (Settings) and "Erase Data" (auto-wipe after repeated
    /// wrong passcodes). Used by the no-progress `AppLockView` path; delegates
    /// to `performStagedWipe` with a no-op reporter so there is exactly ONE
    /// wipe implementation.
    @MainActor
    static func performFullWipe(modelContext: ModelContext) async throws {
        try await performStagedWipe(modelContext: modelContext, onStageComplete: { _ in })
    }

    /// The complete factory wipe, reporting each real deletion `Stage` as it
    /// finishes so the Reset-Aperture UI's progress ring reflects honest
    /// progress. After it returns, the app's persistent state is
    /// indistinguishable from a first install: every SwiftData table empty,
    /// every Aperture Keychain item gone, the full `UserDefaults` domain
    /// removed, the TipKit datastore reset, and the token-logo disk cache
    /// deleted. `RootGate` observes the
    /// wallet count flip to zero and routes back to onboarding.
    ///
    /// **Order is the safety contract.** The SwiftData wallet deletion runs
    /// FIRST and is the ONLY step that throws — if it fails, NOTHING has been
    /// destroyed (the caller surfaces an error and the user keeps a working
    /// app). Every step after it is best-effort so a single failure never
    /// strands a half-reset device. `onStageComplete` is called on the main
    /// actor after each stage genuinely finishes.
    @MainActor
    static func performStagedWipe(
        modelContext: ModelContext,
        onStageComplete: (Stage) -> Void
    ) async throws {
        let log = Logger(subsystem: "com.thuglife.aperture", category: "reset")
        let repo = WalletRepository(modelContainer: modelContext.container)
        // Capture ids up front so Keychain items can be wiped after the
        // SwiftData rows are gone (once the rows go, the ids are lost).
        let walletIds = (try? await repo.allWalletIds()) ?? []

        // STAGE 1 — wallets & history. The custody gate. `deleteAllWallets()`
        // refuses the in-memory fallback store, drops every wallet (with
        // cascades) plus the primitive-keyed chart snapshots, and clears the
        // Keychain wallet manifest. Throws ⇒ nothing destroyed yet.
        try await repo.deleteAllWallets()
        // Structural wipe of EVERY model in `ApertureSchemaV1.models`.
        do { try wipeAllModels(in: modelContext) }
        catch { log.error("Full wipe: structural model wipe failed: \(String(describing: error), privacy: .public)") }
        onStageComplete(.wallets)

        // STAGE 2 — keys & phrases (Keychain). Best-effort; idempotent (a
        // missing item is success).
        for id in walletIds {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
            try? MnemonicVault.deletePrivateKey(for: id)
        }
        // Keychain — PIN hash + salt + both failure records.
        PinCodeStorage.clear()
        onStageComplete(.keys)

        // STAGE 3 — settings & cache. Best-effort.
        // Foundation-level network residue.
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        // Token-logo disk cache (Caches/AperturePaint/CoinMarks).
        await CoinMarkCache.shared.clearAll()
        // Wipe every @AppStorage key (active-wallet pointer, tab, theme/
        // language/currency, pin/biometric/erase flags, restoration stamps,
        // and the fresh-install marker — so the NEXT launch re-runs the
        // fresh-install Keychain purge as a second idempotent sweep). Done
        // before the onboarding flag so it only flips after the data is gone.
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        // Ask the next launch to reset TipKit's "seen" datastore (it can't be
        // reset mid-session — `Tips.configure()` already ran, so
        // `Tips.resetDatastore()` here would throw `tipsDatastoreAlreadyConfigured`).
        // Set AFTER the domain wipe so the marker itself survives.
        UserDefaults.standard.set(true, forKey: tipKitResetFlagKey)
        onStageComplete(.settings)
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
