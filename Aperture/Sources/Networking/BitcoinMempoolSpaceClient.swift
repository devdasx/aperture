import Foundation
import OSLog

/// Bitcoin **send-path** REST facade: **mempool.space only**, via the
/// shared `RPCClient` stack (P1 #8 + #9).
///
/// Architecture:
/// - **Balance / portfolio UTXOs:** Electrum (`BitcoinElectrumBalanceScanner`)
/// - **Send UTXOs + fees + broadcast + tx detail REST:** this facade →
///   `RPCClient.callREST` / `callRESTPostRaw` against the single
///   `btc-mempool` registry endpoint (`https://mempool.space/api`)
///
/// All calls share rate limiting, circuit breaker, concurrency gate, and
/// diagnostics with every other BTC REST request. Do **not** open a
/// parallel `URLSession` to mempool.space.
///
/// Blockstream Esplora is not registered for BTC. LTC still uses
/// litecoinspace via the generic registry.
enum BitcoinMempoolSpaceClient {
    static let shared = BitcoinMempoolSpaceClientLive()
}

/// Thin path helpers over `RPCClient.shared` for chain `.bitcoin`.
struct BitcoinMempoolSpaceClientLive: Sendable {
    private let client: RPCClient
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "btc-mempool")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - UTXOs (send coin selection)

    /// `GET /address/{addr}/utxo`
    func fetchUTXOs(address: String) async throws -> [SelectedUTXO] {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await client.callREST(
            chain: .bitcoin,
            path: "/address/\(trimmed)/utxo"
        )
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw RPCError.decodingFailed("mempool.space UTXO response not an array")
        }
        return arr.compactMap { item in
            guard let txid = item["txid"] as? String,
                  let vout = item["vout"] as? Int,
                  let value = (item["value"] as? NSNumber)?.int64Value else { return nil }
            let confirmed = (item["status"] as? [String: Any])?["confirmed"] as? Bool ?? false
            return SelectedUTXO(
                ownerAddress: trimmed,
                txid: txid,
                vout: vout,
                valueSats: value,
                scriptHex: nil,
                confirmed: confirmed
            )
        }
    }

    /// Parallel UTXO fetch for every wallet address on BTC (each leg still
    /// goes through the shared rate limiter / breaker).
    func fetchUTXOs(addresses: [String]) async throws -> [SelectedUTXO] {
        var seen = Set<String>()
        let unique = addresses.compactMap { raw -> String? in
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, seen.insert(address).inserted else { return nil }
            return address
        }
        guard !unique.isEmpty else { return [] }
        if unique.count == 1, let only = unique.first {
            return try await fetchUTXOs(address: only)
        }
        return try await withThrowingTaskGroup(of: [SelectedUTXO].self) { group in
            for address in unique {
                group.addTask { try await self.fetchUTXOs(address: address) }
            }
            var all: [SelectedUTXO] = []
            for try await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }
    }

    // MARK: - Fees

    /// `GET /v1/fees/recommended` → slow / normal / fast sat/vB.
    /// Uses `RPCClient` so fee probes share health state with UTXO/broadcast.
    func recommendedFees() async throws -> (slow: Decimal, normal: Decimal, fast: Decimal) {
        let data = try await client.callREST(
            chain: .bitcoin,
            path: "/v1/fees/recommended"
        )
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("mempool.space fees not an object")
        }
        func rate(_ key: String) throws -> Decimal {
            guard let number = root[key] as? NSNumber else {
                throw RPCError.decodingFailed("mempool.space fees missing \(key)")
            }
            return number.decimalValue
        }
        let minFee = try rate("minimumFee")
        let slow = max(try rate("economyFee"), minFee)
        let normal = max(try rate("halfHourFee"), minFee)
        let fast = max(try rate("fastestFee"), minFee)
        guard slow > 0, normal > 0, fast > 0 else {
            throw RPCError.decodingFailed("mempool.space fees non-positive")
        }
        return (slow, normal, fast)
    }

    // MARK: - Broadcast

    /// `POST /tx` raw hex body → 64-char txid.
    func broadcast(rawHex: String) async throws -> String {
        let data = try await client.callRESTPostRaw(
            chain: .bitcoin,
            path: "/tx",
            body: rawHex,
            contentType: "text/plain"
        )
        let txid = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isHexTxid = txid.count == 64 && txid.allSatisfy(\.isHexDigit)
        guard isHexTxid else {
            log.debug("mempool.space broadcast non-txid body: \(txid.prefix(80), privacy: .public)")
            throw RPCError.invalidResponse(
                txid.isEmpty ? "mempool.space broadcast empty response" : "mempool.space broadcast: \(txid)"
            )
        }
        return txid
    }

    // MARK: - Tx detail (history enrichment)

    /// `GET /tx/{txid}` JSON object.
    func transactionJSON(txid: String) async throws -> [String: Any] {
        let data = try await client.callREST(
            chain: .bitcoin,
            path: "/tx/\(txid)"
        )
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("mempool.space tx not an object")
        }
        return object
    }
}
