import Foundation
import OSLog

/// **Stellar connector — the Horizon REST reference implementation.**
///
/// A FULLY INDEPENDENT module for `.stellar`: its own Horizon
/// `/accounts/{addr}` native-balance read and its own
/// `/accounts/{addr}/payments` cursor-paginated payment history. It owns
/// its request shapes + parsing end-to-end and dispatches every call
/// through the shared `RPCClient` actor via `callREST` (rotation +
/// rate-limit + circuit-breaking + ConcurrencyGate) against the
/// registered endpoints `RPCRegistry.endpoints(for: .stellar)`
/// (horizon.stellar.org SDF primary, horizon.stellar.lobstr.co fallback —
/// both Horizon, one shape covers both). Never a raw `URLSession`.
///
/// **Ported verbatim-faithful** from `StellarChainAdapter`
/// (balance) and `StellarTransactionAdapter` (history): same
/// `accounts/{addr}` / `accounts/{addr}/payments` paths, same
/// `balances[asset_type == "native"].balance` parsing, same 7-decimal
/// string amounts decoded straight into `Decimal` (Horizon already
/// returns whole-XLM strings — no stroop division needed), same
/// `cursor`/`paging_token` pagination, same `payment` /
/// `path_payment_strict_*` op-kind scoping, same source-side amount
/// selection for outgoing path payments, same (code, issuer) asset
/// disambiguation, and the same 404=unfunded → zero-summary handling
/// (`RPCError.isHTTPNotFound`).
///
/// **No token layer.** Aperture does not scan Stellar trustline tokens
/// today (`RealRPCBalanceScanner` has no Stellar token path), so
/// `fetchTokenBalances` returns `[]` honestly — mirroring the Bitcoin
/// connector's "native coin is the only asset" stance. Issued-asset
/// *transfers* still surface in `fetchHistory` (with (code, issuer)
/// disambiguation), exactly as the existing transaction adapter does.
struct StellarConnector: ChainConnector {
    let chain: SupportedChain = .stellar
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "stellar-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native XLM balance + used-address flag via Horizon's
    /// `/accounts/{addr}`. Ported from
    /// `StellarChainAdapter.fetchAccountSummary`.
    ///
    /// The account's `balances` array carries one entry per asset; the
    /// native XLM lives under `asset_type == "native"` as a whole-XLM
    /// decimal string (Horizon pre-divides stroops, so no 10^7 math is
    /// needed here). `isUsed` keys on a positive balance.
    ///
    /// A 404 from Horizon means the account is unfunded / does not exist
    /// on-chain yet — the normal zero-balance state, not a failure — so
    /// it is mapped to a zero summary rather than thrown
    /// (`RPCError.isHTTPNotFound`). Cancellation still propagates.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callREST(chain: chain, path: "accounts/\(address)")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let balances = json["balances"] as? [[String: Any]] else {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let nativeStr = balances.first(where: { $0["asset_type"] as? String == "native" })?["balance"] as? String ?? "0"
            let balance = Decimal(string: nativeStr) ?? 0
            return ChainAccountSummary(nativeBalance: balance, isUsed: balance > 0)
        } catch {
            if case .cancelled = error { throw error }
            // A 404 from Horizon = the account is unfunded / doesn't exist
            // on-chain yet — the normal "0 balance" state, not an error.
            if RPCError.isHTTPNotFound(error) {
                Self.log.debug("Stellar account \(address, privacy: .private) unfunded (404) — treating as 0 balance")
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            Self.log.error("Stellar balance fetch failed for \(address, privacy: .private): \(String(describing: error), privacy: .public)")
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
    }

    // MARK: - Token balances

    /// Aperture does not track Stellar trustline tokens as held balances
    /// (no Stellar token path in `RealRPCBalanceScanner`) — the native
    /// XLM is the only asset surfaced on the wallet home. Returns `[]`
    /// honestly (Rule #16), mirroring the Bitcoin connector. Issued-asset
    /// movements still appear in `fetchHistory`.
    ///
    /// `customContracts` is unused (no token-balance layer) but kept for
    /// the uniform `ChainConnector` signature.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history

    /// Horizon's documented per-page maximum.
    private static let horizonPageMax = 200

    /// Recent XLM + issued-asset payment history via Horizon's
    /// `/accounts/{addr}/payments`, paging through the `cursor`
    /// (the `paging_token` of the previous page's last record) in batches
    /// until `limit` events, an exhausted budget, a short page (history
    /// exhausted), or a mid-pagination failure (keeps the pages already
    /// fetched). Ported from `StellarTransactionAdapter.fetch`.
    ///
    /// Only `payment` and `path_payment_strict_*` ops are surfaced (the
    /// two op kinds that move funds between accounts). The fetched-record
    /// budget is also capped at `limit` so an account with endless
    /// non-payment operations can't spin the loop.
    ///
    /// `customContracts` is unused (Stellar history is op-derived, not
    /// contract-gated) but kept for the uniform signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let path = "/accounts/\(address)/payments"
        let pageSize = min(limit, Self.horizonPageMax)
        var events: [TransactionEvent] = []
        var cursor: String?
        var fetchedRecords = 0
        while events.count < limit && fetchedRecords < limit {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "include_failed", value: "true"),
            ]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let data: Data
            do {
                data = try await client.callREST(chain: chain, path: path, query: query)
            } catch {
                if case .cancelled = error { throw error }
                if cursor == nil { throw error }
                Self.log.warning("Horizon payments page failed — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let embedded = root["_embedded"] as? [String: Any],
                  let records = embedded["records"] as? [[String: Any]] else {
                break
            }
            if records.isEmpty { break }
            fetchedRecords += records.count
            appendEvents(from: records, address: address, limit: limit, into: &events)
            guard let nextCursor = records.last?["paging_token"] as? String,
                  nextCursor != cursor else { break }
            cursor = nextCursor
            if records.count < pageSize { break } // history exhausted
            if events.count >= limit || fetchedRecords >= limit {
                Self.log.info("Horizon payments hit the \(limit, privacy: .public)-row full-history cap — older rows not fetched this scan")
            }
        }
        return events
    }

    /// Parse one Horizon page of payment operations into events,
    /// appending until `limit`. Ported verbatim from
    /// `StellarTransactionAdapter.appendEvents`.
    private func appendEvents(
        from records: [[String: Any]],
        address: String,
        limit: Int,
        into events: inout [TransactionEvent]
    ) {
        events.reserveCapacity(min(events.count + records.count, limit))
        for op in records {
            if events.count >= limit { break }
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
                chain: chain,
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
    }

    // MARK: - Asset disambiguation (ported verbatim)

    /// Stellar assets Aperture recognizes, keyed by the full
    /// "code|issuer" pair — the code alone is attacker-chosen.
    private static let knownAssets: [String: String] = [
        // Circle USDC — official Stellar issuer.
        "USDC|GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN": "USDC",
    ]

    /// Display symbol for an issued asset. Known (code, issuer) pairs
    /// render their clean symbol; everything else gets the code qualified
    /// by a truncated issuer so a scam issuer's "USDC" is visibly NOT
    /// plain "USDC". Ported from `StellarTransactionAdapter.displaySymbol`.
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
    /// `.withFractionalSeconds` makes `ISO8601DateFormatter` REJECT such
    /// strings — so the primary formatter omits it, with a
    /// fractional-seconds fallback in case an upstream ever adds them.
    /// Failing both would mis-date the row to "now". Ported from
    /// `StellarTransactionAdapter.parseDate`.
    private static func parseDate(_ string: String) -> Date? {
        Self.iso8601.date(from: string) ?? Self.iso8601Fractional.date(from: string)
    }

    /// Hoisted formatters — allocating one per record is wasteful;
    /// `ISO8601DateFormatter` is documented thread-safe by Apple, so the
    /// `nonisolated(unsafe)` opt-out of strict-concurrency checking is
    /// sound here.
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
