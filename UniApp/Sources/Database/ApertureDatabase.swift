import CoreData
import Foundation
import SwiftData
import OSLog

/// Aperture's single SwiftData entry point. Creates the `ModelContainer`
/// once at app launch (`UniAppApp.init()`), bootstraps the singleton
/// `AppMetadataRecord` + `BiometricEnrollmentRecord` rows on first
/// install, and exposes the container to the SwiftUI environment via
/// `.modelContainer(ApertureDatabase.shared.container)`.
///
/// **Zero-latency open.** The container is created synchronously in
/// `init()` so SwiftData has already opened the SQLite file and
/// materialized the schema before the `WindowGroup` body runs. The
/// wallet screen's `@Query` reads then resolve from an already-warm
/// store — no spinner needed on cold open for the wallet list.
///
/// **Failure mode.** Open errors are classified before any recovery
/// runs. Only a genuine schema/migration incompatibility (Cocoa-domain
/// Core Data migration codes — the store can never be read by this
/// binary) triggers the reset-and-reopen path. Every other failure
/// (file-protection before first unlock after reboot, disk full,
/// sandbox denial) retries the open once and, if that also fails,
/// falls back to an in-memory container WITHOUT touching the on-disk
/// file — the store stays intact for the next launch. The error is
/// logged via `os.Logger` so it surfaces in Console.app / sysdiagnose
/// without spamming the user.
@MainActor
final class ApertureDatabase {
    /// App-wide shared instance. Read once in `UniAppApp.init()` to
    /// trigger container creation, then again at WindowGroup body to
    /// inject into the SwiftUI environment.
    static let shared = ApertureDatabase()

    let container: ModelContainer
    /// `true` if the container failed to open on disk and we fell back
    /// to an in-memory store. `WalletRepository` reads the equivalent
    /// signal from its own container's configuration
    /// (`isStoredInMemoryOnly`) and refuses custody mutations
    /// (create / import / delete) during a fallback session — records
    /// written now would vanish at exit while their Keychain writes
    /// (seed, mnemonic, manifest) persisted, permanently orphaning
    /// them. Not yet read by any UI surface; an `About` row that warns
    /// the user the session is volatile is the intended consumer.
    let isInMemoryFallback: Bool

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "database")

    private init() {
        let schema = Schema([
            WalletRecord.self,
            WalletAddressRecord.self,
            TransactionRecord.self,
            TokenBalanceRecord.self,
            CachedPriceRecord.self,
            BiometricEnrollmentRecord.self,
            AppMetadataRecord.self,
            CustomTokenRecord.self,
            BrowserHistoryRecord.self,
            BrowserBookmarkRecord.self
        ])
        let storeURL = Self.defaultStoreURL()
        let onDiskConfig = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        do {
            self.container = try ModelContainer(for: schema, configurations: [onDiskConfig])
            self.isInMemoryFallback = false
            log.info("SwiftData container opened at \(storeURL.path, privacy: .public)")
        } catch let error where Self.isMigrationIncompatibilityError(error) {
            // **2026-06-09 recovery path.** Migration failure (CoreData
            // error 134110, "missing attribute values on mandatory
            // destination attribute") happens when a non-Optional
            // attribute is added to a model that already has rows on
            // disk — lightweight migration has no value to put in the
            // new column. Recovery: delete the corrupted store + its
            // sidecars (`-wal`, `-shm`) and open a FRESH on-disk
            // container. The Keychain `WalletManifestStore.restoreIfNeeded(...)`
            // run from `bootstrap()` rebuilds `WalletRecord`s from the
            // seed material that lives in Keychain (survives store
            // deletion). Balances / transactions refetch on the next
            // refresh. Only cached / derived data is lost — never the
            // seed.
            //
            // This branch fires ONLY for Cocoa-domain migration /
            // schema-incompatibility codes (see
            // `isMigrationIncompatibilityError`) — the one failure
            // class where the store is unreadable by this binary
            // forever and deletion is the correct recovery.
            log.error("SwiftData on-disk container failed with a migration-incompatibility error: \(String(describing: error), privacy: .public); recovering by resetting the store.")
            Self.resetStore(at: storeURL, log: log)
            do {
                self.container = try ModelContainer(for: schema, configurations: [onDiskConfig])
                self.isInMemoryFallback = false
                log.info("SwiftData container re-opened with fresh store at \(storeURL.path, privacy: .public)")
            } catch {
                // Fresh on-disk ALSO failed — disk full, signed sandbox
                // denial, or genuinely broken schema definition. Last
                // resort is in-memory so the app launches into a
                // recoverable state instead of crashing in `init`.
                log.error("Fresh on-disk container failed: \(String(describing: error), privacy: .public); falling back to in-memory.")
                self.container = Self.makeInMemoryFallbackContainer(schema: schema)
                self.isInMemoryFallback = true
            }
        } catch {
            // Non-migration failure — file-protection before first
            // unlock after reboot, disk full, sandbox denial. The
            // store on disk may be perfectly healthy; deleting it
            // here would destroy user data over a transient
            // condition. NEVER reset on this path. Retry the open
            // once; if that also fails, run in-memory for this
            // session and leave the on-disk file intact so the next
            // launch can open it normally.
            log.error("SwiftData on-disk container failed with a non-migration error: \(String(describing: error), privacy: .public); retrying once without resetting the store.")
            do {
                self.container = try ModelContainer(for: schema, configurations: [onDiskConfig])
                self.isInMemoryFallback = false
                log.info("SwiftData container opened on retry at \(storeURL.path, privacy: .public)")
            } catch {
                log.error("Retry failed: \(String(describing: error), privacy: .public); falling back to in-memory. The on-disk store is left intact for the next launch.")
                self.container = Self.makeInMemoryFallbackContainer(schema: schema)
                self.isInMemoryFallback = true
            }
        }
    }

    /// Last-resort in-memory container so the app launches into a
    /// recoverable state instead of crashing in `init`. The on-disk
    /// store (when present) is untouched by this path.
    private static func makeInMemoryFallbackContainer(schema: Schema) -> ModelContainer {
        let inMemoryConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [inMemoryConfig])
        } catch {
            fatalError("SwiftData container unavailable (on-disk and in-memory both failed): \(error)")
        }
    }

    /// Cocoa-domain Core Data codes that mean "this store can never be
    /// opened by this binary" — the only failure class where deleting
    /// the store is the correct recovery. Everything else (transient
    /// file-protection errors before first unlock, disk full, sandbox
    /// denials) must NOT match: the store is healthy and wiping it
    /// would destroy user data.
    ///
    /// Explicitly enumerated, NOT a `134110...134190` range sweep —
    /// that block also contains `NSMigrationCancelledError` (134120,
    /// a cancelled, retryable migration) and `NSSQLiteError` (134180,
    /// Core Data's general "SQLite returned an error" code, raised
    /// for disk-full / I/O / file-locking conditions during open).
    /// Those are transient and fall through to the retry-then-in-memory
    /// branch that leaves the store intact.
    /// `NSMigrationManagerSourceStoreError` / `...DestinationStoreError`
    /// (134150 / 134160) are likewise excluded — they can surface for
    /// environmental I/O problems mid-migration. When unsure a code is
    /// unrecoverable, don't wipe.
    private static let migrationIncompatibilityCodes: Set<Int> = [
        NSPersistentStoreIncompatibleSchemaError,       // 134020
        NSPersistentStoreIncompatibleVersionHashError,  // 134100
        NSMigrationError,                               // 134110
        NSMigrationConstraintViolationError,            // 134111
        NSMigrationMissingSourceModelError,             // 134130
        NSMigrationMissingMappingModelError,            // 134140
        NSEntityMigrationPolicyError,                   // 134170
        NSInferredMappingModelError                     // 134190
    ]

    /// SQLite result codes (carried in `NSSQLiteErrorDomain` underlying
    /// errors) that mean the database FILE itself is corrupt and can
    /// never be reopened: `SQLITE_CORRUPT` (11) and `SQLITE_NOTADB`
    /// (26). These are the only SQLite-level codes that justify the
    /// wipe — every other SQLite result (busy, locked, ioerr, full)
    /// is transient and must leave the store intact.
    private static let sqliteCorruptionCodes: Set<Int> = [11, 26]

    /// `true` iff the thrown error — or any error in its
    /// `NSUnderlyingErrorKey` chain (SwiftData wraps the Core Data
    /// failure) — is a Cocoa-domain migration / schema-incompatibility
    /// code from `migrationIncompatibilityCodes`, or an
    /// `NSSQLiteErrorDomain` file-corruption code from
    /// `sqliteCorruptionCodes`.
    private static func isMigrationIncompatibilityError(_ error: any Error) -> Bool {
        var next: NSError? = error as NSError
        var depth = 0
        while let current = next, depth < 8 {
            if current.domain == NSCocoaErrorDomain,
               migrationIncompatibilityCodes.contains(current.code) {
                return true
            }
            if current.domain == NSSQLiteErrorDomain,
               sqliteCorruptionCodes.contains(current.code) {
                return true
            }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Bootstraps the singleton rows (`AppMetadataRecord`,
    /// `BiometricEnrollmentRecord`) on first launch. Idempotent — called
    /// every cold launch; only writes if the rows don't already exist.
    /// Also updates `lastOpenedAt` on every call so "how recently did
    /// this user open Aperture?" is queryable without instrumentation.
    ///
    /// **Launch latency.** Only the Keychain-manifest restore runs
    /// synchronously here — it MUST land before the first `@Query`
    /// snapshot so `RootGate` routes a returning user to `MainTabView`.
    /// The singleton-row inserts, the `lastOpenedAt` touch, and the
    /// avatar backfill are saves no first-frame read depends on
    /// (`BiometricEnrollmentTracker.fetchOrCreate` self-heals a missing
    /// bio row; every `AppMetadataRecord` consumer tolerates an empty
    /// fetch), so they're deferred to a utility-priority task that runs
    /// after the first render instead of blocking it.
    func bootstrap() {
        let context = ModelContext(container)

        // 2026-06-09 — RESTORE FROM KEYCHAIN MANIFEST after a
        // reinstall. iOS wipes the SwiftData store on
        // `devicectl install` (and on any user-initiated app
        // deletion), but Keychain items survive both. If
        // SwiftData is empty AND `WalletManifestStore` has
        // entries, we re-insert the `WalletRecord`s + their
        // `WalletAddressRecord`s from the manifest before the
        // first `@Query` snapshot is taken — so `RootGate`
        // routes the returning user straight to `MainTabView`
        // instead of `OnboardingView`. The seed material lives
        // in `SeedVault` (Keychain) and was always there; the
        // manifest is the bridge that gives the seed a wallet
        // record to attach to. See `WalletManifestStore.swift`
        // for the full rationale.
        let restored = WalletManifestStore.restoreIfNeeded(into: context)
        if restored > 0 {
            log.info("Restored \(restored) wallets from Keychain manifest after reinstall.")
        }

        // Deferred writes — enqueued on the main actor at utility
        // priority, so they run after the synchronous launch path
        // (and the first frame's `@Query` snapshot) completes.
        Task(priority: .utility) {
            self.bootstrapSingletonRows()

            // 2026-06-09 — backfill avatar defaults onto rows that
            // pre-date the `iconSymbol` / `iconColorHex` schema
            // additive. Idempotent (only writes when a field is
            // empty). Routes through `WalletRepository` so the
            // domain layer owns the backfill — `ApertureDatabase`
            // stays a pure container surface.
            let repo = WalletRepository(modelContainer: self.container)
            do {
                try await repo.backfillAvatarDefaults()
            } catch {
                self.log.error("Avatar backfill failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Insert the singleton rows if missing and touch `lastOpenedAt`,
    /// in one save. Runs from `bootstrap()`'s deferred task — see the
    /// launch-latency note there.
    private func bootstrapSingletonRows() {
        let context = ModelContext(container)
        do {
            let metaCount = try context.fetchCount(FetchDescriptor<AppMetadataRecord>())
            if metaCount == 0 {
                let meta = AppMetadataRecord()
                context.insert(meta)
                log.info("Bootstrapped AppMetadataRecord on first launch.")
            }

            let bioCount = try context.fetchCount(FetchDescriptor<BiometricEnrollmentRecord>())
            if bioCount == 0 {
                let bio = BiometricEnrollmentRecord(domainStateSnapshot: nil)
                context.insert(bio)
            }

            if context.hasChanges {
                try context.save()
            }

            try touchLastOpened(context: context)
        } catch {
            log.error("Bootstrap failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Update `AppMetadataRecord.lastOpenedAt` to now. Called from
    /// `bootstrap()` and from any future scene-active hook.
    private func touchLastOpened(context: ModelContext) throws {
        guard let meta = try context.fetch(FetchDescriptor<AppMetadataRecord>()).first else {
            return
        }
        meta.lastOpenedAt = Date()
        try context.save()
    }

    /// Delete the SQLite store file and its `-wal` / `-shm` sidecars.
    /// Called ONLY when the on-disk container fails to open with a
    /// migration-incompatibility error (see
    /// `isMigrationIncompatibilityError`). Safe to run when files
    /// don't exist — missing sidecars are skipped, and a failed
    /// removal is logged rather than thrown. The Keychain
    /// `WalletManifestStore` survives this deletion and rehydrates
    /// wallets on next bootstrap.
    private static func resetStore(at storeURL: URL, log: Logger) {
        let fm = FileManager.default
        // SQLite names sidecars by appending "-wal" / "-shm" to the
        // FULL store filename ("aperture.sqlite-wal"), not by swapping
        // the path extension — build them from the raw path string.
        let urls = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        for url in urls {
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    log.info("Removed corrupted store file: \(url.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("Failed to remove store file \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Location of the on-disk SQLite store. Lives in Application
    /// Support, with the containing directory EXCLUDED from iCloud /
    /// Finder backups. The seed material in Keychain is written
    /// `…ThisDeviceOnly` (`SeedVault` / `MnemonicVault` /
    /// `WalletManifestStore` — see their ACL doc comments), so it
    /// never migrates to a new device via any backup. If the store
    /// were backed up, a restored phone would present wallets that
    /// look fully capable but can never sign — and the user's full
    /// transaction history + dApp browsing metadata would ride along
    /// in their backups. Excluding the store keeps the on-disk
    /// posture aligned with the Keychain posture: a restored device
    /// starts clean and onboards honestly.
    private static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = appSupport
        } else {
            base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let dir = base.appendingPathComponent("Aperture", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Exclude the store directory (and so the .sqlite + -wal/-shm
        // sidecars inside it) from backups. Re-applied on every launch
        // (idempotent) so stores created before the exclusion shipped
        // pick it up too. A failure here is non-fatal — the store still
        // opens; it just rides along in backups until a later launch
        // succeeds — so it matches the `try?` posture above.
        var excludeFromBackup = URLResourceValues()
        excludeFromBackup.isExcludedFromBackup = true
        var dirURL = dir
        try? dirURL.setResourceValues(excludeFromBackup)
        return dir.appendingPathComponent("aperture.sqlite", isDirectory: false)
    }
}
