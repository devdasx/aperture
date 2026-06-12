import Foundation
import OSLog

/// Transaction-history adapter for the Stellar network. Uses Horizon's
/// REST API: `/accounts/{address}/payments?order=desc&limit=N`.
/// Returns payment operations (native XLM + issued-asset transfers)
/// affecting the address.
///
/// **Scope.** `payment` and `path_payment_strict_*` operations — the
/// two op kinds that move funds between accounts. Other ops
/// (createAccount, manageOffer, AMM operations) are skipped.
struct StellarTransactionAdapter: Sendable {
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "xlm-tx-adapter")

    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        let path = "/accounts/\(address)/payments"
        let query: [URLQueryItem] = [
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "include_failed", value: "true"),
        ]
        let data = try await client.callREST(chain: .stellar, path: path, query: query)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let embedded = root["_embedded"] as? [String: Any],
              let records = embedded["records"] as? [[String: Any]] else {
            return []
        }

        var events: [TransactionEvent] = []
        events.reserveCapacity(records.count)
        for op in records {
            guard let opType = op["type"] as? String,
                  opType == "payment" || opType == "path_payment_strict_send" || opType == "path_payment_strict_receive",
                  let txHash = op["transaction_hash"] as? String,
                  let from = op["from"] as? String,
                  let to = op["to"] as? String else {
                continue
            }

            let direction: TransactionDirection
            let counterparty: String
            if from == address && to == address {
                direction = .internal
                counterparty = ""
            } else if from == address {
                direction = .outgoing
                counterparty = to
            } else if to == address {
                direction = .incoming
                counterparty = from
            } else {
                continue
            }

            // Horizon's `amount` / `asset_*` describe the DESTINATION
            // side of a path payment; what the sender actually paid
            // lives in `source_amount` / `source_asset_*`. An outgoing
            // row must show what the user sent — not what the
            // recipient received after conversion.
            let useSourceSide = opType != "payment" && direction == .outgoing
            guard let amountStr = op[useSourceSide ? "source_amount" : "amount"] as? String,
                  let amount = Decimal(string: amountStr) else {
                continue
            }
            let createdAt = (op["created_at"] as? String) ?? ""
            let occurredAt = Self.parseDate(createdAt) ?? Date()
            let isSuccessful = (op["transaction_successful"] as? Bool) ?? true
            let status: TransactionStatus = isSuccessful ? .confirmed : .failed
            let assetType = (op[useSourceSide ? "source_asset_type" : "asset_type"] as? String) ?? "native"
            let assetCode = op[useSourceSide ? "source_asset_code" : "asset_code"] as? String
            let assetIssuer = op[useSourceSide ? "source_asset_issuer" : "asset_issuer"] as? String
            let symbol: String
            let contract: String?
            if assetType == "native" {
                symbol = "XLM"
                contract = nil
            } else {
                // On Stellar anyone can issue an asset with ANY code —
                // only the (code, issuer) pair identifies an asset.
                // Rendering the self-declared code verbatim would let
                // a scam issuer's "USDC" read as Circle's.
                symbol = Self.displaySymbol(code: assetCode, issuer: assetIssuer)
                contract = assetIssuer
            }

            events.append(TransactionEvent(
                chain: .stellar,
                address: address,
                txHash: txHash,
                direction: direction,
                amount: amount,
                tokenSymbol: symbol,
                tokenContract: contract,
                blockNumber: nil,
                occurredAt: occurredAt,
                status: status,
                counterparty: counterparty,
                fee: nil
            ))
        }
        return events
    }

    /// Stellar assets Aperture recognizes, keyed by the full
    /// "code|issuer" pair — the code alone is attacker-chosen.
    private static let knownAssets: [String: String] = [
        // Circle USDC — official Stellar issuer.
        "USDC|GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN": "USDC",
    ]

    /// Display symbol for an issued asset. Known (code, issuer)
    /// pairs render their clean symbol; everything else gets the
    /// code qualified by a truncated issuer so a scam issuer's
    /// "USDC" is visibly NOT plain "USDC".
    private static func displaySymbol(code: String?, issuer: String?) -> String {
        let assetCode = code ?? ""
        if let issuer, !assetCode.isEmpty,
           let known = knownAssets["\(assetCode)|\(issuer)"] {
            return known
        }
        let issuerTag = issuer.map { "\($0.prefix(4))…" } ?? "?"
        return assetCode.isEmpty ? "ASSET·\(issuerTag)" : "\(assetCode)·\(issuerTag)"
    }

    /// Parse Horizon's `created_at`. Horizon emits whole-second
    /// ISO-8601 (`2024-06-08T12:34:56Z`, NO fractional seconds), and
    /// `.withFractionalSeconds` makes `ISO8601DateFormatter` REJECT
    /// such strings — so the primary formatter omits it, with a
    /// fractional-seconds fallback in case an upstream ever adds
    /// them. Failing both would mis-date the row to "now".
    private static func parseDate(_ string: String) -> Date? {
        Self.iso8601.date(from: string) ?? Self.iso8601Fractional.date(from: string)
    }

    /// Hoisted formatters — allocating one per record is wasteful;
    /// `ISO8601DateFormatter` is documented thread-safe by Apple, so
    /// the `nonisolated(unsafe)` opt-out of strict-concurrency
    /// checking is sound here.
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
