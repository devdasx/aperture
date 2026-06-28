import Foundation
import OSLog
import SwiftData

actor TonBalanceHistoryScanner {
    private let client = TonBalanceHistoryClient()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "ton-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        modelContainer: ModelContainer,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .ton else { return }

        let tokens = TONJettonRegistry.tokens.sorted { $0.symbol < $1.symbol }
        let symbols = Array(Set(([SupportedChain.ton.ticker] + tokens.map(\.symbol)).map { $0.uppercased() })).sorted()

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let accountTask = client.accountSnapshot(address: address.address, supportedTokens: tokens)
        async let historyTask: [TonHistoryEvent] = includeHistory
            ? safeHistory(owner: address.address, tokens: tokens)
            : []

        let account = try await accountTask
        let priceMap = await pricesTask
        let events = await historyTask

        let txRepo = TransactionRepository(modelContainer: modelContainer)
        try await txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.ton.ticker,
            tokenContract: nil,
            decimals: SupportedChain.ton.nativeDecimals,
            rawBalance: account.rawTON,
            fiatValueCached: fiatValue(
                rawBalance: account.rawTON,
                decimals: SupportedChain.ton.nativeDecimals,
                symbol: SupportedChain.ton.ticker,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = account.accountExists || EVMHexQuantity.isPositiveDecimalString(account.rawTON)
        for balance in account.jettonBalances {
            if EVMHexQuantity.isPositiveDecimalString(balance.rawBalance) {
                isUsed = true
            }
            try await txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: balance.entry.symbol,
                tokenContract: balance.entry.masterContract,
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
            onlyChains: [.ton],
            failedChains: [],
            interim: false
        )
    }

    private func safeHistory(
        owner: String,
        tokens: [TONJettonRegistry.Entry]
    ) async -> [TonHistoryEvent] {
        do {
            return try await client.recentEvents(address: owner, supportedTokens: tokens)
        } catch {
            log.debug("TON history failed: \(String(describing: error), privacy: .public)")
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

actor TonBalanceHistoryClient {
    private static let tonAPIBase = URL(string: "https://tonapi.io")!
    private static let tonCenterBase = URL(string: "https://toncenter.com")!

    private let session: URLSession

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

    func accountSnapshot(
        address: String,
        supportedTokens: [TONJettonRegistry.Entry]
    ) async throws -> TonAccountSnapshot {
        async let accountTask = tonAPIAccount(address: address)
        async let jettonsTask = safeTonAPIJettonBalances(address: address, supportedTokens: supportedTokens)

        do {
            let account = try await accountTask
            let jettons = await jettonsTask
            return TonAccountSnapshot(
                rawTON: account.rawBalance,
                accountExists: account.accountExists || EVMHexQuantity.isPositiveDecimalString(account.rawBalance),
                jettonBalances: normalizeJettonBalances(jettons, supportedTokens: supportedTokens)
            )
        } catch {
            let raw = try await tonCenterNativeBalance(address: address)
            return TonAccountSnapshot(
                rawTON: raw,
                accountExists: EVMHexQuantity.isPositiveDecimalString(raw),
                jettonBalances: zeroJettonBalances(supportedTokens)
            )
        }
    }

    func recentEvents(
        address: String,
        supportedTokens: [TONJettonRegistry.Entry]
    ) async throws -> [TonHistoryEvent] {
        do {
            let events = try await tonAPIEvents(address: address, supportedTokens: supportedTokens)
            if !events.isEmpty { return events }
        } catch {
            return try await tonCenterNativeHistory(address: address)
        }
        return try await tonCenterNativeHistory(address: address)
    }

    private func safeTonAPIJettonBalances(
        address: String,
        supportedTokens: [TONJettonRegistry.Entry]
    ) async -> [TonJettonBalanceRead] {
        do {
            return try await tonAPIJettonBalances(address: address, supportedTokens: supportedTokens)
        } catch {
            return zeroJettonBalances(supportedTokens)
        }
    }

    private func tonAPIAccount(address: String) async throws -> TonAPIAccountRead {
        let data = try await get(
            baseURL: Self.tonAPIBase,
            path: "v2/accounts/\(TonURL.pathComponent(address))",
            query: []
        )
        let account = try JSONDecoder().decode(TonAPIAccountResponse.self, from: data)
        return TonAPIAccountRead(
            rawBalance: account.balanceString ?? "0",
            accountExists: account.status == "active" || account.isWallet == true
        )
    }

    private func tonAPIJettonBalances(
        address: String,
        supportedTokens: [TONJettonRegistry.Entry]
    ) async throws -> [TonJettonBalanceRead] {
        let data = try await get(
            baseURL: Self.tonAPIBase,
            path: "v2/accounts/\(TonURL.pathComponent(address))/jettons",
            query: [
                URLQueryItem(name: "currencies", value: "usd")
            ]
        )
        let response = try JSONDecoder().decode(TonAPIJettonBalancesResponse.self, from: data)
        let supported = TonJettonSupportIndex(tokens: supportedTokens)

        var rows: [TonJettonBalanceRead] = []
        for balance in response.balances {
            guard let jettonAddress = balance.jetton.address,
                  let entry = supported.entry(for: jettonAddress) else {
                continue
            }
            rows.append(TonJettonBalanceRead(
                entry: entry,
                rawBalance: balance.balance
            ))
        }
        return rows
    }

    private func tonAPIEvents(
        address: String,
        supportedTokens: [TONJettonRegistry.Entry]
    ) async throws -> [TonHistoryEvent] {
        let data = try await get(
            baseURL: Self.tonAPIBase,
            path: "v2/accounts/\(TonURL.pathComponent(address))/events",
            query: [
                URLQueryItem(name: "limit", value: "60")
            ]
        )
        let response = try JSONDecoder().decode(TonAPIEventsResponse.self, from: data)
        let ownerAliases = TonAddress.aliases(address)
        let supported = TonJettonSupportIndex(tokens: supportedTokens)

        var rows: [TonHistoryEvent] = []
        rows.reserveCapacity(response.events.count)
        for event in response.events {
            for action in event.actions {
                if let tonTransfer = action.tonTransfer,
                   let row = nativeEvent(
                    ownerAliases: ownerAliases,
                    event: event,
                    action: action,
                    transfer: tonTransfer
                   ) {
                    rows.append(row)
                    continue
                }

                if let jettonTransfer = action.jettonTransfer,
                   let row = jettonEvent(
                    ownerAliases: ownerAliases,
                    event: event,
                    action: action,
                    transfer: jettonTransfer,
                    supported: supported
                   ) {
                    rows.append(row)
                }
            }
        }

        return finalize(rows)
    }

    private func tonCenterNativeBalance(address: String) async throws -> String {
        let data = try await get(
            baseURL: Self.tonCenterBase,
            path: "api/v2/getAddressBalance",
            query: [
                URLQueryItem(name: "address", value: address)
            ]
        )
        let response = try JSONDecoder().decode(TonCenterBalanceResponse.self, from: data)
        guard response.ok else { throw TonBalanceHistoryError.providerUnavailable(response.result) }
        return response.result
    }

    private func tonCenterNativeHistory(address: String) async throws -> [TonHistoryEvent] {
        let data = try await get(
            baseURL: Self.tonCenterBase,
            path: "api/v3/transactions",
            query: [
                URLQueryItem(name: "account", value: address),
                URLQueryItem(name: "limit", value: "40")
            ]
        )
        let response = try JSONDecoder().decode(TonCenterTransactionsResponse.self, from: data)
        let ownerAliases = TonAddress.aliases(address)
        var rows: [TonHistoryEvent] = []

        for transaction in response.transactions {
            let fee = transaction.totalFees
            if let inbound = transaction.inMessage,
               EVMHexQuantity.isPositiveDecimalString(inbound.value),
               TonAddress.matches(inbound.destination, aliases: ownerAliases),
               !TonAddress.matches(inbound.source, aliases: ownerAliases),
               let amount = EVMHexQuantity.displayAmount(
                rawBalance: inbound.value,
                decimals: SupportedChain.ton.nativeDecimals
               ) {
                rows.append(TonHistoryEvent(
                    txHash: transaction.hash,
                    direction: .incoming,
                    amount: amount,
                    tokenSymbol: SupportedChain.ton.ticker,
                    tokenContract: nil,
                    blockNumber: transaction.ltInt64,
                    occurredAt: transaction.date,
                    status: transaction.isFailed ? .failed : .confirmed,
                    counterparty: inbound.source ?? "",
                    fee: fee
                ))
            }

            for outbound in transaction.outMessages {
                guard EVMHexQuantity.isPositiveDecimalString(outbound.value),
                      TonAddress.matches(outbound.source, aliases: ownerAliases),
                      !TonAddress.matches(outbound.destination, aliases: ownerAliases),
                      let amount = EVMHexQuantity.displayAmount(
                        rawBalance: outbound.value,
                        decimals: SupportedChain.ton.nativeDecimals
                      ) else {
                    continue
                }
                rows.append(TonHistoryEvent(
                    txHash: transaction.hash,
                    direction: .outgoing,
                    amount: amount,
                    tokenSymbol: SupportedChain.ton.ticker,
                    tokenContract: nil,
                    blockNumber: transaction.ltInt64,
                    occurredAt: transaction.date,
                    status: transaction.isFailed ? .failed : .confirmed,
                    counterparty: outbound.destination ?? "",
                    fee: fee
                ))
            }
        }

        return finalize(rows)
    }

    private func nativeEvent(
        ownerAliases: Set<String>,
        event: TonAPIEvent,
        action: TonAPIAction,
        transfer: TonAPITonTransfer
    ) -> TonHistoryEvent? {
        guard EVMHexQuantity.isPositiveDecimalString(transfer.amount),
              let amount = EVMHexQuantity.displayAmount(
                rawBalance: transfer.amount,
                decimals: SupportedChain.ton.nativeDecimals
              ) else {
            return nil
        }
        guard let direction = direction(sender: transfer.sender.address, recipient: transfer.recipient.address, ownerAliases: ownerAliases) else {
            return nil
        }

        return TonHistoryEvent(
            txHash: action.baseTransactions.first ?? event.eventID,
            direction: direction,
            amount: amount,
            tokenSymbol: SupportedChain.ton.ticker,
            tokenContract: nil,
            blockNumber: event.lt,
            occurredAt: event.date,
            status: status(event: event, action: action),
            counterparty: counterparty(
                direction: direction,
                sender: transfer.sender.address,
                recipient: transfer.recipient.address
            ),
            fee: event.feeRaw
        )
    }

    private func jettonEvent(
        ownerAliases: Set<String>,
        event: TonAPIEvent,
        action: TonAPIAction,
        transfer: TonAPIJettonTransfer,
        supported: TonJettonSupportIndex
    ) -> TonHistoryEvent? {
        guard let jettonAddress = transfer.jetton.address,
              let entry = supported.entry(for: jettonAddress),
              EVMHexQuantity.isPositiveDecimalString(transfer.amount),
              let amount = EVMHexQuantity.displayAmount(rawBalance: transfer.amount, decimals: entry.decimals) else {
            return nil
        }
        guard let direction = direction(sender: transfer.sender?.address, recipient: transfer.recipient?.address, ownerAliases: ownerAliases) else {
            return nil
        }

        return TonHistoryEvent(
            txHash: action.baseTransactions.first ?? event.eventID,
            direction: direction,
            amount: amount,
            tokenSymbol: entry.symbol,
            tokenContract: entry.masterContract,
            blockNumber: event.lt,
            occurredAt: event.date,
            status: status(event: event, action: action),
            counterparty: counterparty(
                direction: direction,
                sender: transfer.sender?.address,
                recipient: transfer.recipient?.address
            ),
            fee: event.feeRaw
        )
    }

    private func direction(
        sender: String?,
        recipient: String?,
        ownerAliases: Set<String>
    ) -> TransactionDirection? {
        let ownsSender = TonAddress.matches(sender, aliases: ownerAliases)
        let ownsRecipient = TonAddress.matches(recipient, aliases: ownerAliases)
        switch (ownsSender, ownsRecipient) {
        case (true, true): return .internal
        case (true, false): return .outgoing
        case (false, true): return .incoming
        case (false, false): return nil
        }
    }

    private func counterparty(
        direction: TransactionDirection,
        sender: String?,
        recipient: String?
    ) -> String {
        switch direction {
        case .incoming:
            return sender ?? ""
        case .outgoing:
            return recipient ?? ""
        case .internal:
            return recipient ?? sender ?? ""
        }
    }

    private func status(event: TonAPIEvent, action: TonAPIAction) -> TransactionStatus {
        if event.inProgress == true { return .pending }
        return action.status == "failed" ? .failed : .confirmed
    }

    private func normalizeJettonBalances(
        _ rows: [TonJettonBalanceRead],
        supportedTokens: [TONJettonRegistry.Entry]
    ) -> [TonJettonBalanceRead] {
        var byMaster: [String: TonJettonBalanceRead] = [:]
        for row in rows {
            byMaster[row.entry.masterContract] = row
        }
        return supportedTokens
            .map { byMaster[$0.masterContract] ?? TonJettonBalanceRead(entry: $0, rawBalance: "0") }
            .sorted { $0.entry.symbol < $1.entry.symbol }
    }

    private func zeroJettonBalances(_ supportedTokens: [TONJettonRegistry.Entry]) -> [TonJettonBalanceRead] {
        supportedTokens
            .map { TonJettonBalanceRead(entry: $0, rawBalance: "0") }
            .sorted { $0.entry.symbol < $1.entry.symbol }
    }

    private func finalize(_ rows: [TonHistoryEvent]) -> [TonHistoryEvent] {
        var seen = Set<String>()
        return rows
            .sorted { $0.occurredAt > $1.occurredAt }
            .filter { row in
                let key = "\(row.txHash)|\(row.tokenContract ?? "native")|\(row.direction.rawValue)|\(row.amount)"
                return seen.insert(key).inserted
            }
    }

    private func get(
        baseURL: URL,
        path: String,
        query: [URLQueryItem]
    ) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw TonBalanceHistoryError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TonBalanceHistoryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TonBalanceHistoryError.httpStatus(http.statusCode)
        }
        return data
    }
}

struct TonAccountSnapshot: Sendable, Equatable {
    let rawTON: String
    let accountExists: Bool
    let jettonBalances: [TonJettonBalanceRead]
}

struct TonJettonBalanceRead: Sendable, Equatable {
    let entry: TONJettonRegistry.Entry
    let rawBalance: String
}

struct TonHistoryEvent: Sendable, Equatable {
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

private struct TonAPIAccountRead: Sendable {
    let rawBalance: String
    let accountExists: Bool
}

private struct TonJettonSupportIndex {
    private let byAlias: [String: TONJettonRegistry.Entry]

    init(tokens: [TONJettonRegistry.Entry]) {
        var rows: [String: TONJettonRegistry.Entry] = [:]
        for token in tokens {
            for alias in TonAddress.aliases(token.masterContract) {
                rows[alias] = token
            }
        }
        self.byAlias = rows
    }

    func entry(for address: String) -> TONJettonRegistry.Entry? {
        for alias in TonAddress.aliases(address) {
            if let entry = byAlias[alias] { return entry }
        }
        return nil
    }
}

private enum TonAddress {
    static func aliases(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var aliases: Set<String> = [trimmed.lowercased()]
        if let raw = rawAddress(fromFriendly: trimmed) {
            aliases.insert(raw.lowercased())
        }
        return aliases
    }

    static func matches(_ value: String?, aliases: Set<String>) -> Bool {
        !TonAddress.aliases(value).isDisjoint(with: aliases)
    }

    private static func rawAddress(fromFriendly address: String) -> String? {
        guard !address.contains(":") else { return address.lowercased() }
        var base64 = address
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64), data.count == 36 else { return nil }
        let bytes = [UInt8](data)
        let workchain = bytes[1] == 0xff ? -1 : Int(Int8(bitPattern: bytes[1]))
        let hash = bytes[2..<34].map { String(format: "%02x", $0) }.joined()
        return "\(workchain):\(hash)"
    }
}

private enum TonURL {
    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private enum TonBalanceHistoryError: Error, CustomStringConvertible {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case providerUnavailable(String)

    var description: String {
        switch self {
        case .invalidURL:
            return "TON request URL could not be built"
        case .invalidResponse:
            return "TON provider returned a non-HTTP response"
        case .httpStatus(let status):
            return "TON provider returned HTTP \(status)"
        case .providerUnavailable(let message):
            return "TON provider unavailable: \(message)"
        }
    }
}

private struct TonAPIAccountResponse: Decodable {
    let balance: TonLosslessString?
    let status: String?
    let isWallet: Bool?

    var balanceString: String? { balance?.value }

    private enum CodingKeys: String, CodingKey {
        case balance
        case status
        case isWallet = "is_wallet"
    }
}

private struct TonAPIJettonBalancesResponse: Decodable {
    let balances: [TonAPIJettonBalance]
}

private struct TonAPIJettonBalance: Decodable {
    let balance: String
    let jetton: TonAPIJettonPreview
}

private struct TonAPIJettonPreview: Decodable {
    let address: String?
    let symbol: String?
    let decimals: Int?
}

private struct TonAPIEventsResponse: Decodable {
    let events: [TonAPIEvent]
}

private struct TonAPIEvent: Decodable {
    let eventID: String
    let timestamp: Int64
    let actions: [TonAPIAction]
    let lt: Int64?
    let inProgress: Bool?
    let extra: Int64?

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
    var feeRaw: String? {
        guard let extra, extra < 0 else { return nil }
        return String(abs(extra))
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case timestamp
        case actions
        case lt
        case inProgress = "in_progress"
        case extra
    }
}

private struct TonAPIAction: Decodable {
    let type: String
    let status: String?
    let tonTransfer: TonAPITonTransfer?
    let jettonTransfer: TonAPIJettonTransfer?
    let baseTransactions: [String]

    private enum CodingKeys: String, CodingKey {
        case type
        case status
        case tonTransfer = "TonTransfer"
        case jettonTransfer = "JettonTransfer"
        case baseTransactions = "base_transactions"
    }
}

private struct TonAPITonTransfer: Decodable {
    let sender: TonAPIAccountAddress
    let recipient: TonAPIAccountAddress
    let amount: String

    private enum CodingKeys: String, CodingKey {
        case sender
        case recipient
        case amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sender = try container.decode(TonAPIAccountAddress.self, forKey: .sender)
        recipient = try container.decode(TonAPIAccountAddress.self, forKey: .recipient)
        amount = try container.decode(TonLosslessString.self, forKey: .amount).value
    }
}

private struct TonAPIJettonTransfer: Decodable {
    let sender: TonAPIAccountAddress?
    let recipient: TonAPIAccountAddress?
    let amount: String
    let jetton: TonAPIJettonPreview

    private enum CodingKeys: String, CodingKey {
        case sender
        case recipient
        case amount
        case jetton
    }
}

private struct TonAPIAccountAddress: Decodable {
    let address: String?
}

private struct TonCenterBalanceResponse: Decodable {
    let ok: Bool
    let result: String
}

private struct TonCenterTransactionsResponse: Decodable {
    let transactions: [TonCenterTransaction]
}

private struct TonCenterTransaction: Decodable {
    let hash: String
    let lt: String?
    let now: Int64?
    let totalFees: String?
    let description: TonCenterTransactionDescription?
    let inMessage: TonCenterMessage?
    let outMessages: [TonCenterMessage]

    var ltInt64: Int64? {
        guard let lt else { return nil }
        return Int64(lt)
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(now ?? 0))
    }

    var isFailed: Bool {
        description?.aborted == true
    }

    private enum CodingKeys: String, CodingKey {
        case hash
        case lt
        case now
        case totalFees = "total_fees"
        case description
        case inMessage = "in_msg"
        case outMessages = "out_msgs"
    }
}

private struct TonCenterTransactionDescription: Decodable {
    let aborted: Bool?
}

private struct TonCenterMessage: Decodable {
    let source: String?
    let destination: String?
    let value: String
}

private struct TonLosslessString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else if let uint = try? container.decode(UInt64.self) {
            value = String(uint)
        } else if let double = try? container.decode(Double.self) {
            value = NSDecimalNumber(value: double).stringValue
        } else {
            value = "0"
        }
    }
}
