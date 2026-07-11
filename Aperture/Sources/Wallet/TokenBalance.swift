import Foundation

/// One fungible-token balance on a specific chain. Parallel to
/// `ChainBalance` but for ERC-20 / SPL / TRC-20 / etc. tokens rather
/// than the chain's native asset.
///
/// **Honest fiat contract (matches `ChainBalance`).** `fiatBalance`
/// is `Decimal?` — `nil` means "we couldn't price it" (Coinbase
/// returned nil for the symbol AND the USDT stablecoin proxy didn't
/// match), a `Decimal` value (including `0`) means "real converted
/// amount." Renders as "Price unavailable" or `$0.00` accordingly.
struct TokenBalance: Hashable, Sendable, Identifiable {
    let chain: SupportedChain
    let address: String              // user's address on this chain
    let contract: String             // token contract / mint address
    let symbol: String               // "USDC", "USDT", "DAI", …
    let name: String                 // "USD Coin", "Tether USD", …
    let decimals: Int
    /// Token amount in canonical units (e.g. `1000` USDC, not
    /// `1_000_000_000`). Already decoded from raw `balanceOf`.
    let amount: Decimal
    let fiatBalance: Decimal?
    let fiatCurrencyCode: String
    let lastUpdated: Date

    var id: String { "\(chain.rawValue)|\(contract)" }
}
