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
/// **Failure mode.** If the container can't be built (corrupt store,
/// disk full, simulator quirk), we fall back to an in-memory container
/// so the app launches into a "no wallets yet" state rather than
/// crashing. The error is logged via `os.Logger` so it surfaces in
/// Console.app / sysdiagnose without spamming the user.
@MainActor
final class ApertureDatabase {
    /// App-wide shared instance. Read once in `UniAppApp.init()` to
    /// trigger container creation, then again at WindowGroup body to
    /// inject into the SwiftUI environment.
    static let shared = ApertureDatabase()

    let container: ModelContainer
    /// `true` if the container failed to open on disk and we fell back
    /// to an in-memory store. Surfaces in `About` so a user trying to
    /// understand "why are my wallets gone after an upgrade" has an
    /// honest answer.
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
            AppMetadataRecord.self
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
        } catch {
            log.error("SwiftData on-disk container failed: \(String(describing: error), privacy: .public); falling back to in-memory.")
            let inMemoryConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                cloudKitDatabase: .none
            )
            do {
                self.container = try ModelContainer(for: schema, configurations: [inMemoryConfig])
            } catch {
                // Both on-disk and in-memory failed — at this point the
                // app cannot function. Fatal is honest: there is no
                // recoverable state to render. iOS surfaces the
                // crash log to the user via Settings → Privacy &
                // Security → Analytics & Improvements.
                fatalError("SwiftData container unavailable (both on-disk and in-memory failed): \(error)")
            }
            self.isInMemoryFallback = true
        }
    }

    /// Bootstraps the singleton rows (`AppMetadataRecord`,
    /// `BiometricEnrollmentRecord`) on first launch. Idempotent — called
    /// every cold launch; only writes if the rows don't already exist.
    /// Also updates `lastOpenedAt` on every call so "how recently did
    /// this user open Aperture?" is queryable without instrumentation.
    func bootstrap() {
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

            // 2026-06-09 — backfill avatar defaults onto rows that
            // pre-date the `iconSymbol` / `iconColorHex` schema
            // additive. Idempotent (only writes when a field is
            // empty). Routes through `WalletRepository` so the
            // domain layer owns the backfill — `ApertureDatabase`
            // stays a pure container surface.
            Task { @MainActor in
                let repo = WalletRepository(modelContainer: container)
                try? await repo.backfillAvatarDefaults()
            }
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

    /// Location of the on-disk SQLite store. Lives in Application
    /// Support so it's backed up by iCloud (per Apple guidance for
    /// user-generated data that the user would expect to survive a
    /// device migration). For a wallet app the seed material in
    /// Keychain is also iCloud-backupable iff the user enables
    /// Keychain iCloud, so this matches that posture.
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
        return dir.appendingPathComponent("aperture.sqlite", isDirectory: false)
    }
}
