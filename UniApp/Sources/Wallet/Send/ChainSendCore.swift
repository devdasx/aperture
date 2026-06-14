import Foundation

/// Core value types for the real send pipeline (Send V2 domain layer).
///
/// The pipeline per chain is: resolve key + context (nonce / blockhash /
/// sequence / UTXOs / runtime) → estimate fee → sign (wallet-core
/// `AnySigner`) → broadcast → watch status. These models are the
/// chain-agnostic currency between those stages; per-family services
/// (EVM first) own the chain specifics.
///
/// **Funds-safety (Rule #16 / Rule #26).** Every value here is honest:
/// amounts are raw integer strings (no float drift), the signed payload
/// carries the real broadcast bytes, and errors name the real failure so
/// the UI never fabricates success. NOTHING key-, mnemonic-, or
/// signature-shaped is ever logged.
///
/// **Off-main (Rule #28).** Building + signing + RPC all run off the main
/// actor; only small Sendable values cross back to the `@MainActor` UI.

// MARK: - Send request

/// A normalized, ready-to-sign send. Built by the per-family service from
/// the `SendDraft` + freshly-fetched on-chain context.
struct ChainSendRequest: Sendable {
    let chain: SupportedChain
    let fromAddress: String
    let toAddress: String
    /// Amount in the asset's smallest unit (wei / satoshi / lamport / …),
    /// as a decimal integer string — never a floating value.
    let rawAmount: String
    /// Token contract / mint / asset id when this is a token send; `nil`
    /// for a native-coin send.
    let tokenContract: String?
    /// Asset decimals (18 for ETH native, 6 for USDC, …).
    let decimals: Int
    let isNative: Bool
    /// Optional memo / destination-tag (XRPL, Stellar, Cosmos, TON).
    let memo: String?
}

// MARK: - Fee

/// A single fee option the user can pick (maps to the UI's `FeeTier`).
struct ChainFeeOption: Sendable {
    enum Speed: String, Sendable { case slow, normal, fast }

    let speed: Speed
    /// The total network fee for this option in the chain's native units.
    let feeNative: Decimal
    /// Rough confirmation time, seconds (for the UI's "~3 min" line).
    let estimatedSeconds: Int

    // EVM specifics (nil on non-EVM families).
    let gasLimit: UInt64?
    let maxFeePerGas: UInt64?      // EIP-1559
    let maxPriorityFeePerGas: UInt64?  // EIP-1559
    let gasPrice: UInt64?          // legacy
}

// MARK: - Signed transaction

/// The output of signing — the exact bytes to broadcast plus the
/// locally-computed hash (where the chain lets us derive it pre-broadcast).
struct ChainSignedTransaction: Sendable {
    /// The broadcast payload in the form the chain's submit RPC expects
    /// (0x-hex for EVM, base64 for Solana/TON, XDR for Stellar, …).
    let broadcastPayload: String
    /// Locally-derived tx hash, or empty when only the node can assign it.
    let txHash: String
}

// MARK: - Status

enum ChainSendStatus: Sendable, Equatable {
    case pending          // broadcast, not yet mined/confirmed
    case confirmed(blockNumber: UInt64?)
    case failed(reason: String)   // mined but reverted / rejected
}

// MARK: - Errors

enum ChainSendError: Error, Sendable, Equatable {
    case unsupportedChain(SupportedChain)
    case walletCannotSign            // watch-only / key not on device / passphrase
    case missingContext(String)      // a required pre-sign fetch failed
    case feeUnavailable
    case signingFailed(String)
    case broadcastRejected(String)   // node rejected the raw tx (honest reason)
    case rpcUnavailable

    /// A short, user-facing line (the Send flow surfaces this on failure).
    var userMessage: String {
        switch self {
        case .unsupportedChain(let c): return "Sending on \(c.displayName) isn't available yet."
        case .walletCannotSign:        return "This wallet can't sign sends."
        case .missingContext:          return "Couldn't reach the network to prepare this send. Try again."
        case .feeUnavailable:          return "Couldn't fetch the network fee. Try again."
        case .signingFailed:           return "Signing failed."
        case .broadcastRejected(let r): return r
        case .rpcUnavailable:          return "The network is unreachable right now. Try again."
        }
    }
}

// MARK: - Amount conversion

enum ChainAmount {
    /// Convert a human decimal amount to the raw smallest-unit integer
    /// string for signing — precision-safe (Decimal scaled by 10^decimals,
    /// truncated to an integer, no Double anywhere).
    static func rawInteger(from amount: Decimal, decimals: Int) -> String {
        guard amount > 0, decimals >= 0 else { return "0" }
        var scaled = amount
        var multiplier = Decimal(1)
        for _ in 0..<decimals { multiplier *= 10 }
        scaled *= multiplier
        // Truncate any sub-unit remainder (never round up — don't spend
        // more than the user typed).
        var truncated = Decimal()
        var input = scaled
        NSDecimalRound(&truncated, &input, 0, .down)
        return NSDecimalNumber(decimal: truncated).stringValue
    }
}
