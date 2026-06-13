import Testing
import Foundation
@testable import Aperture

/// The 2026-06-13 price-scope optimization (user direction: "make
/// syncing maximum faster"). `RealRPCBalanceScanner.uniquePriceSymbols`
/// must scope the price batch to the wallet's HELD tokens in steady
/// state — but never lose a held token's price, and never regress the
/// fresh-wallet first scan.
@Suite struct PriceScopeTests {

    private let ethAddresses: [SupportedChain: String] = [
        .ethereum: "0x057a46b84bf7FD1Cf6EA57F477dD872442A8cE10"
    ]

    @Test("empty priority (fresh wallet) prices the full registry universe")
    func freshWalletPricesFullUniverse() {
        let symbols = Set(RealRPCBalanceScanner.uniquePriceSymbols(
            addresses: ethAddresses,
            customTokens: [:],
            priorityTokenSymbols: []
        ))
        // Native always present.
        #expect(symbols.contains("ETH"))
        // Full universe → many Ethereum registry tokens (USDC, USDT, DAI…).
        #expect(symbols.contains("USDC"))
        #expect(symbols.contains("USDT"))
        // The universe is large (no scoping on a fresh wallet).
        #expect(symbols.count > 10)
    }

    @Test("non-empty priority (steady state) scopes to held + native, dropping the rest")
    func steadyStateScopesToHeld() {
        let symbols = Set(RealRPCBalanceScanner.uniquePriceSymbols(
            addresses: ethAddresses,
            customTokens: [:],
            priorityTokenSymbols: ["USDT"]
        ))
        // Native always present.
        #expect(symbols.contains("ETH"))
        // The held token is priced.
        #expect(symbols.contains("USDT"))
        // An UNHELD registry token (e.g. DAI) is NOT in the scoped batch —
        // this is the speed/load win.
        #expect(!symbols.contains("DAI"))
        // Scoped batch is small: native ticker(s) + the one held token.
        #expect(symbols.count <= 3)
    }

    @Test("held tokens are always in the scoped batch (never 'Price unavailable')")
    func heldTokensAlwaysPriced() {
        let held: Set<String> = ["USDT", "USDC", "WBTC"]
        let symbols = Set(RealRPCBalanceScanner.uniquePriceSymbols(
            addresses: ethAddresses,
            customTokens: [:],
            priorityTokenSymbols: held
        ))
        for token in held {
            #expect(symbols.contains(token), "held \(token) must be priced")
        }
        #expect(symbols.contains("ETH"))
    }
}
