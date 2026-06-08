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
                  let to = op["to"] as? String,
                  let amountStr = op["amount"] as? String,
                  let amount = Decimal(string: amountStr) else {
                continue
            }
            let createdAt = (op["created_at"] as? String) ?? ""
            let occurredAt = Self.makeISO8601().date(from: createdAt) ?? Date()
            let isSuccessful = (op["transaction_successful"] as? Bool) ?? true
            let status: TransactionStatus = isSuccessful ? .confirmed : .failed
            let assetType = (op["asset_type"] as? String) ?? "native"
            let symbol = assetType == "native" ? "XLM" : ((op["asset_code"] as? String) ?? "XLM")
            let contract = assetType == "native" ? nil : (op["asset_issuer"] as? String)

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

    /// One-shot formatter — Stellar's `created_at` always carries
    /// fractional seconds (`2024-06-08T12:34:56.789Z`). Built per
    /// call instead of held statically because `ISO8601DateFormatter`
    /// isn't `Sendable` under Swift 6 strict concurrency.
    private static func makeISO8601() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
