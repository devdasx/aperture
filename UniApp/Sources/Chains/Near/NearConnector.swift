import Foundation
import OSLog

/// **NEAR connector — the named-params JSON-RPC + byte-array view-call
/// reference for the `other`-kind chains.**
///
/// A FULLY INDEPENDENT module for `.near`: its own `query`
/// `view_account` native read, its own NEP-141 `ft_balance_of`
/// view-function token reads (`request_type=call_function`), and its
/// own nearblocks.io indexer history. It owns its request shapes +
/// parsing end-to-end. The duplication is intentional (user
/// direction): per-chain code stays isolated.
///
/// **Two dispatch paths, by upstream identity.**
/// - **Balance + token reads → the shared `RPCClient` actor.** NEAR's
///   `query` method takes a NAMED-OBJECT `params` field (not a
///   positional array), so this connector uses the
///   `callJSONResultData(chain:method:paramsObject:)` variant — the
///   exact path the legacy `RealRPCBalanceScanner.fetchNearTokenBalance`
///   already proved reliable on device. It inherits the registered
///   `near-mainnet → near-lava` rotation
///   (`RPCRegistry.endpoints(for: .near)`), the 10 s timeout, the rate
///   limiter, and the circuit breaker. (The legacy `NEARChainAdapter`
///   balance read POSTed via a raw `URLSession` to dodge an old
///   `[String: Sendable] → [String: Any]` bridging quirk; the
///   named-params client variant is the supported path and is used
///   here — the connector contract forbids bypassing `RPCClient`.)
/// - **History → nearblocks.io directly.** NEAR's own mainnet RPC has
///   no "list transactions for account" method — every transaction
///   must be fetched by hash — and nearblocks.io (the canonical
///   indexer) is NOT a registered `RPCRegistry` endpoint for `.near`
///   (only the two JSON-RPC nodes are). So history GETs the indexer
///   directly with a 10 s timeout, exactly as
///   `LongTailTransactionAdapters.fetchNear` did, until an indexer slot
///   exists in `RPCRegistry`. The `txns-only` variant is used because
///   the plain `txns` endpoint returns receipt-shaped rows without
///   `signer_account_id`.
///
/// **Ported verbatim-faithful** from `NEARChainAdapter` (balance:
/// yoctoNEAR → NEAR, 10^24), `RealRPCBalanceScanner.fetchNearTokenBalance`
/// + `NearTokenRegistry` (NEP-141 byte-array decode), and
/// `LongTailTransactionAdapters.fetchNear` / `appendNearEvents`
/// (nearblocks `txns-only` pagination + signer/receiver direction +
/// `actions_agg.deposit` yoctoNEAR amounts + `outcomes.status`).
struct NearConnector: ChainConnector {
    let chain: SupportedChain = .near
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "near-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native NEAR balance + used-address flag via the `query`
    /// `view_account` request. Ported from
    /// `NEARChainAdapter.fetchAccountSummary`.
    ///
    /// `result.amount` is the account's balance in yoctoNEAR (10^24 per
    /// NEAR) → divided by 10^24. `isUsed` keys on balance > 0.
    ///
    /// **Unfunded account = zero, not a throw.** A NEAR account that
    /// doesn't exist on-chain yet is reported by the RPC either as a
    /// 200 whose `result` has no `amount` (the historical shape the
    /// legacy adapter handled) OR as a JSON-RPC error /
    /// `UNKNOWN_ACCOUNT` — `callJSONResultData` surfaces the latter as
    /// `.rpcError` / `.invalidResponse` / `.decodingFailed`. Both the
    /// missing-amount case and an HTTP-404-shaped failure map to a zero
    /// summary; only a genuine transport outage propagates. `.cancelled`
    /// always propagates.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let params: [String: Sendable] = [
            "request_type": "view_account",
            "finality":     "final",
            "account_id":   address,
        ]
        let data: Data
        do {
            data = try await client.callJSONResultData(
                chain: chain,
                method: "query",
                paramsObject: params
            )
        } catch {
            if case .cancelled = error { throw error }
            // A non-existent / unfunded NEAR account is reported as a
            // JSON-RPC error ("UNKNOWN_ACCOUNT") or a 404-shaped failure
            // — the normal "0 balance" state, not an outage worth
            // alarming. Map those to zero; rethrow everything else.
            if Self.isUnfundedAccount(error) {
                Self.log.debug("NEAR account \(address, privacy: .private) unfunded — treating as 0 balance")
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            throw error
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let amountStr = root["amount"] as? String,
              let yocto = Decimal(string: amountStr) else {
            // 2xx without a parseable `amount` is how NEAR reports an
            // account that doesn't exist yet — an unused address, not a
            // fault.
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let near = yocto / Self.yoctoPerNear
        return ChainAccountSummary(nativeBalance: near, isUsed: near > 0)
    }

    /// A NEAR `query view_account` failure that means "the account
    /// isn't on-chain," not "the chain is unreachable." Covers both the
    /// 404-shaped surface (`RPCError.isHTTPNotFound`) and NEAR's
    /// JSON-RPC `UNKNOWN_ACCOUNT` handler error.
    private static func isUnfundedAccount(_ error: RPCError) -> Bool {
        if RPCError.isHTTPNotFound(error) { return true }
        switch error {
        case .rpcError(_, let message), .invalidResponse(let message), .decodingFailed(let message):
            let lowered = message.lowercased()
            return lowered.contains("unknown_account")
                || lowered.contains("does not exist")
                || lowered.contains("doesn't exist")
        default:
            return false
        }
    }

    // MARK: - Token balances

    /// NEP-141 token balances for the chain's registry tokens + the
    /// user's `customContracts`, each via the `query`
    /// `call_function` → `ft_balance_of` view call. Ported from
    /// `RealRPCBalanceScanner.fetchNearTokenBalance` (byte-array decode)
    /// + `NearTokenRegistry`.
    ///
    /// Non-throwing per the `ChainConnector` contract: a per-token
    /// failure degrades to "no row for that token" (the `withTaskGroup`
    /// fan-out writes `nil` and skips it), never a fabricated zero.
    /// Only POSITIVE balances are returned (Rule #2 §A.7). `fiatBalance`
    /// is `nil` — pricing stays in the coordinator.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        // Registry tokens first, then the user's custom NEP-141 accounts
        // (deduplicated against the registry by lowercased account id).
        var specs: [TokenSpec] = NearTokenRegistry.tokens.map {
            TokenSpec(account: $0.tokenAccount, symbol: $0.symbol, name: $0.name, decimals: $0.decimals)
        }
        let known = Set(NearTokenRegistry.tokens.map { $0.tokenAccount.lowercased() })
        for account in customContracts where !known.contains(account.lowercased()) {
            // Custom contracts ship without registry metadata here; the
            // coordinator's custom-token pass owns symbol/name/decimals.
            // The connector still reads their balance so a user-added
            // token surfaces. NEP-141 has no on-chain decimals in the
            // balance call, so default to 24 (NEAR's native scale) — the
            // canonical amount is re-derived downstream from `ft_metadata`.
            specs.append(TokenSpec(account: account, symbol: Self.shortAccount(account), name: account, decimals: 24))
        }
        guard !specs.isEmpty else { return [] }

        let now = Date()
        var slots: [TokenBalance?] = Array(repeating: nil, count: specs.count)
        await withTaskGroup(of: (Int, TokenBalance?).self) { group in
            for (index, spec) in specs.enumerated() {
                group.addTask {
                    guard let raw = await self.fetchTokenBalance(holder: address, tokenAccount: spec.account) else {
                        return (index, nil)
                    }
                    let amount = raw / Self.pow10(spec.decimals)
                    guard amount > 0 else { return (index, nil) }
                    return (index, TokenBalance(
                        chain: self.chain,
                        address: address,
                        contract: spec.account,
                        symbol: spec.symbol,
                        name: spec.name,
                        decimals: spec.decimals,
                        amount: amount,
                        fiatBalance: nil,           // pricing stays in the coordinator
                        fiatCurrencyCode: "",       // coordinator stamps the active currency
                        lastUpdated: now
                    ))
                }
            }
            for await (index, row) in group {
                slots[index] = row
            }
        }
        return slots.compactMap { $0 }
    }

    /// One NEP-141 token's account + metadata — the connector's internal
    /// work item before a balance lands.
    private struct TokenSpec: Sendable {
        let account: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    /// Single NEP-141 `ft_balance_of` view call. Raw integer balance
    /// (token base units); `nil` when the call fails or the contract
    /// returns no parseable balance. Ported verbatim from
    /// `RealRPCBalanceScanner.fetchNearTokenBalance`.
    ///
    /// NEAR's `query` `call_function` runs a contract's view method with
    /// base64-encoded JSON args; the response carries the view-call
    /// return as a byte array under `result.result`. `ft_balance_of`
    /// returns a JSON string of the balance, so we rebuild the bytes →
    /// UTF-8 → strip the outer quotes → `Decimal`.
    private func fetchTokenBalance(holder: String, tokenAccount: String) async -> Decimal? {
        let argsJSON = "{\"account_id\":\"\(holder)\"}"
        let argsBase64 = Data(argsJSON.utf8).base64EncodedString()
        let params: [String: Sendable] = [
            "request_type": "call_function",
            "finality":     "final",
            "account_id":   tokenAccount,
            "method_name":  "ft_balance_of",
            "args_base64":  argsBase64,
        ]
        guard let data = try? await client.callJSONResultData(
            chain: chain,
            method: "query",
            paramsObject: params
        ),
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let resultBytes = result["result"] as? [Int] else {
            return nil
        }
        let bytes = resultBytes.compactMap { UInt8(exactly: $0) }
        guard let raw = String(data: Data(bytes), encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return Decimal(string: trimmed)
    }

    // MARK: - Transaction history

    /// nearblocks.io's `txns-only` page size — every plan honors 25;
    /// asking bigger risks a silent clamp that breaks short-page
    /// detection.
    private static let pageSize = 25

    /// nearblocks.io indexer host (keyless free tier). NOT a registered
    /// `RPCRegistry` endpoint — NEAR's own RPC can't serve account
    /// history — so this is GET directly.
    private static let indexerHost = "https://api.nearblocks.io"

    /// Recent NEAR history via nearblocks.io
    /// `/v1/account/{address}/txns-only`, paging through `page`/`per_page`
    /// in 25-tx batches until `limit`, an empty/short page (history
    /// exhausted), or a mid-pagination failure (keeps pages already
    /// fetched). Ported from `LongTailTransactionAdapters.fetchNear`.
    ///
    /// The free tier rate-limits aggressively; a mid-walk 429 therefore
    /// degrades to "deep but incomplete" honestly. `RPCError.cancelled`
    /// propagates on task cancellation. `customContracts` is unused
    /// (the indexer's `txns-only` feed is native-NEAR transfers) but
    /// kept for the uniform `ChainConnector` signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        var events: [TransactionEvent] = []
        var page = 1
        while events.count < limit {
            if Task.isCancelled { throw RPCError.cancelled }
            var components = URLComponents(string: Self.indexerHost)
            components?.path = "/v1/account/\(address)/txns-only"
            components?.queryItems = [
                URLQueryItem(name: "per_page", value: String(Self.pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            guard let url = components?.url else { break }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw RPCError.cancelled
            } catch {
                Self.log.error("NEAR history page \(page, privacy: .public) failed — keeping \(events.count, privacy: .public) events: \(String(describing: error), privacy: .public)")
                break
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                Self.log.error("NEAR history page \(page, privacy: .public) returned non-2xx — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let txs = root["txns"] as? [[String: Any]] else {
                break
            }
            if txs.isEmpty { break }
            appendEvents(from: txs, address: address, limit: limit, into: &events)
            if txs.count < Self.pageSize { break } // history exhausted
            page += 1
            if events.count >= limit {
                Self.log.info("NEAR history hit the \(limit, privacy: .public)-event cap — older rows not fetched this scan")
            }
        }
        return events
    }

    /// Parse one nearblocks `txns-only` page, appending events until
    /// `limit`. Ported verbatim from
    /// `LongTailTransactionAdapters.appendNearEvents`.
    ///
    /// `actions_agg.deposit` is the yoctoNEAR amount transferred (served
    /// as a JSON number; a string is accepted defensively for older
    /// payload shapes). `block_timestamp` is nanoseconds since epoch.
    /// `outcomes.status` is a String ("SUCCESS"/"FAILURE") — a Bool is
    /// accepted defensively; anything that isn't an explicit success
    /// maps to `.failed`. Direction is signer/receiver vs. the wallet
    /// address.
    private func appendEvents(
        from txs: [[String: Any]],
        address: String,
        limit: Int,
        into events: inout [TransactionEvent]
    ) {
        events.reserveCapacity(min(events.count + txs.count, limit))
        for tx in txs {
            if events.count >= limit { break }
            guard let hash = tx["transaction_hash"] as? String,
                  let signer = tx["signer_account_id"] as? String,
                  let receiver = tx["receiver_account_id"] as? String else {
                continue
            }
            let actionsAgg = tx["actions_agg"] as? [String: Any] ?? [:]
            let depositRaw: Decimal
            if let s = actionsAgg["deposit"] as? String, let dec = Decimal(string: s) {
                depositRaw = dec
            } else if let n = actionsAgg["deposit"] as? NSDecimalNumber {
                depositRaw = n.decimalValue
            } else if let n = actionsAgg["deposit"] as? NSNumber {
                depositRaw = Decimal(n.doubleValue)
            } else {
                depositRaw = 0
            }
            // NEAR uses 24 decimals (yoctoNEAR → NEAR).
            let amount = depositRaw / Self.pow10(24)
            let blockTimestampStr = (tx["block_timestamp"] as? String) ?? "0"
            // NEAR `block_timestamp` is nanoseconds since epoch.
            let nanos = Int64(blockTimestampStr) ?? 0
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(nanos) / 1_000_000_000)
            let blockHeight = ((tx["block"] as? [String: Any])?["block_height"] as? NSNumber)?.int64Value

            let outcomes = tx["outcomes"] as? [String: Any] ?? [:]
            let success: Bool
            if let statusString = outcomes["status"] as? String {
                success = statusString.uppercased() == "SUCCESS"
            } else if let statusBool = outcomes["status"] as? Bool {
                success = statusBool
            } else {
                success = true
            }

            let direction: TransactionDirection
            let counterparty: String
            if signer == address && receiver == address {
                direction = .internal
                counterparty = ""
            } else if signer == address {
                direction = .outgoing
                counterparty = receiver
            } else if receiver == address {
                direction = .incoming
                counterparty = signer
            } else {
                continue
            }

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: hash,
                direction: direction,
                amount: amount,
                tokenSymbol: "NEAR",
                tokenContract: nil,
                blockNumber: blockHeight,
                occurredAt: occurredAt,
                status: success ? .confirmed : .failed,
                counterparty: counterparty,
                fee: nil
            ))
        }
    }

    // MARK: - Helpers

    /// Short label for a custom NEP-141 account id when no registry
    /// metadata exists (e.g. a 64-hex implicit token account).
    private static func shortAccount(_ account: String) -> String {
        if account.count > 14 {
            return String(account.prefix(6)) + "…" + String(account.suffix(6))
        }
        return account
    }

    /// 10^n as `Decimal`, clamped to a sane range. NEAR's native scale
    /// is 24; NEP-141 tokens are typically 6 (USDC/USDT) or 18/24.
    private static func pow10(_ n: Int) -> Decimal {
        let clamped = min(max(n, 0), 38)
        var r = Decimal(1)
        for _ in 0..<clamped { r *= 10 }
        return r
    }

    /// 10^24 — NEAR's smallest unit is the yoctoNEAR.
    private static let yoctoPerNear: Decimal = {
        var n = Decimal(1)
        for _ in 0..<24 { n *= 10 }
        return n
    }()
}
