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

extension RPCError {
    /// `true` when `error` is an HTTP 404 surfaced as `.invalidResponse`.
    /// For account-based chains (Stellar Horizon, Tron) a 404 on the
    /// account path means the account has never been funded — the normal
    /// "zero balance / no history" state, NOT an error worth alarming
    /// about. Callers treat it as an empty result and log it quietly.
    /// Static + takes `any Error` so it works in untyped `catch` blocks
    /// without a needless conditional cast.
    static func isHTTPNotFound(_ error: any Error) -> Bool {
        guard let rpc = error as? RPCError,
              case .invalidResponse(let message) = rpc else { return false }
        return message.contains("HTTP 404")
    }

    /// `true` when `error` is a cancellation, not a real failure. A per-chain
    /// `withTimeout` elapsing, a superseded pull-to-refresh, or the user
    /// navigating away mid-refresh all cancel the in-flight fetch — the data
    /// is simply unchanged this cycle and the next refresh retries. Callers
    /// must NOT log this as a failure (it spammed the console with e.g.
    /// "Transaction fetch failed … : cancelled", Rule #16 honesty) nor surface
    /// a chain-row error. Catches our own `.cancelled`, Swift's
    /// `CancellationError`, and `URLError.cancelled` from a cancelled
    /// URLSession task.
    static func isCancellation(_ error: any Error) -> Bool {
        if let rpc = error as? RPCError, case .cancelled = rpc { return true }
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }
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
