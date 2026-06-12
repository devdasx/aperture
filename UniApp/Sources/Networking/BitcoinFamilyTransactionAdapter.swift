import Foundation
import OSLog

/// Transaction-history adapter for the Bitcoin family — `bitcoin`,
/// `bitcoinCash`, `litecoin`, `dogecoin`.
///
/// **Per-provider dispatch (2026-06-12).** The registered providers
/// do NOT share one API shape, so each chain routes to its provider's
/// real endpoint — mirroring `BitcoinFamilyAdapter`'s balance
/// dispatch. (The pre-2026-06-12 code sent Esplora's
/// `/address/{addr}/txs` path to every chain; BlockCypher and Haskoin
/// both 404 on it, so DOGE and BCH activity was permanently empty.)
///
/// | Chain | Provider     | Endpoint                                    |
/// |-------|--------------|---------------------------------------------|
/// | BTC   | mempool.space / blockstream (Esplora) | `address/{addr}/txs` |
/// | LTC   | litecoinspace (Esplora)               | `address/{addr}/txs` |
/// | DOGE  | BlockCypher                           | `addrs/{addr}/full`  |
/// | BCH   | Haskoin                               | `bch/address/{addr}/transactions/full` |
///
/// **Response normalization.** Every provider reports per-tx inputs
/// and outputs; each parser reduces them to one `LedgerView` (sats
/// spent / received by the user, first foreign input / output) and
/// the shared `classify` maps that to direction + counterparty +
/// amount. Self-sends — the user funded every input AND every
/// addressed output returns to the user — land as `.internal`; the
/// net change of a real self-send is exactly −fee, never zero, so
/// the classification keys on input/output ownership, not on a
/// zero net. Multi-input / multi-output transactions (PSBT,
/// CoinJoin) reduce to one summary row — the user reads "+ 0.05 BTC
/// from bc1q…" / "− 0.12 BTC to bc1q…" without needing to learn
/// UTXO semantics.
///
/// Per Rule #3 (native-only) we hit the public endpoints directly
/// via `RPCClient.callREST` — no SPM dependency.
struct BitcoinFamilyTransactionAdapter: Sendable {
    let chain: SupportedChain
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "btc-tx-adapter")

    /// Fetch up to `limit` recent transactions for `address`,
    /// routed to the chain's registered provider shape.
    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        switch chain {
        case .bitcoin, .litecoin:
            return try await fetchEsplora(address: address, limit: limit)
        case .dogecoin:
            return try await fetchBlockCypher(address: address, limit: limit)
        case .bitcoinCash:
            return try await fetchHaskoin(address: address, limit: limit)
        default:
            return []
        }
    }

    // MARK: - Esplora (BTC, LTC)

    /// Esplora's `/address/{addr}/txs` — pages in batches of 25 by
    /// default; we ask for one page and slice the result. Each `tx`
    /// object carries `vin[]` (with `prevout.scriptpubkey_address` /
    /// `value`) and `vout[]` (with `scriptpubkey_address` / `value`).
    private func fetchEsplora(address: String, limit: Int) async throws -> [TransactionEvent] {
        let data = try await client.callREST(chain: chain, path: "address/\(address)/txs")
        guard let txs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Self.log.warning("Esplora response not an array for \(chain.rawValue, privacy: .public)")
            return []
        }
        let lower = address.lowercased()
        var events: [TransactionEvent] = []
        events.reserveCapacity(min(txs.count, limit))
        for raw in txs.prefix(limit) {
            guard let txid = raw["txid"] as? String else { continue }
            let status = raw["status"] as? [String: Any] ?? [:]
            let confirmed = status["confirmed"] as? Bool ?? false
            let blockHeight = (status["block_height"] as? Int64)
            let blockTime = status["block_time"] as? Int64
            let occurredAt: Date
            if let blockTime {
                occurredAt = Date(timeIntervalSince1970: TimeInterval(blockTime))
            } else {
                occurredAt = Date()
            }

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
                txid: txid,
                address: address,
                view: view,
                blockNumber: blockHeight,
                occurredAt: occurredAt,
                confirmed: confirmed,
                feeSats: raw["fee"] as? Int64
            ))
        }
        return events
    }

    // MARK: - BlockCypher (DOGE)

    /// Dogecoin history via BlockCypher's full-address endpoint —
    /// GET `{base}/addrs/{addr}/full?limit=N` → `{ txs: [...] }`
    /// where each tx carries `inputs[].addresses` + `output_value`
    /// and `outputs[].addresses` + `value` (koinu), `confirmed`
    /// (ISO-8601), `block_height` (−1 while unconfirmed) and `fees`.
    /// The registered dogechain fallback exposes no JSON tx list
    /// (Cloudflare-gated — see `RPCRegistry`), so DOGE history is
    /// BlockCypher-only in practice.
    private func fetchBlockCypher(address: String, limit: Int) async throws -> [TransactionEvent] {
        let data = try await client.callREST(
            chain: chain,
            path: "addrs/\(address)/full",
            query: [URLQueryItem(name: "limit", value: String(min(limit, 50)))]
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let txs = root["txs"] as? [[String: Any]] else {
            Self.log.warning("BlockCypher response not in expected shape for \(chain.rawValue, privacy: .public)")
            return []
        }
        let lower = address.lowercased()
        var events: [TransactionEvent] = []
        events.reserveCapacity(min(txs.count, limit))
        for raw in txs.prefix(limit) {
            guard let txid = raw["hash"] as? String else { continue }
            let blockHeight = (raw["block_height"] as? NSNumber)?.int64Value ?? -1
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
        return events
    }

    // MARK: - Haskoin (BCH)

    /// BCH history via Haskoin's full-transactions endpoint —
    /// GET `{base}/bch/address/{addr}/transactions/full?limit=N` →
    /// a JSON array of txs with `inputs[].address` /
    /// `outputs[].address` and `value` (satoshis), `fee`, `time`
    /// (unix seconds) and `block.height` (absent while in mempool).
    /// Haskoin returns cashaddr WITH the `bitcoincash:` prefix; the
    /// wallet may store either form, so both sides are normalized
    /// before comparison.
    private func fetchHaskoin(address: String, limit: Int) async throws -> [TransactionEvent] {
        let data = try await client.callREST(
            chain: chain,
            path: "bch/address/\(address)/transactions/full",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        guard let txs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            Self.log.warning("Haskoin response not an array for \(chain.rawValue, privacy: .public)")
            return []
        }
        let user = Self.normalizedCashAddr(address)
        var events: [TransactionEvent] = []
        events.reserveCapacity(min(txs.count, limit))
        for raw in txs.prefix(limit) {
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
        return events
    }

    // MARK: - Shared classification

    /// Net ledger view of one transaction from the wallet address's
    /// perspective — built per provider shape, classified once.
    private struct LedgerView {
        var userSpent: Int64 = 0
        var userReceived: Int64 = 0
        var firstOtherInput: String?
        var firstOtherOutput: String?
        /// `false` once any addressed input is funded by someone else.
        /// Address-less inputs (coinbase, nonstandard scripts) carry
        /// no payer and don't count against self-send.
        var allInputsBelongToUser = true
        /// `false` once any addressed output pays someone else.
        /// Address-less outputs (OP_RETURN) carry no payee and don't
        /// count against self-send.
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

    /// Map a `LedgerView` to direction + counterparty + display
    /// amount (sats).
    ///
    /// **Self-send fix (2026-06-12).** A genuine self-send / UTXO
    /// consolidation nets exactly −fee, never zero, so the old
    /// `netSats == 0` requirement could never match one — those rows
    /// rendered as `.outgoing` with amount = fee and a blank
    /// counterparty. `.internal` now keys on ownership: the user
    /// funded every addressed input AND every addressed output
    /// returns to the user. The displayed amount is what moved back
    /// to the wallet; the fee is carried separately.
    private static func classify(_ view: LedgerView) -> (direction: TransactionDirection, counterparty: String, amountSats: Int64) {
        let netSats = view.userReceived &- view.userSpent
        if view.userSpent > 0 && view.userReceived > 0
            && view.allInputsBelongToUser && view.allOutputsBelongToUser {
            return (.internal, "", view.userReceived)
        }
        if view.userSpent > 0 && view.userReceived > 0 && netSats == 0 {
            // Net-zero but value left to a third party — that's a
            // spend, not an internal shuffle.
            return (.outgoing, view.firstOtherOutput ?? "", 0)
        }
        if netSats >= 0 {
            return (.incoming, view.firstOtherInput ?? "", netSats)
        }
        return (.outgoing, view.firstOtherOutput ?? "", -netSats)
    }

    /// Build the uniform `TransactionEvent` from a classified view.
    /// The fee is attached to `.outgoing` AND `.internal` rows — the
    /// user paid it in both cases.
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
            ? feeSats.map { Decimal($0) / Self.satsPerCoin }
            : nil
        return TransactionEvent(
            chain: chain,
            address: address,
            txHash: txid,
            direction: direction,
            amount: Decimal(amountSats) / Self.satsPerCoin,
            tokenSymbol: chain.ticker,
            tokenContract: nil,
            blockNumber: blockNumber,
            occurredAt: occurredAt,
            status: confirmed ? .confirmed : .pending,
            counterparty: counterparty,
            fee: fee
        )
    }

    /// Lowercase and strip the optional `bitcoincash:` URI prefix so
    /// the wallet's stored form matches Haskoin's prefixed responses.
    private static func normalizedCashAddr(_ addr: String) -> String {
        let lower = addr.lowercased()
        if lower.hasPrefix("bitcoincash:") {
            return String(lower.dropFirst("bitcoincash:".count))
        }
        return lower
    }

    /// Hoisted formatter for BlockCypher's `confirmed` timestamps
    /// ("2026-05-26T14:05:12Z" — no fractional seconds).
    /// `ISO8601DateFormatter` is documented thread-safe by Apple, so
    /// the `nonisolated(unsafe)` opt-out is sound.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    /// 10^8 — every chain in the Bitcoin family uses 8 decimals
    /// (Bitcoin's smallest unit is the satoshi, Litecoin's is the
    /// litoshi, Doge's is the dogetoshi, BCH inherits BTC's 8). One
    /// constant covers all four.
    private static let satsPerCoin: Decimal = {
        var result = Decimal(1)
        for _ in 0..<8 { result *= 10 }
        return result
    }()
}
