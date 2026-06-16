import Foundation
import OSLog

/// **Ripple (XRP Ledger) connector — the rippled JSON-RPC reference
/// implementation.**
///
/// A FULLY INDEPENDENT module for `.ripple`: its own `account_info`
/// native-balance read, its own `account_lines` IOU-trust-line token
/// read, and its own `account_tx` paginated Payment history. It owns
/// its request shapes + parsing end-to-end and dispatches every call
/// through the shared `RPCClient` actor via `callJSONResultData`
/// (rotation + rate-limit + circuit-breaking + ConcurrencyGate)
/// against the registered endpoints `RPCRegistry.endpoints(for:
/// .ripple)` (s1.ripple.com primary, s2.ripple.com fallback,
/// xrplcluster.com last-resort — all the same rippled JSON-RPC shape).
/// Never a raw `URLSession`.
///
/// **The XRPL id-echo quirk.** rippled's HTTP API is JSON-RPC-shaped
/// but does NOT echo the request `id` (verified against s1/s2.ripple.com
/// and xrplcluster.com — the response carries no `id` field at all), so
/// the client's default id-echo validation would reject every response
/// and render XRP as 0. Every call here passes `validatesIDEcho: false`.
///
/// **Ported verbatim-faithful** from `XRPChainAdapter.fetchAccountSummary`
/// (native balance), `RealRPCBalanceScanner.fetchXRPLTokenLines` +
/// the `.ripple` registry-token branch (IOU token balances), and
/// `XRPLTransactionAdapter.fetch` (Payment history): same
/// `account_info` / `account_lines` / `account_tx` methods, same
/// `Balance` drops ÷ 10^6 math, same `(currency, issuer)` IOU keying
/// with already-decimal-string balances (NEVER divided), same
/// partial-payment `delivered_amount` safety, same XRPL 2000-epoch date
/// math, same opaque `marker` pagination.
///
/// **404 / unfunded.** An account that has never been funded does not
/// exist on-ledger; rippled returns a JSON-RPC error
/// (`actNotFound`), NOT an HTTP 404. The native read maps that — and any
/// decode miss — to a zero summary rather than throwing, mirroring the
/// ported adapter's catch-all. `RPCError.cancelled` always propagates.
struct RippleConnector: ChainConnector {
    let chain: SupportedChain = .ripple
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "ripple-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native XRP balance + used-address flag via rippled `account_info`.
    /// Ported from `XRPChainAdapter.fetchAccountSummary`.
    ///
    /// `result.account_data.Balance` is the reserve-inclusive balance in
    /// drops → divided by 10^6 (`dropsPerXRP`). An unfunded account
    /// (rippled `actNotFound`), a missing `account_data`, or any other
    /// read miss degrades to a zero summary — the normal "0 balance"
    /// state, not a failure. `isUsed` keys on a positive balance (an
    /// on-ledger XRPL account always holds at least the base reserve, so
    /// balance > 0 is the honest "this account exists / has been
    /// activated" signal). Cancellation still propagates.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            // rippled does NOT echo the request `id` — opt out of id-echo
            // validation or every response is rejected and XRP reads 0.
            let data = try await client.callJSONResultData(
                chain: chain,
                method: "account_info",
                params: [["account": address, "ledger_index": "validated"]],
                validatesIDEcho: false
            )
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let info = dict["account_data"] as? [String: Any],
               let balanceStr = info["Balance"] as? String,
               let drops = Decimal(string: balanceStr) {
                let xrp = drops / Self.dropsPerXRP
                return ChainAccountSummary(nativeBalance: xrp, isUsed: xrp > 0)
            }
            // No account_data = unfunded / actNotFound — the normal zero state.
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        } catch {
            // Cancellation must propagate; an HTTP 404 (defensive — rippled
            // signals unfunded as a JSON-RPC error, not 404) is the normal
            // zero state. Any other read failure degrades to zero rather
            // than blanking the refresh (mirrors the ported adapter).
            if case .cancelled = error { throw error }
            if RPCError.isHTTPNotFound(error) {
                Self.log.debug("XRP account \(address, privacy: .private) unfunded (404) — treating as 0 balance")
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            Self.log.error("XRP balance fetch failed for \(address, privacy: .private): \(String(describing: error), privacy: .public)")
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }

    // MARK: - Token balances

    /// XRPL IOU token balances via rippled `account_lines`, ported from
    /// `RealRPCBalanceScanner.fetchXRPLTokenLines` + the `.ripple`
    /// registry-token branch.
    ///
    /// `account_lines` returns the holder's trust lines, each carrying
    /// `currency`, `account` (the issuer), and `balance` (an
    /// already-decimal string — XRPL IOU amounts are NEVER divided by
    /// 10^decimals; that's why every `XRPLTokenRegistry.Entry.decimals`
    /// is 0). Lines are indexed by `(currency, issuer)` and matched
    /// against the curated `XRPLTokenRegistry`. Only positive-balance
    /// rows are returned; `fiatBalance` is `nil` (the coordinator prices
    /// downstream). A discovery failure degrades to `[]` (non-throwing
    /// by contract).
    ///
    /// `customContracts` is unused — Aperture's custom-token picker does
    /// not cover XRPL IOUs (matches `RealRPCBalanceScanner.streamCustomTokens`,
    /// which only handles EVM + Solana) — but it's kept for the uniform
    /// `ChainConnector` signature.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        guard let lines = await fetchTrustLines(holder: address) else { return [] }
        let now = Date()
        var balances: [TokenBalance] = []
        for entry in XRPLTokenRegistry.tokens {
            let amount = lines[Self.xrplKey(currency: entry.currency, issuer: entry.issuer)] ?? 0
            guard amount > 0 else { continue }
            balances.append(TokenBalance(
                chain: chain,
                address: address,
                // Matches the scanner's `.ripple` contract keying:
                // "<currency>.<issuer>".
                contract: "\(entry.currency).\(entry.issuer)",
                symbol: entry.symbol,
                name: entry.name,
                decimals: entry.decimals,   // always 0 for XRPL IOUs
                amount: amount,
                fiatBalance: nil,            // priced by the coordinator
                fiatCurrencyCode: "",
                lastUpdated: now
            ))
        }
        return balances
    }

    /// Fetch the holder's IOU trust lines keyed by `(currency, issuer)`.
    /// Ported verbatim from `RealRPCBalanceScanner.fetchXRPLTokenLines`:
    /// the client strips the JSON-RPC envelope, so the returned data IS
    /// the `result` object containing `lines`. Returns `nil` on any
    /// fetch / decode miss (the caller then yields no token rows).
    private func fetchTrustLines(holder: String) async -> [String: Decimal]? {
        guard let data = try? await client.callJSONResultData(
            chain: chain,
            method: "account_lines",
            params: [["account": holder, "ledger_index": "validated"]],
            validatesIDEcho: false
        ),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = result["lines"] as? [[String: Any]] else {
            return nil
        }
        var out: [String: Decimal] = [:]
        for line in lines {
            guard let currency = line["currency"] as? String,
                  let account = line["account"] as? String,
                  let balanceStr = line["balance"] as? String,
                  let balance = Decimal(string: balanceStr) else { continue }
            out[Self.xrplKey(currency: currency, issuer: account)] = balance
        }
        return out
    }

    private static func xrplKey(currency: String, issuer: String) -> String {
        "\(currency.uppercased()).\(issuer)"
    }

    // MARK: - Transaction history

    /// rippled clamps non-admin `account_tx` pages well below this; 200
    /// is the commonly-honored public-server maximum.
    private static let maxPageSize = 200

    /// Recent XRP history via rippled `account_tx`, paging through the
    /// opaque `marker` resume token (echoed back verbatim) until `limit`
    /// events, no marker (history exhausted), an empty page, or a
    /// mid-pagination failure (keeps pages already fetched). Ported from
    /// `XRPLTransactionAdapter.fetch`.
    ///
    /// **Scope.** Payment transactions only — other types (TrustSet,
    /// OfferCreate, AMM, NFT) don't read as sent/received rows. The
    /// fetched-envelope budget is also capped at `limit` so an account
    /// with endless non-Payment traffic can't spin the loop.
    /// `RPCError.cancelled` propagates immediately.
    ///
    /// `customContracts` is unused (XRPL token transfers come through as
    /// issued-currency Payments, gated by the registry, not by
    /// user-added contracts) but kept for the uniform signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let pageSize = min(limit, Self.maxPageSize)
        var events: [TransactionEvent] = []
        var marker: Sendable?
        var fetchedEnvelopes = 0
        var isFirstPage = true
        while events.count < limit && fetchedEnvelopes < limit {
            if Task.isCancelled { throw RPCError.cancelled }
            var params: [String: Sendable] = [
                "account": address,
                "limit": pageSize,
                "ledger_index_min": -1,
                "ledger_index_max": -1,
                "binary": false,
            ]
            if let marker { params["marker"] = marker }
            // rippled never echoes the JSON-RPC `id` — opt out for XRPL.
            let data: Data
            do {
                data = try await client.callJSONResultData(
                    chain: chain,
                    method: "account_tx",
                    params: [params],
                    validatesIDEcho: false
                )
            } catch {
                if case .cancelled = error { throw error }
                if isFirstPage { throw error }
                Self.log.warning("account_tx page failed — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let transactions = result["transactions"] as? [[String: Any]] else {
                break
            }
            // An empty page can't advance the envelope budget — stop
            // rather than spin on a marker that yields nothing.
            if transactions.isEmpty { break }
            fetchedEnvelopes += transactions.count
            appendEvents(from: transactions, address: address, limit: limit, into: &events)
            // No marker = history exhausted; an un-mirrorable marker
            // (shape we can't echo into Sendable) ends the walk honestly.
            guard let rawMarker = result["marker"],
                  let nextMarker = Self.sendableJSON(rawMarker) else { break }
            marker = nextMarker
            isFirstPage = false
            if events.count >= limit || fetchedEnvelopes >= limit {
                Self.log.info("XRPL account_tx hit the \(limit, privacy: .public)-row full-history cap — older rows not fetched this scan")
            }
        }
        return events
    }

    /// Parse one `account_tx` page of envelopes into events. Ported
    /// verbatim from `XRPLTransactionAdapter.appendEvents`.
    private func appendEvents(
        from transactions: [[String: Any]],
        address: String,
        limit: Int,
        into events: inout [TransactionEvent]
    ) {
        events.reserveCapacity(min(events.count + transactions.count, limit))
        for envelope in transactions {
            if events.count >= limit { break }
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
            // actually moved is `meta.delivered_amount` (legacy spelling
            // `meta.DeliveredAmount`); trust `tx.Amount` only when meta
            // genuinely carries neither (pre-2014 ledgers, where
            // `delivered_amount` is the literal string "unavailable").
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
            // value as the amount and the resolved currency code as the
            // symbol; the issuer becomes the token contract.
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
                chain: chain,
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
    }

    // MARK: - Marker mirroring + symbol resolution (ported verbatim)

    /// Mirror a JSON fragment (as produced by `JSONSerialization`) into
    /// `Sendable`-typed values so it can be echoed back in the next
    /// request's params. rippled's `account_tx` `marker` is an opaque
    /// token — a string on some servers, an object (`{"ledger": n,
    /// "seq": n}`) on others — and the spec requires passing it back
    /// EXACTLY as received. Returns `nil` for any fragment that can't be
    /// mirrored losslessly (the caller then stops paginating rather than
    /// sending a corrupted marker). Ported from
    /// `XRPLTransactionAdapter.sendableJSON`.
    private static func sendableJSON(_ value: Any) -> Sendable? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            // JSONSerialization vends booleans as the shared CFBoolean
            // singletons; everything else mirrors as Int64
            // (ledger/seq markers) or Double.
            if number === kCFBooleanTrue || number === kCFBooleanFalse {
                return number.boolValue
            }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                return number.doubleValue
            }
            return number.int64Value
        case let array as [Any]:
            var out: [Sendable] = []
            out.reserveCapacity(array.count)
            for element in array {
                guard let mirrored = sendableJSON(element) else { return nil }
                out.append(mirrored)
            }
            return out
        case let dictionary as [String: Any]:
            var out: [String: Sendable] = [:]
            out.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let mirrored = sendableJSON(element) else { return nil }
                out[key] = mirrored
            }
            return out
        default:
            return nil
        }
    }

    /// Resolve the display symbol for an issued currency. The registry's
    /// (currency, issuer) mapping wins (RLUSD ships as a 40-char hex
    /// code); otherwise non-standard 40-char hex codes decode to ASCII
    /// (trailing NUL padding trimmed) so the feed never renders a raw
    /// "524C5553…" string. Ported from
    /// `XRPLTransactionAdapter.displaySymbol`.
    private static func displaySymbol(currency: String, issuer: String) -> String {
        if let entry = XRPLTokenRegistry.tokens.first(where: {
            $0.currency.caseInsensitiveCompare(currency) == .orderedSame && $0.issuer == issuer
        }) {
            return entry.symbol
        }
        return decodeHexCurrency(currency) ?? currency
    }

    /// Decode a non-standard 40-char hex XRPL currency code to its ASCII
    /// form. Returns `nil` unless every non-padding byte is printable
    /// ASCII — garbage codes stay hex rather than render as control
    /// characters. Ported from `XRPLTransactionAdapter.decodeHexCurrency`.
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

    /// 10^6 — XRP's smallest unit is the drop.
    private static let dropsPerXRP: Decimal = 1_000_000
}
