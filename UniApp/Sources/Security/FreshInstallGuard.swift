import Foundation
import Security
import os.log

/// Wipes Aperture-owned persisted state on the **first launch after a true app
/// reinstall**.
///
/// **The problem this solves.** iOS Keychain items survive app
/// deletion by default. A user who deletes Aperture and re-installs
/// it from TestFlight / App Store / Xcode sees their previously
/// stored wallet/PIN from old Keychain-backed builds come back because
/// the app sandbox got wiped while Keychain entries survived.
///
/// **The fix.** The current wallet store is GRDB in the app sandbox. The guard
/// keeps a non-secret install marker in the sandbox. On delete/reinstall the
/// sandbox marker disappears, so we reset any SQLite sidecars and purge
/// Aperture-accessible Keychain generic-password items before GRDB opens. This
/// deliberately treats a missing sandbox marker as a zero-data install even if
/// iOS or a local restore left some files behind.
///
/// **Why this is safe.** The Keychain items we delete are visible only to this
/// app's Keychain access group. We do NOT touch Keychain items belonging to
/// other apps; iOS scopes those away from this process. The purge covers both
/// local and synchronizable generic-password items so a delete/reinstall cannot
/// resurrect data from iCloud Keychain either.
///
/// **Where this runs.** Synchronously from `UniAppApp.init()` BEFORE
/// any other subsystem touches Keychain — before
/// `AppDatabase.shared.bootstrap()`, before
/// `CurrencyPreference.bootstrapIfNeeded()`, before any vault read.
/// This guarantees a fresh install starts from a known-empty
/// state across every storage tier.
enum FreshInstallGuard {

    #if DEBUG
    nonisolated(unsafe) private static var storeResetHookForTesting: (() throws -> Void)?
    #endif

    private static let installMarkerFileName = ".aperture-install-marker-v1"
    private static let installMarkerService = "com.thuglife.aperture.install-state"
    private static let installMarkerAccount = "current-install"

    /// Every Keychain `kSecAttrService` identifier Aperture writes
    /// under. Kept for audit visibility and targeted database-replacement
    /// cleanup; fresh-install cleanup also enumerates every other generic
    /// password item visible to this app so an unlisted legacy service cannot
    /// resurrect wallets after delete + reinstall.
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
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                ]
                if SecItemDelete(query as CFDictionary) == errSecSuccess {
                    deletedCount += 1
                }
            }
        }
        deletedCount += purgeAllOtherGenericPasswordItems()
        return deletedCount
    }

    /// Password classes Aperture writes today. All current vaults use
    /// `kSecClassGenericPassword` with `kSecAttrService`; internet-password
    /// items key service-like identity through different attributes, so adding
    /// that class here produces invalid Keychain queries on simulator/device.
    /// Future key/cert/internet-password vaults must add their own explicit
    /// purge path.
    private static var serviceScopedClasses: [CFString] {
        [kSecClassGenericPassword]
    }

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "FreshInstallGuard"
    )

    /// Idempotent. Call once from `UniAppApp.init()`. Returns `true`
    /// iff a destructive fresh-install wipe actually ran.
    @discardableResult
    static func purgeKeychainIfFreshInstall() -> Bool {
        let hasContainerMarker = hasContainerInstallMarker()
        guard !hasContainerMarker else {
            ensureCurrentInstallMarkers()
            return false
        }

        do {
            try resetStoreFilesForFreshInstall()
        } catch {
            log.error("Fresh-install SQLite reset failed: \(String(describing: error), privacy: .public)")
        }

        log.log("Fresh install detected — resetting Aperture local data")
        let deletedCount = purgeAllKnownKeychainServicesForDatabaseReplacement()
        ensureCurrentInstallMarkers()

        log.log("Fresh-install cleanup complete — \(deletedCount, privacy: .public) Keychain entries cleared")
        return true
    }

    private static func resetStoreFilesForFreshInstall() throws {
        #if DEBUG
        if let storeResetHookForTesting {
            try storeResetHookForTesting()
            return
        }
        #endif
        try AppDatabase.resetStoreFiles()
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

    private static func purgeAllOtherGenericPasswordItems() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            return 0
        }

        var deletedItems = 0
        for row in rows {
            let service = row[kSecAttrService as String] as? String
            guard service != installMarkerService else { continue }

            var deleteQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
            if let service { deleteQuery[kSecAttrService as String] = service }
            if let account = row[kSecAttrAccount as String] as? String {
                deleteQuery[kSecAttrAccount as String] = account
            }
            if let accessGroup = row[kSecAttrAccessGroup as String] as? String {
                deleteQuery[kSecAttrAccessGroup as String] = accessGroup
            }
            deleteQuery[kSecAttrSynchronizable as String] =
                row[kSecAttrSynchronizable as String] ?? kSecAttrSynchronizableAny

            if SecItemDelete(deleteQuery as CFDictionary) == errSecSuccess {
                deletedItems += 1
            }
        }
        return deletedItems
    }

    /// Test-only. Resets the marker so a subsequent
    /// `purgeKeychainIfFreshInstall()` call performs the wipe. Used
    /// by the smoke test below in DEBUG builds.
    #if DEBUG
    static func _resetMarkerForTesting() {
        storeResetHookForTesting = nil
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

    static func _setStoreResetHookForTesting(_ hook: (() throws -> Void)?) {
        storeResetHookForTesting = hook
    }
    #endif
}
