import Foundation
import OSLog

/// Shared diagnostics for balance / UTXO / history probe failures.
///
/// Soft-fail scanners (BUG-004 keep-last-good) catch transport errors and
/// must not invent zeros — but they still need an **honest, visible**
/// failure record. OSLog `.debug` is filtered out of the Xcode console by
/// default, so these paths looked silent while DOGE/LTC were rate-limited.
///
/// Always write:
/// 1. `DiagnosticsLogStore` (in-app Diagnostics screen + export) at
///    `.warning` / `.error`
/// 2. `Logger` at `.error` so the Xcode console shows the real cause
enum NetworkProbeDiagnostics {
    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "network-probe"
    )

    /// Record a failed network probe with a human-readable summary.
    /// - Parameters:
    ///   - chain: Chain being scanned.
    ///   - operation: Short name (`"balance snapshot"`, `"utxo"`, `"token balance"`).
    ///   - error: Underlying error (often `RPCError.rateLimited`).
    ///   - address: Optional address that was probed.
    ///   - source: Scanner / client name for filtering.
    static func recordFailure(
        chain: SupportedChain,
        operation: String,
        error: Error,
        address: String? = nil,
        source: String
    ) {
        if RPCError.isCancellation(error) {
            // Cancellations are not failures — do not spam diagnostics.
            return
        }

        let detail = RPCError.diagnosticDetail(for: error)
        let kind = RPCError.diagnosticKind(for: error)
        let level: DiagnosticsLogLevel = {
            if case .rateLimited = error as? RPCError { return .warning }
            return .error
        }()

        var metadata: [String: String] = [
            "chain": chain.rawValue,
            "operation": operation,
            "source": source,
            "errorKind": kind,
            "error": detail,
        ]
        if let address, !address.isEmpty {
            // Truncate for privacy / log size; enough to correlate probes.
            metadata["address"] = address.count > 16
                ? "\(address.prefix(8))…\(address.suffix(6))"
                : address
        }
        if let rpc = error as? RPCError, case .rateLimited(let retryAfter) = rpc {
            metadata["retryAfter"] = ISO8601DateFormatter().string(from: retryAfter)
            metadata["retryInSeconds"] = String(max(0, Int(ceil(retryAfter.timeIntervalSinceNow))))
            metadata["userFacing"] = rpc.userFacingLabel
        } else if let rpc = error as? RPCError {
            metadata["userFacing"] = rpc.userFacingLabel
        }

        let message = "\(operation) failed for \(chain.rawValue): \(detail)"
        DiagnosticsLogStore.shared.record(
            level,
            category: "scanner",
            message: message,
            metadata: metadata
        )
        // `.error` is visible in the Xcode console without changing OS_ACTIVITY_MODE;
        // `.debug` is not.
        log.error("\(message, privacy: .public) source=\(source, privacy: .public)")
    }

    /// End-of-scan summary when keep-last-good skipped writes after probe failure.
    static func recordKeepLastGood(
        chain: SupportedChain,
        reasons: [String],
        source: String
    ) {
        guard !reasons.isEmpty else { return }
        let joined = reasons.joined(separator: "; ")
        DiagnosticsLogStore.shared.record(
            .warning,
            category: "scanner",
            message: "\(chain.rawValue) scan kept last-good data (\(joined))",
            metadata: [
                "chain": chain.rawValue,
                "source": source,
                "reasons": joined,
                "policy": "BUG-004 keep-last-good",
            ]
        )
        log.error(
            "\(chain.rawValue, privacy: .public) scan kept last-good data (\(joined, privacy: .public)) source=\(source, privacy: .public)"
        )
    }
}

extension RPCError {
    /// Detailed, log-safe description (includes rate-limit retry timing).
    var diagnosticDetail: String {
        switch self {
        case .noEndpoint(let chain):
            return "noEndpoint(\(chain.rawValue))"
        case .allEndpointsFailed(let chain):
            return "allEndpointsFailed(\(chain.rawValue))"
        case .network(let message):
            return "network(\(message))"
        case .rateLimited(let retryAfter):
            let seconds = max(0, Int(ceil(retryAfter.timeIntervalSinceNow)))
            let iso = ISO8601DateFormatter().string(from: retryAfter)
            return "rateLimited(retryAfter: \(iso), retryInSeconds: \(seconds))"
        case .invalidResponse(let message):
            return "invalidResponse(\(message))"
        case .decodingFailed(let message):
            return "decodingFailed(\(message))"
        case .rpcError(let code, let message):
            return "rpcError(code: \(code), message: \(message))"
        case .cancelled:
            return "cancelled"
        }
    }

    /// Stable kind token for metadata filters (`rateLimited`, `network`, …).
    var diagnosticKind: String {
        switch self {
        case .noEndpoint: return "noEndpoint"
        case .allEndpointsFailed: return "allEndpointsFailed"
        case .network: return "network"
        case .rateLimited: return "rateLimited"
        case .invalidResponse: return "invalidResponse"
        case .decodingFailed: return "decodingFailed"
        case .rpcError: return "rpcError"
        case .cancelled: return "cancelled"
        }
    }

    /// Best-effort detail for any `Error` (prefers `RPCError`).
    static func diagnosticDetail(for error: Error) -> String {
        if let rpc = error as? RPCError {
            return rpc.diagnosticDetail
        }
        return String(describing: error)
    }

    static func diagnosticKind(for error: Error) -> String {
        if let rpc = error as? RPCError {
            return rpc.diagnosticKind
        }
        return String(describing: type(of: error))
    }
}

extension RPCError: CustomStringConvertible {
    var description: String { diagnosticDetail }
}
