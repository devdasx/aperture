import SwiftUI

/// Cross-view signal for the custom (1inch-style) app shell.
///
/// The bottom bar's centre **Actions** FAB lives in `MainTabView`, but the
/// Send / Receive / Swap / Connect flows it triggers live in `WalletHomeView`
/// (where they always have). Rather than hoist those flows up to the shell,
/// the FAB switches to the Wallet tab and bumps `openActionsToken`;
/// `WalletHomeView` observes it and presents the `WalletActionsSheet`. A shared
/// `@Observable` singleton — not an environment object — so `WalletHomeView()`
/// needs no init change and there is no missing-environment trap (the same
/// pattern as `TabReselectSignal`).
@MainActor
@Observable
final class WalletShellSignal {
    static let shared = WalletShellSignal()
    private init() {}

    /// Bumped when the Actions FAB is tapped. `WalletHomeView` opens the
    /// Actions sheet in reaction.
    var openActionsToken: Int = 0

    /// Ask the wallet home to open the Actions sheet, switching tab first is
    /// the caller's job.
    func requestActions() {
        openActionsToken &+= 1
    }
}
