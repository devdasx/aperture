import Foundation

/// Curated set of dollar-pegged stablecoin tickers we ship alongside
/// the 24 supported chains' tokens. Used by the pricing layer to
/// decide whether a Coinbase "no spot price" response should fall
/// back to USDT (`~$1`) instead of surfacing "Price unavailable".
///
/// **Why a curated list (not "anything starting with USD").** A
/// non-stablecoin token whose ticker happens to start with `USD`
/// (e.g. a wrapped governance token, a hypothetical
/// "USD Coin Killer DAO") would silently inherit ~$1 if we matched
/// on prefix — a Rule #2 §A.7 honesty violation. The list is
/// explicit. Adding a new stablecoin is one line + a SHIPPED.md
/// entry; the cost is small and the safety is real.
///
/// Source: `docs/coinbase-coverage.txt` audited 2026-06-06. Tokens
/// marked `OK` in that file (USDC, USDT, DAI, GUSD, PYUSD, USD1,
/// USDS, USDf) get their real Coinbase spot. Tokens marked `NO`
/// (USD0, USDai, USDe, AUSD, FRAX, TUSD, RLUSD, USDG, USDP, USDD,
/// FDUSD, DUSD, lisUSD) need the USDT proxy — they're listed here.
/// Wrapped-asset proxies like WBTC → BTC, WETH → ETH belong in a
/// separate map (`WrappedAssetAliases`) when those tokens land.
enum KnownStablecoins {

    /// Every USD-pegged stablecoin Aperture is aware of. Used for
    /// fallback eligibility — Coinbase-priced ones (USDC, USDT, DAI,
    /// …) get their real spot first; only when Coinbase returns
    /// `nil` does the USDT proxy kick in.
    static let all: Set<String> = [
        // Already covered by Coinbase (kept in the set so the
        // service can answer "is this a stablecoin?" honestly even
        // when it doesn't need the fallback).
        "USDC", "USDT", "DAI", "GUSD", "PYUSD", "USD1", "USDS", "USDF",
        // Not covered by Coinbase — these are the fallback target.
        "USD0", "USDAI", "USDE", "AUSD", "FRAX", "TUSD", "RLUSD",
        "USDG", "USDP", "USDD", "FDUSD", "DUSD", "LISUSD",
    ]

    /// Returns `true` if the symbol is a stablecoin and a USDT proxy
    /// is the honest fallback when Coinbase doesn't quote it.
    /// Excludes USDT itself (no point proxying USDT → USDT).
    static func needsUSDTFallback(symbol: String) -> Bool {
        let s = symbol.uppercased()
        guard s != "USDT" else { return false }
        return all.contains(s)
    }

    /// The symbol the pricing layer asks Coinbase for when a known
    /// stablecoin returns no direct spot. USDT is the canonical
    /// "$1 with off-peg risk" stand-in — same risk profile as the
    /// stablecoin we couldn't verify.
    static let fallbackSymbol = "USDT"
}
