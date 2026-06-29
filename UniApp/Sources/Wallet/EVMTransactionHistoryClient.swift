import Foundation
import OSLog

struct EVMHistoryEvent: Sendable {
    let txHash: String
    let direction: TransactionDirection
    let amount: String
    let tokenSymbol: String
    let tokenContract: String?
    let blockNumber: Int64?
    let occurredAt: Date
    let status: TransactionStatus
    let counterparty: String
    let fee: String?
}

actor EVMTransactionHistoryClient {
    private let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
    private let session: URLSession
    private var requestID = 0
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "evm-history")

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    func recentEvents(
        chain: SupportedChain,
        holder: String,
        tokens: [EVMTokenRegistry.Entry]
    ) async -> [EVMHistoryEvent] {
        let holderAddress = Self.normalizedAddress(holder)
        let supportedTokens = Self.tokenMap(tokens)

        for provider in explorerProviders(for: chain) {
            do {
                let events = try await explorerEvents(
                    provider: provider,
                    chain: chain,
                    holder: holderAddress,
                    supportedTokens: supportedTokens
                )
                return finalize(events)
            } catch {
                log.debug("EVM history provider failed for \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
        }

        let fallback = await rpcTokenTransferFallback(
            chain: chain,
            holder: holderAddress,
            tokens: Array(supportedTokens.values)
        )
        return finalize(fallback)
    }

    private func explorerEvents(
        provider: ExplorerProvider,
        chain: SupportedChain,
        holder: String,
        supportedTokens: [String: EVMTokenRegistry.Entry]
    ) async throws -> [EVMHistoryEvent] {
        switch provider {
        case .blockscout(let baseURL):
            async let native = blockscoutNativeEvents(baseURL: baseURL, chain: chain, holder: holder)
            async let token = blockscoutTokenEvents(baseURL: baseURL, holder: holder, supportedTokens: supportedTokens)
            return try await native + token
        case .etherscanV2(let chainID):
            async let native = etherscanCompatibleNativeEvents(
                baseURL: Self.etherscanV2URL,
                chainID: chainID,
                apiKey: Secrets.etherscanAPIKey,
                chain: chain,
                holder: holder
            )
            async let token = etherscanCompatibleTokenEvents(
                baseURL: Self.etherscanV2URL,
                chainID: chainID,
                apiKey: Secrets.etherscanAPIKey,
                holder: holder,
                supportedTokens: supportedTokens
            )
            return try await native + token
        case .routescan(let chainID):
            let baseURL = Self.routescanURL(chainID: chainID)
            async let native = etherscanCompatibleNativeEvents(
                baseURL: baseURL,
                chainID: nil,
                apiKey: nil,
                chain: chain,
                holder: holder
            )
            async let token = etherscanCompatibleTokenEvents(
                baseURL: baseURL,
                chainID: nil,
                apiKey: nil,
                holder: holder,
                supportedTokens: supportedTokens
            )
            return try await native + token
        case .snowtrace:
            async let native = etherscanCompatibleNativeEvents(
                baseURL: Self.snowtraceURL,
                chainID: nil,
                apiKey: nil,
                chain: chain,
                holder: holder
            )
            async let token = etherscanCompatibleTokenEvents(
                baseURL: Self.snowtraceURL,
                chainID: nil,
                apiKey: nil,
                holder: holder,
                supportedTokens: supportedTokens
            )
            return try await native + token
        }
    }

    private func blockscoutNativeEvents(
        baseURL: URL,
        chain: SupportedChain,
        holder: String
    ) async throws -> [EVMHistoryEvent] {
        let url = try Self.url(
            base: baseURL,
            path: "api/v2/addresses/\(holder)/transactions",
            query: [
                URLQueryItem(name: "items_count", value: "100")
            ]
        )
        let envelope = try await get(BlockscoutList<BlockscoutTransaction>.self, url: url)
        return envelope.items.compactMap {
            Self.decodeBlockscoutNative($0, chain: chain, holder: holder)
        }
    }

    private func blockscoutTokenEvents(
        baseURL: URL,
        holder: String,
        supportedTokens: [String: EVMTokenRegistry.Entry]
    ) async throws -> [EVMHistoryEvent] {
        guard !supportedTokens.isEmpty else { return [] }
        let url = try Self.url(
            base: baseURL,
            path: "api/v2/addresses/\(holder)/token-transfers",
            query: [
                URLQueryItem(name: "type", value: "ERC-20"),
                URLQueryItem(name: "items_count", value: "100")
            ]
        )
        let envelope = try await get(BlockscoutList<BlockscoutTokenTransfer>.self, url: url)
        return envelope.items.compactMap {
            Self.decodeBlockscoutToken($0, holder: holder, supportedTokens: supportedTokens)
        }
    }

    private func etherscanCompatibleNativeEvents(
        baseURL: URL,
        chainID: Int?,
        apiKey: String?,
        chain: SupportedChain,
        holder: String
    ) async throws -> [EVMHistoryEvent] {
        let url = try etherscanURL(
            baseURL: baseURL,
            chainID: chainID,
            apiKey: apiKey,
            action: "txlist",
            address: holder
        )
        let envelope = try await get(EtherscanEnvelope<EtherscanTransaction>.self, url: url)
        guard envelope.isSuccess else { throw EVMHistoryError.providerMessage(envelope.message ?? "Etherscan txlist failed") }
        return envelope.result.compactMap {
            Self.decodeEtherscanNative($0, chain: chain, holder: holder)
        }
    }

    private func etherscanCompatibleTokenEvents(
        baseURL: URL,
        chainID: Int?,
        apiKey: String?,
        holder: String,
        supportedTokens: [String: EVMTokenRegistry.Entry]
    ) async throws -> [EVMHistoryEvent] {
        guard !supportedTokens.isEmpty else { return [] }
        let url = try etherscanURL(
            baseURL: baseURL,
            chainID: chainID,
            apiKey: apiKey,
            action: "tokentx",
            address: holder
        )
        let envelope = try await get(EtherscanEnvelope<EtherscanTokenTransfer>.self, url: url)
        guard envelope.isSuccess else { throw EVMHistoryError.providerMessage(envelope.message ?? "Etherscan tokentx failed") }
        return envelope.result.compactMap {
            Self.decodeEtherscanToken($0, holder: holder, supportedTokens: supportedTokens)
        }
    }

    private func rpcTokenTransferFallback(
        chain: SupportedChain,
        holder: String,
        tokens: [EVMTokenRegistry.Entry]
    ) async -> [EVMHistoryEvent] {
        guard !tokens.isEmpty else { return [] }

        do {
            let latestHex = try await rpcString(chain: chain, method: "eth_blockNumber", params: [])
            let latestBlock = try EVMHexQuantity.int64(from: latestHex)
            let fromBlock = max(0, latestBlock - 2_000)
            let ranges = blockRanges(from: fromBlock, through: latestBlock, chunkSize: 250)
            let holderTopic = Self.indexedAddressTopic(holder)
            let tokenByContract = Self.tokenMap(tokens)
            let logs = await rpcTransferLogs(
                chain: chain,
                holderTopic: holderTopic,
                tokens: tokens,
                ranges: ranges
            )
            let blockNumbers = Set(logs.compactMap { try? EVMHexQuantity.int64(from: $0.blockNumber) })
            let timestamps = await rpcBlockTimestamps(chain: chain, blocks: blockNumbers)

            return logs.compactMap {
                Self.decodeRPCLog(
                    $0,
                    holder: holder,
                    supportedTokens: tokenByContract,
                    timestamps: timestamps
                )
            }
        } catch {
            log.debug("EVM RPC token history fallback failed for \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func rpcTransferLogs(
        chain: SupportedChain,
        holderTopic: String,
        tokens: [EVMTokenRegistry.Entry],
        ranges: [ClosedRange<Int64>]
    ) async -> [EVMRPCLog] {
        await withTaskGroup(of: [EVMRPCLog].self) { group in
            for token in tokens {
                for range in ranges {
                    group.addTask {
                        let params: [[String: Any]] = [[
                            "fromBlock": EVMHexQuantity.hexQuantity(range.lowerBound),
                            "toBlock": EVMHexQuantity.hexQuantity(range.upperBound),
                            "address": token.contract,
                            "topics": [self.transferTopic, NSNull(), holderTopic] as [Any]
                        ]]
                        return (try? await self.rpcLogs(chain: chain, params: params)) ?? []
                    }
                    group.addTask {
                        let params: [[String: Any]] = [[
                            "fromBlock": EVMHexQuantity.hexQuantity(range.lowerBound),
                            "toBlock": EVMHexQuantity.hexQuantity(range.upperBound),
                            "address": token.contract,
                            "topics": [self.transferTopic, holderTopic] as [Any]
                        ]]
                        return (try? await self.rpcLogs(chain: chain, params: params)) ?? []
                    }
                }
            }

            var rows: [EVMRPCLog] = []
            for await chunk in group {
                rows.append(contentsOf: chunk)
            }
            return rows
        }
    }

    private func rpcBlockTimestamps(chain: SupportedChain, blocks: Set<Int64>) async -> [Int64: Date] {
        await withTaskGroup(of: (Int64, Date)?.self) { group in
            for block in blocks {
                group.addTask {
                    guard let timestamp = try? await self.rpcBlockTimestamp(chain: chain, block: block) else { return nil }
                    return (block, timestamp)
                }
            }

            var rows: [Int64: Date] = [:]
            for await item in group {
                if let item {
                    rows[item.0] = item.1
                }
            }
            return rows
        }
    }

    private func rpcBlockTimestamp(chain: SupportedChain, block: Int64) async throws -> Date {
        let block = try await rpcBlock(
            chain: chain,
            method: "eth_getBlockByNumber",
            params: [EVMHexQuantity.hexQuantity(block), false]
        )
        let seconds = try EVMHexQuantity.int64(from: block.timestamp)
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func rpcString(chain: SupportedChain, method: String, params: [Any]) async throws -> String {
        let data = try await rpcPost(chain: chain, method: method, params: params)
        let envelope = try JSONDecoder().decode(EVMJSONRPCStringEnvelope.self, from: data)
        if let error = envelope.error {
            throw EVMHistoryError.rpc(code: error.code, message: error.message)
        }
        guard let result = envelope.result else { throw EVMHistoryError.missingResult(method) }
        return result
    }

    private func rpcLogs(chain: SupportedChain, params: [Any]) async throws -> [EVMRPCLog] {
        let data = try await rpcPost(chain: chain, method: "eth_getLogs", params: params)
        let envelope = try JSONDecoder().decode(EVMJSONRPCLogsEnvelope.self, from: data)
        if let error = envelope.error {
            throw EVMHistoryError.rpc(code: error.code, message: error.message)
        }
        guard let result = envelope.result else { throw EVMHistoryError.missingResult("eth_getLogs") }
        return result
    }

    private func rpcBlock(chain: SupportedChain, method: String, params: [Any]) async throws -> EVMRPCBlock {
        let data = try await rpcPost(chain: chain, method: method, params: params)
        let envelope = try JSONDecoder().decode(EVMJSONRPCBlockEnvelope.self, from: data)
        if let error = envelope.error {
            throw EVMHistoryError.rpc(code: error.code, message: error.message)
        }
        guard let result = envelope.result else { throw EVMHistoryError.missingResult(method) }
        return result
    }

    private func rpcPost(chain: SupportedChain, method: String, params: [Any]) async throws -> Data {
        requestID += 1
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params
        ])

        var lastError: Error?
        for endpoint in RPCRegistry.endpoints(for: chain) where endpoint.kind == .jsonRPC {
            do {
                var request = URLRequest(url: endpoint.url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
                request.httpBody = body

                let (data, response) = try await session.apertureData(
                    for: request,
                    family: "histories",
                    operation: method,
                    metadata: [
                        "chain": chain.rawValue,
                        "endpoint": endpoint.id,
                        "source": "EVMTransactionHistoryClient"
                    ]
                )
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw EVMHistoryError.httpStatus(http.statusCode)
                }
                return data
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? EVMHistoryError.missingResult(method)
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.apertureData(
            for: request,
            family: "histories",
            operation: "\(url.host ?? "api") \(url.path)",
            metadata: ["source": "EVMTransactionHistoryClient"]
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EVMHistoryError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func etherscanURL(
        baseURL: URL,
        chainID: Int?,
        apiKey: String?,
        action: String,
        address: String
    ) throws -> URL {
        var query = [
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "offset", value: "75"),
            URLQueryItem(name: "sort", value: "desc")
        ]
        if let chainID {
            query.append(URLQueryItem(name: "chainid", value: String(chainID)))
        }
        if let apiKey, !apiKey.isEmpty {
            query.append(URLQueryItem(name: "apikey", value: apiKey))
        }
        return try Self.url(base: baseURL, path: nil, query: query)
    }

    private func explorerProviders(for chain: SupportedChain) -> [ExplorerProvider] {
        var providers: [ExplorerProvider] = []
        if Secrets.hasEtherscanKey, let chainID = Self.chainID(for: chain) {
            providers.append(.etherscanV2(chainID: chainID))
        }
        if let blockscout = Self.blockscoutURL(for: chain) {
            providers.append(.blockscout(baseURL: blockscout))
        }
        if let routescanID = Self.routescanChainID(for: chain) {
            providers.append(.routescan(chainID: routescanID))
        }
        if chain == .avalanche {
            providers.append(.snowtrace)
        }
        return providers
    }

    private func finalize(_ events: [EVMHistoryEvent]) -> [EVMHistoryEvent] {
        var seen = Set<String>()
        var rows: [EVMHistoryEvent] = []
        rows.reserveCapacity(events.count)
        for event in events.sorted(by: { $0.occurredAt > $1.occurredAt }) {
            let key = [
                event.txHash.lowercased(),
                event.tokenContract?.lowercased() ?? "native",
                event.direction.rawValue,
                event.amount
            ].joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            rows.append(event)
            if rows.count >= 100 { break }
        }
        return rows
    }

    private func blockRanges(from lower: Int64, through upper: Int64, chunkSize: Int64) -> [ClosedRange<Int64>] {
        guard lower <= upper else { return [] }
        var ranges: [ClosedRange<Int64>] = []
        var start = lower
        while start <= upper {
            let end = min(upper, start + chunkSize - 1)
            ranges.append(start...end)
            start = end + 1
        }
        return ranges
    }
}

private extension EVMTransactionHistoryClient {
    enum ExplorerProvider: Sendable {
        case etherscanV2(chainID: Int)
        case blockscout(baseURL: URL)
        case routescan(chainID: Int)
        case snowtrace
    }

    static let etherscanV2URL = URL(string: "https://api.etherscan.io/v2/api")!
    static let snowtraceURL = URL(string: "https://api.snowtrace.io/api")!

    static func routescanURL(chainID: Int) -> URL {
        URL(string: "https://api.routescan.io/v2/network/mainnet/evm/\(chainID)/etherscan/api")!
    }

    static func chainID(for chain: SupportedChain) -> Int? {
        switch chain {
        case .ethereum: return 1
        case .optimism: return 10
        case .bnbChain: return 56
        case .polygon: return 137
        case .opBNB: return 204
        case .zkSync: return 324
        case .celo: return 42_220
        case .arbitrum: return 42_161
        case .base: return 8_453
        case .avalanche: return 43_114
        case .scroll: return 534_352
        default: return nil
        }
    }

    static func routescanChainID(for chain: SupportedChain) -> Int? {
        switch chain {
        case .ethereum: return 1
        case .avalanche: return 43_114
        default: return nil
        }
    }

    static func blockscoutURL(for chain: SupportedChain) -> URL? {
        switch chain {
        case .ethereum: return URL(string: "https://eth.blockscout.com")
        case .arbitrum: return URL(string: "https://arbitrum.blockscout.com")
        case .base: return URL(string: "https://base.blockscout.com")
        case .optimism: return URL(string: "https://optimism.blockscout.com")
        case .scroll: return URL(string: "https://blockscout.scroll.io")
        case .zkSync: return URL(string: "https://zksync.blockscout.com")
        case .polygon: return URL(string: "https://polygon.blockscout.com")
        case .celo: return URL(string: "https://celo.blockscout.com")
        default: return nil
        }
    }

    static func url(base: URL, path: String?, query: [URLQueryItem]) throws -> URL {
        let url = path.map { base.appendingPathComponent($0) } ?? base
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EVMHistoryError.invalidURL(url.absoluteString)
        }
        components.queryItems = query
        guard let resolved = components.url else {
            throw EVMHistoryError.invalidURL(url.absoluteString)
        }
        return resolved
    }

    static func tokenMap(_ tokens: [EVMTokenRegistry.Entry]) -> [String: EVMTokenRegistry.Entry] {
        Dictionary(uniqueKeysWithValues: tokens.map { (normalizedAddress($0.contract), $0) })
    }

    static func normalizedAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixed = trimmed.lowercased().hasPrefix("0x") ? trimmed : "0x\(trimmed)"
        return prefixed.lowercased()
    }

    static func indexedAddressTopic(_ address: String) -> String {
        let body = normalizedAddress(address).dropFirst(2)
        return "0x" + String(repeating: "0", count: 24) + body
    }

    static func address(fromTopic topic: String) -> String? {
        let body = topic.hasPrefix("0x") ? String(topic.dropFirst(2)) : topic
        guard body.count >= 40 else { return nil }
        return "0x" + String(body.suffix(40)).lowercased()
    }

    static func direction(
        from: String?,
        to: String?,
        holder: String
    ) -> (TransactionDirection, String)? {
        let lowerHolder = normalizedAddress(holder)
        let lowerFrom = from.map(normalizedAddress)
        let lowerTo = to.map(normalizedAddress)

        if lowerFrom == lowerHolder, lowerTo == lowerHolder {
            return (.internal, "")
        }
        if lowerFrom == lowerHolder {
            return (.outgoing, lowerTo ?? "")
        }
        if lowerTo == lowerHolder {
            return (.incoming, lowerFrom ?? "")
        }
        return nil
    }

    static func status(blockscoutResult: String?, blockscoutStatus: String?) -> TransactionStatus {
        let result = (blockscoutResult ?? blockscoutStatus ?? "").lowercased()
        if result.contains("fail") || result.contains("error") || result.contains("revert") { return .failed }
        return .confirmed
    }

    static func status(isError: String?, receiptStatus: String?) -> TransactionStatus {
        if isError == "1" || receiptStatus == "0" { return .failed }
        return .confirmed
    }

    static func decodeBlockscoutNative(
        _ tx: BlockscoutTransaction,
        chain: SupportedChain,
        holder: String
    ) -> EVMHistoryEvent? {
        guard EVMHexQuantity.isPositiveDecimalString(tx.value ?? "0"),
              let direction = direction(from: tx.from?.hash, to: tx.to?.hash, holder: holder),
              let amount = EVMHexQuantity.displayAmount(rawBalance: tx.value ?? "0", decimals: chain.nativeDecimals) else {
            return nil
        }

        return EVMHistoryEvent(
            txHash: tx.hash,
            direction: direction.0,
            amount: amount,
            tokenSymbol: chain.ticker,
            tokenContract: nil,
            blockNumber: tx.blockNumber,
            occurredAt: DateParser.parse(tx.timestamp) ?? Date(),
            status: status(blockscoutResult: tx.result, blockscoutStatus: tx.status),
            counterparty: direction.1,
            fee: displayFee(raw: tx.fee?.value, decimals: chain.nativeDecimals)
        )
    }

    static func decodeBlockscoutToken(
        _ transfer: BlockscoutTokenTransfer,
        holder: String,
        supportedTokens: [String: EVMTokenRegistry.Entry]
    ) -> EVMHistoryEvent? {
        let contract = transfer.token?.addressHash
        guard let contract,
              let token = supportedTokens[normalizedAddress(contract)],
              let raw = transfer.total?.value,
              EVMHexQuantity.isPositiveDecimalString(raw),
              let direction = direction(from: transfer.from?.hash, to: transfer.to?.hash, holder: holder),
              let amount = EVMHexQuantity.displayAmount(rawBalance: raw, decimals: token.decimals) else {
            return nil
        }

        return EVMHistoryEvent(
            txHash: transfer.transactionHash,
            direction: direction.0,
            amount: amount,
            tokenSymbol: token.symbol,
            tokenContract: token.contract.lowercased(),
            blockNumber: transfer.blockNumber,
            occurredAt: DateParser.parse(transfer.timestamp) ?? Date(),
            status: .confirmed,
            counterparty: direction.1,
            fee: nil
        )
    }

    static func decodeEtherscanNative(
        _ tx: EtherscanTransaction,
        chain: SupportedChain,
        holder: String
    ) -> EVMHistoryEvent? {
        guard EVMHexQuantity.isPositiveDecimalString(tx.value),
              let direction = direction(from: tx.from, to: tx.to, holder: holder),
              let amount = EVMHexQuantity.displayAmount(rawBalance: tx.value, decimals: chain.nativeDecimals) else {
            return nil
        }

        return EVMHistoryEvent(
            txHash: tx.hash,
            direction: direction.0,
            amount: amount,
            tokenSymbol: chain.ticker,
            tokenContract: nil,
            blockNumber: Int64(tx.blockNumber),
            occurredAt: Date(timeIntervalSince1970: TimeInterval(Int64(tx.timeStamp) ?? 0)),
            status: status(isError: tx.isError, receiptStatus: tx.txReceiptStatus),
            counterparty: direction.1,
            fee: displayGasFee(gasUsed: tx.gasUsed, gasPrice: tx.gasPrice, decimals: chain.nativeDecimals)
        )
    }

    static func decodeEtherscanToken(
        _ transfer: EtherscanTokenTransfer,
        holder: String,
        supportedTokens: [String: EVMTokenRegistry.Entry]
    ) -> EVMHistoryEvent? {
        guard let token = supportedTokens[normalizedAddress(transfer.contractAddress)],
              EVMHexQuantity.isPositiveDecimalString(transfer.value),
              let direction = direction(from: transfer.from, to: transfer.to, holder: holder),
              let amount = EVMHexQuantity.displayAmount(rawBalance: transfer.value, decimals: token.decimals) else {
            return nil
        }

        return EVMHistoryEvent(
            txHash: transfer.hash,
            direction: direction.0,
            amount: amount,
            tokenSymbol: token.symbol,
            tokenContract: token.contract.lowercased(),
            blockNumber: Int64(transfer.blockNumber),
            occurredAt: Date(timeIntervalSince1970: TimeInterval(Int64(transfer.timeStamp) ?? 0)),
            status: status(isError: transfer.isError, receiptStatus: transfer.txReceiptStatus),
            counterparty: direction.1,
            fee: displayGasFee(gasUsed: transfer.gasUsed, gasPrice: transfer.gasPrice, decimals: 18)
        )
    }

    static func decodeRPCLog(
        _ log: EVMRPCLog,
        holder: String,
        supportedTokens: [String: EVMTokenRegistry.Entry],
        timestamps: [Int64: Date]
    ) -> EVMHistoryEvent? {
        guard let token = supportedTokens[normalizedAddress(log.address)],
              log.topics.count >= 3,
              let from = address(fromTopic: log.topics[1]),
              let to = address(fromTopic: log.topics[2]),
              let raw = try? EVMHexQuantity.decimalString(from: log.data),
              EVMHexQuantity.isPositiveDecimalString(raw),
              let direction = direction(from: from, to: to, holder: holder),
              let amount = EVMHexQuantity.displayAmount(rawBalance: raw, decimals: token.decimals) else {
            return nil
        }

        let blockNumber = try? EVMHexQuantity.int64(from: log.blockNumber)
        return EVMHistoryEvent(
            txHash: log.transactionHash,
            direction: direction.0,
            amount: amount,
            tokenSymbol: token.symbol,
            tokenContract: token.contract.lowercased(),
            blockNumber: blockNumber,
            occurredAt: blockNumber.flatMap { timestamps[$0] } ?? Date(),
            status: .confirmed,
            counterparty: direction.1,
            fee: nil
        )
    }

    static func displayFee(raw: String?, decimals: Int) -> String? {
        guard let raw, EVMHexQuantity.isPositiveDecimalString(raw) else { return nil }
        return EVMHexQuantity.displayAmount(rawBalance: raw, decimals: decimals)
    }

    static func displayGasFee(gasUsed: String?, gasPrice: String?, decimals: Int) -> String? {
        guard let gasUsed,
              let gasPrice,
              let used = Decimal(string: gasUsed),
              let price = Decimal(string: gasPrice) else {
            return nil
        }
        let raw = EVMHexQuantity.decimalString(used * price)
        return EVMHexQuantity.displayAmount(rawBalance: raw, decimals: decimals)
    }
}

private struct BlockscoutList<Item: Decodable>: Decodable {
    let items: [Item]
}

private struct BlockscoutTransaction: Decodable {
    let hash: String
    let value: String?
    let result: String?
    let status: String?
    let from: BlockscoutAddress?
    let to: BlockscoutAddress?
    let blockNumber: Int64?
    let timestamp: String?
    let fee: BlockscoutFee?

    enum CodingKeys: String, CodingKey {
        case hash
        case value
        case result
        case status
        case from
        case to
        case blockNumber = "block_number"
        case timestamp
        case fee
    }
}

private struct BlockscoutTokenTransfer: Decodable {
    let transactionHash: String
    let from: BlockscoutAddress?
    let to: BlockscoutAddress?
    let token: BlockscoutToken?
    let total: BlockscoutTokenTotal?
    let blockNumber: Int64?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case transactionHash = "transaction_hash"
        case from
        case to
        case token
        case total
        case blockNumber = "block_number"
        case timestamp
    }
}

private struct BlockscoutAddress: Decodable {
    let hash: String?
}

private struct BlockscoutToken: Decodable {
    let addressHash: String?

    enum CodingKeys: String, CodingKey {
        case addressHash = "address_hash"
    }
}

private struct BlockscoutTokenTotal: Decodable {
    let value: String?
}

private struct BlockscoutFee: Decodable {
    let value: String?

    enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            self.value = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .value) {
            self.value = value
        } else if let value = try? container.decode(Int64.self, forKey: .value) {
            self.value = String(value)
        } else {
            self.value = nil
        }
    }
}

private struct EtherscanEnvelope<Item: Decodable>: Decodable {
    let status: String?
    let message: String?
    let result: [Item]

    var isSuccess: Bool {
        status == "1" || message?.lowercased() == "no transactions found"
    }

    enum CodingKeys: String, CodingKey {
        case status
        case message
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decode(String.self, forKey: .status)
        message = try? container.decode(String.self, forKey: .message)
        result = (try? container.decode([Item].self, forKey: .result)) ?? []
    }
}

private struct EtherscanTransaction: Decodable {
    let blockNumber: String
    let timeStamp: String
    let hash: String
    let from: String?
    let to: String?
    let value: String
    let gasPrice: String?
    let gasUsed: String?
    let isError: String?
    let txReceiptStatus: String?

    enum CodingKeys: String, CodingKey {
        case blockNumber
        case timeStamp
        case hash
        case from
        case to
        case value
        case gasPrice
        case gasUsed
        case isError
        case txReceiptStatus = "txreceipt_status"
    }
}

private struct EtherscanTokenTransfer: Decodable {
    let blockNumber: String
    let timeStamp: String
    let hash: String
    let from: String?
    let to: String?
    let contractAddress: String
    let value: String
    let gasPrice: String?
    let gasUsed: String?
    let isError: String?
    let txReceiptStatus: String?

    enum CodingKeys: String, CodingKey {
        case blockNumber
        case timeStamp
        case hash
        case from
        case to
        case contractAddress
        case value
        case gasPrice
        case gasUsed
        case isError
        case txReceiptStatus = "txreceipt_status"
    }
}

private struct EVMRPCLog: Decodable, Sendable {
    let address: String
    let topics: [String]
    let data: String
    let blockNumber: String
    let transactionHash: String
    let logIndex: String?
}

private struct EVMRPCBlock: Decodable, Sendable {
    let timestamp: String
}

private struct EVMJSONRPCLogsEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
        let message: String
    }

    let result: [EVMRPCLog]?
    let error: ErrorBody?
}

private struct EVMJSONRPCBlockEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
        let message: String
    }

    let result: EVMRPCBlock?
    let error: ErrorBody?
}

private struct EVMJSONRPCStringEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
        let message: String
    }

    let result: String?
    let error: ErrorBody?
}

private enum DateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

private enum EVMHistoryError: Error, CustomStringConvertible {
    case invalidURL(String)
    case httpStatus(Int)
    case providerMessage(String)
    case rpc(code: Int, message: String)
    case missingResult(String)

    var description: String {
        switch self {
        case .invalidURL(let value): return "Invalid EVM history URL: \(value)"
        case .httpStatus(let status): return "EVM history HTTP \(status)"
        case .providerMessage(let message): return message
        case .rpc(let code, let message): return "EVM history JSON-RPC \(code): \(message)"
        case .missingResult(let method): return "EVM history \(method) returned no result"
        }
    }
}
