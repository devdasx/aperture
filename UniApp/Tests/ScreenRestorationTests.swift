import Testing
import Foundation
@testable import Aperture

/// Regression tests for the 2026-06-14 "app cold-launches straight onto
/// the Activity screen" bug. The wallet-home restoration mirror can
/// legitimately end up holding a deep stack topped by `.allActivity`
/// (the user taps "View all", then leaves the Wallet tab via the tab
/// bar, or iOS kills the app while that tab still has Activity pushed).
/// The fix makes the stack typed + inspectable and refuses to re-open
/// transient list/action screens on a fresh launch:
/// `ScreenRestoration.restoredWalletHomeStack()` truncates at the first
/// non-`isColdLaunchRestorable` destination. These tests lock that
/// contract so the app can only ever resume onto a real "where I was
/// reading" screen — never the Activity list, Send, or Swap.
@Suite @MainActor struct ScreenRestorationTests {

    /// Matches `ScreenRestoration.Key.walletHomePath` (which is private).
    private let walletHomeKey = "restoration.walletHomePath"

    private func clearMirror() {
        UserDefaults.standard.removeObject(forKey: walletHomeKey)
    }

    @Test("Transient screens are not cold-launch restorable; reading screens are")
    func restorabilityPolicy() {
        // Transient: list browse + in-progress action flows.
        #expect(WalletHomeDestination.allActivity.isColdLaunchRestorable == false)
        #expect(WalletHomeDestination.send.isColdLaunchRestorable == false)
        #expect(WalletHomeDestination.swap.isColdLaunchRestorable == false)
        // Reading: genuine "where I was" content.
        #expect(WalletHomeDestination.allSupported.isColdLaunchRestorable == true)
        #expect(WalletHomeDestination.transaction(UUID()).isColdLaunchRestorable == true)
    }

    @Test("A saved stack ending in Activity restores WITHOUT Activity")
    func dropsTrailingActivity() {
        clearMirror()
        ScreenRestoration.saveWalletHomeStack([.allSupported, .allActivity])
        #expect(ScreenRestoration.restoredWalletHomeStack() == [.allSupported])
        clearMirror()
    }

    @Test("A saved stack of only Activity restores to root (the home screen)")
    func activityOnlyRestoresToRoot() {
        clearMirror()
        ScreenRestoration.saveWalletHomeStack([.allActivity])
        #expect(ScreenRestoration.restoredWalletHomeStack().isEmpty)
        clearMirror()
    }

    @Test("A reading-screen stack round-trips intact")
    func readingScreensRestore() {
        clearMirror()
        ScreenRestoration.saveWalletHomeStack([.allSupported])
        #expect(ScreenRestoration.restoredWalletHomeStack() == [.allSupported])
        clearMirror()
    }

    @Test("No mirror present restores to root")
    func emptyMirrorRestoresToRoot() {
        clearMirror()
        #expect(ScreenRestoration.restoredWalletHomeStack().isEmpty)
    }
}
