import Foundation
import OSLog

/// Transaction-history adapter for the XRP Ledger. XRPL exposes
/// `account_tx` over JSON-RPC: returns the list of transactions
/// affecting an account, newest first, with full envelope and
/// metadata. One call = one page of history.
///
/// **Scope.** Payment transactions only (`Payment` type in the
/// XRPL transaction taxonomy). Other types (TrustSet, OfferCreate,
/// AMM operations, NFT mints) are skipped — they don't read as
/// "sent" / "received" rows in a wallet activity feed.
struct XRPLTransactionAdapter: Sendable {
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "xrp-tx-adapter")

    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        let params: [String: Sendable] = [
            "account": address,
            "limit": limit,
            "ledger_index_min": -1,
            "ledger_index_max": -1,
            "binary": false,
        ]
        // rippled never echoes the JSON-RPC `id`, so the default
        // id-echo validation rejects every response and history comes
        // back permanently empty — opt out for XRPL.
        let data = try await client.callJSONResultData(
            chain: .ripple,
            method: "account_tx",
            params: [params],
            validatesIDEcho: false
        )
        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transactions = result["transactions"] as? [[String: Any]] else {
            return []
        }

        var events: [TransactionEvent] = []
        events.reserveCapacity(min(transactions.count, limit))
        for envelope in transactions.prefix(limit) {
            // XRPL wraps each entry as `{ tx: {...}, meta: {...}, validated: true }`.
            // Older nodes use `tx_json` instead of `tx`.
            let tx = (envelope["tx"] as? [String: Any])
                ?? (envelope["tx_json"] as? [String: Any])
                ?? [:]
            guard (tx["TransactionType"] as? String) == "Payment",
                  let txHash = tx["hash"] as? String,
                  let fromAcct = tx["Account"] as? String,
                  let toAcct = tx["Destination"] as? String else {
                continue
            }
            let validated = (envelope["validated"] as? Bool) ?? true
            // `meta.TransactionResult` is `"tesSUCCESS"` for confirmed
            // transactions, or a `tef*` / `tem*` code for failures.
            let metaDict = envelope["meta"] as? [String: Any] ?? [:]
            let txResult = (metaDict["TransactionResult"] as? String) ?? "tesSUCCESS"
            let status: TransactionStatus = (validated && txResult == "tesSUCCESS") ? .confirmed : (validated ? .failed : .pending)

            // Partial-payment safety (xrpl.org "partial payments"
            // warning): `tx.Amount` is only the UPPER BOUND when the
            // tfPartialPayment flag is set — a scam Payment can carry
            // Amount = 10,000 XRP and deliver 1 drop. The value that
            // actually moved is `meta.delivered_amount` (legacy
            // spelling `meta.DeliveredAmount`); trust `tx.Amount`
            // only when meta genuinely carries neither (pre-2014
            // ledgers, where `delivered_amount` is the literal
            // string "unavailable").
            let deliveredField = metaDict["delivered_amount"] ?? metaDict["DeliveredAmount"]
            let amountField: Any?
            if let delivered = deliveredField,
               !(delivered is NSNull),
               (delivered as? String) != "unavailable" {
                amountField = delivered
            } else {
                amountField = tx["Amount"]
            }

            // The amount can be either a string (XRP, in drops) or a
            // dictionary (issued currency, with `currency`, `issuer`,
            // `value`). For an issued-currency payment we report the
            // value as the amount and the resolved currency code as
            // the symbol; the issuer becomes the token contract.
            let symbol: String
            let amount: Decimal
            let contract: String?
            if let dropsString = amountField as? String, let drops = Decimal(string: dropsString) {
                symbol = "XRP"
                amount = drops / Self.dropsPerXRP
                contract = nil
            } else if let issuedAmount = amountField as? [String: Any],
                      let valueString = issuedAmount["value"] as? String,
                      let currencyCode = issuedAmount["currency"] as? String,
                      let issuer = issuedAmount["issuer"] as? String,
                      let parsedValue = Decimal(string: valueString) {
                symbol = Self.displaySymbol(currency: currencyCode, issuer: issuer)
                amount = parsedValue
                contract = issuer
            } else {
                continue
            }

            let direction: TransactionDirection
            let counterparty: String
            if fromAcct == address && toAcct == address {
                direction = .internal
                counterparty = ""
            } else if fromAcct == address {
                direction = .outgoing
                counterparty = toAcct
            } else if toAcct == address {
                direction = .incoming
                counterparty = fromAcct
            } else {
                continue
            }

            // Fee is in drops; only the sender pays it.
            let feeDropsStr = tx["Fee"] as? String ?? "0"
            let feeDrops = Decimal(string: feeDropsStr) ?? 0
            let fee: Decimal? = direction == .outgoing ? (feeDrops / Self.dropsPerXRP) : nil

            let ledgerSeq = (tx["ledger_index"] as? Int64) ?? (envelope["ledger_index"] as? Int64)
            let dateField = tx["date"] as? Int64
            let occurredAt: Date
            if let date = dateField {
                // XRPL's `date` is seconds since 2000-01-01 UTC
                // (epoch 946_684_800 from Unix epoch).
                occurredAt = Date(timeIntervalSince1970: TimeInterval(date) + 946_684_800)
            } else {
                occurredAt = Date()
            }

            events.append(TransactionEvent(
                chain: .ripple,
                address: address,
                txHash: txHash,
                direction: direction,
                amount: amount,
                tokenSymbol: symbol,
                tokenContract: contract,
                blockNumber: ledgerSeq,
                occurredAt: occurredAt,
                status: status,
                counterparty: counterparty,
                fee: fee
            ))
        }
        return events
    }

    /// Resolve the display symbol for an issued currency. The
    /// registry's (currency, issuer) mapping wins (RLUSD ships as a
    /// 40-char hex code); otherwise non-standard 40-char hex codes
    /// decode to ASCII (trailing NUL padding trimmed) so the feed
    /// never renders a raw "524C5553…" string.
    private static func displaySymbol(currency: String, issuer: String) -> String {
        if let entry = XRPLTokenRegistry.tokens.first(where: {
            $0.currency.caseInsensitiveCompare(currency) == .orderedSame && $0.issuer == issuer
        }) {
            return entry.symbol
        }
        return decodeHexCurrency(currency) ?? currency
    }

    /// Decode a non-standard 40-char hex XRPL currency code to its
    /// ASCII form. Returns `nil` unless every non-padding byte is
    /// printable ASCII — garbage codes stay hex rather than render
    /// as control characters.
    private static func decodeHexCurrency(_ code: String) -> String? {
        guard code.count == 40, let bytes = hexBytes(code) else { return nil }
        var trimmed = bytes
        while trimmed.last == 0 { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return nil }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            result.append(byte)
            i = next
        }
        return result
    }

    private static let dropsPerXRP: Decimal = {
        var result = Decimal(1)
        for _ in 0..<6 { result *= 10 }
        return result
    }()
}
