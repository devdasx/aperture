import Foundation
import GRDB
import LocalAuthentication
import OSLog

@MainActor
enum BiometricEnrollmentTracker {
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "biometric-tracker")
    private static let rowID = "biometric-enrollment-singleton"

    static func captureSnapshot(database: AppDatabase = .shared) {
        let snapshot = currentDomainState()
        do {
            try database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO biometric_enrollment
                    (id, domain_state_snapshot, updated_at_ms)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        domain_state_snapshot = excluded.domain_state_snapshot,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [rowID, snapshot, Date.databaseMilliseconds]
                )
            }
            log.info("Captured biometric enrollment snapshot (\(snapshot?.count ?? 0) bytes).")
        } catch {
            log.error("Failed to persist biometric snapshot: \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    static func checkForDrift(database: AppDatabase = .shared) -> Bool {
        let current = currentDomainState()
        guard current != nil else { return false }
        do {
            let stored = try database.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT domain_state_snapshot FROM biometric_enrollment WHERE id = ?",
                    arguments: [rowID]
                )
            }
            guard let stored else { return false }
            let mismatch = stored != current
            if mismatch {
                log.notice("Biometric enrollment changed on device; flagging for re-enrollment.")
                try database.write { db in
                    try db.execute(
                        sql: """
                        UPDATE app_metadata
                        SET requires_biometric_reenrollment = 1
                        WHERE id = 'app-metadata-singleton'
                        """
                    )
                }
                UserDefaults.standard.set(false, forKey: PinCodePreference.biometricEnabledKey)
                UserDefaults.standard.set(false, forKey: PinCodePreference.requireBiometricForSendKey)
            }
            return mismatch
        } catch {
            log.error("Drift check failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func acknowledgeReenrollment(database: AppDatabase = .shared) {
        let snapshot = currentDomainState()
        do {
            try database.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO biometric_enrollment
                    (id, domain_state_snapshot, updated_at_ms)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        domain_state_snapshot = excluded.domain_state_snapshot,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [rowID, snapshot, Date.databaseMilliseconds]
                )
                try db.execute(
                    sql: """
                    UPDATE app_metadata
                    SET requires_biometric_reenrollment = 0
                    WHERE id = 'app-metadata-singleton'
                    """
                )
            }
        } catch {
            log.error("Acknowledge re-enrollment failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func requiresReenrollment(database: AppDatabase = .shared) -> Bool {
        (try? database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT requires_biometric_reenrollment
                FROM app_metadata
                WHERE id = 'app-metadata-singleton'
                """
            ) ?? false
        }) ?? false
    }

    private static func currentDomainState() -> Data? {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.domainState.biometry.stateHash
    }
}
