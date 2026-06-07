import Foundation

/// A single RPC or REST endpoint Aperture can call against a chain.
///
/// One chain typically has multiple endpoints — a primary plus 1–2
/// fallbacks — registered in `RPCRegistry`. The `RPCClient` selects
/// them in `priority` order and rotates to the next on failure.
///
/// **Rule #3 compliance:** every endpoint is a public URL, no auth
/// header, no third-party SDK. The networking layer talks JSON-RPC
/// or REST via `URLSession`.
///
/// **Rule #16 compliance:** `provider` is surfaced in the UI ("Last
/// synced via publicnode.com 2m ago.") so the user knows whose
/// servers received the read.
struct RPCEndpoint: Sendable, Hashable, Identifiable {
    /// Stable identifier — used as the key for the per-endpoint
    /// rate limiter and circuit breaker. Format:
    /// `<chain>-<provider>-<index>` (e.g. `eth-publicnode-1`).
    let id: String

    /// Endpoint root URL. For JSON-RPC: the URL we POST to. For REST:
    /// the path prefix we append paths under.
    let url: URL

    /// Which protocol the endpoint speaks.
    let kind: Kind

    /// Which chain this endpoint serves.
    let chain: SupportedChain

    /// Provider name — surfaced in `Rule #16` honesty footer.
    /// Examples: `"publicnode"`, `"llamarpc"`, `"cloudflare"`,
    /// `"mempool.space"`, `"ankr"`, `"helius"`, `"solana-foundation"`.
    let provider: String

    /// Documented rate limit per the provider's published terms.
    /// The `RateLimiter` honors this conservatively.
    let rateLimit: RateLimit

    /// Lower = tried first. Primary endpoint typically `0`, first
    /// fallback `1`, second fallback `2`, etc. Ties broken by `weight`.
    let priority: Int

    /// When multiple endpoints share the same `priority`, the
    /// dispatcher round-robins by `weight`. Equal weights → equal
    /// share. Future hatch for load balancing across mirrors.
    let weight: Int

    enum Kind: String, Sendable, Hashable {
        /// Standard JSON-RPC 2.0 envelope:
        /// `{ "jsonrpc": "2.0", "id": 1, "method": "...", "params": [...] }`.
        case jsonRPC
        /// REST — caller appends path segments and reads JSON body.
        case rest
    }

    /// Per-endpoint rate limit description. The `RateLimiter` uses
    /// these to size and refill the per-endpoint token bucket.
    struct RateLimit: Sendable, Hashable {
        /// Sustained request rate in requests-per-second (Double so
        /// fractional rates like 0.5 req/s are expressible).
        let requestsPerSecond: Double

        /// Documented per-minute cap. Used as a sanity guard — if
        /// the per-second math is wrong, the per-minute cap catches
        /// the overshoot.
        let requestsPerMinute: Int

        /// Documented daily cap. `nil` = no daily cap.
        let requestsPerDay: Int?

        /// Token-bucket "burst" size — the bucket starts full and
        /// refills at `requestsPerSecond`. A user opening the wallet
        /// home and scanning 8 chains in parallel can spend the
        /// burst immediately and then be throttled smoothly.
        let burstAllowance: Int

        /// Convenience: a "be conservative" default for endpoints
        /// without published numbers. 5 req/s, 60 burst — slow
        /// enough that no published public endpoint will throttle.
        static let conservative = RateLimit(
            requestsPerSecond: 5,
            requestsPerMinute: 300,
            requestsPerDay: nil,
            burstAllowance: 10
        )

        /// PublicNode's "generous" tier. They publish a soft limit
        /// of ~100 req/s per IP; we cap ourselves at 30 to leave
        /// headroom for other Aperture instances on the same NAT.
        static let publicNode = RateLimit(
            requestsPerSecond: 30,
            requestsPerMinute: 1_800,
            requestsPerDay: nil,
            burstAllowance: 20
        )
    }
}
