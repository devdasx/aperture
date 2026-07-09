import Foundation
import Security
import os.log

/// Wipes Aperture-owned legacy Keychain items on the **first launch after
/// a true app reinstall**.
///
/// **The problem this solves.** iOS Keychain items survive app
/// deletion by default. A user who deletes Aperture and re-installs
/// it from TestFlight / App Store / Xcode sees their previously
/// stored wallet/PIN from old Keychain-backed builds come back because
/// the app sandbox got wiped while Keychain entries survived.
///
/// **The fix.** The current wallet store is GRDB in the app sandbox.
/// The guard keeps a non-secret install marker in both the sandbox and
/// Keychain. On normal upgrades both markers remain. On delete/reinstall
/// the sandbox marker disappears while the Keychain marker survives, so
/// we purge legacy Aperture Keychain services and reset any restored
/// SQLite sidecars before GRDB opens. First launch of a pre-marker build
/// with an existing database is adopted, not wiped.
///
/// **Why this is safe.** The Keychain items we delete are all
/// owned by Aperture (`com.thuglife.aperture.*` services). We do NOT
/// touch Keychain items belonging to other apps; that's structurally
/// impossible because iOS scopes Keychain by app entitlement. We do
/// NOT touch iCloud-synced items because the purge only targets
/// generic-password items in this app's access group with Aperture-owned
/// service names.
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

    private static let installMarkerFileName = ".aperture-install-marker-v1"
    private static let installMarkerService = "com.thuglife.aperture.install-state"
    private static let installMarkerAccount = "current-install"
    private static let ownedServicePrefixes = [
        "com.thuglife.aperture.",
        "com.aperture."
    ]

    /// Every Keychain `kSecAttrService` identifier Aperture writes
    /// under. Adding a new vault later requires adding its service
    /// string here so the fresh-install wipe covers it — a service
    /// missing from this list means wallets RESURRECT after a delete
    /// + reinstall, breaking the user's zero-data contract.
    ///
    /// Legacy service inventory. Current wallet/PIN material is stored
    /// in GRDB, but these names are kept so delete/reinstall cannot
    /// resurrect data from older Keychain-backed builds.
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

    /// One-time destructive transition used by database replacement and
    /// reinstall cleanup. The install marker is intentionally excluded so
    /// a successful first launch can still mark this install after purge.
    @discardableResult
    static func purgeAllKnownKeychainServicesForDatabaseReplacement() -> Int {
        var deletedCount = 0
        for serviceName in knownServices {
            for secClass in serviceScopedClasses {
                let query: [String: Any] = [
                    kSecClass as String: secClass,
                    kSecAttrService as String: serviceName,
                ]
                if SecItemDelete(query as CFDictionary) == errSecSuccess {
                    deletedCount += 1
                }
            }
        }
        deletedCount += purgeUnknownOwnedGenericPasswordServices()
        return deletedCount
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
    /// iff a destructive legacy-Keychain wipe actually ran.
    @discardableResult
    static func purgeKeychainIfFreshInstall() -> Bool {
        #if DEBUG
        let shouldRespectExistingStore = !ignoresExistingStoreForTesting
        #else
        let shouldRespectExistingStore = true
        #endif
        let hasStore = shouldRespectExistingStore && hasExistingLocalStore()
        let hasContainerMarker = hasContainerInstallMarker()
        let hasSurvivingKeychainMarker = hasKeychainInstallMarker()
        let isReinstallAfterMarkedBuild = hasSurvivingKeychainMarker && !hasContainerMarker
        let isFirstLaunchWithoutStore = !hasStore && !hasContainerMarker
        let shouldWipe = isReinstallAfterMarkedBuild || isFirstLaunchWithoutStore

        guard shouldWipe else {
            ensureCurrentInstallMarkers()
            return false
        }

        if isReinstallAfterMarkedBuild {
            try? AppDatabase.resetStoreFiles()
        }

        log.log("Fresh install detected — purging Aperture-owned Keychain items")
        let deletedCount = purgeAllKnownKeychainServicesForDatabaseReplacement()
        ensureCurrentInstallMarkers()

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

    private static func hasContainerInstallMarker() -> Bool {
        guard let marker = installMarkerURL(createDirectory: false) else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private static func ensureCurrentInstallMarkers() {
        if let marker = installMarkerURL(createDirectory: true) {
            _ = FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: nil)
        }
        ensureKeychainInstallMarker()
    }

    private static func installMarkerURL(createDirectory: Bool) -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        ) else { return nil }
        let directory = appSupport.appendingPathComponent("Aperture", isDirectory: true)
        if createDirectory {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(installMarkerFileName, isDirectory: false)
    }

    private static func hasKeychainInstallMarker() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: installMarkerService,
            kSecAttrAccount as String: installMarkerAccount,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func ensureKeychainInstallMarker() {
        guard !hasKeychainInstallMarker() else { return }
        let payload = UUID().uuidString.data(using: .utf8) ?? Data()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: installMarkerService,
            kSecAttrAccount as String: installMarkerAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: payload
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: installMarkerService,
                kSecAttrAccount as String: installMarkerAccount
            ]
            let update: [String: Any] = [
                kSecValueData as String: payload
            ]
            _ = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        } else if status != errSecSuccess {
            log.error("Install marker Keychain write failed: OSStatus \(status, privacy: .public)")
        }
    }

    private static func purgeUnknownOwnedGenericPasswordServices() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            return 0
        }

        var deletedServices = Set<String>()
        for row in rows {
            guard let service = row[kSecAttrService as String] as? String,
                  service != installMarkerService,
                  ownedServicePrefixes.contains(where: { service.hasPrefix($0) }),
                  !deletedServices.contains(service)
            else { continue }

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            if SecItemDelete(deleteQuery as CFDictionary) == errSecSuccess {
                deletedServices.insert(service)
            }
        }
        return deletedServices.count
    }

    /// Test-only. Resets the marker so a subsequent
    /// `purgeKeychainIfFreshInstall()` call performs the wipe. Used
    /// by the smoke test below in DEBUG builds.
    #if DEBUG
    static func _resetMarkerForTesting() {
        ignoresExistingStoreForTesting = true
        if let marker = installMarkerURL(createDirectory: false) {
            try? FileManager.default.removeItem(at: marker)
        }
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: installMarkerService,
            kSecAttrAccount as String: installMarkerAccount
        ]
        _ = SecItemDelete(deleteQuery as CFDictionary)
    }
    #endif
}
