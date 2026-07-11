import Foundation
import Testing
@testable import Aperture

/// BUG-015: balances-only refresh must still price; only history is gated.
@Suite("Wallet refresh mode (BUG-015)")
struct WalletRefreshModeTests {

    @Test("balancesOnly always includes prices and never history")
    func balancesOnlyFlags() {
        let mode = WalletDataRefreshCoordinator.RefreshMode.balancesOnly
        #expect(mode.includesPrices)
        #expect(!mode.includesHistory)
    }

    @Test("full includes prices and history")
    func fullFlags() {
        let mode = WalletDataRefreshCoordinator.RefreshMode.full
        #expect(mode.includesPrices)
        #expect(mode.includesHistory)
    }

    @Test("prices are never mode-gated (regression for $0 fiat flash)")
    func pricesNeverGated() {
        for mode in [
            WalletDataRefreshCoordinator.RefreshMode.balancesOnly,
            .full
        ] {
            #expect(
                mode.includesPrices,
                "\(mode.rawValue) must fetch prices so new balances get fiat"
            )
        }
    }
}
