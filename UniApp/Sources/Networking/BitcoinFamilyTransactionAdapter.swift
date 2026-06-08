import Foundation
import OSLog

/// Transaction-history adapter for the Bitcoin family —
/// `bitcoin`, `bitcoinCash`, `litecoin`, `dogecoin`. All four
/// expose Esplora-shaped REST endpoints (`mempool.space` for BTC,
/// `litecoinspace.org` / Blockchair / Sochain for the rest) so the
/// adapter unifies them behind the same `/address/{addr}/txs` path.
///
/// **Response normalization.** Each Esplora `tx` object carries
/// `vin[]` and `vout[]` arrays describing inputs and outputs. We
/// determine direction by checking whether any of the user's address
/// appears in the inputs (= outgoing) vs only in the outputs
/// (= incoming). Self-sends (address appears in both) land as
/// `.internal`. The amount is the net change in the user's outputs;
/// the counterparty is the first input (for incoming) or first
/// output not belonging to the user (for outgoing). Multi-input /
/// multi-output transactions (PSBT, CoinJoin) reduce to one summary
/// row — the user reads "+ 0.05 BTC from bc1q…" / "− 0.12 BTC to
/// bc1q…" without needing to learn UTXO semantics.
///
/// Per Rule #3 (native-only) we hit the public endpoints directly
/// via `RPCClient.callREST` — no SPM dependency.
struct BitcoinFamilyTransactionAdapter: Sendable {
    let chain: SupportedChain
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "btc-tx-adapter")

    /// Fetch up to `limit` confirmed transactions for `address`.
    /// Esplora endpoints page in batches of 25 by default; we ask
    /// for one page and slice the result.
    func fetch(address: String, limit: Int) async throws -> [TransactionEvent] {
        let path = "/address/\(address)/txs"
        let data = try await client.callREST(chain: chain, path: path)
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

            let vin = raw["vin"] as? [[String: Any]] ?? []
            let vout = raw["vout"] as? [[String: Any]] ?? []

            // Inputs from the user's address vs outputs to the user's
            // address. Esplora reports `prevout.scriptpubkey_address`
            // on each vin and `scriptpubkey_address` on each vout.
            var userSpent: Int64 = 0
            var firstOtherInput: String?
            for input in vin {
                guard let prev = input["prevout"] as? [String: Any] else { continue }
                let inputAddr = (prev["scriptpubkey_address"] as? String) ?? ""
                let value = (prev["value"] as? Int64) ?? 0
                if inputAddr.lowercased() == lower {
                    userSpent &+= value
                } else if firstOtherInput == nil, !inputAddr.isEmpty {
                    firstOtherInput = inputAddr
                }
            }

            var userReceived: Int64 = 0
            var firstOtherOutput: String?
            for output in vout {
                let outputAddr = (output["scriptpubkey_address"] as? String) ?? ""
                let value = (output["value"] as? Int64) ?? 0
                if outputAddr.lowercased() == lower {
                    userReceived &+= value
                } else if firstOtherOutput == nil, !outputAddr.isEmpty {
                    firstOtherOutput = outputAddr
                }
            }

            let netSats: Int64 = userReceived &- userSpent
            let direction: TransactionDirection
            let counterparty: String
            if userSpent > 0 && userReceived > 0 && netSats == 0 {
                direction = .internal
                counterparty = ""
            } else if netSats >= 0 {
                direction = .incoming
                counterparty = firstOtherInput ?? ""
            } else {
                direction = .outgoing
                counterparty = firstOtherOutput ?? ""
            }

            let absSats = abs(netSats)
            let amount = Decimal(absSats) / Self.satsPerCoin
            // Fee is the difference between inputs and outputs.
            // Esplora exposes it directly as `fee` on the tx object.
            let feeSats = raw["fee"] as? Int64
            let fee: Decimal? = direction == .outgoing
                ? (feeSats.map { Decimal($0) / Self.satsPerCoin })
                : nil

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: txid,
                direction: direction,
                amount: amount,
                tokenSymbol: chain.ticker,
                tokenContract: nil,
                blockNumber: blockHeight,
                occurredAt: occurredAt,
                status: confirmed ? .confirmed : .pending,
                counterparty: counterparty,
                fee: fee
            ))
        }
        return events
    }

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
