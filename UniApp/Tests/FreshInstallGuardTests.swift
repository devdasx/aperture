import Testing
import Foundation
import Security
@testable import Aperture

/// Smoke tests for `FreshInstallGuard`. The contract:
///
/// 1. First call after test reset → wipe runs, install markers are recreated, returns `true`.
/// 2. Second call with markers present → wipe SKIPPED, returns `false`.
/// 3. After explicit `_resetMarkerForTesting()` → next call wipes again.
///
/// The suite is serialized because each test mutates the same install
/// marker and Keychain namespace. Most tests verify the marker-state
/// machine; one fixture adds an unlisted generic-password item and
/// verifies fresh-install cleanup removes it.
@Suite(.serialized)
struct FreshInstallGuardTests {

    /// Each test starts with install markers reset so the FIRST call
    /// inside the test sees a "fresh install" state regardless of how
    /// the host process left things.
    init() {
        FreshInstallGuard._resetMarkerForTesting()
    }

    @Test("First call wipes; second call no-ops")
    func firstCallWipesSecondNoOps() throws {
        var storeResetCount = 0
        FreshInstallGuard._setStoreResetHookForTesting {
            storeResetCount += 1
        }
        defer { FreshInstallGuard._setStoreResetHookForTesting(nil) }

        let firstResult = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(firstResult == true, "Fresh install (no marker) should return true on first wipe")
        #expect(storeResetCount == 1, "Fresh install must reset SQLite files before GRDB opens")

        let secondResult = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(secondResult == false, "Subsequent call (marker present) should be a no-op")
        #expect(storeResetCount == 1, "Marker-present launches must not reset SQLite again")
    }

    @Test("Resetting the marker re-arms the wipe")
    func resetReArmsTheWipe() throws {
        var storeResetCount = 0
        FreshInstallGuard._setStoreResetHookForTesting {
            storeResetCount += 1
        }
        defer { FreshInstallGuard._setStoreResetHookForTesting(nil) }

        _ = FreshInstallGuard.purgeKeychainIfFreshInstall()  // first wipe, sets marker
        let beforeReset = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(beforeReset == false, "Marker should be set after first wipe")
        #expect(storeResetCount == 1)

        FreshInstallGuard._resetMarkerForTesting()
        FreshInstallGuard._setStoreResetHookForTesting {
            storeResetCount += 1
        }

        let afterReset = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(afterReset == true, "After marker reset, next call should wipe again")
        #expect(storeResetCount == 2, "Resetting the sandbox marker should re-arm SQLite reset")
    }

    @Test("Idempotent: calling multiple times after marker set always returns false")
    func idempotentAfterMarkerSet() throws {
        var storeResetCount = 0
        FreshInstallGuard._setStoreResetHookForTesting {
            storeResetCount += 1
        }
        defer { FreshInstallGuard._setStoreResetHookForTesting(nil) }

        _ = FreshInstallGuard.purgeKeychainIfFreshInstall()
        for _ in 0..<5 {
            #expect(FreshInstallGuard.purgeKeychainIfFreshInstall() == false)
        }
        #expect(storeResetCount == 1)
    }

    @Test("Fresh install purge removes unlisted generic password items")
    func removesUnlistedGenericPasswordItems() throws {
        let service = "com.thuglife.aperture.test.unlisted.\(UUID().uuidString)"
        let account = "fixture"
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(keychainQuery as CFDictionary)
        defer { SecItemDelete(keychainQuery as CFDictionary) }

        var addQuery = keychainQuery
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = Data([1, 2, 3])
        #expect(SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess)
        #expect(SecItemCopyMatching(keychainQuery as CFDictionary, nil) == errSecSuccess)

        var storeResetCount = 0
        FreshInstallGuard._setStoreResetHookForTesting {
            storeResetCount += 1
        }
        defer { FreshInstallGuard._setStoreResetHookForTesting(nil) }

        let didWipe = FreshInstallGuard.purgeKeychainIfFreshInstall()

        #expect(didWipe == true)
        #expect(storeResetCount == 1)
        #expect(SecItemCopyMatching(keychainQuery as CFDictionary, nil) == errSecItemNotFound)
    }
}
