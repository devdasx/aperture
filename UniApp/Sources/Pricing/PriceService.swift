import Foundation

/// A spot price quote for a single token at a moment in time.
struct TokenPrice: Equatable, Sendable {
    /// The token's ticker (`BTC`, `ETH`, `USDC`, …).
    let symbol: String
    /// The fiat ISO-4217 code the price is denominated in.
    let fiat: String
    /// The spot price.
    let amount: Decimal
    /// The moment the price was fetched (server-side responses don't
    /// timestamp; we stamp on receipt).
    let timestamp: Date
}

/// One of the four reasons a price lookup can fail.
enum PriceError: Error, Sendable, Equatable {
    /// Coinbase responded `404` or returned no `data.amount` — the pair
    /// is not listed. Surface to UI as "Price unavailable".
    case unsupportedPair(symbol: String, fiat: String)
    /// Coinbase responded with a non-200 status code that isn't a 404.
    case server(status: Int)
    /// The network call failed entirely (offline, DNS, etc.).
    case network(message: String)
    /// The response body didn't parse as expected JSON.
    case decoding(message: String)
}

/// Protocol the UI consumes for token prices. UI never imports a concrete
/// price provider; it consumes this protocol. (Rule #3 — UI lives behind a
/// local abstraction; only the data layer touches network SDKs.)
protocol PriceService: Sendable {
    /// Fetch the spot price for a single `(symbol, fiat)` pair.
    /// Returns `nil` for unsupported pairs (so the UI can show "Price
    /// unavailable" without try/catch ceremony).
    func price(symbol: String, fiat: String) async -> TokenPrice?

    /// Batch fetch — returns a `[symbol: TokenPrice]` map containing only
    /// the symbols that resolved successfully. Symbols not present in the
    /// map are unsupported / failed.
    func prices(symbols: [String], fiat: String) async -> [String: TokenPrice]
}
