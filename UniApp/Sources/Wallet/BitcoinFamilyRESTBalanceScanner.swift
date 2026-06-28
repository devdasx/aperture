import Foundation
import OSLog
import SwiftData

actor BitcoinFamilyRESTBalanceScanner {
    private let client = RPCClient.shared
    private let utxoService = UTXOService()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "bitcoin-family-rest")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        modelContainer: ModelContainer,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .litecoin || address.chain == .dogecoin else { return }

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: [address.chain.ticker],
                currencyCode: currencyCode
            )
            : [:]
        async let snapshotTask = accountSnapshot(address: address.address, chain: address.chain)
        async let utxosTask = safeUTXOs(address: address.address, chain: address.chain)
        async let historyTask: [BitcoinFamilyRESTEvent] = includeHistory
            ? safeHistory(address: address.address, chain: address.chain)
            : []

        let snapshot = try await snapshotTask
        let prices = await pricesTask
        let utxos = await utxosTask
        let history = await historyTask

        let txRepo = TransactionRepository(modelContainer: modelContainer)
        try await txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: address.chain.ticker,
            tokenContract: nil,
            decimals: address.chain.nativeDecimals,
            rawBalance: snapshot.rawBalance,
            fiatValueCached: fiatValue(
                rawBalance: snapshot.rawBalance,
                decimals: address.chain.nativeDecimals,
                symbol: address.chain.ticker,
                prices: prices
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        let isUsed = snapshot.isUsed || !history.isEmpty || !utxos.isEmpty
        for event in history.prefix(50) {
            try await txRepo.upsertTransaction(
                addressId: address.id,
                txHash: event.txHash,
                direction: event.direction,
                amountRaw: event.amount,
                tokenSymbol: address.chain.ticker,
                tokenContract: nil,
                blockNumber: event.blockNumber,
                occurredAt: event.occurredAt,
                status: event.status,
                counterparty: event.counterparty,
                feeRaw: event.fee,
                save: false
            )
        }

        try await txRepo.markScanComplete(addressId: address.id, isUsed: isUsed, save: false)
        try await txRepo.flush()

        let addressedUTXOs = utxos.map {
            ChainStateRepository.AddressedUTXO(
                address: address.address,
                txid: $0.txid,
                vout: $0.vout,
                valueSats: $0.valueSats,
                scriptHex: $0.scriptHex,
                confirmed: $0.confirmed
            )
        }
        _ = try await ChainStateRepository(modelContainer: modelContainer)
            .replaceAddressedUTXOs(
                walletId: walletId,
                chain: address.chain,
                utxos: addressedUTXOs
            )
        _ = try await ChainStateRepository(modelContainer: modelContainer).rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: Set([address.chain]),
            failedChains: [],
            interim: false
        )
    }

    func accountSnapshot(address: String, chain: SupportedChain) async throws -> BitcoinFamilyRESTSnapshot {
        switch chain {
        case .litecoin:
            return try await litecoinSnapshot(address: address)
        case .dogecoin:
            return try await dogecoinSnapshot(address: address)
        default:
            throw BitcoinFamilyRESTError.unsupportedChain(chain.rawValue)
        }
    }

    func recentEvents(address: String, chain: SupportedChain) async throws -> [BitcoinFamilyRESTEvent] {
        switch chain {
        case .litecoin:
            return try await litecoinHistory(address: address)
        case .dogecoin:
            return try await dogecoinHistory(address: address)
        default:
            throw BitcoinFamilyRESTError.unsupportedChain(chain.rawValue)
        }
    }

    private func safeUTXOs(address: String, chain: SupportedChain) async -> [SelectedUTXO] {
        do {
            return try await utxoService.fetchUTXOs(address: address, chain: chain)
        } catch {
            log.debug("UTXO fetch failed for \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func safeHistory(address: String, chain: SupportedChain) async -> [BitcoinFamilyRESTEvent] {
        do {
            return try await recentEvents(address: address, chain: chain)
        } catch {
            log.debug("History fetch failed for \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func litecoinSnapshot(address: String) async throws -> BitcoinFamilyRESTSnapshot {
        do {
            let data = try await client.callREST(chain: .litecoin, path: "/address/\(address)")
            let root = try JSONObject(data: data)
            let chainStats = root.dictionary("chain_stats") ?? [:]
            let mempoolStats = root.dictionary("mempool_stats") ?? [:]
            let funded = int64(chainStats["funded_txo_sum"]) + int64(mempoolStats["funded_txo_sum"])
            let spent = int64(chainStats["spent_txo_sum"]) + int64(mempoolStats["spent_txo_sum"])
            let txCount = int64(chainStats["tx_count"]) + int64(mempoolStats["tx_count"])
            return BitcoinFamilyRESTSnapshot(
                rawBalance: String(max(0, funded - spent)),
                isUsed: txCount > 0
            )
        } catch {
            return try await blockCypherSnapshot(address: address, chain: .litecoin)
        }
    }

    private func dogecoinSnapshot(address: String) async throws -> BitcoinFamilyRESTSnapshot {
        let response = try await dogecoinAddress(address: address, limit: 1)
        let raw = int64(response["final_balance"] ?? response["balance"])
        let count = int64(response["final_n_tx"] ?? response["n_tx"])
        return BitcoinFamilyRESTSnapshot(
            rawBalance: String(max(0, raw)),
            isUsed: count > 0
        )
    }

    private func litecoinHistory(address: String) async throws -> [BitcoinFamilyRESTEvent] {
        let array: [[String: Any]]
        do {
            let data = try await client.callREST(chain: .litecoin, path: "/address/\(address)/txs")
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw BitcoinFamilyRESTError.invalidResponse("Litecoin txs response was not an array")
            }
            array = decoded
        } catch {
            return try await blockCypherHistory(address: address, chain: .litecoin)
        }

        return array.compactMap { tx in
            guard let txid = tx["txid"] as? String else { return nil }
            let vin = tx["vin"] as? [[String: Any]] ?? []
            let vout = tx["vout"] as? [[String: Any]] ?? []
            let spent = vin.reduce(Int64(0)) { total, input in
                guard let prevout = input["prevout"] as? [String: Any],
                      prevout["scriptpubkey_address"] as? String == address else {
                    return total
                }
                return total + int64(prevout["value"])
            }
            let received = vout.reduce(Int64(0)) { total, output in
                guard output["scriptpubkey_address"] as? String == address else { return total }
                return total + int64(output["value"])
            }
            let delta = received - spent
            guard delta != 0 else { return nil }
            let status = tx["status"] as? [String: Any] ?? [:]
            let confirmed = status["confirmed"] as? Bool ?? false
            let blockHeight = int64(status["block_height"])
            let timestamp = int64(status["block_time"])
            let occurredAt = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : Date()
            return BitcoinFamilyRESTEvent(
                txHash: txid,
                direction: delta > 0 ? .incoming : .outgoing,
                amount: display(raw: abs(delta), decimals: SupportedChain.litecoin.nativeDecimals),
                blockNumber: blockHeight > 0 ? blockHeight : nil,
                occurredAt: occurredAt,
                status: confirmed ? .confirmed : .pending,
                counterparty: "",
                fee: display(raw: int64(tx["fee"]), decimals: SupportedChain.litecoin.nativeDecimals)
            )
        }.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func dogecoinHistory(address: String) async throws -> [BitcoinFamilyRESTEvent] {
        try await blockCypherHistory(address: address, chain: .dogecoin)
    }

    private func blockCypherSnapshot(
        address: String,
        chain: SupportedChain
    ) async throws -> BitcoinFamilyRESTSnapshot {
        let response = try await blockCypherAddress(address: address, chain: chain, limit: 1)
        let raw = int64(response["final_balance"] ?? response["balance"])
        let count = int64(response["final_n_tx"] ?? response["n_tx"])
        return BitcoinFamilyRESTSnapshot(
            rawBalance: String(max(0, raw)),
            isUsed: count > 0
        )
    }

    private func blockCypherHistory(
        address: String,
        chain: SupportedChain
    ) async throws -> [BitcoinFamilyRESTEvent] {
        let response = try await blockCypherAddress(address: address, chain: chain, limit: 50)
        let confirmed = response.array("txrefs")
        let pending = response.array("unconfirmed_txrefs")
        let rows = confirmed.compactMap { blockCypherEvent($0, chain: chain, confirmed: true) }
            + pending.compactMap { blockCypherEvent($0, chain: chain, confirmed: false) }
        var seen = Set<String>()
        return rows
            .filter { seen.insert("\($0.txHash)|\($0.direction.rawValue)|\($0.amount)").inserted }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func blockCypherEvent(
        _ txref: [String: Any],
        chain: SupportedChain,
        confirmed: Bool
    ) -> BitcoinFamilyRESTEvent? {
        guard let hash = txref["tx_hash"] as? String else { return nil }
        let value = int64(txref["value"])
        guard value > 0 else { return nil }
        let inputIndex = int64(txref["tx_input_n"])
        let outputIndex = int64(txref["tx_output_n"])
        let direction: TransactionDirection = inputIndex >= 0 && outputIndex < 0 ? .outgoing : .incoming
        let blockHeight = int64(txref["block_height"])
        let occurredAt = isoDate(txref["confirmed"] as? String) ?? Date()
        return BitcoinFamilyRESTEvent(
            txHash: hash,
            direction: direction,
            amount: display(raw: value, decimals: chain.nativeDecimals),
            blockNumber: blockHeight > 0 ? blockHeight : nil,
            occurredAt: occurredAt,
            status: confirmed ? .confirmed : .pending,
            counterparty: "",
            fee: nil
        )
    }

    private func dogecoinAddress(address: String, limit: Int) async throws -> [String: Any] {
        try await blockCypherAddress(address: address, chain: .dogecoin, limit: limit)
    }

    private func blockCypherAddress(
        address: String,
        chain: SupportedChain,
        limit: Int
    ) async throws -> [String: Any] {
        let data = try await client.callREST(
            chain: chain,
            path: "/addrs/\(address)",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return try JSONObject(data: data)
    }

    private func fiatValue(
        rawBalance: String,
        decimals: Int,
        symbol: String,
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) -> Decimal? {
        guard let price = prices[symbol.uppercased()] else { return nil }
        guard let amount = EVMHexQuantity.decimalAmount(rawBalance: rawBalance, decimals: decimals) else { return nil }
        return amount * price.amount
    }

    private func display(raw: Int64, decimals: Int) -> String {
        EVMHexQuantity.displayAmount(rawBalance: String(raw), decimals: decimals)
            ?? EVMHexQuantity.decimalAmount(rawBalance: String(raw), decimals: decimals)
                .map { NSDecimalNumber(decimal: $0).stringValue }
            ?? "0"
    }

    private func JSONObject(data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BitcoinFamilyRESTError.invalidResponse("response was not an object")
        }
        return root
    }

    private func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string) ?? 0
        default:
            return 0
        }
    }

    private func isoDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

struct BitcoinFamilyRESTSnapshot: Sendable {
    let rawBalance: String
    let isUsed: Bool
}

struct BitcoinFamilyRESTEvent: Sendable {
    let txHash: String
    let direction: TransactionDirection
    let amount: String
    let blockNumber: Int64?
    let occurredAt: Date
    let status: TransactionStatus
    let counterparty: String
    let fee: String?
}

private enum BitcoinFamilyRESTError: Error, CustomStringConvertible {
    case unsupportedChain(String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .unsupportedChain(let chain):
            return "Unsupported Bitcoin-family REST chain: \(chain)"
        case .invalidResponse(let reason):
            return "Invalid Bitcoin-family REST response: \(reason)"
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }
}
