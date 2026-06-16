import Foundation
import OSLog

/// **Bitcoin connector — the REST / UTXO reference implementation.**
///
/// A FULLY INDEPENDENT module for `.bitcoin`: its own Esplora
/// `/address/{addr}` balance read and its own Esplora
/// `/address/{addr}/txs` paginated vin/vout history. It owns its
/// request shapes + parsing end-to-end and dispatches every call
/// through the shared `RPCClient` actor via `callREST` (rotation +
/// rate-limit + circuit-breaking + ConcurrencyGate) against the
/// registered endpoints `RPCRegistry.endpoints(for: .bitcoin)`
/// (mempool.space primary, blockstream fallback — both Esplora, one
/// shape covers both). Never a raw `URLSession`.
///
/// **This is the template for REST / UTXO chains** (Litecoin shares the
/// Esplora shape exactly; Bitcoin Cash uses Haskoin; Dogecoin uses
/// BlockCypher — each sibling copies this file and swaps the
/// provider-specific path shape + parser, mirroring the per-provider
/// dispatch in `BitcoinFamilyAdapter` / `BitcoinFamilyTransactionAdapter`).
/// The duplication is intentional (user direction): per-chain code stays
/// isolated.
///
/// **Ported verbatim-faithful** from `BitcoinFamilyAdapter.fetchEsplora`
/// (balance) and `BitcoinFamilyTransactionAdapter.fetchEsplora`
/// (history): same `/address/{addr}` and `/address/{addr}/txs[/chain/…]`
/// paths, same `chain_stats funded−spent` satoshi math, same 8-decimals
/// (satoshisPerCoin = 10^8), same vin/vout LedgerView classification,
/// same self-send `.internal` keying, same per-page cursor pagination.
struct BitcoinConnector: ChainConnector {
    let chain: SupportedChain = .bitcoin
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "bitcoin-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native BTC balance + used-address flag via Esplora's
    /// `/address/{addr}`. Ported from `BitcoinFamilyAdapter.fetchEsplora`.
    ///
    /// `chain_stats.funded_txo_sum − chain_stats.spent_txo_sum` = current
    /// confirmed balance in satoshis → divided by 10^8. `isUsed` keys on
    /// the tx count (confirmed OR mempool) so an emptied address (balance
    /// 0 but tx_count > 0) still reads as used — gap-limit scanning must
    /// not terminate early on emptied addresses.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data = try await client.callREST(chain: chain, path: "address/\(address)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .decodingFailed("Esplora response not JSON")
        }
        let chainStats = json["chain_stats"] as? [String: Any] ?? [:]
        let mempoolStats = json["mempool_stats"] as? [String: Any] ?? [:]
        let funded = (chainStats["funded_txo_sum"] as? NSNumber)?.int64Value ?? 0
        let spent = (chainStats["spent_txo_sum"] as? NSNumber)?.int64Value ?? 0
        let txCount = (chainStats["tx_count"] as? NSNumber)?.intValue ?? 0
        let mempoolTxCount = (mempoolStats["tx_count"] as? NSNumber)?.intValue ?? 0

        let satoshis = NSDecimalNumber(value: funded - spent).decimalValue
        let nativeBalance = satoshis / Self.satoshisPerCoin
        let isUsed = txCount > 0 || mempoolTxCount > 0
        return ChainAccountSummary(nativeBalance: nativeBalance, isUsed: isUsed)
    }

    // MARK: - Token balances

    /// Bitcoin has no fungible-token layer Aperture tracks — the native
    /// coin is the only asset. Returns `[]` honestly (Rule #16). REST /
    /// UTXO siblings that DO carry tokens (none in the Bitcoin family)
    /// would override this; it exists to satisfy the `ChainConnector`
    /// contract uniformly.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history

    /// Esplora's fixed confirmed-history page size.
    private static let esploraPageSize = 25

    /// Recent BTC history via Esplora's `/address/{addr}/txs`, paging
    /// through `/address/{addr}/txs/chain/{last_seen_txid}` in 25-tx
    /// batches until `limit`, an empty page (history exhausted), or a
    /// mid-pagination failure (keeps pages already fetched). Ported from
    /// `BitcoinFamilyTransactionAdapter.fetchEsplora`.
    ///
    /// `customContracts` is unused (Bitcoin has no token transfers) but
    /// kept for the uniform `ChainConnector` signature.
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
    /// (sats). Self-send (user funded every input AND every addressed
    /// output returns to the user) → `.internal` keyed on ownership, not
    /// on a zero net (a real self-send nets exactly −fee). Ported from
    /// `BitcoinFamilyTransactionAdapter.classify`.
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

    /// 10^8 — Bitcoin's smallest unit is the satoshi.
    private static let satoshisPerCoin: Decimal = 100_000_000
}
