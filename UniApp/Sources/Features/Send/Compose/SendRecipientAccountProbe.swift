import Foundation
import OSLog

/// Live recipient-account probe for Send compose (P0-006).
///
/// Sets honesty flags used by MAX math, validation, and Stellar create_account:
/// - `needsActivation` — brand-new / unfunded destination
/// - `requiresDestinationTag` — XRPL `lsfRequireDestTag`
/// - `requiresMemo` — Stellar SEP-29 / `config.memo_required` data entry
///
/// **Send-only.** Receive never collects memo/tag (product rule). Memo/tag
/// entry already lives on the Send recipient + amount screens for XRP/XLM.
struct SendRecipientAccountProbeResult: Sendable, Equatable, Hashable {
    var needsActivation: Bool
    var requiresDestinationTag: Bool
    var requiresMemo: Bool

    static let none = SendRecipientAccountProbeResult(
        needsActivation: false,
        requiresDestinationTag: false,
        requiresMemo: false
    )
}

enum SendRecipientAccountProbe {
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "send-recipient-probe")

    /// XRPL ledger flag: account requires destination tag on inbound payments.
    /// https://xrpl.org/docs/references/protocol/ledger-data/ledger-entry-types/accountroot
    static let xrpRequireDestTagFlag: UInt32 = 0x0002_0000

    /// Probe the primary recipient for `chain`. Chains without activation /
    /// memo/tag gates return `.none` without network I/O.
    static func probe(
        chain: SupportedChain,
        recipientAddress: String
    ) async -> SendRecipientAccountProbeResult {
        let address = recipientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return .none }

        switch chain {
        case .ripple:
            return await probeXRP(address: address)
        case .stellar:
            return await probeStellar(address: address)
        case .tron:
            return await probeTron(address: address)
        default:
            return .none
        }
    }

    // MARK: - XRP

    private static func probeXRP(address: String) async -> SendRecipientAccountProbeResult {
        do {
            let data = try await RPCClient.shared.callJSONResultData(
                chain: .ripple,
                method: "account_info",
                params: [[
                    "account": address,
                    "ledger_index": "validated",
                ] as [String: Sendable]],
                validatesIDEcho: false
            )
            return parseXRPAccountInfoJSON(data)
        } catch {
            // Typed throw is RPCError — node often surfaces actNotFound as rpcError.
            if case .rpcError(_, let message) = error {
                let lower = message.lowercased()
                if lower.contains("actnotfound")
                    || lower.contains("account not found")
                    || lower.contains("account_not_found") {
                    return SendRecipientAccountProbeResult(
                        needsActivation: true,
                        requiresDestinationTag: false,
                        requiresMemo: false
                    )
                }
            }
            log.debug("XRP recipient probe failed: \(String(describing: error), privacy: .public)")
            // Network failure: do not invent require-tag (would block honest sends).
            // Do not invent activation (would understate MAX incorrectly).
            return .none
        }
    }

    /// Pure parser for tests + production. Interprets `account_info` result.
    static func parseXRPAccountInfoJSON(_ data: Data) -> SendRecipientAccountProbeResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .none
        }
        // Error shape: actNotFound → unfunded account needs activation payment.
        if let error = root["error"] as? String {
            let lower = error.lowercased()
            if lower.contains("actnotfound") || lower.contains("account_not_found") {
                return SendRecipientAccountProbeResult(
                    needsActivation: true,
                    requiresDestinationTag: false,
                    requiresMemo: false
                )
            }
            return .none
        }
        // Some wrappers nest under "result".
        let payload: [String: Any]
        if let nested = root["account_data"] as? [String: Any] {
            payload = root
            _ = nested
        } else if let result = root["result"] as? [String: Any] {
            if let error = result["error"] as? String {
                let lower = error.lowercased()
                if lower.contains("actnotfound") || lower.contains("account_not_found") {
                    return SendRecipientAccountProbeResult(
                        needsActivation: true,
                        requiresDestinationTag: false,
                        requiresMemo: false
                    )
                }
            }
            payload = result
        } else {
            payload = root
        }

        guard let accountData = payload["account_data"] as? [String: Any] else {
            // Successful object without account_data is unexpected — no flags.
            return .none
        }

        var requiresTag = false
        // Prefer structured account_flags when the node provides them.
        if let flags = payload["account_flags"] as? [String: Any],
           let require = flags["requireDestinationTag"] as? Bool {
            requiresTag = require
        } else if let flagsNum = accountData["Flags"] as? NSNumber {
            requiresTag = (flagsNum.uint32Value & xrpRequireDestTagFlag) != 0
        } else if let flagsInt = accountData["Flags"] as? Int {
            requiresTag = (UInt32(truncatingIfNeeded: flagsInt) & xrpRequireDestTagFlag) != 0
        }

        return SendRecipientAccountProbeResult(
            needsActivation: false,
            requiresDestinationTag: requiresTag,
            requiresMemo: false
        )
    }

    // MARK: - Stellar

    private static func probeStellar(address: String) async -> SendRecipientAccountProbeResult {
        do {
            let data = try await RPCClient.shared.callREST(
                chain: .stellar,
                path: "/accounts/\(address)"
            )
            return parseStellarAccountJSON(data, httpNotFound: false)
        } catch {
            if RPCError.isHTTPNotFound(error) {
                return SendRecipientAccountProbeResult(
                    needsActivation: true,
                    requiresDestinationTag: false,
                    requiresMemo: false
                )
            }
            // Some stacks surface 404 as invalidResponse with "not found".
            if case RPCError.invalidResponse(let message) = error,
               message.lowercased().contains("404")
                || message.lowercased().contains("not found")
                || message.lowercased().contains("resource missing") {
                return SendRecipientAccountProbeResult(
                    needsActivation: true,
                    requiresDestinationTag: false,
                    requiresMemo: false
                )
            }
            log.debug("Stellar recipient probe failed: \(String(describing: error), privacy: .public)")
            return .none
        }
    }

    /// Pure parser for Horizon account JSON (or a synthetic not-found marker).
    static func parseStellarAccountJSON(_ data: Data, httpNotFound: Bool) -> SendRecipientAccountProbeResult {
        if httpNotFound {
            return SendRecipientAccountProbeResult(
                needsActivation: true,
                requiresDestinationTag: false,
                requiresMemo: false
            )
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .none
        }
        // Horizon error body for missing account.
        if let status = root["status"] as? Int, status == 404 {
            return SendRecipientAccountProbeResult(
                needsActivation: true,
                requiresDestinationTag: false,
                requiresMemo: false
            )
        }
        if let type = root["type"] as? String,
           type.lowercased().contains("not_found") || type.lowercased().contains("resource_missing") {
            return SendRecipientAccountProbeResult(
                needsActivation: true,
                requiresDestinationTag: false,
                requiresMemo: false
            )
        }

        // Funded account — check SEP-29 style data entry `config.memo_required`.
        let requiresMemo = stellarDataRequiresMemo(root["data"] as? [String: Any])
        return SendRecipientAccountProbeResult(
            needsActivation: false,
            requiresDestinationTag: false,
            requiresMemo: requiresMemo
        )
    }

    /// Horizon stores account data values as base64. SEP-29 / exchange
    /// convention: key `config.memo_required` with value decoding to `"1"` / true.
    static func stellarDataRequiresMemo(_ data: [String: Any]?) -> Bool {
        guard let data else { return false }
        for (key, value) in data {
            let keyLower = key.lowercased()
            guard keyLower == "config.memo_required"
                    || keyLower.hasSuffix("memo_required")
                    || keyLower == "memo_required" else { continue }
            if let string = value as? String {
                if parseMemoRequiredValue(string) { return true }
            }
        }
        return false
    }

    static func parseMemoRequiredValue(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "1" || trimmed.lowercased() == "true" { return true }
        // Base64-encoded "1" is typically "MQ==".
        if let decoded = Data(base64Encoded: trimmed),
           let text = String(data: decoded, encoding: .utf8) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "1" || t.lowercased() == "true" { return true }
        }
        return false
    }

    // MARK: - TRON

    private static func probeTron(address: String) async -> SendRecipientAccountProbeResult {
        do {
            let data = try await RPCClient.shared.callRESTPost(
                chain: .tron,
                path: "/wallet/getaccount",
                body: ["address": address, "visible": true]
            )
            return parseTronGetAccountJSON(data)
        } catch {
            log.debug("TRON recipient probe failed: \(String(describing: error), privacy: .public)")
            return .none
        }
    }

    /// Pure parser: empty object / no address field → unactivated.
    static func parseTronGetAccountJSON(_ data: Data) -> SendRecipientAccountProbeResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .none
        }
        // TronGrid/fullnode returns `{}` or object without `address` when missing.
        let hasAddress = (root["address"] as? String)?.isEmpty == false
        let hasBalance = root["balance"] != nil
        let hasCreate = root["create_time"] != nil || root["createTime"] != nil
        let exists = hasAddress || hasBalance || hasCreate
        return SendRecipientAccountProbeResult(
            needsActivation: !exists,
            requiresDestinationTag: false,
            requiresMemo: false
        )
    }
}
