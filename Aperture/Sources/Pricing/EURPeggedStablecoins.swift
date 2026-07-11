import Foundation

/// Curated set of euro-pegged stablecoin tickers Aperture ships.
/// Companion to `KnownStablecoins` (USD-pegged) — same shape, same
/// honesty bound, but the fallback is `EUR-{fiat}` spot instead of
/// `USDT-{fiat}`.
///
/// **The bug this fixes.** Aperture's `EVMTokenRegistry` ships EURC
/// on Ethereum, Base, Avalanche (3 EVM entries) and
/// `SolanaTokenRegistry` ships it on Solana (1 mint). EURC is
/// Circle's EUR-backed stablecoin — its honest price is the spot of
/// 1 EUR in whatever fiat the user is viewing. Without this map,
/// `CoinbasePriceService.fetchSpot("EURC", "USD")` returned `nil`
/// (Coinbase doesn't quote EURC-USD directly) and EURC silently
/// rendered "Price unavailable" forever — the same shape as the
/// pre-2026-06-12 WETH/WBTC/stETH miss.
///
/// **Honesty (Rule #16 §A.6 + Rule #2 §A.7).** EURC is 1:1
/// backed by EUR in Circle reserves and has tracked EUR within ≤ 1%
/// at all times since launch. Using `EUR-USD` (or `EUR-{fiat}`)
/// spot is an honest approximation — the same approximation
/// `WrappedAssetAliases` uses for WETH → ETH spot, and the same the
/// USDT-fallback uses for $1 stablecoins. The risk of a EURC depeg
/// is the same risk class as a USDT depeg; surfacing the
/// approximation is honest and surfacing "Price unavailable" is
/// not.
///
/// **What does NOT alias here.** Native EUR-priced tokens (not
/// applicable to Aperture). Other fiat-pegged stables that aren't
/// 1:1 EUR-backed (BRL-pegged, etc. — none in the registry today).
/// USD-pegged stables use `KnownStablecoins` instead.
enum EURPeggedStablecoins {

    /// Every EUR-pegged stablecoin Aperture is aware of. Today: EURC
    /// only — the registry has no others. Adding a new one (e.g.,
    /// agEUR if it ever ships in Aperture) is one line + a one-line
    /// rationale comment.
    static let all: Set<String> = [
        "EURC",
    ]

    /// Returns `true` if the symbol is a EUR-pegged stablecoin and
    /// `EUR-{fiat}` spot is the honest fallback.
    static func needsEURFallback(symbol: String) -> Bool {
        all.contains(symbol.uppercased())
    }

    /// The proxy symbol the pricing layer asks Coinbase for when a
    /// EUR-pegged stable doesn't quote directly. Coinbase publishes
    /// `EUR-USD`, `EUR-GBP`, etc., so this maps to the user's fiat
    /// without an extra hop.
    static let fallbackSymbol = "EUR"
}
