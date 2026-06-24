import SwiftUI

/// Cross-view signal for the app shell's **Actions** flow hand-off.
///
/// The Actions button AND its picker sheet live in `MainTabView` (2026-06-24)
/// so the sheet can zoom natively out of the button — `matchedTransitionSource`
/// needs a real SwiftUI source view, which a system tab-bar item can't be on
/// iOS 26 (the zoom never fires from a tab item / `tabViewBottomAccessory`).
/// The Send / Receive / Connect FLOWS still live in `WalletHomeView`.
///
/// When the user taps a tile, `MainTabView` dismisses the picker and — once it
/// has FULLY dismissed (`onDismiss`) — switches to the Wallet tab and bumps
/// `flowToken` carrying the chosen `flow`. `WalletHomeView` observes the token
/// and presents the matching surface. Waiting for the picker to finish
/// dismissing before the flow opens preserves the dismiss-then-present hand-off
/// across the two views (you can't present one sheet while another dismisses).
///
/// A shared `@Observable` singleton — not an environment object — so
/// `WalletHomeView()` needs no init change and there's no missing-environment
/// trap (the same pattern as `TabReselectSignal`).
@MainActor
@Observable
final class WalletShellSignal {
    static let shared = WalletShellSignal()
    private init() {}

    /// The wallet-home flows the Actions sheet can launch.
    enum Flow: Sendable { case send, receive, connect }

    /// The flow the user chose in the Actions picker, read by `WalletHomeView`
    /// when `flowToken` changes.
    private(set) var pendingFlow: Flow?

    /// Bumped (after the Actions picker has fully dismissed) to ask
    /// `WalletHomeView` to open `pendingFlow`.
    private(set) var flowToken: Int = 0

    /// Request a wallet-home flow. The caller must already have switched to the
    /// Wallet tab so `WalletHomeView` is mounted to present it.
    func requestFlow(_ flow: Flow) {
        pendingFlow = flow
        flowToken &+= 1
    }
}
