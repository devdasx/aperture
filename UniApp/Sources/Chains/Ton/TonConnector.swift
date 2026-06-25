import Foundation
import OSLog

/// **TON connector — the toncenter v2 REST reference for the chain.**
///
/// A FULLY INDEPENDENT module for `.ton`: its own toncenter
/// `getAddressBalance` native read and its own paginated
/// `getTransactions` `in_msg` / `out_msgs` history. It owns its request
/// shapes + parsing end-to-end and dispatches every call through the
/// shared `RPCClient` actor via `callREST` (rotation + rate-limit +
/// circuit-breaking + ConcurrencyGate) against the registered endpoints
/// `RPCRegistry.endpoints(for: .ton)` (toncenter primary, tonapi
/// fallback). Never a raw `URLSession`.
///
/// **Ported verbatim-faithful** from `TONChainAdapter.fetchAccountSummary`
/// (balance) and `LongTailTransactionAdapters.fetchTon` (history): same
/// `getAddressBalance?address=` path, same `result` nano string → /10^9
/// math, same paginated `getTransactions?address=&limit=&lt=&hash=`
/// cursor walk, same `in_msg` (incoming) / `out_msgs` (outgoing) leg
/// classification, same `#out{i}` batch-send leg-suffix disambiguation,
/// same `tonLtString` cursor normalization, same 9-decimals
/// (`nanosPerCoin = 10^9`).
///
/// **Why no `.internal` self-send classification (unlike Bitcoin).** The
/// existing TON adapter classifies purely on message direction
/// (`in_msg.source` → incoming, each valued `out_msg` → outgoing); TON's
/// actor/message model has no UTXO vin/vout to reconcile into a net
/// self-send, so this connector preserves that direction-per-message
/// shape verbatim rather than inventing a self-send heuristic.
///
/// **Token (Jetton) balances.** TON's fungible tokens are TIP-3 Jettons,
/// whose balances live in per-user jetton wallets derived off-chain via
/// the master's `get_wallet_address` + `get_wallet_data` get-methods
/// (`runGetMethod`). That derivation is significant per-chain plumbing
/// the existing balance scanner has NOT shipped — `RealRPCBalanceScanner`
/// routes `.ton` to its `default: return` (no jetton scanning), and
/// `TONJettonRegistry` exists only to surface jettons on the Receive
/// screen + signing. To stay verbatim-faithful, `fetchTokenBalances`
/// returns `[]` honestly (Rule #16) rather than fabricating zeros or
/// half-porting an unshipped derivation path.
struct TonConnector: ChainConnector {
    let chain: SupportedChain = .ton
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "ton-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native TON balance + used-address flag via toncenter's
    /// `getAddressBalance?address={addr}`. Ported from
    /// `TONChainAdapter.fetchAccountSummary`.
    ///
    /// The JSON envelope is `{ "ok": true, "result": "<nano-string>" }`;
    /// `result` is the balance in nanotons (10^9 nano = 1 TON), divided
    /// by 10^9 here. `isUsed` keys on a positive balance — toncenter's
    /// balance path is the only honest signal the adapter reads (it does
    /// not separately query account state / seqno), matching the existing
    /// `TONChainAdapter` exactly.
    ///
    /// Typed throws: `RPCError.cancelled` on cancellation,
    /// `.allEndpointsFailed` / `.network` / `.rateLimited` on a genuine
    /// outage. A 404 (unfunded / uninitialized account) maps to a zero
    /// summary rather than throwing — the normal "never funded" state.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            let data = try await client.callREST(
                chain: chain,
                path: "getAddressBalance",
                query: [URLQueryItem(name: "address", value: address)]
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultStr = json["result"] as? String,
                  let nano = Decimal(string: resultStr) else {
                // toncenter served 2xx but no parseable `result` string —
                // treat as a zero balance (the existing adapter does the
                // same), never a fabricated non-zero.
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            let ton = nano / Self.nanosPerCoin
            return ChainAccountSummary(nativeBalance: ton, isUsed: ton > 0)
        } catch {
            // An unfunded / uninitialized TON account surfaced as HTTP 404
            // is the normal zero state, not a failure.
            if RPCError.isHTTPNotFound(error) {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            throw error
        }
    }

    // MARK: - Token balances

    /// TON Jetton (TIP-3) balance scanning is NOT shipped — reading a
    /// jetton balance requires deriving the per-user jetton wallet via the
    /// master's `get_wallet_address` + `get_wallet_data` get-methods
    /// (`runGetMethod`), which the existing `RealRPCBalanceScanner` does
    /// not do (it routes `.ton` to `default: return`). Returns `[]`
    /// honestly (Rule #16) rather than fabricating zeros — when the jetton
    /// derivation path ships, this connector gains its own copy of it.
    ///
    /// `customContracts` is accepted for the uniform `ChainConnector`
    /// signature but unused (no jetton read path exists yet).
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history

    /// toncenter's per-call maximum page size.
    private static let maxPageSize = 100

    /// Recent TON history via toncenter's
    /// `getTransactions?address={addr}&limit=N`, paging on the
    /// `lt` + `hash` cursor of the OLDEST transaction of the previous
    /// page until `limit` events, a page with no new transactions
    /// (history exhausted), or a mid-pagination failure (keeps pages
    /// already fetched; `RPCError.cancelled` still propagates). Ported
    /// from `LongTailTransactionAdapters.fetchTon`.
    ///
    /// Direction is classified per message (TON's actor model):
    /// - `in_msg` with a non-empty `source` and inbound value > 0 → one
    ///   `.incoming` row.
    /// - each `out_msg` with a non-empty `destination` and value > 0 →
    ///   one `.outgoing` row.
    ///
    /// **Batch-send leg identity.** A TON wallet contract can emit up to
    /// 4 messages from one external (batch send), every leg sharing the
    /// same `transaction_id.hash`. When a transaction carries multiple
    /// valued out-messages, each leg's `txHash` gets a `#out{i}` suffix
    /// ("#" never occurs in TON's base64 hashes, so it's unambiguous and
    /// strippable). A single out-message keeps the raw hash — its
    /// direction already distinguishes it from the inbound leg.
    ///
    /// `customContracts` is accepted for the uniform `ChainConnector`
    /// signature but unused (jetton-transfer rows are not parsed — only
    /// native TON message legs, matching the existing adapter).
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let path = "getTransactions"
        let pageSize = min(limit, Self.maxPageSize)
        var events: [TransactionEvent] = []
        var cursorLt: String?
        var cursorHash: String?
        var seenRawHashes = Set<String>()
        pageLoop: while events.count < limit {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "address", value: address),
                URLQueryItem(name: "limit", value: String(pageSize)),
            ]
            if let cursorLt, let cursorHash {
                query.append(URLQueryItem(name: "lt", value: cursorLt))
                query.append(URLQueryItem(name: "hash", value: cursorHash))
            }
            let data: Data
            do {
                data = try await client.callREST(chain: chain, path: path, query: query)
            } catch {
                if case .cancelled = error { throw error }
                if RPCError.isHTTPNotFound(error) {
                    Self.log.warning("TON history endpoint returned 404 — keeping \(events.count, privacy: .public) events")
                    break
                }
                // Keep the pages already fetched on a mid-pagination
                // failure; only the first page failing is a hard error.
                if cursorLt == nil { throw error }
                Self.log.warning("TON page failed — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let txs = root["result"] as? [[String: Any]] else {
                break
            }
            var sawNewTx = false
            for tx in txs {
                guard let transactionId = tx["transaction_id"] as? [String: Any],
                      let hash = transactionId["hash"] as? String,
                      let utime = tx["utime"] as? Int64 else {
                    continue
                }
                // Skip the inclusive cursor-boundary repeat.
                guard seenRawHashes.insert(hash).inserted else { continue }
                sawNewTx = true
                if events.count >= limit {
                    Self.log.info("TON history hit the \(limit, privacy: .public)-event cap — older rows not fetched this scan")
                    break pageLoop
                }
                let inMsg = tx["in_msg"] as? [String: Any]
                let outMsgs = tx["out_msgs"] as? [[String: Any]] ?? []

                // Incoming: in_msg.source is non-empty AND inbound value > 0.
                if let inMsg, let valueStr = inMsg["value"] as? String,
                   let valueNano = Int64(valueStr), valueNano > 0,
                   let source = inMsg["source"] as? String, !source.isEmpty {
                    let amount = Decimal(valueNano) / Self.nanosPerCoin
                    events.append(TransactionEvent(
                        chain: chain,
                        address: address,
                        txHash: hash,
                        direction: .incoming,
                        amount: amount,
                        tokenSymbol: chain.ticker,
                        tokenContract: nil,
                        blockNumber: nil,
                        occurredAt: Date(timeIntervalSince1970: TimeInterval(utime)),
                        status: .confirmed,
                        counterparty: source,
                        fee: nil
                    ))
                }
                // Outgoing: each out_msg with value > 0 is one outgoing leg.
                let valuedOutMsgs: [(dest: String, valueNano: Int64)] = outMsgs.compactMap { outMsg in
                    guard let valueStr = outMsg["value"] as? String,
                          let valueNano = Int64(valueStr), valueNano > 0,
                          let dest = outMsg["destination"] as? String, !dest.isEmpty else {
                        return nil
                    }
                    return (dest, valueNano)
                }
                for (index, leg) in valuedOutMsgs.enumerated() {
                    let legHash = valuedOutMsgs.count > 1 ? "\(hash)#out\(index)" : hash
                    let amount = Decimal(leg.valueNano) / Self.nanosPerCoin
                    events.append(TransactionEvent(
                        chain: chain,
                        address: address,
                        txHash: legHash,
                        direction: .outgoing,
                        amount: amount,
                        tokenSymbol: chain.ticker,
                        tokenContract: nil,
                        blockNumber: nil,
                        occurredAt: Date(timeIntervalSince1970: TimeInterval(utime)),
                        status: .confirmed,
                        counterparty: leg.dest,
                        fee: nil
                    ))
                }
            }
            // Advance the cursor to the OLDEST transaction of this page;
            // toncenter walks backwards from (lt, hash). No new
            // transactions = the cursor repeat was the whole page
            // (history exhausted).
            guard sawNewTx,
                  let lastId = txs.last?["transaction_id"] as? [String: Any],
                  let lastLt = Self.tonLtString(lastId["lt"]),
                  let lastHash = lastId["hash"] as? String,
                  lastHash != cursorHash else { break }
            cursorLt = lastLt
            cursorHash = lastHash
            if txs.count < pageSize { break } // history exhausted
        }
        return events
    }

    // MARK: - Helpers (ported verbatim)

    /// toncenter serves `transaction_id.lt` as a string on v2 but a
    /// number on some mirrors — normalize either to the decimal string
    /// the `lt` query param expects. Ported from
    /// `LongTailTransactionAdapters.tonLtString`.
    private static func tonLtString(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// 10^9 — TON's smallest unit is the nanoton.
    private static let nanosPerCoin: Decimal = 1_000_000_000
}
