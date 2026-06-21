import Foundation
import OSLog

/// **Bitcoin Cash connector — the Haskoin REST / UTXO sibling.**
///
/// A FULLY INDEPENDENT module for `.bitcoinCash`. It mirrors the
/// `BitcoinConnector` REST/UTXO template (address balance + paginated
/// vin/vout history with the self-send `LedgerView` classifier) but
/// owns BCH's OWN provider shape — Haskoin, NOT Esplora. Bitcoin Cash
/// has no public keyless Esplora index that still serves JSON (the
/// loping.net / imaginary.cash hosts started returning anti-bot HTML to
/// non-browser User-Agents — see `RPCRegistry.bitcoinCashEndpoints`), so
/// BCH runs on `api.haskoin.com` alone, the canonical free BCH index API.
///
/// Every call dispatches through the shared `RPCClient` actor via
/// `callREST` (rotation + rate-limit + circuit-breaking + ConcurrencyGate)
/// against `RPCRegistry.endpoints(for: .bitcoinCash)`. Never a raw
/// `URLSession`. The duplication versus `BitcoinConnector` is intentional
/// (user direction): BCH's provider quirk (Haskoin's
/// `bch/address/{addr}/…` path shape, its `confirmed`/`txs` balance keys,
/// its `inputs[]`/`outputs[]` arrays, and its `bitcoincash:`-prefixed
/// cashaddr responses) stays isolated in this file and never leaks into a
/// sibling.
///
/// **Ported verbatim-faithful** from `BitcoinFamilyAdapter.fetchHaskoinBCH`
/// (balance) and `BitcoinFamilyTransactionAdapter.fetchHaskoin` (history):
/// same `bch/address/{addr}/balance` (`confirmed` satoshis / 10^8, `txs`
/// count for `isUsed`), same `bch/address/{addr}/transactions/full` with
/// `limit`/`offset` query pagination, same `inputs[].address`/`.value` +
/// `outputs[].address`/`.value` ledger reduction, same `bitcoincash:`
/// cashaddr normalization before user-ownership comparison, same 8
/// decimals (satoshisPerCoin = 10^8), same `block.height`-present ⇒
/// confirmed heuristic, same self-send `.internal` keying.
struct BitcoinCashConnector: ChainConnector {
    let chain: SupportedChain = .bitcoinCash
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "bitcoincash-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native BCH balance + used-address flag via Haskoin's
    /// `bch/address/{addr}/balance`. Ported from
    /// `BitcoinFamilyAdapter.fetchHaskoinBCH`.
    ///
    /// Haskoin returns `{address, confirmed, unconfirmed, utxo, txs,
    /// received}` — `confirmed` is the confirmed balance in satoshis
    /// (divided by 10^8 here) and `txs` is the address's total tx count.
    /// `isUsed` keys on `txs > 0` (OR a positive balance) so an emptied
    /// address (balance 0, txs > 0) still reads as used — gap-limit
    /// scanning must not terminate early on emptied addresses.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data = try await client.callREST(chain: chain, path: "bch/address/\(address)/balance")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .decodingFailed("Haskoin BCH response not JSON")
        }
        let confirmed: Decimal
        if let n = json["confirmed"] as? NSNumber {
            confirmed = NSDecimalNumber(value: n.int64Value).decimalValue
        } else if let i = json["confirmed"] as? Int {
            confirmed = Decimal(i)
        } else {
            confirmed = 0
        }
        // Haskoin reports `unconfirmed` (the signed mempool delta — positive
        // for a pending incoming tx, negative for a pending spend) separately.
        // Include it so an incoming pending tx shows in the balance
        // immediately, not only after confirmation. Clamp the total at 0
        // since `unconfirmed` is signed.
        let unconfirmed: Decimal
        if let n = json["unconfirmed"] as? NSNumber {
            unconfirmed = NSDecimalNumber(value: n.int64Value).decimalValue
        } else if let i = json["unconfirmed"] as? Int {
            unconfirmed = Decimal(i)
        } else {
            unconfirmed = 0
        }
        let txs = (json["txs"] as? NSNumber)?.intValue
            ?? (json["txs"] as? Int) ?? 0
        let bch = max(0, confirmed + unconfirmed) / Self.satoshisPerCoin
        return ChainAccountSummary(nativeBalance: bch, isUsed: txs > 0 || bch > 0)
    }

    // MARK: - Token balances

    /// Bitcoin Cash has no fungible-token layer Aperture tracks — the
    /// native coin is the only asset (SLP tokens are out of scope).
    /// Returns `[]` honestly (Rule #16). The parameter is kept for the
    /// uniform `ChainConnector` signature.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history

    /// Conservative page size — Haskoin serves FULL transactions (every
    /// input/output inlined), so big pages are heavy. Capped at 100.
    private static let maxPageSize = 100

    /// Recent BCH history via Haskoin's
    /// `bch/address/{addr}/transactions/full?limit=N&offset=N`, paging in
    /// `limit`/`offset` batches until `limit` events, a short page
    /// (history exhausted), or a mid-pagination failure (keeps pages
    /// already fetched). Ported from
    /// `BitcoinFamilyTransactionAdapter.fetchHaskoin`.
    ///
    /// Each tx carries `inputs[].address`/`.value` and
    /// `outputs[].address`/`.value` (satoshis), `fee`, `time` (unix
    /// seconds) and `block.height` (absent while in mempool ⇒ pending).
    /// Haskoin returns cashaddr WITH the `bitcoincash:` prefix, so both
    /// the wallet address and each in/out address are normalized before
    /// the user-ownership comparison.
    ///
    /// `customContracts` is unused (BCH has no token transfers) but kept
    /// for the uniform `ChainConnector` signature.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let pageSize = min(limit, Self.maxPageSize)
        guard pageSize > 0 else { return [] }
        let user = Self.normalizedCashAddr(address)
        var events: [TransactionEvent] = []
        var offset = 0
        while events.count < limit {
            let data: Data
            do {
                data = try await client.callREST(
                    chain: chain,
                    path: "bch/address/\(address)/transactions/full",
                    query: [
                        URLQueryItem(name: "limit", value: String(pageSize)),
                        URLQueryItem(name: "offset", value: String(offset)),
                    ]
                )
            } catch {
                if case .cancelled = error { throw error }
                if offset == 0 { throw error }
                Self.log.warning("Haskoin page at offset \(offset, privacy: .public) failed on \(self.chain.rawValue, privacy: .public) — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let txs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                Self.log.warning("Haskoin response not an array for \(self.chain.rawValue, privacy: .public)")
                break
            }
            if txs.isEmpty { break }
            for raw in txs {
                if events.count >= limit { break }
                guard let txid = raw["txid"] as? String else { continue }
                let block = raw["block"] as? [String: Any] ?? [:]
                let blockHeight = (block["height"] as? NSNumber)?.int64Value
                let time = (raw["time"] as? NSNumber)?.doubleValue
                let occurredAt = time.map { Date(timeIntervalSince1970: $0) } ?? Date()

                var view = LedgerView()
                for input in raw["inputs"] as? [[String: Any]] ?? [] {
                    let addr = (input["address"] as? String) ?? ""
                    let value = (input["value"] as? NSNumber)?.int64Value ?? 0
                    view.addInput(address: addr, value: value, isUser: Self.normalizedCashAddr(addr) == user)
                }
                for output in raw["outputs"] as? [[String: Any]] ?? [] {
                    let addr = (output["address"] as? String) ?? ""
                    let value = (output["value"] as? NSNumber)?.int64Value ?? 0
                    view.addOutput(address: addr, value: value, isUser: Self.normalizedCashAddr(addr) == user)
                }

                events.append(event(
                    txid: txid,
                    address: address,
                    view: view,
                    blockNumber: blockHeight,
                    occurredAt: occurredAt,
                    confirmed: blockHeight != nil,
                    feeSats: (raw["fee"] as? NSNumber)?.int64Value
                ))
            }
            if txs.count < pageSize { break } // history exhausted
            offset += txs.count
            if events.count >= limit {
                Self.log.info("Haskoin history on \(self.chain.rawValue, privacy: .public) hit the \(limit, privacy: .public)-event cap")
            }
        }
        return events
    }

    // MARK: - Ledger classification (ported verbatim)

    /// Net ledger view of one transaction from the wallet address's
    /// perspective — built from Haskoin's `inputs[]`/`outputs[]`,
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
    /// (sats). Self-send (user funded every addressed input AND every
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

    /// Lowercase and strip the optional `bitcoincash:` URI prefix so the
    /// wallet's stored form matches Haskoin's prefixed cashaddr responses.
    private static func normalizedCashAddr(_ addr: String) -> String {
        let lower = addr.lowercased()
        if lower.hasPrefix("bitcoincash:") {
            return String(lower.dropFirst("bitcoincash:".count))
        }
        return lower
    }

    /// 10^8 — Bitcoin Cash's smallest unit is the satoshi.
    private static let satoshisPerCoin: Decimal = 100_000_000
}
