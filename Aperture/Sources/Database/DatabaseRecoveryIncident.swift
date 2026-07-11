import Foundation
import OSLog

/// Durable record of a destructive database recovery event (BUG-020 / P0-001).
///
/// Stored as a JSON marker **next to** the store (Application Support), not
/// inside the recovered SQLite file — the recovered DB is empty/untrusted and
/// must not be the only place we remember that wallets were quarantined.
///
/// **Contract:** while `needsUserAcknowledgement` is true, the app root shows
/// a blocking recovery screen and never pretends this is a normal cold launch.
struct DatabaseRecoveryIncident: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Corrupt/unopenable primary store was moved to CorruptStore-* and
        /// replaced with a new empty DB at the normal path.
        case quarantinedAndReplaced
        /// Could not use permanent Application Support storage; running on a
        /// temp/ephemeral file that may vanish after reboot.
        case ephemeralFallback
    }

    var kind: Kind
    /// Technical open/migrate/integrity error (safe for support; no secrets).
    var reason: String
    /// Absolute path to `CorruptStore-<ms>/` if files were quarantined.
    var quarantineDirectoryPath: String?
    /// Path of the store that is currently open.
    var storePath: String
    var createdAtMs: Int64
    /// Cleared only after the user explicitly acknowledges the recovery UI.
    var acknowledged: Bool

    var quarantineDirectoryURL: URL? {
        guard let quarantineDirectoryPath, !quarantineDirectoryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: quarantineDirectoryPath, isDirectory: true)
    }

    var needsUserAcknowledgement: Bool { !acknowledged }

    /// Ephemeral sessions must never accept wallet writes (create/import/sign
    /// secrets) — the store can disappear without warning.
    var refusesUserWrites: Bool { kind == .ephemeralFallback }

    // MARK: - Persistence

    private static let markerFileName = ".aperture-db-recovery-v1.json"
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "database-recovery")

    /// Marker lives in the Aperture Application Support directory (same parent
    /// as `aperture.sqlite` when permanent storage works).
    static func markerURL(storeDirectory: URL? = nil) -> URL? {
        if let storeDirectory {
            return storeDirectory.appendingPathComponent(markerFileName, isDirectory: false)
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("Aperture", isDirectory: true)
            .appendingPathComponent(markerFileName, isDirectory: false)
    }

    static func loadPending(storeDirectory: URL? = nil) -> DatabaseRecoveryIncident? {
        guard let url = markerURL(storeDirectory: storeDirectory),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let incident = try? JSONDecoder().decode(DatabaseRecoveryIncident.self, from: data)
        else { return nil }
        return incident
    }

    /// True when the user must still see the blocking recovery screen.
    static func needsBlockingUI(storeDirectory: URL? = nil) -> Bool {
        guard let incident = loadPending(storeDirectory: storeDirectory) else { return false }
        return incident.needsUserAcknowledgement
    }

    static func record(
        kind: Kind,
        reason: String,
        quarantineDirectory: URL?,
        storeURL: URL
    ) {
        let incident = DatabaseRecoveryIncident(
            kind: kind,
            reason: reason,
            quarantineDirectoryPath: quarantineDirectory?.path,
            storePath: storeURL.path,
            createdAtMs: Date.databaseMilliseconds,
            acknowledged: false
        )
        save(incident, preferredDirectory: storeURL.deletingLastPathComponent())
        // Always also try Application Support so UI can load even if the open
        // store is under TemporaryDirectory.
        if let appSupport = markerURL()?.deletingLastPathComponent() {
            save(incident, preferredDirectory: appSupport)
        }
        log.warning(
            "Database recovery recorded kind=\(kind.rawValue, privacy: .public) quarantine=\(quarantineDirectory?.path ?? "none", privacy: .public)"
        )
    }

    static func acknowledge(_ incident: DatabaseRecoveryIncident) {
        var updated = incident
        updated.acknowledged = true
        save(updated, preferredDirectory: URL(fileURLWithPath: incident.storePath).deletingLastPathComponent())
        if let appSupport = markerURL()?.deletingLastPathComponent() {
            save(updated, preferredDirectory: appSupport)
        }
        // After acknowledgement of a permanent replacement, drop the marker so
        // future launches are quiet. Ephemeral markers stay acknowledged but
        // present until a later successful permanent open clears them.
        if incident.kind == .quarantinedAndReplaced {
            clearMarkers()
        }
    }

    /// Successful open of the permanent store clears any stale ephemeral
    /// recovery marker from a previous broken session.
    static func clearIfPermanentStoreHealthy() {
        guard let pending = loadPending() else { return }
        if pending.kind == .ephemeralFallback || pending.acknowledged {
            clearMarkers()
        }
    }

    static func clearMarkers() {
        if let url = markerURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Files inside a quarantine directory that should be offered for export
    /// (sqlite + sidecars + reason.txt). Empty if path missing.
    static func exportableFiles(in quarantineDirectory: URL) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: quarantineDirectory.path),
              let contents = try? fm.contentsOfDirectory(
                at: quarantineDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Discover the newest `CorruptStore-*` folder next to the default store
    /// when the marker is missing but quarantine remains on disk.
    static func latestQuarantineDirectory(near storeURL: URL) -> URL? {
        let directory = storeURL.deletingLastPathComponent()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = contents.filter { url in
            url.lastPathComponent.hasPrefix("CorruptStore-")
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        return candidates.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da < db
        }
    }

    // MARK: - Private

    private static func save(_ incident: DatabaseRecoveryIncident, preferredDirectory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: preferredDirectory, withIntermediateDirectories: true)
        let url = preferredDirectory.appendingPathComponent(markerFileName, isDirectory: false)
        guard let data = try? JSONEncoder().encode(incident) else { return }
        try? data.write(to: url, options: [.atomic])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = preferredDirectory
        try? mutable.setResourceValues(values)
    }
}

// MARK: - Process gate (UI)

/// Main-actor gate so SwiftUI can observe recovery without re-reading disk
/// on every body evaluation.
@MainActor
@Observable
final class DatabaseRecoveryGate {
    static let shared = DatabaseRecoveryGate()

    private(set) var incident: DatabaseRecoveryIncident?
    private(set) var isEphemeralStore: Bool = false

    private init() {}

    /// Call after `AppDatabase.shared` is live (from bootstrap / AppRoot).
    func refresh(from database: AppDatabase = .shared) {
        isEphemeralStore = database.isInMemoryFallback
        if let live = database.recoveryIncident, live.needsUserAcknowledgement {
            incident = live
            return
        }
        if let pending = DatabaseRecoveryIncident.loadPending(), pending.needsUserAcknowledgement {
            incident = pending
            return
        }
        // Disk quarantine without marker (upgrade path / lost marker).
        if let quarantine = DatabaseRecoveryIncident.latestQuarantineDirectory(near: database.storeURL),
           database.recoveryIncident == nil,
           !database.isInMemoryFallback {
            // Only surface orphan quarantine if it looks recent and empty wallets?
            // Safer: do not auto-block forever on old CorruptStore folders.
            // Leave orphan discovery for export button inside an already-pending incident.
            _ = quarantine
        }
        incident = nil
    }

    /// Session-only: after the user acknowledges an ephemeral-storage
    /// warning we allow them into onboarding, but `AppDatabase.write`
    /// still refuses user data.
    private(set) var ephemeralWarningDismissedThisSession = false

    var shouldBlockApp: Bool {
        if isEphemeralStore && !ephemeralWarningDismissedThisSession {
            return true
        }
        return incident?.needsUserAcknowledgement == true
    }

    func acknowledgeAndContinue() {
        if let incident {
            DatabaseRecoveryIncident.acknowledge(incident)
        }
        self.incident = nil
        refresh()
    }

    func dismissEphemeralWarningForSession() {
        ephemeralWarningDismissedThisSession = true
        if let incident, incident.kind == .ephemeralFallback {
            DatabaseRecoveryIncident.acknowledge(incident)
        }
        self.incident = nil
    }
}
