import Testing
import Foundation
import Security
@testable import Aperture

/// Smoke tests for `FreshInstallGuard`. The contract:
///
/// 1. First call (marker absent) → wipe runs, marker set, returns `true`.
/// 2. Second call (marker present) → wipe SKIPPED, returns `false`.
/// 3. After explicit `_resetMarkerForTesting()` → next call wipes again.
///
/// These do not (and cannot) assert that Keychain is empty afterward
/// because the test bundle's Keychain access group is the same as the
/// host app's; an integration test would risk wiping data a parallel
/// dev session is using. Instead we verify the marker-state state
/// machine — which is the load-bearing property — and trust the
/// underlying `SecItemDelete` to do its job (it's an Apple API
/// already validated for two decades).
struct FreshInstallGuardTests {

    /// Each test starts with the marker reset so the FIRST call inside
    /// the test sees a "fresh install" state regardless of how the
    /// host process left things.
    init() {
        FreshInstallGuard._resetMarkerForTesting()
    }

    @Test("First call wipes; second call no-ops")
    func firstCallWipesSecondNoOps() throws {
        let firstResult = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(firstResult == true, "Fresh install (no marker) should return true on first wipe")

        let secondResult = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(secondResult == false, "Subsequent call (marker present) should be a no-op")
    }

    @Test("Resetting the marker re-arms the wipe")
    func resetReArmsTheWipe() throws {
        _ = FreshInstallGuard.purgeKeychainIfFreshInstall()  // first wipe, sets marker
        let beforeReset = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(beforeReset == false, "Marker should be set after first wipe")

        FreshInstallGuard._resetMarkerForTesting()

        let afterReset = FreshInstallGuard.purgeKeychainIfFreshInstall()
        #expect(afterReset == true, "After marker reset, next call should wipe again")
    }

    @Test("Idempotent: calling multiple times after marker set always returns false")
    func idempotentAfterMarkerSet() throws {
        _ = FreshInstallGuard.purgeKeychainIfFreshInstall()
        for _ in 0..<5 {
            #expect(FreshInstallGuard.purgeKeychainIfFreshInstall() == false)
        }
    }
}
