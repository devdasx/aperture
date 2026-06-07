import Foundation

/// Domain-layer adapter for Bitcoin-family chains via Esplora-style
/// REST endpoints. Covers `.bitcoin / .bitcoinCash / .litecoin /
/// .dogecoin`. Dogecoin uses dogechain.info's shape; the other 3
/// share Esplora's `/address/{addr}` JSON shape.
struct BitcoinFamilyAdapter: Sendable {
    let chain: SupportedChain
    let client: RPCClient

    /// Native balance in chain units (BTC, BCH, LTC, DOGE) — already
    /// divided by 10^8.
    func fetchAccountSummary(address: String) async throws(RPCError) -> AccountSummary {
        switch chain {
        case .dogecoin:
            return try await fetchDogecoin(address: address)
        case .bitcoinCash:
            return try await fetchHaskoinBCH(address: address)
        case .bitcoin, .litecoin:
            return try await fetchEsplora(address: address)
        default:
            throw .noEndpoint(chain)
        }
    }

    /// BCH via Haskoin. `/bch/address/{addr}/balance` returns
    /// `{address, confirmed, unconfirmed, utxo, txs, received}` —
    /// `confirmed` is satoshis confirmed, `txs` is the address's
    /// total tx count (`> 0` ⇒ used).
    private func fetchHaskoinBCH(address: String) async throws(RPCError) -> AccountSummary {
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
        let txs = (json["txs"] as? NSNumber)?.intValue
            ?? (json["txs"] as? Int) ?? 0
        let bch = confirmed / Self.satoshisPerCoin
        return AccountSummary(nativeBalance: bch, isUsed: txs > 0 || bch > 0)
    }

    private func fetchEsplora(address: String) async throws(RPCError) -> AccountSummary {
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
        return AccountSummary(nativeBalance: nativeBalance, isUsed: isUsed)
    }

    private func fetchDogecoin(address: String) async throws(RPCError) -> AccountSummary {
        // BlockCypher path/shape (primary endpoint per registry):
        // GET /v1/doge/main/addrs/{addr}/balance → JSON with
        // `balance` as a JSON number in koinu (10^8 per DOGE).
        // The dogechain.info path is `/address/balance/{addr}`
        // returning a JSON string in DOGE; that endpoint is
        // currently Cloudflare-gated against non-browser UAs, so
        // we lead with BlockCypher.
        let data = try await client.callREST(chain: chain, path: "addrs/\(address)/balance")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .decodingFailed("Dogecoin response not JSON")
        }
        // BlockCypher returns a JSON number; dogechain returns a string.
        // Accept either so a future fallback still works.
        let koinu: Decimal
        if let n = json["balance"] as? NSNumber {
            koinu = NSDecimalNumber(value: n.int64Value).decimalValue
        } else if let s = json["balance"] as? String,
                  let dec = Decimal(string: s) {
            // dogechain.info shape — already in DOGE (not koinu).
            return AccountSummary(nativeBalance: dec, isUsed: dec > 0)
        } else {
            throw .decodingFailed("Dogecoin balance field missing or wrong type")
        }
        let doge = koinu / 100_000_000
        return AccountSummary(nativeBalance: doge, isUsed: doge > 0)
    }

    /// First-page of recent transactions. v1 returns up to `limit`
    /// confirmed transactions on Esplora chains; Dogecoin's
    /// dogechain.info shape doesn't expose the same list so it
    /// returns empty until that integration lands.
    func fetchRecentTransactions(address: String, limit: Int = 25) async throws(RPCError) -> [RawTransaction] {
        switch chain {
        case .bitcoin, .bitcoinCash, .litecoin:
            let data = try await client.callREST(chain: chain, path: "address/\(address)/txs")
            let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            return array.prefix(limit).map { tx in
                let status = tx["status"] as? [String: Any] ?? [:]
                let blockTime = (status["block_time"] as? NSNumber)?.doubleValue
                let blockHeight = (status["block_height"] as? NSNumber)?.int64Value
                let confirmed = (status["confirmed"] as? Bool) ?? false
                return RawTransaction(
                    txHash: tx["txid"] as? String ?? "",
                    blockNumber: blockHeight,
                    occurredAt: blockTime.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                    status: confirmed ? .confirmed : .pending
                )
            }
        default:
            return []
        }
    }

    struct AccountSummary: Sendable {
        let nativeBalance: Decimal
        let isUsed: Bool
    }

    struct RawTransaction: Sendable {
        let txHash: String
        let blockNumber: Int64?
        let occurredAt: Date
        let status: TxStatus
    }

    enum TxStatus: Sendable { case pending, confirmed, failed }

    private static let satoshisPerCoin: Decimal = 100_000_000
}
