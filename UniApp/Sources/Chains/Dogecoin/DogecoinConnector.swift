import Foundation
import OSLog

/// **Dogecoin connector — the BlockCypher REST / UTXO sibling.**
///
/// A FULLY INDEPENDENT module for `.dogecoin`. It mirrors the
/// `BitcoinConnector` REST/UTXO template (address balance + paginated
/// vin/vout history with the self-send `LedgerView` classifier) but
/// owns Dogecoin's OWN provider shape — BlockCypher, NOT Esplora.
/// Dogecoin has no clean keyless Esplora index that still serves JSON
/// to a non-browser client (dogechain.info gates every non-browser
/// request behind a Cloudflare interstitial; blockchair is keyed;
/// sochain/dogeblocks 502; Trezor doge1 returns Cloudflare HTML — see
/// `RPCRegistry.dogecoinEndpoints`), so DOGE runs on
/// `api.blockcypher.com/v1/doge/main` alone, the canonical free DOGE
/// index API. BlockCypher's keyless tier is the most fragile UTXO
/// source the registry measured (~100 req/hr, 429s under concurrency),
/// which is why its endpoint is registered at `.blockCypherKeyless`
/// (~0.5 req/s, burst 1) with a per-host `ConcurrencyGate` slot — the
/// connector inherits that throttling for free by dispatching through
/// `RPCClient`.
///
/// Every call dispatches through the shared `RPCClient` actor via
/// `callREST` (rotation + rate-limit + circuit-breaking + ConcurrencyGate)
/// against `RPCRegistry.endpoints(for: .dogecoin)`. Never a raw
/// `URLSession`. The duplication versus `BitcoinConnector` is intentional
/// (user direction): DOGE's provider quirk (BlockCypher's
/// `addrs/{addr}/balance` integer-koinu balance, its `n_tx` count, its
/// `addrs/{addr}/full?limit=N&before=H` cursor pagination with the root
/// `hasMore` flag, its `inputs[].addresses[]`/`output_value` +
/// `outputs[].addresses[]`/`value` arrays, and its ISO-8601 `confirmed`
/// timestamps) stays isolated in this file and never leaks into a sibling.
///
/// **Ported verbatim-faithful** from `BitcoinFamilyAdapter.fetchBlockCypher`
/// (balance) and `BitcoinFamilyTransactionAdapter.fetchBlockCypher`
/// (history): same `addrs/{addr}/balance` (`balance` koinu / 10^8, `n_tx`
/// count for `isUsed`), same `addrs/{addr}/full?limit=50&before=H` cursor
/// pagination keyed on the minimum confirmed `block_height` and gated by
/// the root `hasMore` flag, same `inputs[].addresses[0]`/`output_value` +
/// `outputs[].addresses[0]`/`value` ledger reduction, same 8 decimals
/// (satoshisPerCoin = 10^8 — Doge's smallest unit is the koinu /
/// dogetoshi), same `block_height > 0` ⇒ confirmed heuristic, same
/// self-send `.internal` keying.
struct DogecoinConnector: ChainConnector {
    let chain: SupportedChain = .dogecoin
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "dogecoin-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native DOGE balance + used-address flag via BlockCypher's
    /// `addrs/{addr}/balance`. Ported from
    /// `BitcoinFamilyAdapter.fetchBlockCypher`.
    ///
    /// BlockCypher returns `{address, total_received, total_sent,
    /// balance, unconfirmed_balance, final_balance, n_tx, …}` — `balance`
    /// is the confirmed balance in koinu (divided by 10^8 here) and
    /// `n_tx` is the address's total tx count. `isUsed` prefers `n_tx`
    /// (> 0) so an emptied address (balance 0 but n_tx > 0) still reads
    /// as used — gap-limit scanning must not terminate early on emptied
    /// addresses; it falls back to `balance > 0` only when `n_tx` is
    /// absent. An HTTP 404 for a never-funded address maps to a zero
    /// summary per the `ChainConnector` contract.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data: Data
        do {
            data = try await client.callREST(chain: chain, path: "addrs/\(address)/balance")
        } catch {
            if case .cancelled = error { throw error }
            if RPCError.isHTTPNotFound(error) {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            throw error
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .decodingFailed("BlockCypher response not JSON")
        }
        let units: Decimal
        if let n = json["balance"] as? NSNumber {
            units = NSDecimalNumber(value: n.int64Value).decimalValue
        } else if let i = json["balance"] as? Int {
            units = Decimal(i)
        } else {
            throw .decodingFailed("BlockCypher balance field missing or wrong type")
        }
        let coins = units / Self.satoshisPerCoin
        if let nTx = (json["n_tx"] as? NSNumber)?.intValue {
            return ChainAccountSummary(nativeBalance: coins, isUsed: nTx > 0)
        }
        return ChainAccountSummary(nativeBalance: coins, isUsed: coins > 0)
    }

    // MARK: - Token balances

    /// Dogecoin has no fungible-token layer Aperture tracks — the native
    /// coin is the only asset. Returns `[]` honestly (matching
    /// `BitcoinConnector`); it exists to satisfy the `ChainConnector`
    /// contract uniformly. The parameter is kept for the uniform signature.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history

    /// BlockCypher's documented per-page maximum for `/full`.
    private static let pageSize = 50

    /// Recent DOGE history via BlockCypher's full-address endpoint —
    /// `addrs/{addr}/full?limit=50[&before=H]` → `{ txs: [...], hasMore }`
    /// where each tx carries `inputs[].addresses[0]` + `output_value`
    /// (the value the input consumed) and `outputs[].addresses[0]` +
    /// `value` (koinu), `confirmed` (ISO-8601), `block_height` (−1 while
    /// unconfirmed) and `fees`. Ported verbatim from
    /// `BitcoinFamilyTransactionAdapter.fetchBlockCypher`.
    ///
    /// BlockCypher pages with the `before={blockHeight}` cursor
    /// (exclusive — the minimum confirmed height seen this page) and
    /// signals more data via the root `hasMore` flag; its per-page
    /// maximum is 50. Pages run sequentially through the rate-limited
    /// `RPCClient` until `limit` events (the per-chain full-history cap —
    /// logged when hit), `hasMore == false`, an all-mempool page (no
    /// confirmed boundary height to form the next cursor — stop
    /// honestly), or a mid-pagination failure — which keeps the pages
    /// already fetched (`RPCError.cancelled` still propagates immediately).
    ///
    /// `customContracts` is unused (Dogecoin has no token transfers) but
    /// kept for the uniform `ChainConnector` signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let lower = address.lowercased()
        var events: [TransactionEvent] = []
        var before: Int64?
        while events.count < limit {
            var query = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
            if let before {
                query.append(URLQueryItem(name: "before", value: String(before)))
            }
            let data: Data
            do {
                data = try await client.callREST(
                    chain: chain,
                    path: "addrs/\(address)/full",
                    query: query
                )
            } catch {
                if case .cancelled = error { throw error }
                if before == nil { throw error }
                Self.log.warning("BlockCypher page before \(before ?? 0, privacy: .public) failed on \(self.chain.rawValue, privacy: .public) — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let txs = root["txs"] as? [[String: Any]] else {
                Self.log.warning("BlockCypher response not in expected shape for \(self.chain.rawValue, privacy: .public)")
                break
            }
            if txs.isEmpty { break }
            var minHeight: Int64?
            for raw in txs {
                guard let txid = raw["hash"] as? String else { continue }
                let blockHeight = (raw["block_height"] as? NSNumber)?.int64Value ?? -1
                if blockHeight > 0 {
                    minHeight = min(minHeight ?? blockHeight, blockHeight)
                }
                if events.count >= limit { continue }
                let confirmedStr = raw["confirmed"] as? String
                let confirmed = blockHeight > 0 && confirmedStr != nil
                let occurredAt = confirmedStr.flatMap { Self.iso8601.date(from: $0) } ?? Date()

                var view = LedgerView()
                for input in raw["inputs"] as? [[String: Any]] ?? [] {
                    let addr = (input["addresses"] as? [String])?.first ?? ""
                    let value = (input["output_value"] as? NSNumber)?.int64Value ?? 0
                    view.addInput(address: addr, value: value, isUser: addr.lowercased() == lower)
                }
                for output in raw["outputs"] as? [[String: Any]] ?? [] {
                    let addr = (output["addresses"] as? [String])?.first ?? ""
                    let value = (output["value"] as? NSNumber)?.int64Value ?? 0
                    view.addOutput(address: addr, value: value, isUser: addr.lowercased() == lower)
                }

                events.append(event(
                    txid: txid,
                    address: address,
                    view: view,
                    blockNumber: blockHeight > 0 ? blockHeight : nil,
                    occurredAt: occurredAt,
                    confirmed: confirmed,
                    feeSats: (raw["fees"] as? NSNumber)?.int64Value
                ))
            }
            let hasMore = (root["hasMore"] as? Bool) ?? false
            // No confirmed boundary height → can't form the next cursor
            // (an all-mempool page); stop honestly.
            guard hasMore, let nextBefore = minHeight, nextBefore != before else { break }
            before = nextBefore
            if events.count >= limit {
                Self.log.info("BlockCypher history on \(self.chain.rawValue, privacy: .public) hit the \(limit, privacy: .public)-event cap — older rows not fetched this scan")
            }
        }
        return events
    }

    // MARK: - Ledger classification (ported verbatim)

    /// Net ledger view of one transaction from the wallet address's
    /// perspective — built from BlockCypher's `inputs[]`/`outputs[]`,
    /// classified once. Address-less inputs/outputs (coinbase,
    /// OP_RETURN, nonstandard scripts) carry no payer/payee and don't
    /// count against self-send.
    private struct LedgerView {
        var userSpent: Int64 = 0
        var userReceived: Int64 = 0
        var firstOtherInput: String?
        var firstOtherOutput: String?
        var allInputsBelongToUser = true
        var allOutputsBelongToUser = true

        mutating func addInput(address: String, value: Int64, isUser: Bool) {
            if isUser, !address.isEmpty {
                userSpent &+= value
            } else if !address.isEmpty {
                allInputsBelongToUser = false
                if firstOtherInput == nil { firstOtherInput = address }
            }
        }

        mutating func addOutput(address: String, value: Int64, isUser: Bool) {
            if isUser, !address.isEmpty {
                userReceived &+= value
            } else if !address.isEmpty {
                allOutputsBelongToUser = false
                if firstOtherOutput == nil { firstOtherOutput = address }
            }
        }
    }

    /// Map a `LedgerView` → direction + counterparty + display amount
    /// (koinu). Self-send (user funded every addressed input AND every
    /// addressed output returns to the user) → `.internal` keyed on
    /// ownership, not on a zero net (a real self-send nets exactly −fee).
    /// Ported from `BitcoinFamilyTransactionAdapter.classify`.
    private static func classify(_ view: LedgerView) -> (direction: TransactionDirection, counterparty: String, amountSats: Int64) {
        let netSats = view.userReceived &- view.userSpent
        if view.userSpent > 0 && view.userReceived > 0
            && view.allInputsBelongToUser && view.allOutputsBelongToUser {
            return (.internal, "", view.userReceived)
        }
        if view.userSpent > 0 && view.userReceived > 0 && netSats == 0 {
            return (.outgoing, view.firstOtherOutput ?? "", 0)
        }
        if netSats >= 0 {
            return (.incoming, view.firstOtherInput ?? "", netSats)
        }
        return (.outgoing, view.firstOtherOutput ?? "", -netSats)
    }

    /// Build the uniform `TransactionEvent` from a classified view. Fee
    /// attaches to `.outgoing` AND `.internal` (the user paid it in both).
    private func event(
        txid: String,
        address: String,
        view: LedgerView,
        blockNumber: Int64?,
        occurredAt: Date,
        confirmed: Bool,
        feeSats: Int64?
    ) -> TransactionEvent {
        let (direction, counterparty, amountSats) = Self.classify(view)
        let fee: Decimal? = (direction == .outgoing || direction == .internal)
            ? feeSats.map { Decimal($0) / Self.satoshisPerCoin }
            : nil
        return TransactionEvent(
            chain: chain,
            address: address,
            txHash: txid,
            direction: direction,
            amount: Decimal(amountSats) / Self.satoshisPerCoin,
            tokenSymbol: chain.ticker,
            tokenContract: nil,
            blockNumber: blockNumber,
            occurredAt: occurredAt,
            status: confirmed ? .confirmed : .pending,
            counterparty: counterparty,
            fee: fee
        )
    }

    /// Hoisted formatter for BlockCypher's `confirmed` timestamps
    /// ("2026-05-26T14:05:12Z" — no fractional seconds).
    /// `ISO8601DateFormatter` is documented thread-safe by Apple, so the
    /// `nonisolated(unsafe)` opt-out is sound.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    /// 10^8 — Dogecoin's smallest unit is the koinu (dogetoshi).
    private static let satoshisPerCoin: Decimal = 100_000_000
}
