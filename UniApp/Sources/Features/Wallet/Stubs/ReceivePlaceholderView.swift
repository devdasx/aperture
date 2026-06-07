import SwiftUI

/// **Historical forwarder — no longer in the navigation graph.**
///
/// Receive v2 (2026-06-06) replaced the push-to-Receive navigation
/// destination with a sheet presentation owned by `WalletHomeView`
/// (`isShowingReceive` + `receivePath`). The `.receive` case was
/// removed from `WalletHomeDestination` accordingly.
///
/// This file is retained for one turn so historical references in
/// archived branches don't 404 a grep. It can be deleted in a
/// follow-up clean-up pass.
struct ReceivePlaceholderView: View {
    @State private var path: NavigationPath = NavigationPath()

    var body: some View {
        ReceiveView(navigationPath: $path)
    }
}
