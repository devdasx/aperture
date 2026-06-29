import Foundation
import OSLog
import SwiftData

actor NearBalanceHistoryScanner {
    private let rpc = NearRPCBalanceClient()
    private let history = NearBlocksHistoryClient()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "near-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        modelContainer: ModelContainer,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .near else { return }

        let tokens = NearTokenRegistry.tokens
        let symbols = Array(Set((["NEAR"] + tokens.map(\.symbol)).map { $0.uppercased() })).sorted()

        async let priceTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let accountTask = rpc.account(accountId: address.address)
        async let tokenBalancesTask = tokenBalances(accountId: address.address, tokens: tokens)
        async let nativeHistoryTask: [NearHistoryEvent] = includeHistory
            ? safeNativeHistory(accountId: address.address)
            : []
        async let tokenHistoryTask: [NearHistoryEvent] = includeHistory
            ? safeTokenHistory(accountId: address.address, tokens: tokens)
            : []

        let (priceMap, account, tokenBalances, nativeEvents, tokenEvents) = try await (
            priceTask,
            accountTask,
            tokenBalancesTask,
            nativeHistoryTask,
            tokenHistoryTask
        )

        let txRepo = TransactionRepository(modelContainer: modelContainer)
        try await txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.near.ticker,
            tokenContract: nil,
            decimals: SupportedChain.near.nativeDecimals,
            rawBalance: account.amount,
            fiatValueCached: fiatValue(
                rawBalance: account.amount,
                decimals: SupportedChain.near.nativeDecimals,
                symbol: SupportedChain.near.ticker,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = DecimalString.isPositive(account.amount)
        for tokenBalance in tokenBalances {
            if DecimalString.isPositive(tokenBalance.rawBalance) {
                isUsed = true
            }
            try await txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: tokenBalance.symbol,
                tokenContract: tokenBalance.tokenAccount,
                decimals: tokenBalance.decimals,
                rawBalance: tokenBalance.rawBalance,
                fiatValueCached: fiatValue(
                    rawBalance: tokenBalance.rawBalance,
                    decimals: tokenBalance.decimals,
                    symbol: tokenBalance.symbol,
                    prices: priceMap
                ),
                fiatCurrencyCode: currencyCode,
                save: false
            )
        }

        let events = (nativeEvents + tokenEvents)
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(50)
        if !events.isEmpty {
            isUsed = true
        }
        for event in events {
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
            onlyChains: [.near],
            failedChains: [],
            interim: false
        )
    }

    private func tokenBalances(
        accountId: String,
        tokens: [NearTokenRegistry.Entry]
    ) async -> [NearTokenBalance] {
        await withTaskGroup(of: NearTokenBalance?.self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        return try await self.rpc.ftBalance(accountId: accountId, token: token)
                    } catch {
                        await self.logTokenBalanceFailure(symbol: token.symbol, error: error)
                        return nil
                    }
                }
            }

            var rows: [NearTokenBalance] = []
            rows.reserveCapacity(tokens.count)
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows.sorted { $0.symbol < $1.symbol }
        }
    }

    private func safeNativeHistory(accountId: String) async -> [NearHistoryEvent] {
        do {
            return try await history.nativeActivities(accountId: accountId, limit: 25)
        } catch {
            log.debug("NEAR native history failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func safeTokenHistory(
        accountId: String,
        tokens: [NearTokenRegistry.Entry]
    ) async -> [NearHistoryEvent] {
        await withTaskGroup(of: [NearHistoryEvent].self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        return try await self.history.ftEvents(accountId: accountId, token: token, limit: 12)
                    } catch {
                        await self.logTokenHistoryFailure(symbol: token.symbol, error: error)
                        return []
                    }
                }
            }

            var rows: [NearHistoryEvent] = []
            for await chunk in group {
                rows.append(contentsOf: chunk)
            }
            return rows
        }
    }

    private func logTokenBalanceFailure(symbol: String, error: Error) {
        log.debug("NEAR token balance failed for \(symbol, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    private func logTokenHistoryFailure(symbol: String, error: Error) {
        log.debug("NEAR token history failed for \(symbol, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    private func fiatValue(
        rawBalance: String,
        decimals: Int,
        symbol: String,
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) -> Decimal? {
        guard let price = prices[symbol.uppercased()] else { return nil }
        guard let amount = DecimalString.decimalAmount(rawBalance: rawBalance, decimals: decimals) else { return nil }
        return amount * price.amount
    }
}

private actor NearRPCBalanceClient {
    private let endpoints = [
        URL(string: "https://rpc.mainnet.near.org")!,
        URL(string: "https://near.lava.build")!,
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

    func account(accountId: String) async throws -> NearAccountBalance {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "aperture-near-account",
            "method": "query",
            "params": [
                "request_type": "view_account",
                "finality": "final",
                "account_id": accountId
            ]
        ]

        do {
            let data = try await post(body)
            let root = try NearJSON.object(data)
            let result = try NearJSON.requiredObject(root["result"], "result")
            return NearAccountBalance(
                amount: try NearJSON.requiredString(result["amount"], "amount"),
                locked: try NearJSON.requiredString(result["locked"], "locked"),
                storageUsage: NearJSON.int64(result["storage_usage"]) ?? 0,
                blockHeight: NearJSON.int64(result["block_height"]) ?? 0,
                accountExists: true
            )
        } catch let error as NearRPCError where error.isUnknownAccount {
            return .zero(accountExists: false)
        }
    }

    func ftBalance(accountId: String, token: NearTokenRegistry.Entry) async throws -> NearTokenBalance {
        let args = try JSONSerialization.data(withJSONObject: ["account_id": accountId])
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "aperture-near-ft-balance",
            "method": "query",
            "params": [
                "request_type": "call_function",
                "finality": "final",
                "account_id": token.tokenAccount,
                "method_name": "ft_balance_of",
                "args_base64": args.base64EncodedString()
            ]
        ]

        do {
            let data = try await post(body)
            let root = try NearJSON.object(data)
            let result = try NearJSON.requiredObject(root["result"], "result")
            let bytes = try NearJSON.requiredArray(result["result"], "result.result")
            let resultData = Data(bytes.compactMap { NearJSON.int64($0).map(UInt8.init(truncatingIfNeeded:)) })
            let jsonString = String(data: resultData, encoding: .utf8) ?? "0"
            let decoded = (try? JSONDecoder().decode(String.self, from: Data(jsonString.utf8)))
                ?? jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return NearTokenBalance(
                tokenAccount: token.tokenAccount,
                symbol: token.symbol,
                decimals: token.decimals,
                rawBalance: DecimalString.digitsOnly(decoded)
            )
        } catch let error as NearRPCError where error.isUnknownAccount {
            return NearTokenBalance(
                tokenAccount: token.tokenAccount,
                symbol: token.symbol,
                decimals: token.decimals,
                rawBalance: "0"
            )
        }
    }

    private func post(_ body: [String: Any]) async throws -> Data {
        var lastError: Error?
        for endpoint in endpoints {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await session.apertureData(
                    for: request,
                    family: "histories",
                    operation: "NEAR RPC",
                    metadata: [
                        "chain": "near",
                        "source": "NearRPCClient",
                        "endpoint": endpoint.host ?? ""
                    ]
                )
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NearRPCError.http(http.statusCode)
                }
                if let error = try? NearJSON.rpcError(from: data) {
                    throw error
                }
                return data
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NearRPCError.noEndpoint
    }
}

private actor NearBlocksHistoryClient {
    private let baseURL = URL(string: "https://api.nearblocks.io")!
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

    func nativeActivities(accountId: String, limit: Int) async throws -> [NearHistoryEvent] {
        let fetchLimit = max(limit + 1, 2)
        let url = baseURL.appending(path: "v1/account/\(accountId)/activities")
            .appending(queryItems: [
                URLQueryItem(name: "per_page", value: String(fetchLimit)),
            ])
        let data = try await get(url)
        let root = try NearJSON.object(data)
        let parsed = try NearJSON.requiredArray(root["activities"], "activities")
            .compactMap { $0 as? [String: Any] }

        var events: [NearHistoryEvent] = []
        events.reserveCapacity(min(limit, parsed.count))
        for index in parsed.indices {
            guard events.count < limit else { break }
            let item = parsed[index]
            guard let eventIndex = item["event_index"] as? String else { continue }
            guard let nextOlder = parsed.indices.contains(index + 1) ? parsed[index + 1] : nil else {
                continue
            }
            let current = NearJSON.decimal(item["absolute_nonstaked_amount"]) ?? 0
            let previous = NearJSON.decimal(nextOlder["absolute_nonstaked_amount"]) ?? current
            let delta = current - previous
            guard delta != 0 else { continue }

            let direction: TransactionDirection = delta > 0 ? .incoming : .outgoing
            let magnitude = delta < 0 ? -delta : delta
            let txHash = item["transaction_hash"] as? String
            let receipt = item["receipt_id"] as? String
            let identifier = txHash ?? receipt ?? eventIndex
            let displayAmount = DecimalString.displayAmount(
                rawBalance: DecimalString.string(magnitude),
                decimals: SupportedChain.near.nativeDecimals
            )

            events.append(NearHistoryEvent(
                txHash: identifier,
                direction: direction,
                amount: displayAmount,
                tokenSymbol: SupportedChain.near.ticker,
                tokenContract: nil,
                blockNumber: NearJSON.int64(item["block_height"]),
                occurredAt: NearJSON.dateFromNanoseconds(item["block_timestamp"]),
                status: .confirmed,
                counterparty: item["involved_account_id"] as? String ?? "",
                fee: nil
            ))
        }
        return events
    }

    func ftEvents(accountId: String, token: NearTokenRegistry.Entry, limit: Int) async throws -> [NearHistoryEvent] {
        let url = baseURL.appending(path: "v1/account/\(accountId)/ft-txns")
            .appending(queryItems: [
                URLQueryItem(name: "contract", value: token.tokenAccount),
                URLQueryItem(name: "per_page", value: String(limit)),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "order", value: "desc"),
            ])
        let data = try await get(url)
        let root = try NearJSON.object(data)
        let rows = try NearJSON.requiredArray(root["txns"], "txns")
            .compactMap { $0 as? [String: Any] }

        return rows.compactMap { item in
            guard let eventIndex = item["event_index"] as? String,
                  let rawAmount = item["delta_amount"] as? String,
                  rawAmount != "0" else { return nil }

            let signed = Decimal(string: rawAmount) ?? 0
            let direction: TransactionDirection = signed < 0 ? .outgoing : .incoming
            let magnitude = signed < 0 ? -signed : signed
            let ft = item["ft"] as? [String: Any]
            let block = item["block"] as? [String: Any]
            let outcomes = item["outcomes"] as? [String: Any]
            let feeYocto = (item["outcomes_agg"] as? [String: Any])
                .flatMap { NearJSON.decimal($0["transaction_fee"]) }
            let displayFee = direction == .outgoing
                ? feeYocto.map {
                    DecimalString.displayAmount(
                        rawBalance: DecimalString.string($0),
                        decimals: SupportedChain.near.nativeDecimals
                    )
                }
                : nil

            return NearHistoryEvent(
                txHash: item["transaction_hash"] as? String ?? eventIndex,
                direction: direction,
                amount: DecimalString.displayAmount(
                    rawBalance: DecimalString.string(magnitude),
                    decimals: token.decimals
                ),
                tokenSymbol: token.symbol,
                tokenContract: (ft?["contract"] as? String) ?? token.tokenAccount,
                blockNumber: NearJSON.int64(block?["block_height"]),
                occurredAt: NearJSON.dateFromNanoseconds(item["block_timestamp"]),
                status: (outcomes?["status"] as? Bool) == false ? .failed : .confirmed,
                counterparty: item["involved_account_id"] as? String ?? "",
                fee: displayFee
            )
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.apertureData(
            for: request,
            family: "histories",
            operation: "\(url.host ?? "api") \(url.path)",
            metadata: ["chain": "near", "source": "NearBlocksHistoryClient"]
        )
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return Data(#"{"activities":[],"txns":[]}"#.utf8)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NearRPCError.http(http.statusCode)
        }
        return data
    }
}

private struct NearAccountBalance: Sendable {
    let amount: String
    let locked: String
    let storageUsage: Int64
    let blockHeight: Int64
    let accountExists: Bool

    static func zero(accountExists: Bool) -> NearAccountBalance {
        NearAccountBalance(
            amount: "0",
            locked: "0",
            storageUsage: 0,
            blockHeight: 0,
            accountExists: accountExists
        )
    }
}

private struct NearTokenBalance: Sendable {
    let tokenAccount: String
    let symbol: String
    let decimals: Int
    let rawBalance: String
}

private struct NearHistoryEvent: Sendable, Hashable {
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

private enum NearRPCError: Error, CustomStringConvertible {
    case noEndpoint
    case http(Int)
    case rpc(code: Int, message: String)
    case missing(String)
    case malformed(String)

    var isUnknownAccount: Bool {
        switch self {
        case .rpc(_, let message):
            let lower = message.lowercased()
            return lower.contains("does not exist")
                || lower.contains("unknown account")
                || lower.contains("account not found")
        default:
            return false
        }
    }

    var description: String {
        switch self {
        case .noEndpoint:
            return "No NEAR endpoint is available"
        case .http(let status):
            return "NEAR HTTP \(status)"
        case .rpc(let code, let message):
            return "NEAR RPC \(code): \(message)"
        case .missing(let field):
            return "NEAR response missing \(field)"
        case .malformed(let detail):
            return "Malformed NEAR response: \(detail)"
        }
    }
}

private enum NearJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NearRPCError.malformed("root")
        }
        if let error = root["error"] as? [String: Any] {
            let code = int64(error["code"]).map(Int.init) ?? 0
            let message = error["message"] as? String ?? String(describing: error)
            throw NearRPCError.rpc(code: code, message: message)
        }
        return root
    }

    static func rpcError(from data: Data) throws -> NearRPCError? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return nil
        }
        let code = int64(error["code"]).map(Int.init) ?? 0
        let message = error["message"] as? String ?? String(describing: error)
        return .rpc(code: code, message: message)
    }

    static func requiredObject(_ value: Any?, _ field: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw NearRPCError.missing(field) }
        return object
    }

    static func requiredArray(_ value: Any?, _ field: String) throws -> [Any] {
        guard let array = value as? [Any] else { throw NearRPCError.missing(field) }
        return array
    }

    static func requiredString(_ value: Any?, _ field: String) throws -> String {
        guard let string = value as? String else { throw NearRPCError.missing(field) }
        return string
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let value = value as? Decimal { return value }
        if let value = value as? String { return Decimal(string: value) }
        if let value = value as? NSNumber { return Decimal(string: value.stringValue) }
        return nil
    }

    static func dateFromNanoseconds(_ value: Any?) -> Date {
        if let string = value as? String, string.count >= 10 {
            return Date(timeIntervalSince1970: Double(String(string.prefix(10))) ?? 0)
        }
        if let number = int64(value) {
            return Date(timeIntervalSince1970: Double(number) / 1_000_000_000)
        }
        return Date(timeIntervalSince1970: 0)
    }
}

private enum DecimalString {
    static func digitsOnly(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return "0" }
        return trimmed
    }

    static func isPositive(_ value: String) -> Bool {
        value.contains { $0 != "0" }
    }

    static func decimalAmount(rawBalance: String, decimals: Int) -> Decimal? {
        guard let raw = Decimal(string: rawBalance) else { return nil }
        guard decimals > 0 else { return raw }
        var divisor = Decimal(1)
        for _ in 0..<decimals {
            divisor *= 10
        }
        return raw / divisor
    }

    static func displayAmount(rawBalance: String, decimals: Int) -> String {
        guard let amount = decimalAmount(rawBalance: rawBalance, decimals: decimals) else { return "0" }
        return string(amount)
    }

    static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
