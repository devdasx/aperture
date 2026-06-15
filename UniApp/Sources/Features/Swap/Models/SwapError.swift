import Foundation

/// Typed, honest errors the swap quote engine throws. Every case has a
/// user-facing English message (Rule #9 — English literals, no
/// `Localizable.xcstrings` edits this turn). The engine NEVER returns a
/// fabricated quote on failure — it throws one of these so the UI shows
/// the honest state (Rule #16 / Rule #24 / Rule #26).
enum SwapError: Error, Sendable, Equatable {
    /// `Secrets.hasLifiKey == false` — the Li.Fi key isn't configured,
    /// so EVM/cross-chain quotes are unavailable. Solana→Solana
    /// (Jupiter, keyless) still works. Honest gate per `Secrets.swift`.
    case notConfigured
    /// The from/to chain or token pair isn't supported by any provider
    /// (e.g. an EVM chain Li.Fi doesn't index, or a non-EVM/non-Solana
    /// chain). The associated string names what was unsupported.
    case unsupportedPair(String)
    /// No route exists for this pair/amount (Li.Fi 404 / empty routes,
    /// Jupiter no route). Try a different amount or token.
    case noRoute
    /// Liquidity too thin to fill the requested size.
    case insufficientLiquidity
    /// The amount is below the provider's minimum (dust).
    case amountTooSmall
    /// The router/spender the quote would route funds through is NOT on
    /// the allowlist — refused for safety (ported from Stabro's
    /// `RouterAllowlist`). The associated string is the rejected address.
    case untrustedRouter(String)
    /// Transport-level failure (offline, DNS, TLS, timeout). Associated
    /// string is a short, non-leaking detail.
    case network(String)
    /// Provider returned an HTTP error we couldn't map to a cleaner case.
    case provider(status: Int, message: String)
    /// Response body didn't match the documented shape (missing
    /// `estimate.toAmount`, malformed JSON, etc.).
    case invalidResponse(String)
    /// The caller cancelled (user changed the amount mid-quote — the UI
    /// debounces and re-quotes). Not surfaced as an error to the user.
    case cancelled
    /// A cross-chain BRIDGE where the wallet has no receiving address on
    /// the destination chain. Blocking this is fund-safety: without the
    /// wallet's own dest-chain address the provider would default the
    /// receiver to the SOURCE address — harmless for EVM→EVM (same 0x
    /// address) but a cross-family bridge (EVM↔Solana) would send the
    /// bridged funds to a wrong-format address = loss. The associated
    /// string is the destination chain's display name.
    case noReceivingAddress(String)

    /// Honest, user-facing English message (Rule #9 / Rule #16).
    var message: String {
        switch self {
        case .notConfigured:
            return "Swap isn't available right now. The swap service isn't configured."
        case .unsupportedPair(let detail):
            return "This pair can't be swapped: \(detail)."
        case .noRoute:
            return "No swap route found for this pair. Try a different amount or token."
        case .insufficientLiquidity:
            return "Not enough liquidity for this swap. Try a smaller amount."
        case .amountTooSmall:
            return "This amount is too small to swap. Try a larger amount."
        case .untrustedRouter(let address):
            return "This route was refused for safety — its router (\(address)) isn't recognized."
        case .network(let detail):
            return "Network error: \(detail)"
        case .provider(let status, let message):
            return "The swap service returned an error (\(status)): \(message)"
        case .invalidResponse(let detail):
            return "Received an unexpected response from the swap service: \(detail)"
        case .cancelled:
            return "Quote cancelled."
        case .noReceivingAddress(let chain):
            return "This wallet has no \(chain) address to receive the bridged funds yet."
        }
    }
}

// MARK: - Body-pattern mapping

extension SwapError {
    /// Maps a provider HTTP error (status + raw body) to the cleanest
    /// typed case. Mirrors Stabro's `SwapErrorMapper.matchBodyPattern`
    /// — scans the body for known phrases regardless of status code,
    /// because Li.Fi returns 404 for "no route" but 400 for several
    /// other distinct conditions.
    static func from(status: Int, body: String) -> SwapError {
        let lower = body.lowercased()

        if lower.contains("no route") || lower.contains("no routes")
            || lower.contains("unable to find a quote") || lower.contains("no path")
            || lower.contains("no quote") {
            return .noRoute
        }
        if lower.contains("insufficient liquidity") || lower.contains("not enough liquidity") {
            return .insufficientLiquidity
        }
        if lower.contains("amount too low") || lower.contains("below minimum")
            || lower.contains("minimum amount") || lower.contains("amount is too small")
            || lower.contains("dust") {
            return .amountTooSmall
        }
        if lower.contains("could not find token") || lower.contains("token not found")
            || lower.contains("unknown token") || lower.contains("not supported") {
            return .unsupportedPair("token not supported on this network")
        }

        switch status {
        case 400, 422:
            // Li.Fi/Jupiter return 400 with a body for most quote-shape
            // problems; if no pattern matched it's a no-route in practice.
            return .noRoute
        case 401, 403:
            return .notConfigured
        case 404:
            return .noRoute
        case 429:
            return .network("rate limited — try again shortly")
        case 500...599:
            return .provider(status: status, message: "service temporarily unavailable")
        default:
            return .provider(status: status, message: body.isEmpty ? "request failed" : String(body.prefix(120)))
        }
    }
}
