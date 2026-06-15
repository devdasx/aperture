import Foundation
import OSLog

/// Fetches the UTXO set for a Bitcoin-family address and runs coin
/// selection + vsize estimation + change/dust handling. Reuses the
/// shared `RPCClient` (registered Esplora/Haskoin/BlockCypher providers).
///
/// Doc-grounded (`.claude/send-compose-matrix.md`, live-verified 2026-06-15):
/// - BTC: `GET mempool.space/api/address/{addr}/utxo` (Esplora shape).
/// - LTC: `GET litecoinspace.org/api/address/{addr}/utxo` (Esplora shape).
/// - BCH: `GET api.haskoin.com/bch/address/{addr}/unspent` (pkscript inline).
/// - DOGE: `GET api.blockcypher.com/v1/doge/main/addrs/{addr}?unspentOnly=true&includeScript=true`.
///
/// Off-main (Rule #28): a `struct` with async methods; the heavy decode +
/// selection runs on the calling background task.
struct UTXOService: Sendable {

    let client: RPCClient
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "utxo-service")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Fetch

    /// Fetch the address's UTXO set. Throws on transport failure — never
    /// returns an empty set on error (the caller must distinguish
    /// "no UTXOs" from "couldn't reach the chain").
    func fetchUTXOs(address: String, chain: SupportedChain) async throws -> [SelectedUTXO] {
        switch chain {
        case .bitcoin, .litecoin:
            return try await fetchEsplora(address: address, chain: chain)
        case .bitcoinCash:
            return try await fetchHaskoin(address: address)
        case .dogecoin:
            return try await fetchBlockCypher(address: address, chain: chain)
        default:
            throw RPCError.invalidResponse("UTXOService called for non-UTXO chain \(chain.rawValue)")
        }
    }

    /// Esplora `/address/{addr}/utxo` (BTC, LTC). Script not returned —
    /// the signer derives it locally for the own address.
    private func fetchEsplora(address: String, chain: SupportedChain) async throws -> [SelectedUTXO] {
        let data = try await client.callREST(chain: chain, path: "/address/\(address)/utxo")
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw RPCError.decodingFailed("Esplora UTXO response not an array")
        }
        return arr.compactMap { item in
            guard let txid = item["txid"] as? String,
                  let vout = item["vout"] as? Int,
                  let value = (item["value"] as? NSNumber)?.int64Value else { return nil }
            let confirmed = (item["status"] as? [String: Any])?["confirmed"] as? Bool ?? false
            return SelectedUTXO(txid: txid, vout: vout, valueSats: value, scriptHex: nil, confirmed: confirmed)
        }
    }

    /// Haskoin `/bch/address/{addr}/unspent` — pkscript returned inline.
    private func fetchHaskoin(address: String) async throws -> [SelectedUTXO] {
        // Haskoin accepts the cashaddr with or without the prefix; strip
        // the `bitcoincash:` prefix the way the history adapter does.
        let normalized = address.replacingOccurrences(of: "bitcoincash:", with: "")
        let data = try await client.callREST(
            chain: .bitcoinCash,
            path: "/bch/address/\(normalized)/unspent",
            query: [URLQueryItem(name: "limit", value: "1000")]
        )
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw RPCError.decodingFailed("Haskoin unspent response not an array")
        }
        return arr.compactMap { item in
            guard let txid = item["txid"] as? String,
                  let index = item["index"] as? Int,
                  let value = (item["value"] as? NSNumber)?.int64Value else { return nil }
            let script = item["pkscript"] as? String
            let confirmed = (item["block"] as? [String: Any])?["height"] != nil
            return SelectedUTXO(txid: txid, vout: index, valueSats: value, scriptHex: script, confirmed: confirmed)
        }
    }

    /// BlockCypher `/addrs/{addr}?unspentOnly=true&includeScript=true` (DOGE).
    private func fetchBlockCypher(address: String, chain: SupportedChain) async throws -> [SelectedUTXO] {
        let data = try await client.callREST(
            chain: chain,
            path: "/addrs/\(address)",
            query: [
                URLQueryItem(name: "unspentOnly", value: "true"),
                URLQueryItem(name: "includeScript", value: "true"),
                URLQueryItem(name: "limit", value: "2000"),
            ]
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("BlockCypher response not an object")
        }
        let txrefs = root["txrefs"] as? [[String: Any]] ?? []
        return txrefs.compactMap { item in
            guard let txid = item["tx_hash"] as? String,
                  let vout = item["tx_output_n"] as? Int,
                  let value = (item["value"] as? NSNumber)?.int64Value,
                  vout >= 0 else { return nil }
            let script = item["script"] as? String
            let confirmed = (item["confirmed"] as? String) != nil
                || ((item["confirmations"] as? NSNumber)?.intValue ?? 0) > 0
            return SelectedUTXO(txid: txid, vout: vout, valueSats: value, scriptHex: script, confirmed: confirmed)
        }
    }

    // MARK: - Coin selection

    /// The result of coin selection for a target send.
    struct CoinSelection: Sendable, Hashable {
        let inputs: [SelectedUTXO]
        /// Total fee in sats (rate × estimated vsize).
        let feeSats: Int64
        /// Change in sats (0 when folded into fee or send-all).
        let changeSats: Int64
        /// Estimated vsize (vB) the fee was computed from.
        let estimatedVsize: Int
        /// True when the selected inputs cover amount + fee.
        let funded: Bool
    }

    /// Largest-first (accumulative) coin selection with dust handling.
    /// Bitcoin Core's BnB is optimal but largest-first is robust,
    /// deterministic, and what most wallets fall back to. The fee
    /// re-estimates as inputs are added (each input grows vsize).
    ///
    /// - Parameters:
    ///   - utxos: candidate set (caller pre-filters confirmed if desired).
    ///   - targetSats: amount to send (0 for send-all — pass `sendAll: true`).
    ///   - feeRate: sat/vB (BTC/LTC) or sat/byte (BCH/DOGE).
    ///   - chain: drives per-input/output vsize + dust threshold.
    ///   - recipientCount: number of recipient outputs.
    ///   - recipientValues: per-recipient output values (koinu/sats) for
    ///     the DOGE soft-dust surcharge. When `nil`, the single-recipient
    ///     fallback treats `targetSats` as the one recipient value.
    ///   - sendAll: when true, spend every confirmed input minus fee.
    func selectCoins(
        utxos: [SelectedUTXO],
        targetSats: Int64,
        feeRate: Decimal,
        chain: SupportedChain,
        recipientCount: Int = 1,
        recipientValues: [Int64]? = nil,
        sendAll: Bool = false
    ) -> CoinSelection {
        let model = SizeModel(chain: chain)
        let rate = max(feeRate, model.minRelayRate) // clamp to relay floor

        // Recipient output values for the soft-dust band count. Use the
        // caller-supplied split when present; otherwise fall back to the
        // single-recipient case (targetSats is the lone recipient value).
        let recipientVals = recipientValues ?? [targetSats]

        if sendAll {
            // Spend everything; one output, no change.
            let inputs = utxos.sorted { $0.valueSats > $1.valueSats }
            let vsize = model.vsize(inputs: inputs.count, recipientOutputs: recipientCount, hasChange: false)
            let total = inputs.reduce(Int64(0)) { $0 + $1.valueSats }
            // Send-all recipient value = total − fee; iterate once on the
            // pre-fee total to classify the soft-dust band (close enough —
            // the fee is a tiny fraction of a non-dust send-all).
            let belowSoft = model.outputsBelowSoftDust(
                recipientValues: [max(total, 0)], changeSats: 0)
            let fee = feeSats(rate: rate, vsize: vsize, chain: chain, outputsBelowSoftDust: belowSoft)
            return CoinSelection(inputs: inputs, feeSats: fee, changeSats: 0,
                                 estimatedVsize: vsize, funded: total > fee)
        }

        // Accumulative largest-first.
        let sorted = utxos.sorted { $0.valueSats > $1.valueSats }
        var selected: [SelectedUTXO] = []
        var accumulated: Int64 = 0
        for utxo in sorted {
            selected.append(utxo)
            accumulated += utxo.valueSats
            let vsizeWithChange = model.vsize(inputs: selected.count, recipientOutputs: recipientCount, hasChange: true)
            // First pass: estimate the fee ignoring change-band surcharge to
            // derive the change value, then re-classify including change.
            let provisionalFee = feeSats(
                rate: rate, vsize: vsizeWithChange, chain: chain,
                outputsBelowSoftDust: model.outputsBelowSoftDust(
                    recipientValues: recipientVals, changeSats: 0))
            if accumulated >= targetSats + provisionalFee {
                let provisionalChange = accumulated - targetSats - provisionalFee
                if provisionalChange >= model.dustThreshold {
                    // Re-classify with the actual change output in the band.
                    let belowSoft = model.outputsBelowSoftDust(
                        recipientValues: recipientVals, changeSats: provisionalChange)
                    let feeWithChange = feeSats(rate: rate, vsize: vsizeWithChange, chain: chain,
                                                outputsBelowSoftDust: belowSoft)
                    let change = accumulated - targetSats - feeWithChange
                    if change >= model.dustThreshold {
                        return CoinSelection(inputs: selected, feeSats: feeWithChange, changeSats: change,
                                             estimatedVsize: vsizeWithChange, funded: true)
                    }
                    // The surcharge pushed change below dust → fold into fee.
                }
                // Change is (or became) dust → drop it into the fee,
                // recompute without a change output (no change-band output).
                let vsizeNoChange = model.vsize(inputs: selected.count, recipientOutputs: recipientCount, hasChange: false)
                let belowSoftNoChange = model.outputsBelowSoftDust(
                    recipientValues: recipientVals, changeSats: 0)
                let feeNoChange = feeSats(rate: rate, vsize: vsizeNoChange, chain: chain,
                                          outputsBelowSoftDust: belowSoftNoChange)
                if accumulated >= targetSats + feeNoChange {
                    return CoinSelection(inputs: selected, feeSats: accumulated - targetSats, changeSats: 0,
                                         estimatedVsize: vsizeNoChange, funded: true)
                }
            }
        }
        // Insufficient funds — return the full selection so the validator
        // can compute the shortfall.
        let vsize = model.vsize(inputs: selected.count, recipientOutputs: recipientCount, hasChange: false)
        let belowSoft = model.outputsBelowSoftDust(recipientValues: recipientVals, changeSats: 0)
        let fee = feeSats(rate: rate, vsize: vsize, chain: chain, outputsBelowSoftDust: belowSoft)
        return CoinSelection(inputs: selected, feeSats: fee, changeSats: 0,
                             estimatedVsize: vsize, funded: false)
    }

    /// Fee in sats = ceil(rate × vsize), plus the DOGE soft-dust surcharge
    /// (+0.01 DOGE = 1,000,000 koinu per output in [hardDust, softDust)).
    /// Doc: Dogecoin Core fee-recommendation.md — outputs under 0.01 DOGE
    /// "require an additional 0.01 DOGE per output added to the fee".
    private func feeSats(rate: Decimal, vsize: Int, chain: SupportedChain, outputsBelowSoftDust: Int) -> Int64 {
        let base = ComposeDecimal.ceilToInteger(rate * Decimal(vsize))
        var total = base
        if chain == .dogecoin && outputsBelowSoftDust > 0 {
            // 0.01 DOGE = 1,000,000 koinu per sub-soft-dust output.
            total += Decimal(outputsBelowSoftDust) * Decimal(1_000_000)
        }
        return NSDecimalNumber(decimal: total).int64Value
    }
}

/// Per-chain virtual-size + dust model (doc-grounded vB constants from
/// the matrix). BTC/LTC use vsize (segwit discount); BCH/DOGE use raw
/// bytes (no witness).
private struct SizeModel {
    let chain: SupportedChain

    /// Overhead vB (version + locktime + counts).
    var overhead: Decimal { hasWitness ? Decimal(string: "10.5")! : 10 }
    /// Per-input vB (default P2WPKH for segwit, P2PKH for legacy).
    var perInput: Decimal { hasWitness ? 68 : 148 }
    /// Per-output vB (default P2WPKH for segwit, P2PKH for legacy).
    var perOutput: Decimal { hasWitness ? 31 : 34 }

    var hasWitness: Bool { chain == .bitcoin || chain == .litecoin }

    /// Dust threshold in sats (P2WPKH 294 / P2PKH 546; DOGE hard 100,000).
    var dustThreshold: Int64 {
        switch chain {
        case .bitcoin, .litecoin: return 294
        case .bitcoinCash:        return 546
        case .dogecoin:           return 100_000 // hard dust = 0.001 DOGE
        default:                  return 546
        }
    }

    /// DOGE SOFT-dust threshold in koinu = 0.01 DOGE = 1,000,000 koinu.
    /// Any output whose value is in [hardDust, softDust) requires an extra
    /// 0.01 DOGE per output added to the fee or the tx is rejected for
    /// "too low fee". Only DOGE has this rule; `nil` elsewhere.
    /// Doc: Dogecoin Core fee-recommendation.md ("Soft Dust Limit: 0.01
    /// DOGE … require an additional 0.01 DOGE per output added to the fee").
    var softDustThreshold: Int64? {
        chain == .dogecoin ? 1_000_000 : nil
    }

    /// Count the recipient + change outputs whose value falls in the
    /// soft-dust band [hardDust, softDust) — each one incurs the DOGE
    /// soft-dust surcharge. Sub-hard-dust change is never created (folded
    /// into fee), so it is excluded here.
    func outputsBelowSoftDust(recipientValues: [Int64], changeSats: Int64) -> Int {
        guard let soft = softDustThreshold else { return 0 }
        let hard = dustThreshold
        var count = 0
        for v in recipientValues where v >= hard && v < soft { count += 1 }
        if changeSats >= hard && changeSats < soft { count += 1 }
        return count
    }

    /// Minimum relay fee rate (sat/vB or sat/byte) — clamp floor.
    var minRelayRate: Decimal {
        switch chain {
        case .dogecoin:
            // DOGE min-relay floor = 0.001 DOGE/kB. 0.001 DOGE = 100,000
            // koinu; / 1000 bytes = 100 koinu/byte (NOT 1000 — that is the
            // 0.01 DOGE/kB RECOMMENDED rate, which is the `.normal` preset,
            // not the relay floor). Doc: Dogecoin Core fee-recommendation.md
            // (github.com/dogecoin/dogecoin/blob/master/doc/fee-recommendation.md):
            // "Minimum Relay Fee: 0.001 DOGE/kB", "Recommended Fee: 0.01
            // DOGE per kilobyte". Live BlockCypher market rates sit far
            // above both; this is only the protocol hard floor.
            return 100
        default:
            return 1
        }
    }

    /// Estimated vsize for the given shape.
    func vsize(inputs: Int, recipientOutputs: Int, hasChange: Bool) -> Int {
        let outs = recipientOutputs + (hasChange ? 1 : 0)
        let total = overhead + Decimal(inputs) * perInput + Decimal(outs) * perOutput
        return NSDecimalNumber(decimal: ComposeDecimal.ceilToInteger(total)).intValue
    }
}
