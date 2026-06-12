import Foundation
import LocalAuthentication
import SwiftData
import OSLog

/// Detects when the user has changed their biometric enrollment in iOS
/// Settings (added a new Face ID, removed all enrolled faces, registered
/// a new fingerprint, …) and forces Aperture to re-prompt for biometric
/// approval per the user's 2026-06-06 direction.
///
/// **Mechanism.** Apple's `LAContext.evaluatedPolicyDomainState` returns
/// an opaque `Data` hash of the current biometric enrollment. Every time
/// the user successfully authenticates, we capture the current hash and
/// write it to `BiometricEnrollmentRecord`. On every cold launch (and on
/// `applicationWillEnterForeground`) we capture the current hash again
/// and compare:
///
///   - **Match** → no change; biometric stays trusted.
///   - **Mismatch** → enrollment changed; set
///     `AppMetadataRecord.requiresBiometricReenrollment = true` and
///     flip `@AppStorage("biometricEnabled")` to `false`. The next time
///     the user reaches a biometric-gated surface they're prompted to
///     re-enable (which captures the new snapshot and clears the flag).
///   - **Snapshot was nil** (user never enabled biometric) → no-op.
///
/// **Why not just rely on Keychain `.biometryCurrentSet` ACL?** That ACL
/// is the right protection for *Keychain items* (the Keychain item
/// becomes inaccessible automatically when enrollment changes — a great
/// "fail-closed" guarantee for stored secrets). But Aperture's `SeedVault`
/// items are protected by `.WhenPasscodeSetThisDeviceOnly` so the seed
/// stays accessible whether or not biometrics are enabled — we use the
/// app-level PIN + biometric for UI gating, not for Keychain ACL gating.
/// That choice keeps the user's wallet recoverable when they re-enroll
/// Face ID; the tradeoff is that we have to detect drift explicitly,
/// which is exactly what this tracker does.
@MainActor
enum BiometricEnrollmentTracker {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "biometric-tracker")

    /// Capture the current biometric domain state and persist it as the
    /// new baseline. Called after every successful biometric
    /// authentication (e.g. on `BiometricService.authenticate(...)`
    /// success) and after the user re-enables biometric from Settings.
    static func captureSnapshot(in container: ModelContainer) {
        let snapshot = currentDomainState()
        do {
            let context = ModelContext(container)
            let record = try fetchOrCreate(context: context)
            record.domainStateSnapshot = snapshot
            record.updatedAt = Date()
            try context.save()
            log.info("Captured biometric enrollment snapshot (\(snapshot?.count ?? 0) bytes).")
        } catch {
            log.error("Failed to persist biometric snapshot: \(String(describing: error), privacy: .public)")
        }
    }

    /// Compare the current device biometric state against the stored
    /// snapshot. Mutates app state if a mismatch is detected:
    ///
    /// 1. Sets `AppMetadataRecord.requiresBiometricReenrollment = true`.
    /// 2. Flips `@AppStorage("biometricEnabled")` to `false` so any
    ///    biometric-gated surface treats biometric as unavailable until
    ///    the user re-enables it.
    ///
    /// Returns `true` if a mismatch was detected (caller can react with
    /// UI if useful); `false` if matched, snapshot absent, or
    /// biometrics unavailable on the device.
    @discardableResult
    static func checkForDrift(in container: ModelContainer) -> Bool {
        let current = currentDomainState()

        // No biometry on this device → nothing to track. Don't flip the
        // user's preference; they may have never set it.
        guard current != nil else { return false }

        do {
            let context = ModelContext(container)
            let record = try fetchOrCreate(context: context)
            guard let stored = record.domainStateSnapshot else {
                // First check after a fresh install (or before user ever
                // enabled biometric) — no baseline to compare against.
                // Don't write the snapshot yet; we only capture the
                // baseline after a successful authenticate so a passive
                // launch doesn't pin a stale value.
                return false
            }
            let mismatch = (stored != current)
            if mismatch {
                log.notice("Biometric enrollment changed on device; flagging for re-enrollment.")
                if let meta = try context.fetch(FetchDescriptor<AppMetadataRecord>()).first {
                    meta.requiresBiometricReenrollment = true
                    try context.save()
                }
                UserDefaults.standard.set(false, forKey: "biometricEnabled")
            }
            return mismatch
        } catch {
            log.error("Drift check failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Clear the re-enrollment flag. Called after the user successfully
    /// re-authenticates with the new enrollment (via
    /// `BiometricService.authenticate(...)`). Also captures the new
    /// snapshot in the same write.
    static func acknowledgeReenrollment(in container: ModelContainer) {
        let snapshot = currentDomainState()
        do {
            let context = ModelContext(container)
            let record = try fetchOrCreate(context: context)
            record.domainStateSnapshot = snapshot
            record.updatedAt = Date()
            if let meta = try context.fetch(FetchDescriptor<AppMetadataRecord>()).first {
                meta.requiresBiometricReenrollment = false
            }
            try context.save()
        } catch {
            log.error("Acknowledge re-enrollment failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Read the current `AppMetadataRecord.requiresBiometricReenrollment`
    /// flag synchronously. Used by views / flows that need to know
    /// whether to surface the re-enable affordance.
    static func requiresReenrollment(in container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        do {
            return try context.fetch(FetchDescriptor<AppMetadataRecord>()).first?.requiresBiometricReenrollment ?? false
        } catch {
            return false
        }
    }

    // MARK: - Internals

    /// Returns the current biometric enrollment hash, or `nil` if
    /// biometry is unavailable on this device. The hash is opaque —
    /// only equality comparisons are meaningful.
    ///
    /// Note: `evaluatedPolicyDomainState` is marked deprecated in
    /// iOS 18, but its replacement (`LADomainState`) isn't exposed on
    /// the SDK we currently compile against. The deprecation is a
    /// warning, not an error; we accept the warning until the new API
    /// is available, at which point this is a one-line swap. A
    /// silencing pragma would hide breakage if the API is removed in
    /// a future SDK, so we keep the warning visible instead.
    private static func currentDomainState() -> Data? {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        // `domainState.biometry.stateHash` is the iOS 18+ replacement
        // for the deprecated `evaluatedPolicyDomainState` — the same
        // opaque enrollment fingerprint, populated after
        // `canEvaluatePolicy`. Nil on devices without biometry.
        return context.domainState.biometry.stateHash
    }

    private static func fetchOrCreate(context: ModelContext) throws -> BiometricEnrollmentRecord {
        if let existing = try context.fetch(FetchDescriptor<BiometricEnrollmentRecord>()).first {
            return existing
        }
        let record = BiometricEnrollmentRecord(domainStateSnapshot: nil)
        context.insert(record)
        return record
    }
}
