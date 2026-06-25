import Foundation

/// One per-chain balance snapshot. `nativeBalance` is in the chain's
/// base unit (e.g. BTC, ETH, SOL — not satoshis/wei/lamports).
///
/// `fiatBalance` is **optional** so the UI can honestly distinguish
/// "zero balance × known price = $0.00" from "I couldn't get the
/// price — `nil`" (Rule #2 §A.7). A `0` fiat is real $0.00; only
/// `nil` triggers the "Price unavailable" row.
struct ChainBalance: Hashable, Sendable {
    let chain: SupportedChain
    let address: String
    let nativeBalance: Decimal
    let fiatBalance: Decimal?         // nil = price genuinely unavailable
    let fiatCurrencyCode: String      // "USD", "EUR", …
    let isUsed: Bool                  // address has > 0 transactions on-chain
    let lastUpdated: Date
}
