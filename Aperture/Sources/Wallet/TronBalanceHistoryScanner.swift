import CryptoKit
import Foundation

actor TronBalanceHistoryScanner {
    private let client = TronBalanceHistoryClient()

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        customTokens: [CustomTokenSnapshot] = [],
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .tron else { return }

        let tokens = supportedTokens(customTokens: customTokens)
        let symbols = Array(Set(([SupportedChain.tron.ticker] + tokens.map(\.symbol)).map { $0.uppercased() })).sorted()

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let accountTask = client.accountSnapshot(address: address.address, supportedTokens: tokens)
        async let historyTask: [TronHistoryEvent] = includeHistory
            ? safeHistory(owner: address.address, tokens: tokens)
            : []

        let account = try await accountTask
        let priceMap = await pricesTask
        let events = await historyTask

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.tron.ticker,
            tokenContract: nil,
            decimals: SupportedChain.tron.nativeDecimals,
            rawBalance: account.rawTRX,
            fiatValueCached: fiatValue(
                rawBalance: account.rawTRX,
                decimals: SupportedChain.tron.nativeDecimals,
                symbol: SupportedChain.tron.ticker,
                trxQuotedPrice: nil,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = account.accountExists || EVMHexQuantity.isPositiveDecimalString(account.rawTRX)
        // BUG-004: only rewrite TRC-20 rows when a token-capable provider
        // succeeded. `nil` = full-node/native-only fallback — keep last good.
        if let tokenBalances = account.tokenBalances {
            for balance in tokenBalances {
                if EVMHexQuantity.isPositiveDecimalString(balance.rawBalance) {
                    isUsed = true
                }
                try txRepo.upsertBalance(
                    addressId: address.id,
                    tokenSymbol: balance.entry.symbol,
                    tokenContract: balance.entry.contract,
                    decimals: balance.entry.decimals,
                    rawBalance: balance.rawBalance,
                    fiatValueCached: fiatValue(
                        rawBalance: balance.rawBalance,
                        decimals: balance.entry.decimals,
                        symbol: balance.entry.symbol,
                        trxQuotedPrice: balance.priceInTRX,
                        prices: priceMap
                    ),
                    fiatCurrencyCode: currencyCode,
                    save: false
                )
            }
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
            onlyChains: [.tron],
            failedChains: BalanceProbeKeepLastGood.failedChains(
                chain: .tron,
                nativeProbeSucceeded: true,
                tokenProbeSucceeded: account.tokenBalances != nil
            ),
            interim: false
        )
    }

    private func supportedTokens(customTokens: [CustomTokenSnapshot]) -> [TronTokenRegistry.Entry] {
        var rows = TronTokenRegistry.tokens
        var seen = Set(rows.map(\.contract))
        for token in customTokens where token.chain == .tron {
            guard seen.insert(token.contract).inserted else { continue }
            rows.append(TronTokenRegistry.Entry(
                contract: token.contract,
                symbol: token.symbol,
                name: token.name,
                decimals: token.decimals
            ))
        }
        return rows.sorted {
            if $0.symbol == $1.symbol { return $0.contract < $1.contract }
            return $0.symbol < $1.symbol
        }
    }

    private func safeHistory(
        owner: String,
        tokens: [TronTokenRegistry.Entry]
    ) async -> [TronHistoryEvent] {
        await client.recentEvents(address: owner, supportedTokens: tokens)
    }

    private func fiatValue(
        rawBalance: String,
        decimals: Int,
        symbol: String,
        trxQuotedPrice: Decimal?,
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) -> Decimal? {
        guard let amount = EVMHexQuantity.decimalAmount(rawBalance: rawBalance, decimals: decimals) else {
            return nil
        }
        if let direct = prices[symbol.uppercased()] {
            return amount * direct.amount
        }
        guard let trxQuotedPrice, let trxPrice = prices[SupportedChain.tron.ticker.uppercased()] else {
            return nil
        }
        return amount * trxQuotedPrice * trxPrice.amount
    }
}

actor TronBalanceHistoryClient {
    private static let tronGridBase = URL(string: "https://api.trongrid.io")!
    private static let tronScanBase = URL(string: "https://apilist.tronscanapi.com")!
    private static let publicNodeBase = URL(string: "https://tron-rpc.publicnode.com")!
    private static let tronGridThrottle = TronProviderThrottle(minimumDelay: 1.05)

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
        supportedTokens: [TronTokenRegistry.Entry]
    ) async throws -> TronAccountSnapshot {
        do {
            return try await tronScanAccountSnapshot(address: address, supportedTokens: supportedTokens)
        } catch {
            do {
                return try await tronGridAccountSnapshot(address: address, supportedTokens: supportedTokens)
            } catch {
                return try await fullNodeAccountSnapshot(address: address, supportedTokens: supportedTokens)
            }
        }
    }

    func recentEvents(
        address: String,
        supportedTokens: [TronTokenRegistry.Entry]
    ) async -> [TronHistoryEvent] {
        async let nativeEvents = safeTronGridNativeTransfers(address: address)
        async let tokenEvents = safeTronGridTRC20Transfers(address: address, supportedTokens: supportedTokens)

        let combined = await nativeEvents + tokenEvents
        return finalize(combined)
    }

    private func tronScanAccountSnapshot(
        address: String,
        supportedTokens: [TronTokenRegistry.Entry]
    ) async throws -> TronAccountSnapshot {
        guard Secrets.hasTronScanAPIKey else {
            throw TronBalanceHistoryError.providerUnavailable("TRONSCAN API key is not configured")
        }

        let response = try await get(
            baseURL: Self.tronScanBase,
            path: "api/account/token_asset_overview",
            query: [
                URLQueryItem(name: "address", value: address),
                URLQueryItem(name: "start", value: "0"),
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "hidden", value: "0"),
                URLQueryItem(name: "sort", value: "true"),
            ],
            headers: ["TRON-PRO-API-KEY": Secrets.tronScanAPIKey]
        )
        let decoded = try JSONDecoder().decode(TronScanTokenEnvelope.self, from: response)

        let supported = Dictionary(uniqueKeysWithValues: supportedTokens.map { ($0.contract, $0) })
        var tokenRows: [TronTokenBalanceRead] = []
        var nativeRaw: String?
        for token in decoded.tokens {
            guard let balance = token.balanceString, EVMHexQuantity.isPositiveDecimalString(balance) else {
                continue
            }
            let symbol = token.symbol?.uppercased()
            let contract = token.contract
            if symbol == SupportedChain.tron.ticker {
                nativeRaw = balance
                continue
            }
            guard let contract, let entry = supported[contract] else { continue }
            tokenRows.append(TronTokenBalanceRead(
                entry: entry,
                rawBalance: balance,
                priceInTRX: token.priceInTRX
            ))
        }

        let gridNative = try? await fullNodeAccountSnapshot(address: address, supportedTokens: supportedTokens)
        return TronAccountSnapshot(
            rawTRX: nativeRaw ?? gridNative?.rawTRX ?? "0",
            accountExists: decoded.totalTokenCount > 0 || gridNative?.accountExists == true,
            tokenBalances: normalizeTokenBalances(tokenRows, supportedTokens: supportedTokens)
        )
    }

    private func tronGridAccountSnapshot(
        address: String,
        supportedTokens: [TronTokenRegistry.Entry]
    ) async throws -> TronAccountSnapshot {
        let response = try await get(
            baseURL: Self.tronGridBase,
            path: "v1/accounts/\(address)",
            query: []
        )
        let decoded = try JSONDecoder().decode(TronGridAccountEnvelope.self, from: response)
        guard let account = decoded.data.first else {
            // Account truly missing: zero native + empty token set is honest.
            return TronAccountSnapshot(
                rawTRX: "0",
                accountExists: false,
                tokenBalances: normalizeTokenBalances([], supportedTokens: supportedTokens)
            )
        }

        let supported = Dictionary(uniqueKeysWithValues: supportedTokens.map { ($0.contract, $0) })
        var rows: [TronTokenBalanceRead] = []
        for tokenMap in account.trc20 ?? [] {
            for (contract, balance) in tokenMap {
                guard let entry = supported[contract] else { continue }
                rows.append(TronTokenBalanceRead(entry: entry, rawBalance: balance, priceInTRX: nil))
            }
        }

        return TronAccountSnapshot(
            rawTRX: String(account.balance ?? 0),
            accountExists: true,
            tokenBalances: normalizeTokenBalances(rows, supportedTokens: supportedTokens)
        )
    }

    private func fullNodeAccountSnapshot(
        address: String,
        supportedTokens: [TronTokenRegistry.Entry]
    ) async throws -> TronAccountSnapshot {
        let response = try await post(
            baseURL: Self.publicNodeBase,
            path: "wallet/getaccount",
            body: ["address": address, "visible": true]
        )
        let decoded = try JSONDecoder().decode(TronFullNodeAccount.self, from: response)
        // Full-node getaccount has no TRC-20 inventory. BUG-004: do not
        // invent zero token balances — leave last-good jetton/TRC-20 rows.
        _ = supportedTokens
        return TronAccountSnapshot(
            rawTRX: String(decoded.balance ?? 0),
            accountExists: decoded.balance != nil || decoded.createTime != nil,
            tokenBalances: nil
        )
    }

    private func tronGridNativeTransfers(address: String) async throws -> [TronHistoryEvent] {
        let response = try await get(
            baseURL: Self.tronGridBase,
            path: "v1/accounts/\(address)/transactions",
            query: [
                URLQueryItem(name: "limit", value: "\(HistoryScanLimits.perAddress)"),
                URLQueryItem(name: "only_confirmed", value: "true"),
                URLQueryItem(name: "order_by", value: "block_timestamp,desc"),
            ]
        )
        let decoded = try JSONDecoder().decode(TronGridNativeTransactionEnvelope.self, from: response)
        return decoded.data.compactMap { tx in
            guard let contract = tx.rawData?.contract.first(where: { $0.type == "TransferContract" }),
                  let value = contract.parameter?.value,
                  let amount = value.amount,
                  EVMHexQuantity.isPositiveDecimalString(String(amount)),
                  let direction = direction(from: value.ownerAddress, to: value.toAddress, owner: address),
                  let displayAmount = EVMHexQuantity.displayAmount(
                    rawBalance: String(amount),
                    decimals: SupportedChain.tron.nativeDecimals
                  ) else {
                return nil
            }

            return TronHistoryEvent(
                txHash: tx.txID,
                direction: direction.0,
                amount: displayAmount,
                tokenSymbol: SupportedChain.tron.ticker,
                tokenContract: nil,
                blockNumber: tx.blockNumber,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(tx.blockTimestamp ?? 0) / 1000),
                status: tx.status,
                counterparty: direction.1,
                fee: tx.feeRaw.flatMap {
                    EVMHexQuantity.displayAmount(rawBalance: String($0), decimals: SupportedChain.tron.nativeDecimals)
                }
            )
        }
    }

    private func safeTronGridNativeTransfers(address: String) async -> [TronHistoryEvent] {
        (try? await tronGridNativeTransfers(address: address)) ?? []
    }

    private func safeTronGridTRC20Transfers(
        address: String,
        supportedTokens: [TronTokenRegistry.Entry]
    ) async -> [TronHistoryEvent] {
        if let events = try? await tronGridTRC20Transfers(address: address, supportedTokens: supportedTokens) {
            return events
        }

        return await withTaskGroup(of: [TronHistoryEvent].self) { group in
            for token in supportedTokens {
                group.addTask {
                    (try? await self.tronGridTRC20Transfers(address: address, token: token)) ?? []
                }
            }

            var rows: [TronHistoryEvent] = []
            for await events in group {
                rows.append(contentsOf: events)
            }
            return rows
        }
    }

    private func tronGridTRC20Transfers(
        address: String,
        supportedTokens: [TronTokenRegistry.Entry]
    ) async throws -> [TronHistoryEvent] {
        let response = try await get(
            baseURL: Self.tronGridBase,
            path: "v1/accounts/\(address)/transactions/trc20",
            query: [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "only_confirmed", value: "true"),
                URLQueryItem(name: "order_by", value: "block_timestamp,desc"),
            ]
        )
        let decoded = try JSONDecoder().decode(TronGridTRC20TransferEnvelope.self, from: response)
        let supported = Dictionary(uniqueKeysWithValues: supportedTokens.map { ($0.contract, $0) })
        return decoded.data.compactMap { transfer in
            guard let contract = transfer.tokenInfo?.address,
                  let token = supported[contract] else {
                return nil
            }
            return makeTRC20HistoryEvent(from: transfer, token: token, owner: address)
        }
    }

    private func tronGridTRC20Transfers(
        address: String,
        token: TronTokenRegistry.Entry
    ) async throws -> [TronHistoryEvent] {
        let response = try await get(
            baseURL: Self.tronGridBase,
            path: "v1/accounts/\(address)/transactions/trc20",
            query: [
                URLQueryItem(name: "limit", value: "\(HistoryScanLimits.perAddress)"),
                URLQueryItem(name: "only_confirmed", value: "true"),
                URLQueryItem(name: "order_by", value: "block_timestamp,desc"),
                URLQueryItem(name: "contract_address", value: token.contract),
            ]
        )
        let decoded = try JSONDecoder().decode(TronGridTRC20TransferEnvelope.self, from: response)
        return decoded.data.compactMap { transfer in
            makeTRC20HistoryEvent(from: transfer, token: token, owner: address)
        }
    }

    private func makeTRC20HistoryEvent(
        from transfer: TronGridTRC20Transfer,
        token: TronTokenRegistry.Entry,
        owner: String
    ) -> TronHistoryEvent? {
        guard transfer.tokenInfo?.address == token.contract,
              EVMHexQuantity.isPositiveDecimalString(transfer.value),
              let direction = direction(from: transfer.from, to: transfer.to, owner: owner),
              let displayAmount = EVMHexQuantity.displayAmount(
                rawBalance: transfer.value,
                decimals: transfer.tokenInfo?.decimals ?? token.decimals
              ) else {
            return nil
        }

        return TronHistoryEvent(
            txHash: transfer.transactionID,
            direction: direction.0,
            amount: displayAmount,
            tokenSymbol: token.symbol,
            tokenContract: token.contract,
            blockNumber: nil,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(transfer.blockTimestamp) / 1000),
            status: .confirmed,
            counterparty: direction.1,
            fee: nil
        )
    }

    /// Successful token-capable provider responses: missing registry tokens
    /// are truly zero. Never call after a provider failure (BUG-004).
    private func normalizeTokenBalances(
        _ rows: [TronTokenBalanceRead],
        supportedTokens: [TronTokenRegistry.Entry]
    ) -> [TronTokenBalanceRead] {
        let byContract = Dictionary(uniqueKeysWithValues: rows.map { ($0.entry.contract, $0) })
        return supportedTokens.sorted { $0.symbol < $1.symbol }.map { token in
            byContract[token.contract] ?? TronTokenBalanceRead(entry: token, rawBalance: "0", priceInTRX: nil)
        }
    }

    private func finalize(_ events: [TronHistoryEvent]) -> [TronHistoryEvent] {
        var seen = Set<String>()
        return events
            .sorted { $0.occurredAt > $1.occurredAt }
            .filter { event in
                let key = "\(event.txHash)|\(event.tokenContract ?? "native")|\(event.direction.rawValue)|\(event.amount)"
                return seen.insert(key).inserted
            }
    }

    private func direction(
        from: String?,
        to: String?,
        owner: String
    ) -> (TransactionDirection, String)? {
        let normalizedOwner = normalizeAddress(owner)
        let normalizedFrom = from.map(normalizeAddress)
        let normalizedTo = to.map(normalizeAddress)

        if normalizedFrom == normalizedOwner && normalizedTo == normalizedOwner {
            return (.internal, "")
        }
        if normalizedFrom == normalizedOwner {
            return (.outgoing, normalizedTo ?? "")
        }
        if normalizedTo == normalizedOwner {
            return (.incoming, normalizedFrom ?? "")
        }
        return nil
    }

    private func normalizeAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 42, trimmed.lowercased().hasPrefix("41"),
           let payload = Self.hexBytes(trimmed) {
            return Self.base58Check(payload)
        }
        return trimmed
    }

    private func get(
        baseURL: URL,
        path: String,
        query: [URLQueryItem],
        headers: [String: String] = [:]
    ) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw TronBalanceHistoryError.malformed("Could not build URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await data(for: request)
    }

    private func post(
        baseURL: URL,
        path: String,
        body: [String: Any]
    ) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await data(for: request)
    }

    private func data(for request: URLRequest) async throws -> Data {
        try await data(for: request, retryCount: 0)
    }

    private func data(for request: URLRequest, retryCount: Int) async throws -> Data {
        if request.url?.host == Self.tronGridBase.host {
            await Self.tronGridThrottle.wait()
        }

        let (responseData, response) = try await session.apertureData(
            for: request,
            family: "histories",
            operation: request.url?.path.isEmpty == false ? request.url?.path ?? "TRON request" : "TRON request",
            metadata: [
                "chain": "tron",
                "source": "TronProviderClient",
                "retryCount": "\(retryCount)"
            ]
        )
        guard let http = response as? HTTPURLResponse else { return responseData }
        if http.statusCode == 429, retryCount < 2 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await data(for: request, retryCount: retryCount + 1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TronBalanceHistoryError.providerUnavailable("HTTP \(http.statusCode) from \(request.url?.host ?? "TRON provider")")
        }
        return responseData
    }

    private static func base58Check(_ payload: [UInt8]) -> String {
        let first = SHA256.hash(data: Data(payload))
        let second = SHA256.hash(data: Data(first))
        let checksum = Array(second.prefix(4))
        return Base58.encode(Data(payload + checksum))
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

private actor TronProviderThrottle {
    private let minimumDelay: TimeInterval
    private var nextStart = Date.distantPast

    init(minimumDelay: TimeInterval) {
        self.minimumDelay = minimumDelay
    }

    func wait() async {
        let now = Date()
        if nextStart > now {
            let delay = nextStart.timeIntervalSince(now)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        nextStart = Date().addingTimeInterval(minimumDelay)
    }
}

struct TronAccountSnapshot: Sendable {
    let rawTRX: String
    let accountExists: Bool
    /// `nil` when only a native full-node path ran (no TRC-20 inventory) —
    /// scanners must not overwrite stored token balances with invented zeros
    /// (BUG-004).
    let tokenBalances: [TronTokenBalanceRead]?
}

struct TronTokenBalanceRead: Sendable {
    let entry: TronTokenRegistry.Entry
    let rawBalance: String
    let priceInTRX: Decimal?
}

struct TronHistoryEvent: Sendable {
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

private struct TronGridAccountEnvelope: Decodable {
    let data: [TronGridAccount]
}

private struct TronGridAccount: Decodable {
    let balance: Int64?
    let trc20: [[String: String]]?
}

private struct TronFullNodeAccount: Decodable {
    let balance: Int64?
    let createTime: Int64?

    enum CodingKeys: String, CodingKey {
        case balance
        case createTime = "create_time"
    }
}

private struct TronGridNativeTransactionEnvelope: Decodable {
    let data: [TronGridNativeTransaction]
}

private struct TronGridNativeTransaction: Decodable {
    let txID: String
    let ret: [TronGridTransactionRet]?
    let blockNumber: Int64?
    let blockTimestamp: Int64?
    let rawData: TronGridRawData?
    let netFee: Int64?
    let energyFee: Int64?

    var status: TransactionStatus {
        guard let result = ret?.first?.contractRet else { return .confirmed }
        return result.uppercased() == "SUCCESS" ? .confirmed : .failed
    }

    var feeRaw: Int64? {
        let fee = (netFee ?? 0) + (energyFee ?? 0)
        return fee > 0 ? fee : nil
    }

    enum CodingKeys: String, CodingKey {
        case txID
        case ret
        case blockNumber
        case blockTimestamp = "block_timestamp"
        case rawData = "raw_data"
        case netFee = "net_fee"
        case energyFee = "energy_fee"
    }
}

private struct TronGridTransactionRet: Decodable {
    let contractRet: String?
}

private struct TronGridRawData: Decodable {
    let contract: [TronGridContract]
}

private struct TronGridContract: Decodable {
    let type: String?
    let parameter: TronGridContractParameter?
}

private struct TronGridContractParameter: Decodable {
    let value: TronGridContractValue?
}

private struct TronGridContractValue: Decodable {
    let amount: Int64?
    let ownerAddress: String?
    let toAddress: String?

    enum CodingKeys: String, CodingKey {
        case amount
        case ownerAddress = "owner_address"
        case toAddress = "to_address"
    }
}

private struct TronGridTRC20TransferEnvelope: Decodable {
    let data: [TronGridTRC20Transfer]
}

private struct TronGridTRC20Transfer: Decodable {
    let transactionID: String
    let tokenInfo: TronGridTRC20TokenInfo?
    let blockTimestamp: Int64
    let from: String?
    let to: String?
    let value: String

    enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case tokenInfo = "token_info"
        case blockTimestamp = "block_timestamp"
        case from
        case to
        case value
    }
}

private struct TronGridTRC20TokenInfo: Decodable {
    let symbol: String?
    let address: String?
    let decimals: Int?
    let name: String?
}

private struct TronScanTokenEnvelope: Decodable {
    let data: [TronScanToken]?
    let trc20TokenBalances: [TronScanToken]?
    let tokenBalances: [TronScanToken]?
    let total: Int?

    var tokens: [TronScanToken] {
        data ?? trc20TokenBalances ?? tokenBalances ?? []
    }

    var totalTokenCount: Int {
        total ?? tokens.count
    }

    enum CodingKeys: String, CodingKey {
        case data
        case trc20TokenBalances = "trc20token_balances"
        case tokenBalances = "tokenBalances"
        case total
    }
}

private struct TronScanToken: Decodable {
    let tokenId: String?
    let tokenID: String?
    let contractAddress: String?
    let tokenAddress: String?
    let addressRaw: String?
    let tokenAbbr: String?
    let tokenSymbol: String?
    let symbolRaw: String?
    let balanceRaw: FlexibleString?
    let quantityRaw: FlexibleString?
    let amountRaw: FlexibleString?
    let tokenDecimalRaw: FlexibleInt?
    let decimalsRaw: FlexibleInt?
    let tokenPriceInTrxRaw: FlexibleDecimal?

    var symbol: String? {
        tokenAbbr ?? tokenSymbol ?? symbolRaw
    }

    var contract: String? {
        let candidate = tokenId ?? tokenID ?? contractAddress ?? tokenAddress ?? addressRaw
        guard let candidate, candidate != "_" else { return nil }
        return candidate
    }

    var balanceString: String? {
        balanceRaw?.value ?? quantityRaw?.value ?? amountRaw?.value
    }

    var priceInTRX: Decimal? {
        tokenPriceInTrxRaw?.value
    }

    enum CodingKeys: String, CodingKey {
        case tokenId
        case tokenID
        case contractAddress
        case tokenAddress
        case addressRaw = "address"
        case tokenAbbr
        case tokenSymbol
        case symbolRaw = "symbol"
        case balanceRaw = "balance"
        case quantityRaw = "quantity"
        case amountRaw = "amount"
        case tokenDecimalRaw = "tokenDecimal"
        case decimalsRaw = "decimals"
        case tokenPriceInTrxRaw = "tokenPriceInTrx"
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = NSDecimalNumber(value: double).stringValue
        } else {
            value = "0"
        }
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self), let int = Int(string) {
            value = int
        } else {
            value = 0
        }
    }
}

private struct FlexibleDecimal: Decodable {
    let value: Decimal

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let decimal = Decimal(string: string) {
            value = decimal
        } else if let int = try? container.decode(Int.self) {
            value = Decimal(int)
        } else if let double = try? container.decode(Double.self) {
            value = Decimal(double)
        } else {
            value = 0
        }
    }
}

private enum TronBalanceHistoryError: Error, CustomStringConvertible {
    case malformed(String)
    case providerUnavailable(String)

    var description: String {
        switch self {
        case .malformed(let reason):
            return "Malformed TRON response: \(reason)"
        case .providerUnavailable(let reason):
            return "TRON provider unavailable: \(reason)"
        }
    }
}
