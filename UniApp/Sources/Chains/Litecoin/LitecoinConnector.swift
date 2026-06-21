import Foundation
import OSLog

/// **Litecoin connector — REST / UTXO, the Esplora-with-fallback sibling.**
///
/// A FULLY INDEPENDENT module for `.litecoin`, copied from
/// `BitcoinConnector` (the REST/UTXO template) and adapted to
/// Litecoin's registered providers. It owns its request shapes +
/// parsing end-to-end and dispatches every call through the shared
/// `RPCClient` actor via `callREST` (rotation + rate-limit +
/// circuit-breaking + ConcurrencyGate) against the endpoints
/// `RPCRegistry.endpoints(for: .litecoin)` — never a raw `URLSession`.
///
/// **Two provider shapes (ported verbatim from `BitcoinFamilyAdapter`).**
/// Litecoin registers two REST providers with *different* URL shapes:
///   1. **litecoinspace.org** (Esplora) — the primary that carries the
///      load. Same shape as Bitcoin's mempool.space / blockstream:
///      `address/{addr}` for balance, `address/{addr}/txs[/chain/{txid}]`
///      for paginated vin/vout history.
///   2. **BlockCypher** (`/v1/ltc/main`) — the rate-capped
///      (`.blockCypherKeyless`, ~0.5 req/s) last-resort fallback,
///      reached only when litecoinspace fails. It speaks
///      `addrs/{addr}/balance`, NOT Esplora's `address/{addr}`.
///
/// Because `callREST` appends ONE path to every registered endpoint,
/// `fetchNativeBalance` runs the Esplora-shaped pass first and, on a
/// non-cancellation failure, a BlockCypher-shaped pass — mirroring
/// `BitcoinFamilyAdapter.fetchAccountSummary`'s `.litecoin` branch.
/// `fetchHistory` is Esplora-only (litecoinspace), exactly as
/// `BitcoinFamilyTransactionAdapter.fetch` routes `.litecoin` — the
/// BlockCypher fallback exposes no equivalent paginated tx list that
/// adapter consumes, so history degrades gracefully to the pages
/// already fetched rather than switching providers mid-stream.
///
/// **Ported verbatim-faithful**: same `chain_stats funded−spent`
/// satoshi math, same 8-decimals (litoshi, 10^8 per LTC), same
/// vin/vout `LedgerView` classification, same self-send `.internal`
/// keying, same per-page cursor pagination, same mid-pagination
/// failure handling.
struct LitecoinConnector: ChainConnector {
    let chain: SupportedChain = .litecoin
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "litecoin-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native LTC balance + used-address flag.
    ///
    /// litecoinspace (Esplora) primary shape first; on a
    /// non-cancellation failure, the registered BlockCypher fallback
    /// shape. Ported from `BitcoinFamilyAdapter.fetchAccountSummary`'s
    /// `.litecoin` branch.
    ///
    /// litecoinspace returns zero-stats JSON for a valid-but-unfunded
    /// address (not a 404), so the Esplora path covers unfunded
    /// accounts honestly without special-casing; an HTTP 404 from
    /// either provider for an unfunded account is mapped to a zero
    /// summary per the `ChainConnector` contract.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        do {
            return try await fetchEsploraBalance(address: address)
        } catch {
            if case .cancelled = error { throw error }
            if RPCError.isHTTPNotFound(error) {
                return ChainAccountSummary(nativeBalance: 0, isUsed: false)
            }
            Self.log.warning("litecoinspace balance failed — falling back to BlockCypher shape")
            do {
                return try await fetchBlockCypherBalance(address: address)
            } catch {
                if case .cancelled = error { throw error }
                if RPCError.isHTTPNotFound(error) {
                    return ChainAccountSummary(nativeBalance: 0, isUsed: false)
                }
                throw error
            }
        }
    }

    /// litecoinspace (Esplora) `/address/{addr}`.
    /// `chain_stats.funded_txo_sum − chain_stats.spent_txo_sum` =
    /// current confirmed balance in litoshi → divided by 10^8.
    /// `isUsed` keys on the tx count (confirmed OR mempool) so an
    /// emptied address (balance 0 but tx_count > 0) still reads as used.
    private func fetchEsploraBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data = try await client.callREST(chain: chain, path: "address/\(address)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .decodingFailed("Esplora response not JSON")
        }
        let chainStats = json["chain_stats"] as? [String: Any] ?? [:]
        let mempoolStats = json["mempool_stats"] as? [String: Any] ?? [:]
        let funded = (chainStats["funded_txo_sum"] as? NSNumber)?.int64Value ?? 0
        let spent = (chainStats["spent_txo_sum"] as? NSNumber)?.int64Value ?? 0
        let txCount = (chainStats["tx_count"] as? NSNumber)?.intValue ?? 0
        // Include the mempool (unconfirmed) delta so an incoming pending tx is
        // reflected in the balance immediately, not only after confirmation.
        let mempoolFunded = (mempoolStats["funded_txo_sum"] as? NSNumber)?.int64Value ?? 0
        let mempoolSpent = (mempoolStats["spent_txo_sum"] as? NSNumber)?.int64Value ?? 0
        let mempoolTxCount = (mempoolStats["tx_count"] as? NSNumber)?.intValue ?? 0

        let litoshi = NSDecimalNumber(value: (funded - spent) + (mempoolFunded - mempoolSpent)).decimalValue
        let nativeBalance = litoshi / Self.litoshiPerCoin
        let isUsed = txCount > 0 || mempoolTxCount > 0
        return ChainAccountSummary(nativeBalance: nativeBalance, isUsed: isUsed)
    }

    /// BlockCypher fallback — `addrs/{addr}/balance` → JSON with
    /// `balance` as a number in litoshi (10^8 per LTC) and `n_tx`
    /// (total tx count). Ported from `BitcoinFamilyAdapter.fetchBlockCypher`.
    /// Prefer `n_tx` for `isUsed` — an emptied address has balance 0
    /// but `n_tx > 0`; deriving `isUsed` from balance alone would
    /// terminate gap-limit scanning too early.
    private func fetchBlockCypherBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data = try await client.callREST(chain: chain, path: "addrs/\(address)/balance")
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
        let coins = units / Self.litoshiPerCoin
        if let nTx = (json["n_tx"] as? NSNumber)?.intValue {
            return ChainAccountSummary(nativeBalance: coins, isUsed: nTx > 0)
        }
        return ChainAccountSummary(nativeBalance: coins, isUsed: coins > 0)
    }

    // MARK: - Token balances

    /// Litecoin has no fungible-token layer Aperture tracks — the
    /// native coin is the only asset. Returns `[]` honestly (matching
    /// `BitcoinConnector`); it exists to satisfy the `ChainConnector`
    /// contract uniformly.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history

    /// Esplora's fixed confirmed-history page size.
    private static let esploraPageSize = 25

    /// Recent LTC history via litecoinspace (Esplora)
    /// `/address/{addr}/txs`, paging through
    /// `/address/{addr}/txs/chain/{last_seen_txid}` in 25-tx batches
    /// until `limit`, an empty page (history exhausted), or a
    /// mid-pagination failure (keeps pages already fetched). Ported
    /// verbatim from `BitcoinFamilyTransactionAdapter.fetchEsplora`.
    ///
    /// History is Esplora-only — the same routing the existing
    /// `BitcoinFamilyTransactionAdapter.fetch` uses for `.litecoin`.
    /// `customContracts` is unused (Litecoin has no token transfers)
    /// but kept for the uniform `ChainConnector` signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let lower = address.lowercased()
        var events: [TransactionEvent] = []
        var lastTxid: String?
        while events.count < limit {
            let path = lastTxid.map { "address/\(address)/txs/chain/\($0)" } ?? "address/\(address)/txs"
            let data: Data
            do {
                data = try await client.callREST(chain: chain, path: path)
            } catch {
                if case .cancelled = error { throw error }
                if lastTxid == nil { throw error }
                Self.log.warning("Esplora page after \(lastTxid ?? "-", privacy: .public) failed on \(self.chain.rawValue, privacy: .public) — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let txs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                Self.log.warning("Esplora response not an array for \(self.chain.rawValue, privacy: .public)")
                break
            }
            if txs.isEmpty { break }
            for raw in txs {
                if events.count >= limit { break }
                guard let txid = raw["txid"] as? String else { continue }
                let status = raw["status"] as? [String: Any] ?? [:]
                let confirmed = status["confirmed"] as? Bool ?? false
                let blockHeight = status["block_height"] as? Int64
                let blockTime = status["block_time"] as? Int64
                let occurredAt = blockTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()

                var view = LedgerView()
                for input in raw["vin"] as? [[String: Any]] ?? [] {
                    guard let prev = input["prevout"] as? [String: Any] else { continue }
                    let inputAddr = (prev["scriptpubkey_address"] as? String) ?? ""
                    let value = (prev["value"] as? Int64) ?? 0
                    view.addInput(address: inputAddr, value: value, isUser: inputAddr.lowercased() == lower)
                }
                for output in raw["vout"] as? [[String: Any]] ?? [] {
                    let outputAddr = (output["scriptpubkey_address"] as? String) ?? ""
                    let value = (output["value"] as? Int64) ?? 0
                    view.addOutput(address: outputAddr, value: value, isUser: outputAddr.lowercased() == lower)
                }

                events.append(event(
                    txid: txid, address: address, view: view,
                    blockNumber: blockHeight, occurredAt: occurredAt,
                    confirmed: confirmed, feeSats: raw["fee"] as? Int64
                ))
            }
            guard let newLast = txs.last?["txid"] as? String, newLast != lastTxid else { break }
            lastTxid = newLast
            if txs.count < Self.esploraPageSize { break }
            if events.count >= limit {
                Self.log.info("Esplora history on \(self.chain.rawValue, privacy: .public) hit the \(limit, privacy: .public)-event cap")
            }
        }
        return events
    }

    // MARK: - Ledger classification (ported verbatim)

    /// Net ledger view of one transaction from the wallet address's
    /// perspective — built per provider shape, classified once.
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
    /// (litoshi). Self-send (user funded every input AND every
    /// addressed output returns to the user) → `.internal` keyed on
    /// ownership, not on a zero net (a real self-send nets exactly
    /// −fee). Ported from `BitcoinFamilyTransactionAdapter.classify`.
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
            ? feeSats.map { Decimal($0) / Self.litoshiPerCoin }
            : nil
        return TransactionEvent(
            chain: chain,
            address: address,
            txHash: txid,
            direction: direction,
            amount: Decimal(amountSats) / Self.litoshiPerCoin,
            tokenSymbol: chain.ticker,
            tokenContract: nil,
            blockNumber: blockNumber,
            occurredAt: occurredAt,
            status: confirmed ? .confirmed : .pending,
            counterparty: counterparty,
            fee: fee
        )
    }

    /// 10^8 — Litecoin's smallest unit is the litoshi.
    private static let litoshiPerCoin: Decimal = 100_000_000
}
