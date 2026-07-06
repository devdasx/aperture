import Foundation
import OSLog

actor RippleBalanceHistoryScanner {
    private let client = RippleBalanceHistoryClient()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "ripple-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .ripple else { return }

        let tokens = XRPLTokenRegistry.tokens.sorted { $0.symbol < $1.symbol }
        let symbols = Array(Set(([SupportedChain.ripple.ticker] + tokens.map(\.symbol)).map { $0.uppercased() })).sorted()

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let accountTask = client.accountSnapshot(address: address.address, supportedTokens: tokens)
        async let historyTask: [RippleHistoryEvent] = includeHistory
            ? safeHistory(owner: address.address, tokens: tokens)
            : []

        let account = try await accountTask
        let priceMap = await pricesTask
        let events = await historyTask

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.ripple.ticker,
            tokenContract: nil,
            decimals: SupportedChain.ripple.nativeDecimals,
            rawBalance: account.rawXRP,
            fiatValueCached: fiatValue(
                rawBalance: account.rawXRP,
                decimals: SupportedChain.ripple.nativeDecimals,
                symbol: SupportedChain.ripple.ticker,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = account.accountExists || EVMHexQuantity.isPositiveDecimalString(account.rawXRP)
        for balance in account.tokenBalances {
            if RippleBalanceHistoryClient.isNonZeroXRPLAmount(balance.rawBalance) {
                isUsed = true
            }
            try txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: balance.entry.symbol,
                tokenContract: RippleBalanceHistoryClient.contract(for: balance.entry),
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
            onlyChains: [.ripple],
            failedChains: [],
            interim: false
        )
    }

    private func safeHistory(
        owner: String,
        tokens: [XRPLTokenRegistry.Entry]
    ) async -> [RippleHistoryEvent] {
        do {
            return try await client.recentEvents(address: owner, supportedTokens: tokens)
        } catch {
            log.debug("XRP Ledger history failed: \(String(describing: error), privacy: .public)")
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

actor RippleBalanceHistoryClient {
    private let rpc: RPCClient

    init(rpc: RPCClient = .shared) {
        self.rpc = rpc
    }

    func accountSnapshot(
        address: String,
        supportedTokens: [XRPLTokenRegistry.Entry]
    ) async throws -> RippleAccountSnapshot {
        async let accountTask = accountInfo(address: address)
        async let linesTask = safeAccountLines(address: address)

        let account = try await accountTask
        let lines = await linesTask
        return RippleAccountSnapshot(
            rawXRP: account.rawXRP,
            accountExists: account.accountExists,
            tokenBalances: normalizeTokenBalances(lines, supportedTokens: supportedTokens)
        )
    }

    func recentEvents(
        address: String,
        supportedTokens: [XRPLTokenRegistry.Entry]
    ) async throws -> [RippleHistoryEvent] {
        let data = try await rpc.callJSONResultData(
            chain: .ripple,
            method: "account_tx",
            params: [[
                "account": address,
                "ledger_index_min": -1,
                "ledger_index_max": -1,
                "limit": 100,
                "forward": false,
            ] as [String: Sendable]],
            validatesIDEcho: false
        )
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RippleBalanceHistoryError.invalidResponse("account_tx result was not an object")
        }
        guard isSuccess(result) else {
            if isMissingAccount(result) { return [] }
            throw RippleBalanceHistoryError.xrplError(errorMessage(result))
        }
        let rows = result["transactions"] as? [[String: Any]] ?? []
        let supported = RippleSupportedTokenIndex(tokens: supportedTokens)
        var events: [RippleHistoryEvent] = []
        events.reserveCapacity(rows.count)
        for row in rows {
            if let event = decodePayment(row: row, owner: address, supported: supported) {
                events.append(event)
            }
        }
        return dedupe(events).sorted { $0.occurredAt > $1.occurredAt }
    }

    private func accountInfo(address: String) async throws -> RippleAccountRead {
        let data = try await rpc.callJSONResultData(
            chain: .ripple,
            method: "account_info",
            params: [[
                "account": address,
                "ledger_index": "validated",
            ] as [String: Sendable]],
            validatesIDEcho: false
        )
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RippleBalanceHistoryError.invalidResponse("account_info result was not an object")
        }
        guard isSuccess(result) else {
            if isMissingAccount(result) {
                return RippleAccountRead(rawXRP: "0", accountExists: false)
            }
            throw RippleBalanceHistoryError.xrplError(errorMessage(result))
        }
        guard let accountData = result["account_data"] as? [String: Any] else {
            throw RippleBalanceHistoryError.invalidResponse("account_info missing account_data")
        }
        return RippleAccountRead(
            rawXRP: stringValue(accountData["Balance"]) ?? "0",
            accountExists: true
        )
    }

    private func safeAccountLines(address: String) async -> [RippleAccountLineRead] {
        do {
            return try await accountLines(address: address)
        } catch {
            return []
        }
    }

    private func accountLines(address: String) async throws -> [RippleAccountLineRead] {
        var marker: String?
        var lines: [RippleAccountLineRead] = []
        for _ in 0..<6 {
            var params: [String: Sendable] = [
                "account": address,
                "ledger_index": "validated",
                "limit": 400,
            ]
            if let marker {
                params["marker"] = marker
            }
            let data = try await rpc.callJSONResultData(
                chain: .ripple,
                method: "account_lines",
                params: [params],
                validatesIDEcho: false
            )
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RippleBalanceHistoryError.invalidResponse("account_lines result was not an object")
            }
            guard isSuccess(result) else {
                if isMissingAccount(result) { return [] }
                throw RippleBalanceHistoryError.xrplError(errorMessage(result))
            }
            let rawLines = result["lines"] as? [[String: Any]] ?? []
            for line in rawLines {
                guard let currency = stringValue(line["currency"]),
                      let issuer = stringValue(line["account"]),
                      let balance = stringValue(line["balance"]) else {
                    continue
                }
                lines.append(RippleAccountLineRead(currency: currency, issuer: issuer, balance: balance))
            }
            guard let next = result["marker"] as? String, !next.isEmpty else { break }
            marker = next
        }
        return lines
    }

    private func normalizeTokenBalances(
        _ lines: [RippleAccountLineRead],
        supportedTokens: [XRPLTokenRegistry.Entry]
    ) -> [RippleTokenBalanceRead] {
        let supported = RippleSupportedTokenIndex(tokens: supportedTokens)
        var byContract: [String: String] = [:]
        for line in lines {
            guard let token = supported.entry(currency: line.currency, issuer: line.issuer) else {
                continue
            }
            byContract[Self.contract(for: token)] = line.balance
        }
        return supportedTokens.map { entry in
            RippleTokenBalanceRead(entry: entry, rawBalance: byContract[Self.contract(for: entry)] ?? "0")
        }
    }

    private func decodePayment(
        row: [String: Any],
        owner: String,
        supported: RippleSupportedTokenIndex
    ) -> RippleHistoryEvent? {
        let tx = (row["tx"] as? [String: Any])
            ?? (row["tx_json"] as? [String: Any])
            ?? row
        let meta = (row["meta"] as? [String: Any])
            ?? (row["metaData"] as? [String: Any])
            ?? [:]

        guard stringValue(tx["TransactionType"]) == "Payment" else { return nil }
        guard let source = stringValue(tx["Account"]),
              let destination = stringValue(tx["Destination"]) else { return nil }
        let ownerIsSource = source.caseInsensitiveCompare(owner) == .orderedSame
        let ownerIsDestination = destination.caseInsensitiveCompare(owner) == .orderedSame
        guard ownerIsSource || ownerIsDestination else { return nil }

        let amountSource = meta["delivered_amount"]
            ?? meta["DeliveredAmount"]
            ?? tx["DeliverMax"]
            ?? tx["Amount"]
        guard let amount = decodeAmount(amountSource, supported: supported) else { return nil }

        let hash = stringValue(tx["hash"]) ?? stringValue(row["hash"])
        guard let hash, !hash.isEmpty else { return nil }
        let ledger = int64Value(tx["ledger_index"])
            ?? int64Value(row["ledger_index"])
            ?? int64Value(tx["inLedger"])
            ?? int64Value(row["inLedger"])
        let occurredAt = xrplDate(tx["date"] ?? row["date"]) ?? Date()
        let txResult = stringValue(meta["TransactionResult"]) ?? "tesSUCCESS"
        let validated = (row["validated"] as? Bool) ?? true
        let status: TransactionStatus = validated
            ? (txResult == "tesSUCCESS" ? .confirmed : .failed)
            : .pending

        let direction: TransactionDirection
        let counterparty: String
        if ownerIsSource && ownerIsDestination {
            direction = .internal
            counterparty = ""
        } else if ownerIsDestination {
            direction = .incoming
            counterparty = source
        } else {
            direction = .outgoing
            counterparty = destination
        }

        return RippleHistoryEvent(
            txHash: hash,
            direction: direction,
            amount: amount.amount,
            tokenSymbol: amount.symbol,
            tokenContract: amount.tokenContract,
            blockNumber: ledger,
            occurredAt: occurredAt,
            status: status,
            counterparty: counterparty,
            fee: ownerIsSource ? dropsToXRPString(stringValue(tx["Fee"])) : nil
        )
    }

    private func decodeAmount(
        _ value: Any?,
        supported: RippleSupportedTokenIndex
    ) -> RippleAmountRead? {
        if let drops = value as? String {
            guard drops != "unavailable", let amount = dropsToXRPString(drops) else { return nil }
            return RippleAmountRead(
                amount: amount,
                symbol: SupportedChain.ripple.ticker,
                tokenContract: nil
            )
        }
        guard let dict = value as? [String: Any],
              let currency = stringValue(dict["currency"]),
              let issuer = stringValue(dict["issuer"]),
              let token = supported.entry(currency: currency, issuer: issuer),
              let amount = stringValue(dict["value"]) else {
            return nil
        }
        return RippleAmountRead(
            amount: normalizeDecimalString(amount),
            symbol: token.symbol,
            tokenContract: Self.contract(for: token)
        )
    }

    private func dedupe(_ events: [RippleHistoryEvent]) -> [RippleHistoryEvent] {
        var seen = Set<String>()
        var rows: [RippleHistoryEvent] = []
        for event in events {
            let key = "\(event.txHash)|\(event.tokenContract ?? "native")|\(event.direction.rawValue)|\(event.amount)"
            if seen.insert(key).inserted {
                rows.append(event)
            }
        }
        return rows
    }

    static func contract(for entry: XRPLTokenRegistry.Entry) -> String {
        "\(entry.currency).\(entry.issuer)"
    }

    static func isNonZeroXRPLAmount(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains { character in
            character.isNumber && character != "0"
        }
    }

    private func isSuccess(_ result: [String: Any]) -> Bool {
        (result["status"] as? String) == "success"
    }

    private func isMissingAccount(_ result: [String: Any]) -> Bool {
        let error = (result["error"] as? String)?.lowercased() ?? ""
        let message = (result["error_message"] as? String)?.lowercased() ?? ""
        return error == "actnotfound"
            || message.contains("account not found")
    }

    private func errorMessage(_ result: [String: Any]) -> String {
        let error = result["error"] as? String
        let message = result["error_message"] as? String
        return [error, message].compactMap { $0 }.joined(separator: ": ")
    }

    private func dropsToXRPString(_ drops: String?) -> String? {
        guard let drops, let value = Decimal(string: drops) else { return nil }
        let amount = value / Decimal(1_000_000)
        return EVMHexQuantity.decimalString(amount)
    }

    private func xrplDate(_ value: Any?) -> Date? {
        guard let seconds = int64Value(value) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds + 946_684_800))
    }

    private func normalizeDecimalString(_ value: String) -> String {
        Decimal(string: value).map(EVMHexQuantity.decimalString) ?? value
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}

struct RippleAccountSnapshot: Sendable, Hashable {
    let rawXRP: String
    let accountExists: Bool
    let tokenBalances: [RippleTokenBalanceRead]
}

struct RippleTokenBalanceRead: Sendable, Hashable {
    let entry: XRPLTokenRegistry.Entry
    let rawBalance: String
}

struct RippleHistoryEvent: Sendable, Hashable {
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

private struct RippleAccountRead: Sendable, Hashable {
    let rawXRP: String
    let accountExists: Bool
}

private struct RippleAccountLineRead: Sendable, Hashable {
    let currency: String
    let issuer: String
    let balance: String
}

private struct RippleAmountRead: Sendable, Hashable {
    let amount: String
    let symbol: String
    let tokenContract: String?
}

private struct RippleSupportedTokenIndex: Sendable {
    private let byKey: [String: XRPLTokenRegistry.Entry]

    init(tokens: [XRPLTokenRegistry.Entry]) {
        self.byKey = Dictionary(uniqueKeysWithValues: tokens.map {
            (Self.key(currency: $0.currency, issuer: $0.issuer), $0)
        })
    }

    func entry(currency: String, issuer: String) -> XRPLTokenRegistry.Entry? {
        byKey[Self.key(currency: currency, issuer: issuer)]
    }

    private static func key(currency: String, issuer: String) -> String {
        "\(currency.lowercased())|\(issuer.lowercased())"
    }
}

enum RippleBalanceHistoryError: Error, Sendable, CustomStringConvertible {
    case invalidResponse(String)
    case xrplError(String)

    var description: String {
        switch self {
        case .invalidResponse(let message):
            return "Invalid XRP Ledger response: \(message)"
        case .xrplError(let message):
            return "XRP Ledger error: \(message)"
        }
    }
}
