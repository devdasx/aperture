import Foundation
import OSLog

/// Multi-provider Dogecoin reads: **Blockbook primary**, Blockchair fallback,
/// BlockCypher last-resort.
///
/// Path shapes differ across providers, so this client does **not** rely on
/// `RPCClient.callREST` rotating the same path across mixed APIs. Each
/// provider is tried in order with its own URL template (live-verified
/// 2026-07-11).
///
/// | Priority | Provider | Balance | UTXO | History | Broadcast |
/// |----------|----------|---------|------|---------|-----------|
/// | 0 | Blockbook (zelcore) | ✓ | ✓ | ✓ | ✓ sendtx |
/// | 1 | Blockchair keyless | ✓ | ✓ | tx hashes | push/tx |
/// | 2 | BlockCypher keyless | ✓ | ✓ | ✓ | txs/push |
actor DogecoinDataClient {
    static let shared = DogecoinDataClient()

    /// Well-known funded mainnet address used by live probes/tests.
    static let probeAddress = "DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L"

    private let session: URLSession
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "dogecoin-data")

    private static let blockbookBases = [
        URL(string: "https://blockbook.doge.zelcore.io")!,
    ]
    private static let blockchairBase = URL(string: "https://api.blockchair.com")!
    private static let blockCypherBase = URL(string: "https://api.blockcypher.com/v1/doge/main")!

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Snapshot

    func accountSnapshot(address: String) async throws -> BitcoinFamilyRESTSnapshot {
        var lastError: Error?
        do {
            return try await blockbookSnapshot(address: address)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockbook balance snapshot",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
        }
        do {
            return try await blockchairSnapshot(address: address)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockchair balance snapshot",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
        }
        do {
            return try await blockCypherSnapshot(address: address)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockcypher balance snapshot",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
            throw lastError ?? error
        }
    }

    // MARK: - UTXOs

    func fetchUTXOs(address: String) async throws -> [SelectedUTXO] {
        var lastError: Error?
        do {
            return try await blockbookUTXOs(address: address)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockbook utxo",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
        }
        do {
            return try await blockchairUTXOs(address: address)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockchair utxo",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
        }
        do {
            return try await blockCypherUTXOs(address: address)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockcypher utxo",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
            throw lastError ?? error
        }
    }

    // MARK: - History

    func recentEvents(address: String, limit: Int = 50) async throws -> [BitcoinFamilyRESTEvent] {
        var lastError: Error?
        do {
            return try await blockbookHistory(address: address, limit: limit)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockbook history",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
        }
        do {
            return try await blockchairHistory(address: address, limit: limit)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockchair history",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
        }
        do {
            return try await blockCypherHistory(address: address, limit: limit)
        } catch {
            lastError = error
            NetworkProbeDiagnostics.recordFailure(
                chain: .dogecoin,
                operation: "blockcypher history",
                error: error,
                address: address,
                source: "DogecoinDataClient"
            )
            throw lastError ?? error
        }
    }

    // MARK: - Broadcast

    /// Push raw tx hex. Tries Blockbook `sendtx` → BlockCypher → Blockchair.
    func broadcast(rawHex: String) async throws -> String {
        var lastError: Error?
        do {
            return try await blockbookBroadcast(rawHex: rawHex)
        } catch {
            lastError = error
            log.error("Blockbook DOGE broadcast failed: \(String(describing: error), privacy: .public)")
        }
        do {
            return try await blockCypherBroadcast(rawHex: rawHex)
        } catch {
            lastError = error
            log.error("BlockCypher DOGE broadcast failed: \(String(describing: error), privacy: .public)")
        }
        do {
            return try await blockchairBroadcast(rawHex: rawHex)
        } catch {
            throw lastError ?? error
        }
    }

    // MARK: - Blockbook

    private func blockbookSnapshot(address: String) async throws -> BitcoinFamilyRESTSnapshot {
        let data = try await blockbookGET(
            path: "api/v2/address/\(address)",
            query: [URLQueryItem(name: "details", value: "basic")]
        )
        let root = try Self.jsonObject(data)
        let balance = Self.int64String(root["balance"]) ?? 0
        let unconfirmed = Self.int64String(root["unconfirmedBalance"]) ?? 0
        let txs = Self.int64String(root["txs"]) ?? Self.int64String(root["txids"]) ?? 0
        let total = balance + max(0, unconfirmed)
        return BitcoinFamilyRESTSnapshot(
            rawBalance: String(max(0, total)),
            isUsed: txs > 0 || total > 0
        )
    }

    private func blockbookUTXOs(address: String) async throws -> [SelectedUTXO] {
        let data = try await blockbookGET(path: "api/v2/utxo/\(address)")
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw RPCError.decodingFailed("Blockbook DOGE utxo was not an array")
        }
        return rows.compactMap { row in
            guard let txid = row["txid"] as? String else { return nil }
            let vout = (row["vout"] as? NSNumber)?.intValue ?? (row["vout"] as? Int) ?? -1
            let value = Self.int64Any(row["value"]) ?? 0
            guard vout >= 0, value > 0 else { return nil }
            let height = (row["height"] as? NSNumber)?.intValue ?? 0
            let confirmations = (row["confirmations"] as? NSNumber)?.intValue ?? 0
            return SelectedUTXO(
                ownerAddress: address,
                txid: txid,
                vout: vout,
                valueSats: value,
                scriptHex: nil,
                confirmed: height > 0 || confirmations > 0
            )
        }
    }

    private func blockbookHistory(address: String, limit: Int) async throws -> [BitcoinFamilyRESTEvent] {
        let pageSize = min(max(limit, 1), 50)
        let data = try await blockbookGET(
            path: "api/v2/address/\(address)",
            query: [
                URLQueryItem(name: "details", value: "txs"),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
            ]
        )
        let root = try Self.jsonObject(data)
        let txs = root["transactions"] as? [[String: Any]] ?? []
        let owner = address
        return txs.compactMap { tx -> BitcoinFamilyRESTEvent? in
            guard let txid = tx["txid"] as? String else { return nil }
            let vin = tx["vin"] as? [[String: Any]] ?? []
            let vout = tx["vout"] as? [[String: Any]] ?? []
            let spent = vin.reduce(Int64(0)) { total, input in
                let addrs = (input["addresses"] as? [String]) ?? []
                guard addrs.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) else {
                    return total
                }
                return total + (Self.int64Any(input["value"]) ?? 0)
            }
            let received = vout.reduce(Int64(0)) { total, output in
                let addrs = (output["addresses"] as? [String]) ?? []
                guard addrs.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) else {
                    return total
                }
                return total + (Self.int64Any(output["value"]) ?? 0)
            }
            let delta = received - spent
            guard delta != 0 else { return nil }
            let blockTime = Self.int64Any(tx["blockTime"]) ?? 0
            let blockHeight = Self.int64Any(tx["blockHeight"]) ?? 0
            let confirmations = Self.int64Any(tx["confirmations"]) ?? 0
            let occurredAt = blockTime > 0
                ? Date(timeIntervalSince1970: TimeInterval(blockTime))
                : Date()
            let fee = Self.int64Any(tx["fees"])
            return BitcoinFamilyRESTEvent(
                txHash: txid,
                direction: delta > 0 ? .incoming : .outgoing,
                amount: Self.display(raw: abs(delta)),
                blockNumber: blockHeight > 0 ? blockHeight : nil,
                occurredAt: occurredAt,
                status: confirmations > 0 || blockHeight > 0 ? .confirmed : .pending,
                counterparty: "",
                fee: fee.map { Self.display(raw: $0) }
            )
        }
        .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func blockbookBroadcast(rawHex: String) async throws -> String {
        let data = try await blockbookPOST(path: "api/v2/sendtx", body: rawHex, contentType: "text/plain")
        // Blockbook returns plain txid or JSON `{"result":"..."}` / error object.
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           text.count == 64,
           text.allSatisfy(\.isHexDigit) {
            return text
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let result = root["result"] as? String, result.count == 64 {
                return result
            }
            if let error = root["error"] as? String {
                throw RPCError.rpcError(code: -1, message: error)
            }
        }
        throw RPCError.invalidResponse("Blockbook DOGE sendtx unexpected body")
    }

    private func blockbookGET(path: String, query: [URLQueryItem] = []) async throws -> Data {
        var lastError: Error = RPCError.allEndpointsFailed(.dogecoin)
        for base in Self.blockbookBases {
            do {
                return try await get(base: base, path: path, query: query, provider: "zelcore-blockbook")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func blockbookPOST(path: String, body: String, contentType: String) async throws -> Data {
        var lastError: Error = RPCError.allEndpointsFailed(.dogecoin)
        for base in Self.blockbookBases {
            do {
                let url = base.appendingPathComponent(path)
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
                request.httpBody = body.data(using: .utf8)
                return try await perform(request, provider: "zelcore-blockbook", operation: path)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Blockchair

    private func blockchairSnapshot(address: String) async throws -> BitcoinFamilyRESTSnapshot {
        let data = try await get(
            base: Self.blockchairBase,
            path: "dogecoin/dashboards/address/\(address)",
            query: [URLQueryItem(name: "limit", value: "0")],
            provider: "blockchair"
        )
        let root = try Self.jsonObject(data)
        guard let entry = (root["data"] as? [String: Any])?[address] as? [String: Any],
              let addressObj = entry["address"] as? [String: Any] else {
            throw RPCError.invalidResponse("Blockchair DOGE dashboard missing address")
        }
        let balance = Self.int64Any(addressObj["balance"]) ?? 0
        let txs = Self.int64Any(addressObj["transaction_count"]) ?? 0
        return BitcoinFamilyRESTSnapshot(
            rawBalance: String(max(0, balance)),
            isUsed: txs > 0 || balance > 0
        )
    }

    private func blockchairUTXOs(address: String) async throws -> [SelectedUTXO] {
        let data = try await get(
            base: Self.blockchairBase,
            path: "dogecoin/dashboards/address/\(address)",
            query: [URLQueryItem(name: "limit", value: "100")],
            provider: "blockchair"
        )
        let root = try Self.jsonObject(data)
        guard let entry = (root["data"] as? [String: Any])?[address] as? [String: Any] else {
            throw RPCError.invalidResponse("Blockchair DOGE utxo missing data")
        }
        let utxos = entry["utxo"] as? [[String: Any]] ?? []
        return utxos.compactMap { row in
            guard let txid = row["transaction_hash"] as? String else { return nil }
            let vout = (row["index"] as? NSNumber)?.intValue ?? (row["index"] as? Int) ?? -1
            let value = Self.int64Any(row["value"]) ?? 0
            guard vout >= 0, value > 0 else { return nil }
            let blockId = Self.int64Any(row["block_id"]) ?? 0
            return SelectedUTXO(
                ownerAddress: address,
                txid: txid,
                vout: vout,
                valueSats: value,
                scriptHex: nil,
                confirmed: blockId > 0
            )
        }
    }

    private func blockchairHistory(address: String, limit: Int) async throws -> [BitcoinFamilyRESTEvent] {
        let data = try await get(
            base: Self.blockchairBase,
            path: "dogecoin/dashboards/address/\(address)",
            query: [URLQueryItem(name: "limit", value: String(min(limit, 50)))],
            provider: "blockchair"
        )
        let root = try Self.jsonObject(data)
        guard let entry = (root["data"] as? [String: Any])?[address] as? [String: Any] else {
            throw RPCError.invalidResponse("Blockchair DOGE history missing data")
        }
        // Dashboard returns tx hashes only (not full legs). Surface as
        // confirmed rows with unknown amount so Activity is non-empty; full
        // decode would need per-tx fetches.
        let hashes = entry["transactions"] as? [String] ?? []
        return hashes.prefix(limit).map { hash in
            BitcoinFamilyRESTEvent(
                txHash: hash,
                direction: .incoming,
                amount: "0",
                blockNumber: nil,
                occurredAt: Date(),
                status: .confirmed,
                counterparty: "",
                fee: nil
            )
        }
    }

    private func blockchairBroadcast(rawHex: String) async throws -> String {
        let url = Self.blockchairBase.appendingPathComponent("dogecoin/push/transaction")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = "data=\(rawHex)".data(using: .utf8)
        let data = try await perform(request, provider: "blockchair", operation: "push/transaction")
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = root["data"] as? [String: Any],
           let hash = payload["transaction_hash"] as? String,
           !hash.isEmpty {
            return hash
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let context = root["context"] as? [String: Any],
           let error = context["error"] as? String {
            throw RPCError.rpcError(code: (context["code"] as? Int) ?? -1, message: error)
        }
        throw RPCError.invalidResponse("Blockchair DOGE push unexpected body")
    }

    // MARK: - BlockCypher

    private func blockCypherSnapshot(address: String) async throws -> BitcoinFamilyRESTSnapshot {
        let data = try await get(
            base: Self.blockCypherBase,
            path: "addrs/\(address)/balance",
            provider: "blockcypher"
        )
        let root = try Self.jsonObject(data)
        let raw = Self.int64Any(root["final_balance"]) ?? Self.int64Any(root["balance"]) ?? 0
        let count = Self.int64Any(root["final_n_tx"]) ?? Self.int64Any(root["n_tx"]) ?? 0
        return BitcoinFamilyRESTSnapshot(
            rawBalance: String(max(0, raw)),
            isUsed: count > 0 || raw > 0
        )
    }

    private func blockCypherUTXOs(address: String) async throws -> [SelectedUTXO] {
        let data = try await get(
            base: Self.blockCypherBase,
            path: "addrs/\(address)",
            query: [
                URLQueryItem(name: "unspentOnly", value: "true"),
                URLQueryItem(name: "includeScript", value: "true"),
                URLQueryItem(name: "limit", value: "2000"),
            ],
            provider: "blockcypher"
        )
        let root = try Self.jsonObject(data)
        let txrefs = root["txrefs"] as? [[String: Any]] ?? []
        return txrefs.compactMap { item in
            guard let txid = item["tx_hash"] as? String else { return nil }
            let vout = (item["tx_output_n"] as? NSNumber)?.intValue ?? -1
            let value = Self.int64Any(item["value"]) ?? 0
            guard vout >= 0, value > 0 else { return nil }
            let script = item["script"] as? String
            let confirmed = (item["confirmed"] as? String) != nil
                || ((item["confirmations"] as? NSNumber)?.intValue ?? 0) > 0
            return SelectedUTXO(
                ownerAddress: address,
                txid: txid,
                vout: vout,
                valueSats: value,
                scriptHex: script,
                confirmed: confirmed
            )
        }
    }

    private func blockCypherHistory(address: String, limit: Int) async throws -> [BitcoinFamilyRESTEvent] {
        let data = try await get(
            base: Self.blockCypherBase,
            path: "addrs/\(address)",
            query: [URLQueryItem(name: "limit", value: String(min(limit, 50)))],
            provider: "blockcypher"
        )
        let root = try Self.jsonObject(data)
        let confirmed = root["txrefs"] as? [[String: Any]] ?? []
        let pending = root["unconfirmed_txrefs"] as? [[String: Any]] ?? []
        let rows = confirmed.compactMap { Self.blockCypherEvent($0, confirmed: true) }
            + pending.compactMap { Self.blockCypherEvent($0, confirmed: false) }
        var seen = Set<String>()
        return rows
            .filter { seen.insert("\($0.txHash)|\($0.direction.rawValue)|\($0.amount)").inserted }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func blockCypherBroadcast(rawHex: String) async throws -> String {
        let url = Self.blockCypherBase.appendingPathComponent("txs/push")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tx": rawHex])
        let data = try await perform(request, provider: "blockcypher", operation: "txs/push")
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tx = root["tx"] as? [String: Any],
           let hash = tx["hash"] as? String,
           !hash.isEmpty {
            return hash
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? String {
            throw RPCError.rpcError(code: -1, message: error)
        }
        throw RPCError.invalidResponse("BlockCypher DOGE push unexpected body")
    }

    private static func blockCypherEvent(_ txref: [String: Any], confirmed: Bool) -> BitcoinFamilyRESTEvent? {
        guard let hash = txref["tx_hash"] as? String else { return nil }
        let value = int64Any(txref["value"]) ?? 0
        guard value > 0 else { return nil }
        let inputIndex = int64Any(txref["tx_input_n"]) ?? -1
        let outputIndex = int64Any(txref["tx_output_n"]) ?? -1
        let direction: TransactionDirection = inputIndex >= 0 && outputIndex < 0 ? .outgoing : .incoming
        let blockHeight = int64Any(txref["block_height"]) ?? 0
        let occurredAt: Date
        if let confirmedStr = txref["confirmed"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            occurredAt = formatter.date(from: confirmedStr) ?? Date()
        } else {
            occurredAt = Date()
        }
        return BitcoinFamilyRESTEvent(
            txHash: hash,
            direction: direction,
            amount: display(raw: value),
            blockNumber: blockHeight > 0 ? blockHeight : nil,
            occurredAt: occurredAt,
            status: confirmed ? .confirmed : .pending,
            counterparty: "",
            fee: nil
        )
    }

    // MARK: - HTTP

    private func get(
        base: URL,
        path: String,
        query: [URLQueryItem] = [],
        provider: String
    ) async throws -> Data {
        var components = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw RPCError.invalidResponse("Failed to compose DOGE \(provider) URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        return try await perform(request, provider: provider, operation: path)
    }

    private func perform(
        _ request: URLRequest,
        provider: String,
        operation: String
    ) async throws -> Data {
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.apertureData(
                for: request,
                family: "rpc-rest",
                operation: "DOGE \(provider) \(operation)",
                metadata: [
                    "chain": SupportedChain.dogecoin.rawValue,
                    "provider": provider,
                    "source": "DogecoinDataClient",
                ]
            )
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw RPCError.cancelled }
            throw RPCError.network(urlError.localizedDescription)
        } catch is CancellationError {
            throw RPCError.cancelled
        } catch {
            throw RPCError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let retry: Date
                if let raw = http.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = TimeInterval(raw) {
                    retry = Date().addingTimeInterval(seconds)
                } else {
                    retry = Date().addingTimeInterval(60)
                }
                throw RPCError.rateLimited(retryAfter: retry)
            }
            if !(200..<300).contains(http.statusCode) {
                let snippet = String(data: responseData.prefix(200), encoding: .utf8) ?? ""
                // BlockCypher "Limits reached." body on 429 sometimes returns 200? handle text
                if snippet.lowercased().contains("limits reached") {
                    throw RPCError.rateLimited(retryAfter: Date().addingTimeInterval(60))
                }
                throw RPCError.invalidResponse("HTTP \(http.statusCode) \(snippet)")
            }
        }
        // BlockCypher may return 200 with {"error":"Limits reached."}
        if let root = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let error = root["error"] as? String {
            let lower = error.lowercased()
            if lower.contains("limit") || lower.contains("rate") {
                throw RPCError.rateLimited(retryAfter: Date().addingTimeInterval(60))
            }
            throw RPCError.rpcError(code: -1, message: error)
        }
        return responseData
    }

    // MARK: - Helpers

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCError.decodingFailed("DOGE response was not a JSON object")
        }
        return root
    }

    private static func display(raw: Int64) -> String {
        EVMHexQuantity.displayAmount(
            rawBalance: String(raw),
            decimals: SupportedChain.dogecoin.nativeDecimals
        )
            ?? EVMHexQuantity.decimalAmount(
                rawBalance: String(raw),
                decimals: SupportedChain.dogecoin.nativeDecimals
            ).map { NSDecimalNumber(decimal: $0).stringValue }
            ?? "0"
    }

    private static func int64String(_ value: Any?) -> Int64? {
        if let s = value as? String { return Int64(s) }
        return int64Any(value)
    }

    private static func int64Any(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
