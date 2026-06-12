import Foundation

/// Domain-layer adapter for Bitcoin-family chains via public REST
/// endpoints. Covers `.bitcoin / .bitcoinCash / .litecoin /
/// .dogecoin`. Bitcoin and Litecoin lead with Esplora's
/// `/address/{addr}` shape; Dogecoin leads with BlockCypher (with a
/// dogechain-shaped second pass for the registered fallback); BCH
/// uses Haskoin. Each provider's path shape gets its own pass — see
/// `fetchAccountSummary`.
struct BitcoinFamilyAdapter: Sendable {
    let chain: SupportedChain
    let client: RPCClient

    /// Native balance in chain units (BTC, BCH, LTC, DOGE) — already
    /// divided by 10^8.
    ///
    /// **Per-provider path shapes (2026-06-12).** `callREST` appends
    /// ONE path to every registered endpoint, but DOGE and LTC each
    /// register two providers with *different* URL shapes (BlockCypher
    /// `addrs/{addr}/balance` vs dogechain `address/balance/{addr}` vs
    /// Esplora `address/{addr}`). A single-shape call left the
    /// fallback provider permanently 404ing — once the primary
    /// rate-limited, the chain silently failed despite a registered
    /// fallback. Each provider shape now gets its own pass, chained
    /// primary-shape → fallback-shape. Cancellation propagates
    /// instead of cascading.
    func fetchAccountSummary(address: String) async throws(RPCError) -> AccountSummary {
        switch chain {
        case .dogecoin:
            // BlockCypher (primary) shape first; dogechain's own
            // shape second so the registered fallback is reachable.
            do {
                return try await fetchBlockCypher(address: address)
            } catch {
                if case .cancelled = error { throw error }
                return try await fetchDogechain(address: address)
            }
        case .bitcoinCash:
            return try await fetchHaskoinBCH(address: address)
        case .bitcoin:
            // Both registered endpoints (mempool.space, blockstream)
            // are Esplora — one shape covers both.
            return try await fetchEsplora(address: address)
        case .litecoin:
            // litecoinspace (Esplora) primary; the registered
            // BlockCypher fallback speaks `addrs/{addr}/balance`,
            // not Esplora's `address/{addr}`.
            do {
                return try await fetchEsplora(address: address)
            } catch {
                if case .cancelled = error { throw error }
                return try await fetchBlockCypher(address: address)
            }
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

    /// BlockCypher shape — DOGE's registered primary AND LTC's
    /// registered fallback: GET {base}/addrs/{addr}/balance → JSON
    /// with `balance` as a number in the chain's smallest unit
    /// (koinu / litoshi, 10^8 per coin).
    private func fetchBlockCypher(address: String) async throws(RPCError) -> AccountSummary {
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
        let coins = units / Self.satoshisPerCoin
        // BlockCypher's same payload carries `n_tx` (total tx count).
        // Prefer it for `isUsed` — an address that received and then
        // spent everything has balance 0 but n_tx > 0; deriving
        // `isUsed` from balance alone would terminate gap-limit
        // scanning too early on emptied addresses.
        if let nTx = (json["n_tx"] as? NSNumber)?.intValue {
            return AccountSummary(nativeBalance: coins, isUsed: nTx > 0)
        }
        return AccountSummary(nativeBalance: coins, isUsed: coins > 0)
    }

    /// dogechain.info shape — DOGE's registered fallback:
    /// GET {base}/address/balance/{addr} → `balance` as a string
    /// already denominated in DOGE (not koinu). The host is
    /// currently Cloudflare-gated against non-browser UAs (see
    /// `RPCRegistry`), so this pass usually fails today — it exists
    /// so the registered fallback is shape-correct the moment the
    /// gate drops, instead of 404ing on a BlockCypher-shaped path.
    private func fetchDogechain(address: String) async throws(RPCError) -> AccountSummary {
        let data = try await client.callREST(chain: chain, path: "address/balance/\(address)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .decodingFailed("dogechain response not JSON")
        }
        let doge: Decimal
        if let s = json["balance"] as? String, let dec = Decimal(string: s) {
            doge = dec
        } else if let n = json["balance"] as? NSNumber {
            doge = n.decimalValue
        } else {
            throw .decodingFailed("dogechain balance field missing or wrong type")
        }
        // No tx count on this payload, so balance > 0 is the best
        // available `isUsed` signal here.
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
