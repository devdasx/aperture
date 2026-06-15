import Foundation

/// Decodable mirrors of the KyberSwap Aggregator API responses
/// (`https://aggregator-api.kyberswap.com/{chainSlug}/api/v1/...`).
///
/// **Doc-grounded + live-verified 2026-06-16** against the two-step
/// KyberSwap aggregator flow on Base (0.01 ETH→USDC and 20 USDC→ETH):
/// - `GET /routes` → `code 0`, `data.routeSummary` + `data.routerAddress`.
/// - `POST /route/build` → `code 0`, `data { data (calldata), routerAddress,
///   amountIn, amountOut, gas, transactionValue }`.
///
/// **`routeSummary` is preserved verbatim and re-sent to `/route/build`.**
/// It is arbitrary provider JSON (pool extras, routing internals,
/// checksum) that the build step requires byte-for-byte. Decoding it into
/// a typed shape and re-encoding would risk dropping a field, so the
/// `routeSummary` is captured as a raw `JSONValue` and round-tripped — the
/// only fields read out of it are `amountOut` (the raw out) and
/// `amountInUsd` / `amountOutUsd` (price-impact) via typed accessors on
/// `KyberRouteSummaryView`.

// MARK: - GET /routes

/// `GET /routes` envelope: `{ code, message, data: { routeSummary,
/// routerAddress } }`. `code == 0` means success.
struct KyberRoutesDTO: Decodable, Sendable {
    let code: Int
    let message: String?
    let data: RouteData?

    struct RouteData: Decodable, Sendable {
        /// The opaque route summary — re-sent verbatim to `/route/build`.
        let routeSummary: JSONValue
        /// The router contract for this chain (the `to` of the eventual tx
        /// AND the ERC-20 spender). Allowlist-gated before use.
        let routerAddress: String
    }
}

/// Typed read-only view over the opaque `routeSummary` for the few values
/// the quote builder needs. Constructed from the captured `JSONValue` so
/// the verbatim summary is never lossy-re-decoded.
struct KyberRouteSummaryView: Sendable {
    /// Raw out-amount (smallest unit of `tokenOut`). The route's expected
    /// output — NOT the slippage-protected min (the build calldata enforces
    /// slippage; the honest min is derived in the client).
    let amountOut: String?
    /// USD value of the in-leg (price-impact numerator).
    let amountInUsd: String?
    /// USD value of the out-leg (price-impact denominator).
    let amountOutUsd: String?

    init(_ summary: JSONValue) {
        self.amountOut = summary["amountOut"]?.stringValue
        self.amountInUsd = summary["amountInUsd"]?.stringValue
        self.amountOutUsd = summary["amountOutUsd"]?.stringValue
    }
}

// MARK: - POST /route/build

/// `POST /route/build` envelope: `{ code, message, data: { ... } }`.
/// `code == 0` means success; the `data` block carries the signable tx.
struct KyberBuildDTO: Decodable, Sendable {
    let code: Int
    let message: String?
    let data: BuildData?

    struct BuildData: Decodable, Sendable {
        /// Router contract — the tx `to` and the ERC-20 spender.
        let routerAddress: String
        /// ABI-encoded calldata (hex `0x…`).
        let data: String
        /// Echoed raw in-amount (smallest unit of `tokenIn`).
        let amountIn: String?
        /// Expected raw out-amount after the build (≈ route's amountOut).
        let amountOut: String?
        /// Suggested gas limit (decimal string). The signer may re-estimate.
        let gas: String?
        /// Native value the tx must send: the in-amount for native-in,
        /// `"0"` for ERC-20-in (live-verified 2026-06-16).
        let transactionValue: String?
    }
}

// MARK: - JSONValue (lossless opaque JSON)

/// A minimal, lossless JSON value used to capture `routeSummary` verbatim
/// from `/routes` and re-encode it byte-equivalent into the `/route/build`
/// body. Decodes into a faithful tree (objects, arrays, strings, numbers,
/// bools, null) and re-encodes via `Codable` without dropping unknown
/// fields — the build step requires the full summary, so a typed model
/// would be unsafe (any missing pool/extra field breaks the build).
indirect enum JSONValue: Codable, Sendable {
    case string(String)
    case integer(Int64)
    case uinteger(UInt64)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        // Decode integers LOSSLESSLY (Int64 → UInt64) BEFORE Double: the
        // routeSummary is re-sent verbatim to /route/build, and a Double
        // round-trip corrupts integers > 2^53 nested in pool-extra objects
        // (e.g. sqrtPriceX96, reserves) — which silently drops the KyberSwap
        // racer on those routes. Only true fractional numbers fall to Double.
        } else if let i = try? container.decode(Int64.self) {
            self = .integer(i)
        } else if let u = try? container.decode(UInt64.self) {
            self = .uinteger(u)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):   try container.encode(s)
        case .integer(let i):  try container.encode(i)
        case .uinteger(let u): try container.encode(u)
        case .number(let n):   try container.encode(n)
        case .bool(let b):     try container.encode(b)
        case .object(let o):   try container.encode(o)
        case .array(let a):    try container.encode(a)
        case .null:            try container.encodeNil()
        }
    }

    /// Object-member access (returns `nil` for non-objects / missing keys).
    subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The string form of a scalar leaf — `.string` verbatim, a `.number`
    /// rendered without scientific notation / trailing `.0`. KyberSwap
    /// returns `amountOut` etc. as JSON strings, so `.string` is the path
    /// that fires; `.number` is a defensive fallback.
    var stringValue: String? {
        switch self {
        case .string(let s):
            return s
        case .integer(let i):
            return String(i)
        case .uinteger(let u):
            return String(u)
        case .number(let n):
            // Integer-valued doubles render without a decimal point.
            if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
                return String(Int64(n))
            }
            return String(n)
        default:
            return nil
        }
    }
}
