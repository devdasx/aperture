import Testing
import Foundation
@testable import Aperture

/// Pure-function tests for the pricing pipeline's two fallback maps:
/// `WrappedAssetAliases` (WETH/WBTC/stETH → underlying) and
/// `KnownStablecoins` (off-Coinbase $1-pegged stables → USDT proxy).
/// No network — these are deterministic table lookups, and the
/// table contents are what guards every WETH / WBTC / AUSD / FRAX
/// balance from rendering "Price unavailable" forever.
struct PriceFallbackTests {

    // MARK: - WrappedAssetAliases

    @Test("WETH resolves to ETH for Coinbase pricing")
    func wethAliasesToEth() throws {
        #expect(WrappedAssetAliases.resolveSymbol("WETH") == "ETH")
        #expect(WrappedAssetAliases.resolveSymbol("weth") == "ETH")  // case-insensitive
        #expect(WrappedAssetAliases.resolveSymbol("wEth") == "ETH")
    }

    @Test("WBTC resolves to BTC for Coinbase pricing")
    func wbtcAliasesToBtc() throws {
        #expect(WrappedAssetAliases.resolveSymbol("WBTC") == "BTC")
        #expect(WrappedAssetAliases.resolveSymbol("wbtc") == "BTC")
    }

    @Test("stETH resolves to ETH for Coinbase pricing")
    func stethAliasesToEth() throws {
        #expect(WrappedAssetAliases.resolveSymbol("stETH") == "ETH")
        #expect(WrappedAssetAliases.resolveSymbol("STETH") == "ETH")
        #expect(WrappedAssetAliases.resolveSymbol("steth") == "ETH")
    }

    @Test("Non-wrapped symbol returns itself (uppercased)")
    func nonWrappedReturnsSelf() throws {
        #expect(WrappedAssetAliases.resolveSymbol("USDC") == "USDC")
        #expect(WrappedAssetAliases.resolveSymbol("USDT") == "USDT")
        #expect(WrappedAssetAliases.resolveSymbol("DAI") == "DAI")
        #expect(WrappedAssetAliases.resolveSymbol("ETH") == "ETH")
        #expect(WrappedAssetAliases.resolveSymbol("BTC") == "BTC")
    }

    @Test("Unknown symbol returns itself (uppercased)")
    func unknownSymbolReturnsSelf() throws {
        #expect(WrappedAssetAliases.resolveSymbol("XYZQUUX") == "XYZQUUX")
        #expect(WrappedAssetAliases.resolveSymbol("xyzquux") == "XYZQUUX")
    }

    // MARK: - KnownStablecoins

    @Test(
        "Stablecoins needing USDT fallback are correctly flagged",
        arguments: ["USD0", "USDAI", "USDE", "AUSD", "FRAX", "TUSD", "RLUSD", "USDG", "USDP", "USDD", "FDUSD", "DUSD", "LISUSD"]
    )
    func stablecoinFallback(_ symbol: String) throws {
        #expect(
            KnownStablecoins.needsUSDTFallback(symbol: symbol),
            "\(symbol) should need USDT fallback"
        )
        // Case-insensitive
        #expect(KnownStablecoins.needsUSDTFallback(symbol: symbol.lowercased()))
    }

    @Test(
        "Coinbase-priced stablecoins are in the set (for membership-check purposes) but don't need fallback",
        arguments: ["USDC", "USDT", "DAI", "GUSD", "PYUSD", "USD1", "USDS", "USDF"]
    )
    func directlyPricedStablecoins(_ symbol: String) throws {
        // They're in the set — `all.contains(...)` is what
        // `needsUSDTFallback` checks before excluding USDT itself.
        #expect(
            KnownStablecoins.all.contains(symbol.uppercased()),
            "\(symbol) should be in KnownStablecoins.all"
        )
    }

    @Test("USDT does not proxy to itself")
    func usdtNoSelfProxy() throws {
        #expect(
            !KnownStablecoins.needsUSDTFallback(symbol: "USDT"),
            "USDT should not need USDT fallback"
        )
    }

    @Test("Non-stablecoin is not flagged for USDT fallback")
    func nonStablecoinNoFallback() throws {
        #expect(!KnownStablecoins.needsUSDTFallback(symbol: "ETH"))
        #expect(!KnownStablecoins.needsUSDTFallback(symbol: "BTC"))
        #expect(!KnownStablecoins.needsUSDTFallback(symbol: "SOL"))
        #expect(!KnownStablecoins.needsUSDTFallback(symbol: "WETH"))
        #expect(!KnownStablecoins.needsUSDTFallback(symbol: "WBTC"))
    }

    // MARK: - Sanity: every EVM token resolves via Coinbase OR fallback OR alias

    @Test(
        "Every EVM registry token has a resolvable pricing path",
        arguments: EVMTokenTestCase.all
    )
    func everyEVMTokenIsPriceable(_ tc: EVMTokenTestCase) throws {
        let symbol = tc.entry.symbol.uppercased()
        let aliased = WrappedAssetAliases.resolveSymbol(symbol)
        let isAliased = aliased != symbol
        let needsStableFallback = KnownStablecoins.needsUSDTFallback(symbol: symbol)
        let needsEURFallback = EURPeggedStablecoins.needsEURFallback(symbol: symbol)
        let isDirectlyPriced = KnownStablecoins.all.contains(symbol)
            || symbol == "ETH" || symbol == "BTC" || symbol == "POL"
            || symbol == "BNB" || symbol == "AVAX" || symbol == "CELO"
            || symbol == "KAVA" || symbol == "MATIC"
        #expect(
            isAliased || needsStableFallback || needsEURFallback || isDirectlyPriced,
            "\(tc.label): no pricing path — symbol \(symbol) not in WrappedAssetAliases / KnownStablecoins / EURPeggedStablecoins / direct-Coinbase set"
        )
    }

    @Test(
        "Every Solana registry mint has a resolvable pricing path",
        arguments: SolanaMintTestCase.all
    )
    func everySolanaMintIsPriceable(_ tc: SolanaMintTestCase) throws {
        let symbol = tc.entry.symbol.uppercased()
        let aliased = WrappedAssetAliases.resolveSymbol(symbol)
        let isAliased = aliased != symbol
        let needsStableFallback = KnownStablecoins.needsUSDTFallback(symbol: symbol)
        let needsEURFallback = EURPeggedStablecoins.needsEURFallback(symbol: symbol)
        let isDirectlyPriced = KnownStablecoins.all.contains(symbol)
        #expect(
            isAliased || needsStableFallback || needsEURFallback || isDirectlyPriced,
            "\(tc.label): no pricing path — symbol \(symbol) not in WrappedAssetAliases / KnownStablecoins / EURPeggedStablecoins / direct-Coinbase set"
        )
    }

    // MARK: - EURPeggedStablecoins

    @Test("EURC is flagged for EUR fallback")
    func eurcEURFallback() throws {
        #expect(EURPeggedStablecoins.needsEURFallback(symbol: "EURC"))
        #expect(EURPeggedStablecoins.needsEURFallback(symbol: "eurc"))  // case-insensitive
    }

    @Test("Non-EUR-pegged tokens are not flagged for EUR fallback")
    func nonEURPeggedNoFallback() throws {
        #expect(!EURPeggedStablecoins.needsEURFallback(symbol: "USDC"))
        #expect(!EURPeggedStablecoins.needsEURFallback(symbol: "ETH"))
        #expect(!EURPeggedStablecoins.needsEURFallback(symbol: "EUR"))
    }
}
