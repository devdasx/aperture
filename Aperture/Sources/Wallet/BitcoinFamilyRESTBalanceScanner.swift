import Foundation
import GRDB
import OSLog

actor BitcoinFamilyRESTBalanceScanner {
    private let client = RPCClient.shared
    private let utxoService = UTXOService()
    private let dogecoin = DogecoinDataClient.shared
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "bitcoin-family-rest")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .litecoin || address.chain == .dogecoin else { return }
        let chain = address.chain

        // BUG-016: multi-address receive/change (gap 20) for LTC/DOGE.
        let words = try? WalletSecretPersistence.loadMnemonic(for: walletId, database: database)
        if let words, !words.isEmpty {
            _ = try? BitcoinFamilyAddressBook.ensureGapCoverage(
                walletId: walletId,
                chain: chain,
                words: words,
                database: database
            )
        }
        var addressRows = (try? BitcoinFamilyAddressBook.persistedAddresses(
            walletId: walletId,
            chain: chain,
            database: database
        )) ?? []
        if addressRows.isEmpty {
            addressRows = [(address.address, "")]
        }

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: [chain.ticker],
                currencyCode: currencyCode
            )
            : [:]

        // Scan every known address; extend gap when activity found.
        // P1-001 / BUG-004: never invent zeros on RPC failure — only fold in
        // successful probes, and skip balance/UTXO writes when any probe fails.
        var totalRaw: Int64 = 0
        var allUTXOs: [SelectedUTXO] = []
        /// History legs tagged with the address they were fetched for.
        var allHistory: [(address: String, event: BitcoinFamilyRESTEvent)] = []
        var activeAddresses = Set<String>()
        var scanned = Set<String>()
        var queue = addressRows.map(\.address)
        var pathByAddress = Dictionary(uniqueKeysWithValues: addressRows.map { ($0.address, $0.path) })
        var loopGuard = 0
        var anySnapshotFailed = false
        var anyUTXOFailed = false

        while !queue.isEmpty, loopGuard < 12 {
            loopGuard += 1
            let batch = queue
            queue = []
            for addr in batch where scanned.insert(addr).inserted {
                async let snap = safeSnapshot(address: addr, chain: chain)
                async let utxos = safeUTXOs(address: addr, chain: chain)
                async let history: [BitcoinFamilyRESTEvent] = includeHistory
                    ? safeHistory(address: addr, chain: chain)
                    : []
                let snapshot = await snap
                let addrUTXOs = await utxos
                let addrHistory = await history

                if let snapshot {
                    if let raw = Int64(snapshot.rawBalance) {
                        let (sum, overflow) = totalRaw.addingReportingOverflow(raw)
                        totalRaw = overflow ? Int64.max : sum
                    }
                    if snapshot.isUsed {
                        activeAddresses.insert(addr)
                    }
                } else {
                    anySnapshotFailed = true
                }

                if let addrUTXOs {
                    if !addrUTXOs.isEmpty {
                        activeAddresses.insert(addr)
                    }
                    allUTXOs.append(contentsOf: addrUTXOs.map { utxo in
                        SelectedUTXO(
                            ownerAddress: addr,
                            txid: utxo.txid,
                            vout: utxo.vout,
                            valueSats: utxo.valueSats,
                            scriptHex: utxo.scriptHex,
                            confirmed: utxo.confirmed
                        )
                    })
                } else {
                    anyUTXOFailed = true
                }

                if !addrHistory.isEmpty {
                    activeAddresses.insert(addr)
                }
                // Per-address cap — never dump every path onto primary only.
                for event in addrHistory.prefix(HistoryScanLimits.perAddress) {
                    allHistory.append((addr, event))
                }
            }

            let extensions = (try? BitcoinFamilyAddressBook.markUsedAndExtendIfNeeded(
                walletId: walletId,
                chain: chain,
                activeAddresses: activeAddresses,
                words: words,
                database: database
            )) ?? []
            for item in extensions where !scanned.contains(item.address) {
                queue.append(item.address)
                pathByAddress[item.address] = item.path
            }
            // Persist quiet addresses too so we don't regenerate them.
            let discovered = pathByAddress.map { addr, path in
                ChainStateRepository.DiscoveredAddress(
                    address: addr,
                    derivationPath: path,
                    isUsed: activeAddresses.contains(addr)
                )
            }
            _ = try? ChainStateRepository(database: database).upsertDiscoveredAddresses(
                walletId: walletId,
                chain: chain,
                addresses: discovered
            )
        }

        let prices = await pricesTask
        let snapshotOK = !anySnapshotFailed
        let utxoOK = !anyUTXOFailed
        let failed = BalanceProbeKeepLastGood.failedChains(
            chain: chain,
            nativeProbeSucceeded: snapshotOK && utxoOK
        )
        let txRepo = TransactionRepository(database: database)

        // P1-001: only rewrite native balance when every address snapshot succeeded.
        // A partial sum undercounts; inventing "0" for failed addresses wipes last-good.
        if BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: snapshotOK) {
            let rawBalance = String(max(0, totalRaw))
            try txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: chain.ticker,
                tokenContract: nil,
                decimals: chain.nativeDecimals,
                rawBalance: rawBalance,
                fiatValueCached: fiatValue(
                    rawBalance: rawBalance,
                    decimals: chain.nativeDecimals,
                    symbol: chain.ticker,
                    prices: prices
                ),
                fiatCurrencyCode: currencyCode,
                save: false
            )
        }

        // Attribute each leg to the address it was fetched for (multi-path).
        let addressIds = try Self.addressIdByAddress(
            walletId: walletId,
            chain: chain,
            database: database
        )
        var seenLeg = Set<String>()
        for item in allHistory {
            let addressId = addressIds[item.address] ?? (item.address == address.address ? address.id : nil)
            guard let addressId else { continue }
            let legKey = "\(item.event.txHash)|\(addressId.uuidString)"
            guard seenLeg.insert(legKey).inserted else { continue }
            try txRepo.upsertTransaction(
                addressId: addressId,
                txHash: item.event.txHash,
                direction: item.event.direction,
                amountRaw: item.event.amount,
                tokenSymbol: chain.ticker,
                tokenContract: nil,
                blockNumber: item.event.blockNumber,
                occurredAt: item.event.occurredAt,
                status: item.event.status,
                counterparty: item.event.counterparty,
                feeRaw: item.event.fee,
                save: false
            )
        }

        // Keep last-good is_used when probes failed and we saw no new activity.
        if snapshotOK || !activeAddresses.isEmpty || !allHistory.isEmpty {
            let isUsed = !activeAddresses.isEmpty || (snapshotOK && totalRaw > 0)
            try txRepo.markScanComplete(addressId: address.id, isUsed: isUsed, save: false)
        }
        try txRepo.flush()

        // P1-001: never replace UTXO cache with a partial/empty set from failed fetches
        // (compose would otherwise see empty UTXOs and refuse spends).
        if BalanceProbeKeepLastGood.shouldReplaceUTXOs(probeSucceeded: utxoOK) {
            let addressedUTXOs = allUTXOs.map {
                ChainStateRepository.AddressedUTXO(
                    address: $0.ownerAddress ?? address.address,
                    txid: $0.txid,
                    vout: $0.vout,
                    valueSats: $0.valueSats,
                    scriptHex: $0.scriptHex,
                    confirmed: $0.confirmed
                )
            }
            _ = try ChainStateRepository(database: database)
                .replaceAddressedUTXOs(
                    walletId: walletId,
                    chain: chain,
                    utxos: addressedUTXOs
                )
        }
        _ = try ChainStateRepository(database: database).rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: Set([chain]),
            failedChains: failed,
            interim: false
        )

        // Soft-fail scans return success to the wallet runner (keep-last-good
        // did not throw). Surface the real cause in Diagnostics + Xcode console.
        if !failed.isEmpty {
            var reasons: [String] = []
            if anySnapshotFailed { reasons.append("balance snapshot") }
            if anyUTXOFailed { reasons.append("utxo") }
            NetworkProbeDiagnostics.recordKeepLastGood(
                chain: chain,
                reasons: reasons,
                source: "BitcoinFamilyRESTBalanceScanner"
            )
        }
    }

    /// P1-001 / BUG-004: `nil` on transport failure — never invent `"0"`.
    private func safeSnapshot(address: String, chain: SupportedChain) async -> BitcoinFamilyRESTSnapshot? {
        do {
            return try await accountSnapshot(address: address, chain: chain)
        } catch {
            NetworkProbeDiagnostics.recordFailure(
                chain: chain,
                operation: "balance snapshot",
                error: error,
                address: address,
                source: "BitcoinFamilyRESTBalanceScanner"
            )
            return nil
        }
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

    /// P1-001 / BUG-004: `nil` on transport failure — never invent empty UTXO list.
    private func safeUTXOs(address: String, chain: SupportedChain) async -> [SelectedUTXO]? {
        do {
            return try await utxoService.fetchUTXOs(address: address, chain: chain)
        } catch {
            NetworkProbeDiagnostics.recordFailure(
                chain: chain,
                operation: "utxo",
                error: error,
                address: address,
                source: "BitcoinFamilyRESTBalanceScanner"
            )
            return nil
        }
    }

    private func safeHistory(address: String, chain: SupportedChain) async -> [BitcoinFamilyRESTEvent] {
        do {
            return try await recentEvents(address: address, chain: chain)
        } catch {
            // History is non-critical for spendable balance; still record so
            // rate-limits are visible (but do not mark keep-last-good alone).
            NetworkProbeDiagnostics.recordFailure(
                chain: chain,
                operation: "history",
                error: error,
                address: address,
                source: "BitcoinFamilyRESTBalanceScanner"
            )
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
        // Multi-provider cascade: Blockbook → Blockchair → BlockCypher.
        try await dogecoin.accountSnapshot(address: address)
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
        try await dogecoin.recentEvents(address: address, limit: HistoryScanLimits.perAddress)
    }

    private static func addressIdByAddress(
        walletId: UUID,
        chain: SupportedChain,
        database: AppDatabase
    ) throws -> [String: UUID] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, address FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ?
                """,
                arguments: [walletId.uuidString, chain.rawValue]
            ).reduce(into: [String: UUID]()) { partial, row in
                guard let id = UUID(uuidString: row["id"]) else { return }
                partial[row["address"]] = id
            }
        }
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
        let response = try await blockCypherAddress(address: address, chain: chain, limit: HistoryScanLimits.perAddress)
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
