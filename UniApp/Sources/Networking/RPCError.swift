import Foundation

/// Errors thrown by the networking stack.
///
/// `Sendable` so the typed throw crosses actor boundaries cleanly.
/// `Equatable` for tests that pattern-match the kind of failure.
enum RPCError: Error, Sendable, Equatable {
    /// `RPCRegistry.endpoints(for: chain)` returned empty — the
    /// chain has no registered endpoints in this build. UI surfaces
    /// "Not available on this build" for the chain row.
    case noEndpoint(SupportedChain)

    /// Every endpoint for this chain returned a non-recoverable
    /// error or is in circuit-breaker timeout. UI surfaces a chain-
    /// level "Refresh failed — tap to retry" row footer.
    case allEndpointsFailed(SupportedChain)

    /// `URLSession` rejected the request before a response. Common
    /// causes: airplane mode, captive-portal WiFi, DNS failure,
    /// `URLError.cannotConnectToHost` from a flaky public RPC.
    case network(String)

    /// Provider returned HTTP 429 (or equivalent JSON-RPC error
    /// code). The associated `retryAfter` is the absolute time at
    /// which the next call may succeed. The dispatcher's circuit
    /// breaker uses this directly when present.
    case rateLimited(retryAfter: Date)

    /// HTTP 2xx but the body didn't match our expectations (missing
    /// `result` key, unexpected type, etc.).
    case invalidResponse(String)

    /// JSON parse failure on the response body.
    case decodingFailed(String)

    /// JSON-RPC envelope returned `{ "error": { "code": …, "message": … } }`.
    /// Standard codes per JSON-RPC 2.0: `-32700` parse, `-32600`
    /// invalid request, `-32601` method not found, `-32602` invalid
    /// params, `-32603` internal error.
    case rpcError(code: Int, message: String)

    /// All-endpoints request was cancelled by the caller (e.g.
    /// user navigated away from the wallet home mid-refresh).
    case cancelled
}

// MARK: - User-facing description (for the UI footer / banner)

extension RPCError {
    /// Short user-facing label for the chain-row error footer.
    /// Honest about the kind of failure without leaking provider
    /// internals.
    var userFacingLabel: String {
        switch self {
        case .noEndpoint:
            return String.apertureLocalized("Not available on this build")
        case .allEndpointsFailed:
            return String.apertureLocalized("Couldn't reach the chain")
        case .network:
            return String.apertureLocalized("You're offline")
        case .rateLimited:
            return String.apertureLocalized("Rate-limited — try again in a moment")
        case .invalidResponse, .decodingFailed:
            return String.apertureLocalized("Unexpected response")
        case .rpcError:
            return String.apertureLocalized("Chain reported an error")
        case .cancelled:
            return String.apertureLocalized("Cancelled")
        }
    }
}
