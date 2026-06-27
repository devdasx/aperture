import Foundation
import OSLog
import SwiftData

actor AptosBalanceHistoryScanner {
    private let fullnode = AptosFullnodeBalanceClient()
    private let indexer = AptosIndexerClient()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "aptos-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        modelContainer: ModelContainer
    ) async throws {
        guard address.chain == .aptos else { return }

        let tokens = AptosTokenRegistry.tokens.sorted { $0.symbol < $1.symbol }
        let symbols = Array(Set(([SupportedChain.aptos.ticker] + tokens.map(\.symbol)).map { $0.uppercased() })).sorted()

        async let pricesTask = TokenPricingEngine.shared.unitPrices(
            symbols: symbols,
            currencyCode: currencyCode
        )
        async let nativeTask = fullnode.nativeBalance(address: address.address)
        async let tokenTask = tokenBalances(owner: address.address, tokens: tokens)
        async let historyTask = safeHistory(owner: address.address)

        let native = try await nativeTask
        let tokenBalances = await tokenTask
        let priceMap = await pricesTask
        let events = await historyTask

        let txRepo = TransactionRepository(modelContainer: modelContainer)
        try await txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.aptos.ticker,
            tokenContract: nil,
            decimals: SupportedChain.aptos.nativeDecimals,
            rawBalance: native.rawBalance,
            fiatValueCached: fiatValue(
                rawBalance: native.rawBalance,
                decimals: SupportedChain.aptos.nativeDecimals,
                symbol: SupportedChain.aptos.ticker,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = native.accountExists || EVMHexQuantity.isPositiveDecimalString(native.rawBalance)
        for balance in tokenBalances {
            if EVMHexQuantity.isPositiveDecimalString(balance.rawBalance) {
                isUsed = true
            }
            try await txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: balance.token.symbol,
                tokenContract: balance.token.contract,
                decimals: balance.token.decimals,
                rawBalance: balance.rawBalance,
                fiatValueCached: fiatValue(
                    rawBalance: balance.rawBalance,
                    decimals: balance.token.decimals,
                    symbol: balance.token.symbol,
                    prices: priceMap
                ),
                fiatCurrencyCode: currencyCode,
                save: false
            )
        }

        if !events.isEmpty {
            isUsed = true
        }
        for event in events.prefix(50) {
            try await txRepo.upsertTransaction(
                addressId: address.id,
                txHash: event.txHash,
                direction: event.direction,
                amountRaw: event.amount,
                tokenSymbol: event.tokenSymbol,
                tokenContract: event.tokenContract,
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

        _ = try await ChainStateRepository(modelContainer: modelContainer).rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: [.aptos],
            failedChains: [],
            interim: false
        )
    }

    private func tokenBalances(
        owner: String,
        tokens: [AptosTokenRegistry.Entry]
    ) async -> [AptosTokenRead] {
        let fullnode = self.fullnode
        return await withTaskGroup(of: AptosTokenRead.self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        return try await fullnode.tokenBalance(owner: owner, token: token)
                    } catch {
                        return AptosTokenRead(token: token, rawBalance: "0")
                    }
                }
            }

            var rows: [AptosTokenRead] = []
            rows.reserveCapacity(tokens.count)
            for await row in group {
                rows.append(row)
            }
            return rows.sorted { $0.token.symbol < $1.token.symbol }
        }
    }

    private func safeHistory(owner: String) async -> [AptosHistoryEvent] {
        do {
            let activities = try await indexer.activities(owner: owner, limit: 60)
            return await historyEvents(owner: owner, activities: activities)
        } catch {
            log.debug("Aptos history failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func historyEvents(
        owner: String,
        activities: [AptosIndexerActivity]
    ) async -> [AptosHistoryEvent] {
        let supportedTokens = Dictionary(
            uniqueKeysWithValues: AptosTokenRegistry.tokens.map {
                (AptosAssetType.normalizedAddress($0.contract), $0)
            }
        )
        let filtered = activities.compactMap { activity -> AptosActivityLeg? in
            let assetType = AptosAssetType.normalizedAddress(activity.assetType)
            if AptosAssetType.isNativeAPT(assetType) {
                return AptosActivityLeg(
                    activity: activity,
                    tokenSymbol: SupportedChain.aptos.ticker,
                    tokenContract: nil,
                    decimals: SupportedChain.aptos.nativeDecimals
                )
            }
            guard let token = supportedTokens[assetType] else { return nil }
            return AptosActivityLeg(
                activity: activity,
                tokenSymbol: token.symbol,
                tokenContract: token.contract,
                decimals: token.decimals
            )
        }

        let metadataByVersion = await transactionMetadata(
            versions: filtered.map { $0.activity.transactionVersion }
        )

        var rows: [AptosHistoryEvent] = []
        rows.reserveCapacity(filtered.count)
        for leg in filtered {
            guard let direction = AptosAssetType.direction(from: leg.activity.type),
                  let displayAmount = EVMHexQuantity.displayAmount(
                    rawBalance: leg.activity.amount,
                    decimals: leg.decimals
                  ) else {
                continue
            }
            let metadata = metadataByVersion[leg.activity.transactionVersion]
            rows.append(AptosHistoryEvent(
                txHash: metadata?.hash ?? "aptos-\(leg.activity.transactionVersion)-\(leg.activity.eventIndex)",
                direction: direction,
                amount: displayAmount,
                tokenSymbol: leg.tokenSymbol,
                tokenContract: leg.tokenContract,
                blockNumber: leg.activity.blockHeight,
                occurredAt: AptosDateParser.date(fromIndexerTimestamp: leg.activity.transactionTimestamp),
                status: metadata?.success == false ? .failed : .confirmed,
                counterparty: "",
                fee: metadata?.fee
            ))
        }

        var seen = Set<String>()
        let deduped = rows.filter { row in
            let key = "\(row.txHash)|\(row.tokenContract ?? "native")|\(row.direction.rawValue)|\(row.amount)"
            return seen.insert(key).inserted
        }
        return deduped.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func transactionMetadata(versions: [Int64]) async -> [Int64: AptosTransactionMetadata] {
        let unique = Array(Set(versions)).sorted(by: >).prefix(50)
        let fullnode = self.fullnode
        return await withTaskGroup(of: (Int64, AptosTransactionMetadata?).self) { group in
            for version in unique {
                group.addTask {
                    let metadata = try? await fullnode.transactionMetadata(version: version)
                    return (version, metadata)
                }
            }

            var rows: [Int64: AptosTransactionMetadata] = [:]
            for await (version, metadata) in group {
                rows[version] = metadata
            }
            return rows
        }
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
}

private actor AptosFullnodeBalanceClient {
    private let rpc = RPCClient.shared

    func nativeBalance(address: String) async throws -> AptosNativeRead {
        do {
            let raw = try await viewString(
                function: "0x1::coin::balance",
                typeArguments: ["0x1::aptos_coin::AptosCoin"],
                arguments: [address]
            )
            return AptosNativeRead(rawBalance: raw, accountExists: true)
        } catch {
            if AptosErrorClassifier.isAccountNotFound(error) {
                return AptosNativeRead(rawBalance: "0", accountExists: false)
            }
            if (try? await accountExists(address: address)) == false {
                return AptosNativeRead(rawBalance: "0", accountExists: false)
            }
            throw error
        }
    }

    func tokenBalance(
        owner: String,
        token: AptosTokenRegistry.Entry
    ) async throws -> AptosTokenRead {
        let raw = try await viewString(
            function: "0x1::primary_fungible_store::balance",
            typeArguments: ["0x1::fungible_asset::Metadata"],
            arguments: [owner, token.contract]
        )
        return AptosTokenRead(token: token, rawBalance: raw)
    }

    func transactionMetadata(version: Int64) async throws -> AptosTransactionMetadata {
        let data = try await rpc.callREST(chain: .aptos, path: "transactions/by_version/\(version)")
        let response = try JSONDecoder().decode(AptosFullnodeTransactionResponse.self, from: data)
        return AptosTransactionMetadata(
            hash: response.hash,
            success: response.success,
            fee: response.fee
        )
    }

    private func viewString(
        function: String,
        typeArguments: [String],
        arguments: [String]
    ) async throws -> String {
        let body: [String: Sendable] = [
            "function": function,
            "type_arguments": typeArguments,
            "arguments": arguments
        ]
        let data = try await rpc.callRESTPost(chain: .aptos, path: "view", body: body)
        let values = try JSONDecoder().decode([AptosNumericString].self, from: data)
        return values.first?.value ?? "0"
    }

    private func accountExists(address: String) async throws -> Bool {
        do {
            _ = try await rpc.callREST(chain: .aptos, path: "accounts/\(address)")
            return true
        } catch let rpcError {
            if case .invalidResponse(let message) = rpcError,
               message.contains("HTTP 404") {
                return false
            }
            throw rpcError
        }
    }
}

private actor AptosIndexerClient {
    private let endpoints = [
        URL(string: "https://api.mainnet.aptoslabs.com/v1/graphql")!,
        URL(string: "https://indexer.mainnet.aptoslabs.com/v1/graphql")!,
    ]
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 18
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
    }

    func activities(owner: String, limit: Int) async throws -> [AptosIndexerActivity] {
        let query = """
        query Activities($owner: String!, $limit: Int!) {
          fungible_asset_activities(
            where: {owner_address: {_eq: $owner}, is_transaction_success: {_eq: true}}
            order_by: [{transaction_version: desc}, {event_index: desc}]
            limit: $limit
          ) {
            transaction_version
            event_index
            amount
            asset_type
            type
            is_transaction_success
            is_gas_fee
            block_height
            transaction_timestamp
            metadata {
              asset_type
              name
              symbol
              decimals
            }
          }
        }
        """
        let body: [String: Any] = [
            "query": query,
            "variables": [
                "owner": owner,
                "limit": limit
            ]
        ]
        let data = try await post(body: body)
        let response = try JSONDecoder().decode(AptosGraphQLResponse<AptosActivitiesPayload>.self, from: data)
        if let error = response.errors?.first {
            throw AptosBalanceHistoryError.indexer(error.message)
        }
        return response.data?.fungibleAssetActivities ?? []
    }

    private func post(body: [String: Any]) async throws -> Data {
        var lastError: Error?
        for endpoint in endpoints {
            do {
                let bodyData = try JSONSerialization.data(withJSONObject: body)
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpBody = bodyData

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw AptosBalanceHistoryError.indexer("missing HTTP response")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw AptosBalanceHistoryError.indexer("HTTP \(http.statusCode)")
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AptosBalanceHistoryError.indexer("all indexer endpoints failed")
    }
}

private struct AptosNativeRead: Sendable {
    let rawBalance: String
    let accountExists: Bool
}

private struct AptosTokenRead: Sendable {
    let token: AptosTokenRegistry.Entry
    let rawBalance: String
}

private struct AptosActivityLeg: Sendable {
    let activity: AptosIndexerActivity
    let tokenSymbol: String
    let tokenContract: String?
    let decimals: Int
}

private struct AptosHistoryEvent: Sendable {
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

private struct AptosTransactionMetadata: Sendable {
    let hash: String
    let success: Bool
    let fee: String?
}

private struct AptosFullnodeTransactionResponse: Decodable {
    let hash: String
    let success: Bool
    let gasUsed: AptosNumericString?
    let gasUnitPrice: AptosNumericString?

    enum CodingKeys: String, CodingKey {
        case hash
        case success
        case gasUsed = "gas_used"
        case gasUnitPrice = "gas_unit_price"
    }

    var fee: String? {
        guard let gasUsed = gasUsed?.value,
              let gasUnitPrice = gasUnitPrice?.value,
              let raw = AptosDecimal.multiply(gasUsed, gasUnitPrice) else {
            return nil
        }
        return EVMHexQuantity.displayAmount(
            rawBalance: raw,
            decimals: SupportedChain.aptos.nativeDecimals
        )
    }
}

private struct AptosGraphQLResponse<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [AptosGraphQLError]?
}

private struct AptosGraphQLError: Decodable {
    let message: String
}

private struct AptosActivitiesPayload: Decodable {
    let fungibleAssetActivities: [AptosIndexerActivity]

    enum CodingKeys: String, CodingKey {
        case fungibleAssetActivities = "fungible_asset_activities"
    }
}

private struct AptosIndexerActivity: Decodable, Sendable {
    let transactionVersion: Int64
    let eventIndex: Int
    let amount: String
    let assetType: String
    let type: String
    let blockHeight: Int64?
    let transactionTimestamp: String

    enum CodingKeys: String, CodingKey {
        case transactionVersion = "transaction_version"
        case eventIndex = "event_index"
        case amount
        case assetType = "asset_type"
        case type
        case blockHeight = "block_height"
        case transactionTimestamp = "transaction_timestamp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionVersion = try container.decode(AptosNumericString.self, forKey: .transactionVersion).int64Value
        eventIndex = try container.decode(AptosNumericString.self, forKey: .eventIndex).intValue
        amount = try container.decode(AptosNumericString.self, forKey: .amount).value
        assetType = try container.decode(String.self, forKey: .assetType)
        type = try container.decode(String.self, forKey: .type)
        blockHeight = try container.decodeIfPresent(AptosNumericString.self, forKey: .blockHeight)?.int64Value
        transactionTimestamp = try container.decode(String.self, forKey: .transactionTimestamp)
    }
}

private struct AptosNumericString: Decodable, Sendable {
    let value: String

    var int64Value: Int64 {
        Int64(value) ?? 0
    }

    var intValue: Int {
        Int(value) ?? 0
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(UInt64.self) {
            self.value = String(value)
        } else if let value = try? container.decode(Int64.self) {
            self.value = String(value)
        } else if let value = try? container.decode(Decimal.self) {
            self.value = NSDecimalNumber(decimal: value).stringValue
        } else {
            throw AptosBalanceHistoryError.malformed("numeric value")
        }
    }
}

private enum AptosAssetType {
    private static let aptosCoinType = "0x1::aptos_coin::aptoscoin"
    private static let aptosMetadata = normalizedAddress("0xa")

    static func normalizedAddress(_ value: String) -> String {
        let lower = value.lowercased()
        guard lower.hasPrefix("0x") else { return lower }
        if lower.contains("::") { return lower }
        let body = String(lower.dropFirst(2))
        guard body.allSatisfy(\.isHexDigit) else { return lower }
        if body.count >= 64 { return "0x" + body }
        return "0x" + String(repeating: "0", count: 64 - body.count) + body
    }

    static func isNativeAPT(_ assetType: String) -> Bool {
        assetType == aptosMetadata || assetType == aptosCoinType
    }

    static func direction(from type: String) -> TransactionDirection? {
        let normalized = type.lowercased()
        if normalized.hasSuffix("::deposit") || normalized.contains("::deposit<") {
            return .incoming
        }
        if normalized.hasSuffix("::withdraw") || normalized.contains("::withdraw<") {
            return .outgoing
        }
        return nil
    }
}

private enum AptosDateParser {
    static func date(fromIndexerTimestamp raw: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw + "Z") {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw + "Z") ?? Date()
    }
}

private enum AptosDecimal {
    static func multiply(_ lhs: String, _ rhs: String) -> String? {
        guard let left = Decimal(string: lhs), let right = Decimal(string: rhs) else { return nil }
        return NSDecimalNumber(decimal: left * right).stringValue
    }
}

private enum AptosErrorClassifier {
    static func isAccountNotFound(_ error: Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        switch rpc {
        case .invalidResponse(let message), .network(let message), .decodingFailed(let message):
            return message.lowercased().contains("account not found")
        case .rpcError(_, let message):
            return message.lowercased().contains("account not found")
        default:
            return false
        }
    }
}

private enum AptosBalanceHistoryError: Error, CustomStringConvertible {
    case malformed(String)
    case indexer(String)

    var description: String {
        switch self {
        case .malformed(let reason):
            return "Malformed Aptos response: \(reason)"
        case .indexer(let reason):
            return "Aptos indexer failed: \(reason)"
        }
    }
}
