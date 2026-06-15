import Foundation

/// Decodable mirror of the OpenOcean v4 `quote` + `swap` responses.
///
/// **Doc-grounded + live-verified 2026-06-16** against the OpenOcean v4
/// API (`https://open-api.openocean.finance/v4/{chainCode}/quote` and
/// `/swap`). The keyless free tier (~1–2 RPS) was curled live for a BSC
/// pair (USDT `0x55d398…7955` → ETH-BEP20 `0x2170ed…f933f8`) for both
/// ERC-20-in and native-in (BNB → USDT) to confirm the exact field names
/// decoded here.
///
/// **Response envelope:** every v4 response is `{ "code": 200, "data": {…} }`.
/// A non-200 `code` (or an HTTP error body) is treated as a provider
/// failure — `OpenOceanClient` never builds a quote from a non-200 code.
///
/// Only the fields Aperture's `SwapQuote` needs are decoded; the rest of
/// the live payload (`dexes`, `rfqDeadline`, `gmxFee`, `blockNumber`,
/// `volume`, …) is ignored.

// MARK: - Quote (GET /{chainCode}/quote)

/// `data` block of the `quote` response. Used for the price leg.
/// Live shape: `data { inToken, outToken, inAmount, outAmount,
/// estimatedGas, dexes, … }`. `estimatedGas` arrives as a JSON STRING on
/// `/quote` (e.g. `"129863"`) — decoded via `FlexibleInt` so the string
/// and the numeric form `/swap` returns both parse.
struct OpenOceanQuoteDTO: Decodable, Sendable {
    let code: Int
    let data: QuoteData?

    struct QuoteData: Decodable, Sendable {
        let inToken: TokenInfo?
        let outToken: TokenInfo?
        let inAmount: String?
        /// Provider raw out-amount (smallest units of the out token).
        let outAmount: String
        /// Gas units estimate. String on `/quote`, number on `/swap`.
        let estimatedGas: FlexibleInt?
    }

    struct TokenInfo: Decodable, Sendable {
        let address: String?
        let symbol: String?
        let name: String?
        let decimals: Int?
        /// USD spot price string (e.g. `"0.999493"`); informational.
        let usd: String?
    }
}

// MARK: - Swap (GET /{chainCode}/swap)

/// `data` block of the `swap` response — the signable transaction.
///
/// Live-verified field names (BSC):
/// - `to`         router contract = `0x6352a56caadC4F1E25CD6c75970Fa768A3304e64`
/// - `data`       ABI-encoded calldata (`0x…`)
/// - `value`      `"0"` for ERC-20-in, the native amount for native-in
/// - `gasPrice`   wei string (e.g. `"1000000000"`)
/// - `estimatedGas` gas-units NUMBER on `/swap` (e.g. `259656`)
/// - `outAmount`  raw expected out
/// - `minOutAmount` raw slippage-protected floor (the guaranteed minimum)
/// - `chainId`    EIP-155 chain id NUMBER (e.g. `56`)
/// - `price_impact` percent string (e.g. `"0.06%"`, can be negative)
struct OpenOceanSwapDTO: Decodable, Sendable {
    let code: Int
    let data: SwapData?

    struct SwapData: Decodable, Sendable {
        let to: String?
        let data: String?
        let value: String?
        let gasPrice: String?
        let estimatedGas: FlexibleInt?
        let outAmount: String?
        let minOutAmount: String?
        let chainId: Int?
        let from: String?
        /// Percent string, e.g. `"0.06%"` or `"-0.01%"`. Optional.
        let price_impact: String?
    }
}

// MARK: - FlexibleInt

/// Decodes an integer that the OpenOcean API returns inconsistently as a
/// JSON number (`/swap`: `"estimatedGas": 259656`) OR a JSON string
/// (`/quote`: `"estimatedGas": "129863"`). Funds-path precision: we keep
/// the underlying integer exactly and re-emit it as a decimal string for
/// the hex gas-limit conversion — never a `Double`.
struct FlexibleInt: Decodable, Sendable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self),
                  let parsed = Int(stringValue) {
            value = parsed
        } else {
            value = 0
        }
    }
}
