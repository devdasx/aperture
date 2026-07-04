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
/// **The fix.** The local GRDB store lives in the app sandbox and is
/// deleted with the app. On launch, a missing local SQLite store means
/// this process is the first launch of a fresh install, so we delete
/// every Keychain item under our known service identifiers before any
/// vault opens. Subsequent launches see the GRDB store and no-op.
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
/// `AppDatabase.shared.bootstrap()`, before
/// `CurrencyPreference.bootstrapIfNeeded()`, before any vault read.
/// This guarantees a fresh install starts from a known-empty
/// state across every storage tier.
enum FreshInstallGuard {

    #if DEBUG
    nonisolated(unsafe) private static var ignoresExistingStoreForTesting = false
    #endif

    /// Every Keychain `kSecAttrService` identifier Aperture writes
    /// under. Adding a new vault later requires adding its service
    /// string here so the fresh-install wipe covers it — a service
    /// missing from this list means wallets RESURRECT after a delete
    /// + reinstall, breaking the user's zero-data contract.
    ///
    /// **Test-facing inventory (audited 2026-06-13).** Each entry
    /// below mirrors the `static let` service constant in the file
    /// named in its comment — those constants are `private`, so the
    /// literal is duplicated here by design and the pairing is pinned
    /// two ways:
    ///
    /// 1. `ResetCompletenessTests.freshInstallGuardCoversEveryKnownKeychainService`
    ///    compares `knownServicesForAudit` against the expected set —
    ///    a new vault that forgets this list fails the suite.
    /// 2. The grep audit:
    ///    `grep -rnE 'kSecAttrService as String:|com\.thuglife\.aperture\.' UniApp/Sources/`
    ///    — every service literal in the codebase must appear here.
    ///    As of 2026-06-13 the only files touching Keychain are
    ///    `SeedVault`, `MnemonicVault`, `WalletManifestStore`,
    ///    `PinCodeStorage`, and this guard.
    private static let knownServices: [String] = [
        "com.thuglife.aperture.seed.cipher",       // SeedVault.cipherService — encrypted BIP-39 seeds
        "com.thuglife.aperture.seed.key",          // SeedVault.keyService — AES-GCM keys
        "com.thuglife.aperture.mnemonic.cipher",   // MnemonicVault.cipherService — encrypted phrases
        "com.thuglife.aperture.mnemonic.key",      // MnemonicVault.keyService — AES-GCM keys
        "com.thuglife.aperture.privatekey.cipher", // MnemonicVault.privateKeyCipherService — encrypted imported key strings
        "com.thuglife.aperture.privatekey.key",    // MnemonicVault.privateKeyKeyService — AES-GCM keys (imported keys)
        "com.thuglife.aperture.wallet-secret.master-key", // WalletSecretCrypto — AES-GCM master key for GRDB secret rows
        "com.thuglife.aperture.wallet-manifest",   // WalletManifestStore.service — wallet list metadata
        "com.thuglife.aperture.pin",               // PinCodeStorage.service — PBKDF2 hash + salt + failure record
        "com.thuglife.aperture.pin.smoketest",     // PinCodeStorage.smokeCheckService — DEBUG smoke check
        "com.thuglife.aperture.chainkey.master",   // ChainKeyVault — AES-GCM master key for per-chain key blobs
    ]

    /// Read-only mirror of `knownServices` for the audit test
    /// (`ResetCompletenessTests`). Never used by production code.
    static var knownServicesForAudit: [String] { knownServices }

    /// One-time destructive transition used by the GRDB replacement build.
    /// It intentionally clears every Aperture-owned Keychain service even
    /// when the app is not a fresh install, because the old GRDB store is
    /// discarded instead of migrated.
    static func purgeAllKnownKeychainServicesForDatabaseReplacement() {
        for serviceName in knownServices {
            for secClass in serviceScopedClasses {
                let query: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecAttrService as String: serviceName,
                ]
                SecItemDelete(query as CFDictionary)
            }
        }
    }

    /// Password classes Aperture writes today. All current vaults use
    /// `kSecClassGenericPassword` with `kSecAttrService`; internet-password
    /// items key service-like identity through different attributes, so adding
    /// that class here produces invalid Keychain queries on simulator/device.
    /// Future key/cert/internet-password vaults must add their own explicit
    /// purge path; this guard does not perform class-wide deletes.
    private static var serviceScopedClasses: [CFString] {
        [kSecClassGenericPassword]
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
        #if DEBUG
        let shouldRespectExistingStore = !ignoresExistingStoreForTesting
        #else
        let shouldRespectExistingStore = true
        #endif
        if shouldRespectExistingStore, hasExistingLocalStore() {
            // An existing GRDB store means this is not a fresh install.
            // Purging Keychain here would orphan encrypted WalletSecretRecord
            // rows from the master key that opens them.
            return false
        }

        log.log("Fresh install detected — purging Keychain items for \(knownServices.count, privacy: .public) known services")

        var deletedCount = 0

        // 1) Password items — deleted PRECISELY, one query per (service, class).
        //    Only password classes accept the `kSecAttrService` match attribute.
        for serviceName in knownServices {
            for secClass in serviceScopedClasses {
                let query: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecAttrService as String: serviceName,
                ]
                let status = SecItemDelete(query as CFDictionary)
                switch status {
                case errSecSuccess:
                    deletedCount += 1
                    log.log("Deleted Keychain items for service \(serviceName, privacy: .public)")
                case errSecItemNotFound:
                    // Nothing stored for this (service, class) — fine.
                    break
                default:
                    // Best-effort: a single failure shouldn't block the rest.
                    log.error("SecItemDelete failed for service \(serviceName, privacy: .public): OSStatus \(status, privacy: .public)")
                }
            }
        }

        #if DEBUG
        ignoresExistingStoreForTesting = false
        #endif
        log.log("Fresh-install Keychain purge complete — \(deletedCount, privacy: .public) entries cleared")
        return true
    }

    private static func hasExistingLocalStore() -> Bool {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            base = appSupport
        } else {
            base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let store = base
            .appendingPathComponent("Aperture", isDirectory: true)
            .appendingPathComponent("aperture.sqlite", isDirectory: false)
        return fm.fileExists(atPath: store.path)
            || fm.fileExists(atPath: store.path + "-wal")
            || fm.fileExists(atPath: store.path + "-shm")
    }

    /// Test-only. Resets the marker so a subsequent
    /// `purgeKeychainIfFreshInstall()` call performs the wipe. Used
    /// by the smoke test below in DEBUG builds.
    #if DEBUG
    static func _resetMarkerForTesting() {
        ignoresExistingStoreForTesting = true
    }
    #endif
}
