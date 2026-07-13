import Foundation
import OSLog

actor SuiBalanceHistoryScanner {
    private let client = SuiBalanceHistoryClient()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "sui-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .sui else { return }

        let tokens = SuiTokenRegistry.tokens.sorted { $0.symbol < $1.symbol }
        let symbols = Array(Set(([SupportedChain.sui.ticker] + tokens.map(\.symbol)).map { $0.uppercased() })).sorted()

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let snapshotTask = client.accountSnapshot(address: address.address, supportedTokens: tokens)
        async let historyTask: [SuiHistoryEvent] = includeHistory
            ? safeHistory(address: address.address, supportedTokens: tokens)
            : []

        let snapshot = try await snapshotTask
        let priceMap = await pricesTask
        let events = await historyTask

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.sui.ticker,
            tokenContract: nil,
            decimals: SupportedChain.sui.nativeDecimals,
            rawBalance: snapshot.rawSUI,
            fiatValueCached: fiatValue(
                rawBalance: snapshot.rawSUI,
                decimals: SupportedChain.sui.nativeDecimals,
                symbol: SupportedChain.sui.ticker,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = snapshot.accountExists || EVMHexQuantity.isPositiveDecimalString(snapshot.rawSUI)
        for balance in snapshot.tokenBalances {
            if EVMHexQuantity.isPositiveDecimalString(balance.rawBalance) {
                isUsed = true
            }
            try txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: balance.entry.symbol,
                tokenContract: balance.entry.coinType,
                decimals: balance.entry.decimals,
                rawBalance: balance.rawBalance,
                fiatValueCached: fiatValue(
                    rawBalance: balance.rawBalance,
                    decimals: balance.entry.decimals,
                    symbol: balance.entry.symbol,
                    prices: priceMap
                ),
                fiatCurrencyCode: currencyCode,
                save: false
            )
        }

        if !events.isEmpty {
            isUsed = true
        }
        for event in events.prefix(HistoryScanLimits.perAddress) {
            try txRepo.upsertTransaction(
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

        try txRepo.markScanComplete(addressId: address.id, isUsed: isUsed, save: false)
        try txRepo.flush()

        _ = try ChainStateRepository(database: database).rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: [.sui],
            failedChains: [],
            interim: false
        )
    }

    private func safeHistory(
        address: String,
        supportedTokens: [SuiTokenRegistry.Entry]
    ) async -> [SuiHistoryEvent] {
        do {
            return try await client.recentEvents(address: address, supportedTokens: supportedTokens)
        } catch {
            log.debug("Sui history failed: \(String(describing: error), privacy: .public)")
            return []
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

actor SuiBalanceHistoryClient {
    private static let nativeCoinType = "0x2::sui::SUI"
    private static let endpoints = [
        URL(string: "https://fullnode.mainnet.sui.io")!,
        URL(string: "https://sui-mainnet-endpoint.blockvision.org")!,
    ]

    private let session: URLSession
    private var requestID = 0

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
    }

    func accountSnapshot(
        address: String,
        supportedTokens: [SuiTokenRegistry.Entry]
    ) async throws -> SuiAccountSnapshot {
        let balances = try await allBalances(address: address)
        let byCoinType = Dictionary(uniqueKeysWithValues: balances.map {
            (SuiCoinType.normalized($0.coinType), $0)
        })
        let nativeKey = SuiCoinType.normalized(Self.nativeCoinType)
        let native = byCoinType[nativeKey]?.totalBalance ?? "0"

        let tokenBalances = supportedTokens.sorted { $0.symbol < $1.symbol }.map { token in
            SuiTokenBalanceRead(
                entry: token,
                rawBalance: byCoinType[SuiCoinType.normalized(token.coinType)]?.totalBalance ?? "0"
            )
        }

        return SuiAccountSnapshot(
            rawSUI: native,
            accountExists: !balances.isEmpty,
            tokenBalances: tokenBalances
        )
    }

    func recentEvents(
        address: String,
        supportedTokens: [SuiTokenRegistry.Entry]
    ) async throws -> [SuiHistoryEvent] {
        async let fromTask = transactionBlocks(filterName: "FromAddress", address: address, limit: HistoryScanLimits.perAddress)
        async let toTask = transactionBlocks(filterName: "ToAddress", address: address, limit: HistoryScanLimits.perAddress)
        let pages = try await fromTask + toTask

        let supported = SuiSupportIndex(tokens: supportedTokens)
        let owner = SuiAddress.normalized(address)
        var rows: [SuiHistoryEvent] = []
        rows.reserveCapacity(pages.count)

        for block in pages {
            rows.append(contentsOf: events(from: block, owner: owner, supported: supported))
        }

        var seen = Set<String>()
        return rows
            .sorted { $0.occurredAt > $1.occurredAt }
            .filter { event in
                let key = "\(event.txHash)|\(event.tokenContract ?? "native")|\(event.direction.rawValue)|\(event.amount)"
                return seen.insert(key).inserted
            }
    }

    private func allBalances(address: String) async throws -> [SuiCoinBalance] {
        let data = try await callResultData(
            method: "suix_getAllBalances",
            params: [address]
        )
        return try JSONDecoder().decode([SuiCoinBalance].self, from: data)
    }

    private func transactionBlocks(
        filterName: String,
        address: String,
        limit: Int
    ) async throws -> [SuiTransactionBlock] {
        let query: [String: Any] = [
            "filter": [filterName: address],
            "options": [
                "showEffects": true,
                "showBalanceChanges": true,
                "showInput": true,
            ],
        ]
        let data = try await callResultData(
            method: "suix_queryTransactionBlocks",
            params: [query, NSNull(), limit, true]
        )
        let page = try JSONDecoder().decode(SuiTransactionPage.self, from: data)
        return page.data
    }

    private func events(
        from block: SuiTransactionBlock,
        owner: String,
        supported: SuiSupportIndex
    ) -> [SuiHistoryEvent] {
        var deltas: [String: Decimal] = [:]
        var counterparties: [String: String] = [:]
        for change in block.balanceChanges {
            guard SuiOwner.addressValue(change.owner).map(SuiAddress.normalized) == owner,
                  let amount = Decimal(string: change.amount),
                  amount != 0 else {
                continue
            }
            let coinType = SuiCoinType.normalized(change.coinType)
            deltas[coinType, default: 0] += amount
            if counterparties[coinType] == nil {
                counterparties[coinType] = counterparty(
                    for: coinType,
                    owner: owner,
                    sender: block.transaction?.data.sender,
                    changes: block.balanceChanges
                )
            }
        }

        return deltas.compactMap { coinType, signedAmount in
            guard signedAmount != 0 else { return nil }

            let tokenSymbol: String
            let tokenContract: String?
            let decimals: Int
            if coinType == SuiCoinType.normalized(Self.nativeCoinType) {
                tokenSymbol = SupportedChain.sui.ticker
                tokenContract = nil
                decimals = SupportedChain.sui.nativeDecimals
            } else if let entry = supported.entry(for: coinType) {
                tokenSymbol = entry.symbol
                tokenContract = entry.coinType
                decimals = entry.decimals
            } else {
                return nil
            }

            let direction: TransactionDirection = signedAmount > 0 ? .incoming : .outgoing
            let rawMagnitude = SuiDecimalString.rawString(signedAmount < 0 ? -signedAmount : signedAmount)
            guard let displayAmount = EVMHexQuantity.displayAmount(rawBalance: rawMagnitude, decimals: decimals) else {
                return nil
            }

            return SuiHistoryEvent(
                txHash: block.digest,
                direction: direction,
                amount: displayAmount,
                tokenSymbol: tokenSymbol,
                tokenContract: tokenContract,
                blockNumber: block.checkpointInt64,
                occurredAt: block.date,
                status: block.effects?.status.status == "failure" ? .failed : .confirmed,
                counterparty: counterparties[coinType] ?? "",
                fee: coinType == SuiCoinType.normalized(Self.nativeCoinType) && direction == .outgoing
                    ? block.effects?.gasUsed.netFeeDisplay(decimals: SupportedChain.sui.nativeDecimals)
                    : nil
            )
        }
    }

    private func counterparty(
        for coinType: String,
        owner: String,
        sender: String?,
        changes: [SuiBalanceChange]
    ) -> String {
        let normalizedSender = sender.map(SuiAddress.normalized)
        for change in changes {
            guard SuiCoinType.normalized(change.coinType) == coinType,
                  let address = SuiOwner.addressValue(change.owner).map(SuiAddress.normalized),
                  address != owner else {
                continue
            }
            if normalizedSender == owner, (Decimal(string: change.amount) ?? 0) > 0 {
                return address
            }
            if normalizedSender == address {
                return address
            }
        }
        return normalizedSender == owner ? "" : (sender ?? "")
    }

    private func callResultData(method: String, params: [Any]) async throws -> Data {
        var lastError: Error?
        for endpoint in Self.endpoints {
            do {
                let result = try await call(endpoint: endpoint, method: method, params: params)
                guard JSONSerialization.isValidJSONObject(result),
                      let data = try? JSONSerialization.data(withJSONObject: result) else {
                    throw SuiBalanceHistoryError.malformed("\(method) result is not JSON")
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SuiBalanceHistoryError.providerUnavailable("No Sui endpoint returned \(method)")
    }

    private func call(endpoint: URL, method: String, params: [Any]) async throws -> Any {
        requestID += 1
        let id = requestID
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData

        let (data, response) = try await session.apertureData(
            for: request,
            family: "histories",
            operation: method,
            metadata: ["chain": "sui", "source": "SuiRPCClient"]
        )
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw SuiBalanceHistoryError.httpStatus(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(SuiJSONRPCEnvelope.self, from: data)
        if let error = envelope.error {
            throw SuiBalanceHistoryError.rpc(code: error.code, message: error.message)
        }
        guard let result = envelope.result else {
            throw SuiBalanceHistoryError.malformed("\(method) returned no result")
        }
        return result.value
    }
}

struct SuiAccountSnapshot: Sendable, Equatable {
    let rawSUI: String
    let accountExists: Bool
    let tokenBalances: [SuiTokenBalanceRead]
}

struct SuiTokenBalanceRead: Sendable, Equatable {
    let entry: SuiTokenRegistry.Entry
    let rawBalance: String
}

struct SuiHistoryEvent: Sendable, Equatable {
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

private struct SuiSupportIndex {
    private let byCoinType: [String: SuiTokenRegistry.Entry]

    init(tokens: [SuiTokenRegistry.Entry]) {
        byCoinType = Dictionary(uniqueKeysWithValues: tokens.map { (SuiCoinType.normalized($0.coinType), $0) })
    }

    func entry(for coinType: String) -> SuiTokenRegistry.Entry? {
        byCoinType[SuiCoinType.normalized(coinType)]
    }
}

private struct SuiCoinBalance: Decodable, Sendable {
    let coinType: String
    let totalBalance: String
}

private struct SuiTransactionPage: Decodable {
    let data: [SuiTransactionBlock]
}

private struct SuiTransactionBlock: Decodable, Sendable {
    let digest: String
    let transaction: SuiTransactionEnvelope?
    let effects: SuiEffects?
    let balanceChanges: [SuiBalanceChange]
    let timestampMs: SuiLosslessString?
    let checkpoint: SuiLosslessString?

    var checkpointInt64: Int64? { checkpoint?.int64Value }

    var date: Date {
        guard let timestamp = timestampMs?.int64Value else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
    }

    enum CodingKeys: String, CodingKey {
        case digest
        case transaction
        case effects
        case balanceChanges
        case timestampMs
        case checkpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        digest = try container.decode(String.self, forKey: .digest)
        transaction = try container.decodeIfPresent(SuiTransactionEnvelope.self, forKey: .transaction)
        effects = try container.decodeIfPresent(SuiEffects.self, forKey: .effects)
        balanceChanges = try container.decodeIfPresent([SuiBalanceChange].self, forKey: .balanceChanges) ?? []
        timestampMs = try container.decodeIfPresent(SuiLosslessString.self, forKey: .timestampMs)
        checkpoint = try container.decodeIfPresent(SuiLosslessString.self, forKey: .checkpoint)
    }
}

private struct SuiTransactionEnvelope: Decodable, Sendable {
    let data: SuiTransactionData
}

private struct SuiTransactionData: Decodable, Sendable {
    let sender: String?
}

private struct SuiEffects: Decodable, Sendable {
    let status: SuiEffectsStatus
    let gasUsed: SuiGasUsed
}

private struct SuiEffectsStatus: Decodable, Sendable {
    let status: String
}

private struct SuiGasUsed: Decodable, Sendable {
    let computationCost: String
    let storageCost: String
    let storageRebate: String
    let nonRefundableStorageFee: String?

    func netFeeDisplay(decimals: Int) -> String? {
        let computation = Decimal(string: computationCost) ?? 0
        let storage = Decimal(string: storageCost) ?? 0
        let rebate = Decimal(string: storageRebate) ?? 0
        let nonRefundable = nonRefundableStorageFee.flatMap { Decimal(string: $0) } ?? 0
        let fee = max(0, computation + storage + nonRefundable - rebate)
        return EVMHexQuantity.displayAmount(
            rawBalance: SuiDecimalString.rawString(fee),
            decimals: decimals
        )
    }
}

private struct SuiBalanceChange: Decodable, Sendable {
    let owner: SuiOwner
    let coinType: String
    let amount: String
}

private enum SuiOwner: Decodable, Sendable, Equatable {
    case address(String)
    case object(String)
    case shared
    case immutable
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            switch string {
            case "Shared": self = .shared
            case "Immutable": self = .immutable
            default: self = .unknown
            }
            return
        }
        if let object = try? container.decode([String: String].self) {
            if let address = object["AddressOwner"] {
                self = .address(address)
            } else if let objectId = object["ObjectOwner"] {
                self = .object(objectId)
            } else {
                self = .unknown
            }
            return
        }
        self = .unknown
    }

    static func addressValue(_ owner: SuiOwner) -> String? {
        if case .address(let value) = owner {
            return value
        }
        return nil
    }
}

private enum SuiCoinType {
    static func normalized(_ coinType: String) -> String {
        let parts = coinType.split(separator: "::", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return coinType.lowercased() }
        let address = SuiAddress.normalized(String(parts[0]))
        return ([address] + parts.dropFirst().map { String($0).lowercased() }).joined(separator: "::")
    }
}

private enum SuiAddress {
    static func normalized(_ value: String) -> String {
        var lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("0x") else { return lower }
        lower.removeFirst(2)
        while lower.count > 1 && lower.first == "0" {
            lower.removeFirst()
        }
        return "0x" + lower
    }
}

private enum SuiDecimalString {
    static func rawString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        ).stringValue
    }
}

private struct SuiJSONRPCEnvelope: Decodable {
    let result: SuiJSONValue?
    let error: SuiJSONRPCError?
}

private struct SuiJSONRPCError: Decodable {
    let code: Int
    let message: String
}

private enum SuiJSONValue: Decodable {
    case object([String: SuiJSONValue])
    case array([SuiJSONValue])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode([SuiJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SuiJSONValue].self))
        }
    }

    var value: Any {
        switch self {
        case .object(let object):
            return object.mapValues(\.value)
        case .array(let array):
            return array.map(\.value)
        case .string(let string):
            return string
        case .number(let number):
            return NSDecimalNumber(decimal: number)
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        }
    }
}

private struct SuiLosslessString: Decodable, Sendable {
    let value: String

    var int64Value: Int64? { Int64(value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(Int64.self) {
            self.value = String(value)
        } else if let value = try? container.decode(UInt64.self) {
            self.value = String(value)
        } else {
            self.value = "0"
        }
    }
}

private enum SuiBalanceHistoryError: Error, CustomStringConvertible {
    case httpStatus(Int)
    case rpc(code: Int, message: String)
    case malformed(String)
    case providerUnavailable(String)

    var description: String {
        switch self {
        case .httpStatus(let status):
            return "Sui provider returned HTTP \(status)"
        case .rpc(let code, let message):
            return "Sui JSON-RPC \(code): \(message)"
        case .malformed(let reason):
            return "Malformed Sui response: \(reason)"
        case .providerUnavailable(let reason):
            return "Sui provider unavailable: \(reason)"
        }
    }
}
