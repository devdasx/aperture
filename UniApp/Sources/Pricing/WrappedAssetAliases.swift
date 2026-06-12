import Foundation

/// Symbol aliases for wrapped / liquid-staked variants whose price is
/// honestly approximated by their underlying — `WETH → ETH`,
/// `WBTC → BTC`, `stETH → ETH`, etc.
///
/// **Why this exists (the bug it fixes).** Coinbase Spot publishes
/// pairs for ETH, BTC, SOL, and the major L1s — but NOT for the
/// wrapped or staked variants Aperture's `EVMTokenRegistry` ships
/// (WETH on 6 EVM chains, WBTC on 5, stETH on Ethereum, plus their
/// `SolanaTokenRegistry` counterparts). Without an alias, every WETH
/// / WBTC / stETH balance rendered as "Price unavailable" forever —
/// per `KnownStablecoins.swift` line 21, the placeholder for this
/// map had been documented since the registries first landed.
///
/// **Honesty (Rule #16 §A.7).** Wrapped 1:1 backings are a real
/// approximation, not a fabrication — WETH IS ETH wrapped, WBTC IS
/// BTC custodied. The footer convention `≈ $…` (per
/// `BalanceFormatter.fiat(_:currencyCode:)`) signals the user that
/// the fiat is an approximation, which it already is for any spot
/// price. The risk of depeg is exactly the same risk profile as the
/// existing `KnownStablecoins → USDT` fallback for stablecoins
/// Coinbase doesn't quote — we tolerate it for the same reason: the
/// alternative is a wall of "Price unavailable" rows that read
/// worse than an approximate value.
///
/// **What does NOT alias.** Native chain coins (their tickers are
/// already what Coinbase publishes). Stablecoins (handled by
/// `KnownStablecoins`). Tokens whose price is materially different
/// from their underlying (e.g. a liquid-staking derivative trading
/// at a steep discount — but stETH on Ethereum has historically
/// stayed within ±1% of ETH, which is the same honesty bound as
/// USDT vs USD). Any new alias should land with a one-line note
/// here explaining why the approximation holds.
enum WrappedAssetAliases {

    /// `<wrappedSymbol> → <underlyingSymbol>` map. Keys are
    /// uppercased; the pricing layer also uppercases before
    /// lookup so `WETH` / `wETH` / `weth` all resolve identically.
    ///
    /// **The set today.**
    /// - `WETH → ETH`: ERC-20 Wrapped Ether. Aperture ships it on
    ///   Ethereum / Arbitrum / Base / Optimism / Polygon / BNB
    ///   Chain / Avalanche / Solana. 1:1 backed by ETH in the
    ///   canonical WETH9 contract; the only meaningful depeg risk
    ///   is contract failure, which has not happened in WETH9's
    ///   history.
    /// - `WBTC → BTC`: Wrapped Bitcoin custodied by BitGo. Aperture
    ///   ships it on Ethereum / Arbitrum / Optimism / Avalanche /
    ///   Solana / TRON. Trades within ±1-2% of BTC; brief depegs
    ///   under custodian-credibility events (2024 BitGo
    ///   restructuring) but recovers; honest "≈" mark on the fiat
    ///   row is the right register.
    /// - `STETH → ETH`: Lido's liquid-staked ETH. Aperture ships
    ///   it on Ethereum. Rebases daily to track ETH 1:1, with the
    ///   wrapped variant (wstETH, which we don't ship) being the
    ///   non-rebasing alternative. Spot has stayed within ±1% of
    ///   ETH since the merge.
    static let aliases: [String: String] = [
        "WETH":  "ETH",
        "WBTC":  "BTC",
        "STETH": "ETH",
    ]

    /// Returns the underlying ticker for `symbol` if `symbol` is a
    /// known wrapped/staked variant, else returns `symbol`
    /// uppercased (no-op). Pricing pipeline calls this BEFORE the
    /// Coinbase fetch so the wrapped symbol resolves through its
    /// underlying's spot. Same shape as `KnownStablecoins.needsUSDTFallback`
    /// — one tiny lookup, no allocations.
    static func resolveSymbol(_ symbol: String) -> String {
        let upper = symbol.uppercased()
        return aliases[upper] ?? upper
    }
}
