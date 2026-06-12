import Foundation
import Security
import os.log

/// Wipes every Keychain item this app owns on the **first launch after
/// an install**.
///
/// **The problem this solves.** iOS Keychain items survive app
/// deletion by default. A user who deletes Aperture and re-installs
/// it from TestFlight / App Store / Xcode sees their previously
/// stored wallet, PIN hash, biometric state, and seed manifest come
/// back — because the SQLite database in the app sandbox got wiped
/// (correct iOS behavior) but the Keychain entries that hold the
/// encryption keys + manifest survived (also correct iOS behavior).
/// Aperture's own contract per Rule #16 §A.5 — *"no servers, no
/// accounts, your wallet only lives on this iPhone"* — is broken when
/// "delete and re-install" doesn't actually reset the wallet.
///
/// **The fix.** A marker bit in `UserDefaults` (which IS wiped on
/// app delete) records that this install has run before. On the
/// very first launch of a fresh install, the marker is missing —
/// we delete every Keychain item under our known service identifiers,
/// then set the marker. Subsequent launches see the marker and
/// no-op.
///
/// **Why this is safe.** The Keychain items we delete are all
/// owned by Aperture (`com.thuglife.aperture.*` services). We do NOT
/// touch Keychain items belonging to other apps; that's structurally
/// impossible because iOS scopes Keychain by app entitlement. We do
/// NOT touch iCloud-synced items because none of Aperture's writes
/// use the `kSecAttrSynchronizable: true` attribute (verified in
/// `SeedVault`, `MnemonicVault`, `PinCodeStorage`, and
/// `WalletManifestStore` — all use the default per-device
/// scoping).
///
/// **Where this runs.** Synchronously from `UniAppApp.init()` BEFORE
/// any other subsystem touches Keychain — before
/// `ApertureDatabase.shared.bootstrap()`, before
/// `CurrencyPreference.bootstrapIfNeeded()`, before any vault read.
/// This guarantees a fresh install starts from a known-empty
/// state across every storage tier.
enum FreshInstallGuard {

    /// `UserDefaults` key that records "this install has run at
    /// least once." Deleted automatically by iOS when the user
    /// removes the app. We don't put any user data behind this key
    /// — just a Bool that flips to `true` on first run.
    private static let installedMarkerKey = "aperture.freshInstall.completed"

    /// Every Keychain `kSecAttrService` identifier Aperture writes
    /// under. Adding a new vault later requires adding its service
    /// string here so the fresh-install wipe covers it. The audit:
    /// `grep -rnE 'kSecAttrService as String:' UniApp/Sources/Security/`
    /// — every result's service literal must be in this list.
    private static let knownServices: [String] = [
        "com.thuglife.aperture.seed.cipher",       // SeedVault — encrypted BIP-39 seeds
        "com.thuglife.aperture.seed.key",          // SeedVault — AES-GCM keys
        "com.thuglife.aperture.mnemonic.cipher",   // MnemonicVault — encrypted phrases
        "com.thuglife.aperture.mnemonic.key",      // MnemonicVault — AES-GCM keys
        "com.thuglife.aperture.privatekey.cipher", // MnemonicVault — encrypted imported key strings
        "com.thuglife.aperture.privatekey.key",    // MnemonicVault — AES-GCM keys (imported keys)
        "com.thuglife.aperture.wallet-manifest",   // WalletManifestStore — wallet list metadata
        "com.thuglife.aperture.pin",               // PinCodeStorage — PBKDF2 hashes + salt
        "com.thuglife.aperture.pin.smoketest",     // PinCodeStorage — DEBUG smoke check
    ]

    /// Every Keychain class Aperture touches across the services
    /// above. Today everything is `kSecClassGenericPassword`; the
    /// list is kept open in case a future vault uses a different
    /// class (`kSecClassKey`, `kSecClassCertificate`). A wipe loops
    /// across every (class, service) pair to be safe.
    ///
    /// **Concurrency note.** `CFString` is a reference type — Swift
    /// 6's strict-concurrency checker won't accept it as `Sendable`
    /// in a `static let`. The values here are Apple-defined
    /// constants (immutable at runtime), so we expose them via a
    /// nonisolated computed property that re-reads each call. Same
    /// observable behavior; no shared mutable state crossing
    /// isolation boundaries.
    private static var knownClasses: [CFString] {
        [
            kSecClassGenericPassword,
            kSecClassKey,
            kSecClassCertificate,
            kSecClassIdentity,
        ]
    }

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "FreshInstallGuard"
    )

    /// Idempotent. Call once from `UniAppApp.init()`. Returns `true`
    /// iff a wipe actually ran (i.e. this WAS a fresh install) — so
    /// callers can log + smoke-test if needed.
    @discardableResult
    static func purgeKeychainIfFreshInstall() -> Bool {
        if UserDefaults.standard.bool(forKey: installedMarkerKey) {
            // Marker present → not a fresh install. No-op.
            return false
        }

        log.log("Fresh install detected — purging Keychain items for \(knownServices.count, privacy: .public) known services across \(knownClasses.count, privacy: .public) classes")

        var deletedCount = 0
        for serviceName in knownServices {
            for secClass in knownClasses {
                let query: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecAttrService as String: serviceName,
                ]
                let status = SecItemDelete(query as CFDictionary)
                switch status {
                case errSecSuccess:
                    deletedCount += 1
                    log.log("Deleted Keychain items for service \(serviceName, privacy: .public) class \(String(describing: secClass), privacy: .public)")
                case errSecItemNotFound:
                    // Nothing to delete for this (class, service) — fine.
                    break
                default:
                    // Don't propagate — a single class/service failure shouldn't
                    // block subsequent ones. The user already wanted a wipe;
                    // best-effort is honest about partial coverage.
                    log.error("SecItemDelete failed for service \(serviceName, privacy: .public): OSStatus \(status, privacy: .public)")
                }
            }
        }

        // Set the marker LAST. If iOS crashes between wipe and marker
        // (extremely unlikely on a sync call from init), next launch
        // will re-wipe — which is idempotent on an empty Keychain.
        UserDefaults.standard.set(true, forKey: installedMarkerKey)
        log.log("Fresh-install Keychain purge complete — \(deletedCount, privacy: .public) (class, service) tuples cleared, marker set")
        return true
    }

    /// Test-only. Resets the marker so a subsequent
    /// `purgeKeychainIfFreshInstall()` call performs the wipe. Used
    /// by the smoke test below in DEBUG builds.
    #if DEBUG
    static func _resetMarkerForTesting() {
        UserDefaults.standard.removeObject(forKey: installedMarkerKey)
    }
    #endif
}
