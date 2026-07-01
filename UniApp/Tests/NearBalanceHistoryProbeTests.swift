import Foundation
import SwiftData
import Testing
@testable import Aperture

@Suite("NEAR balance + history probe")
struct NearBalanceHistoryProbeTests {
    private static let accountId = "near"

    @Test("NEAR RPC account balance response decodes exact yoctoNEAR")
    func accountBalanceDecode() async throws {
        let client = NearProbeRPCClient()
        let account = try await client.account(accountId: Self.accountId)

        #expect(!account.amount.isEmpty)
        #expect(account.amount.allSatisfy { $0.isNumber })
        #expect(account.blockHeight > 0)
        #expect(account.storageUsage > 0)
    }

    @Test("NEAR RPC supported token balances decode ft_balance_of results")
    func supportedTokenBalancesDecode() async throws {
        let client = NearProbeRPCClient()

        let balances = await withTaskGroup(of: NearProbeTokenBalance?.self) { group in
            for token in NearTokenRegistry.tokens {
                group.addTask {
                    try? await client.ftBalance(accountId: Self.accountId, token: token)
                }
            }

            var rows: [NearProbeTokenBalance] = []
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows.sorted { $0.symbol < $1.symbol }
        }

        let returnedSymbols = Set(balances.map(\.symbol))
        let missingSymbols = NearTokenRegistry.tokens
            .map(\.symbol)
            .filter { !returnedSymbols.contains($0) }
        #expect(!balances.isEmpty)
        #expect(balances.count <= NearTokenRegistry.tokens.count)
        for balance in balances {
            #expect(!balance.rawBalance.isEmpty)
            #expect(balance.rawBalance.allSatisfy { $0.isNumber })
        }
        if !missingSymbols.isEmpty {
            print("[NearProbe] Token balance endpoint did not return: \(missingSymbols.joined(separator: ","))")
        }
    }

    @Test("Live NEAR scan gets balance and history in parallel")
    func liveNearBalanceAndHistory() async throws {
        let markerPath = "/tmp/aperture_live_near_probe"
        let shouldRunLiveProbe = ProcessInfo.processInfo.environment["APERTURE_LIVE_NEAR_PROBE"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
        guard shouldRunLiveProbe else {
            print("[NearProbe] Skipped live probe. Set APERTURE_LIVE_NEAR_PROBE=1 or create \(markerPath) to run it.")
            return
        }

        let scanner = NearProbeScanner()
        let started = ContinuousClock.now
        let result = try await scanner.scan(accountId: Self.accountId)
        let elapsed = started.duration(to: .now)
        let elapsedMS = Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        #expect(!result.account.amount.isEmpty)
        #expect(result.tokenBalances.count == NearTokenRegistry.tokens.count)
        #expect(result.events.allSatisfy { !$0.id.isEmpty })

        print("""
        [NearProbe] account=\(Self.accountId) elapsedMS=\(elapsedMS)
        [NearProbe] nativeYocto=\(result.account.amount) block=\(result.account.blockHeight)
        [NearProbe] tokenBalances=\(result.tokenBalances.map { "\($0.symbol)=\($0.rawBalance)" }.joined(separator: ","))
        [NearProbe] events=\(result.events.count) nativeEvents=\(result.events.filter { $0.tokenContract == nil }.count) tokenEvents=\(result.events.filter { $0.tokenContract != nil }.count)
        """)
    }

    @Test("Live production NEAR scanner persists balances and history")
    func liveProductionNearScannerPersistsBalancesAndHistory() async throws {
        let markerPath = "/tmp/aperture_live_near_probe"
        let shouldRunLiveProbe = ProcessInfo.processInfo.environment["APERTURE_LIVE_NEAR_PROBE"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
        guard shouldRunLiveProbe else {
            print("[NearProbe] Skipped production persistence probe. Set APERTURE_LIVE_NEAR_PROBE=1 or create \(markerPath) to run it.")
            return
        }

        let container = try TestModelContainerFactory.makeContainer(name: "near-production-scan")
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "NEAR Probe",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        let address = WalletAddressRecord(chainRaw: SupportedChain.near.rawValue, address: Self.accountId)
        address.wallet = wallet
        context.insert(wallet)
        context.insert(address)
        try context.save()

        let scanner = NearBalanceHistoryScanner()
        let started = ContinuousClock.now
        try await scanner.scanAndPersist(
            walletId: wallet.id,
            address: WalletRepository.AddressSnapshot(
                id: address.id,
                chain: .near,
                address: Self.accountId
            ),
            currencyCode: "USD",
            modelContainer: container
        )
        let elapsed = started.duration(to: .now)
        let elapsedMS = Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        let addressId = address.id
        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let txs = try context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let nearBalance = balances.first(where: { row in
            row.tokenSymbol == "NEAR" && row.tokenContract == nil
        })
        let near = try #require(nearBalance)
        #expect(near.decimals == SupportedChain.near.nativeDecimals)
        #expect(Decimal(string: near.rawBalance) ?? 0 > 0)
        #expect(balances.count == NearTokenRegistry.tokens.count + 1)
        #expect(!txs.isEmpty)

        print("[NearProbe] production persisted balances=\(balances.count) txs=\(txs.count) elapsedMS=\(elapsedMS)")
    }
}

private struct NearProbeScanner: Sendable {
    private let rpc = NearProbeRPCClient()
    private let history = NearProbeHistoryClient()

    func scan(accountId: String) async throws -> NearProbeScanResult {
        async let accountTask = rpc.account(accountId: accountId)
        async let tokenBalancesTask = tokenBalances(accountId: accountId)
        async let nativeHistoryTask = history.nativeActivities(accountId: accountId, limit: 25)
        async let tokenHistoryTask = tokenHistory(accountId: accountId)

        let (account, balances, nativeEvents, tokenEvents) = try await (
            accountTask,
            tokenBalancesTask,
            nativeHistoryTask,
            tokenHistoryTask
        )
        return NearProbeScanResult(
            account: account,
            tokenBalances: balances,
            events: (nativeEvents + tokenEvents).sorted { $0.occurredAt > $1.occurredAt }
        )
    }

    private func tokenBalances(accountId: String) async -> [NearProbeTokenBalance] {
        await withTaskGroup(of: NearProbeTokenBalance?.self) { group in
            for token in NearTokenRegistry.tokens {
                group.addTask {
                    try? await rpc.ftBalance(accountId: accountId, token: token)
                }
            }

            var rows: [NearProbeTokenBalance] = []
            rows.reserveCapacity(NearTokenRegistry.tokens.count)
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows.sorted { $0.symbol < $1.symbol }
        }
    }

    private func tokenHistory(accountId: String) async -> [NearProbeHistoryEvent] {
        await withTaskGroup(of: [NearProbeHistoryEvent].self) { group in
            for token in NearTokenRegistry.tokens {
                group.addTask {
                    (try? await history.ftEvents(accountId: accountId, token: token, limit: 10)) ?? []
                }
            }

            var rows: [NearProbeHistoryEvent] = []
            for await chunk in group {
                rows.append(contentsOf: chunk)
            }
            return rows
        }
    }
}

private struct NearProbeScanResult: Sendable {
    let account: NearProbeAccount
    let tokenBalances: [NearProbeTokenBalance]
    let events: [NearProbeHistoryEvent]
}

private struct NearProbeAccount: Sendable {
    let amount: String
    let locked: String
    let storageUsage: Int64
    let blockHeight: Int64
}

private struct NearProbeTokenBalance: Sendable {
    let tokenAccount: String
    let symbol: String
    let decimals: Int
    let rawBalance: String
}

private struct NearProbeHistoryEvent: Sendable, Hashable {
    let id: String
    let txHash: String
    let direction: TransactionDirection
    let amountRaw: String
    let tokenSymbol: String
    let tokenContract: String?
    let blockNumber: Int64?
    let occurredAt: Date
    let status: TransactionStatus
    let counterparty: String
    let feeRaw: String?
}

private struct NearProbeRPCClient: Sendable {
    private let endpoints = [
        URL(string: "https://rpc.mainnet.near.org")!,
        URL(string: "https://near.lava.build")!,
    ]

    func account(accountId: String) async throws -> NearProbeAccount {
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
        let data = try await post(body)
        let root = try object(data)
        let result = try requiredObject(root["result"], "result")
        return NearProbeAccount(
            amount: try requiredString(result["amount"], "amount"),
            locked: try requiredString(result["locked"], "locked"),
            storageUsage: int64(result["storage_usage"]) ?? 0,
            blockHeight: int64(result["block_height"]) ?? 0
        )
    }

    func ftBalance(accountId: String, token: NearTokenRegistry.Entry) async throws -> NearProbeTokenBalance {
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

        let data = try await post(body)
        let root = try object(data)
        let result = try requiredObject(root["result"], "result")
        let bytes = try requiredArray(result["result"], "result.result")
        let resultData = Data(bytes.compactMap { int64($0).map(UInt8.init(truncatingIfNeeded:)) })
        let jsonString = String(data: resultData, encoding: .utf8) ?? "0"
        let decoded = (try? JSONDecoder().decode(String.self, from: Data(jsonString.utf8))) ?? jsonString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return NearProbeTokenBalance(
            tokenAccount: token.tokenAccount,
            symbol: token.symbol,
            decimals: token.decimals,
            rawBalance: decoded
        )
    }

    private func post(_ body: [String: Any]) async throws -> Data {
        var lastError: Error?
        for endpoint in endpoints {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 12
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NearProbeError.http(http.statusCode)
                }
                return data
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NearProbeError.noEndpoint
    }
}

private struct NearProbeHistoryClient: Sendable {
    private let baseURL = URL(string: "https://api.nearblocks.io")!

    func nativeActivities(accountId: String, limit: Int) async throws -> [NearProbeHistoryEvent] {
        let url = baseURL.appending(path: "v1/account/\(accountId)/activities")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: String(max(limit, 2)))])
        let data = try await get(url)
        let root = try object(data)
        let activities = try requiredArray(root["activities"], "activities")

        let parsed = activities.compactMap { $0 as? [String: Any] }
        var events: [NearProbeHistoryEvent] = []
        events.reserveCapacity(parsed.count)
        for index in parsed.indices {
            let item = parsed[index]
            let nextOlder = parsed.indices.contains(index + 1) ? parsed[index + 1] : nil
            guard let eventIndex = item["event_index"] as? String else { continue }
            let current = decimal(item["absolute_nonstaked_amount"]) ?? 0
            let previous = nextOlder.flatMap { decimal($0["absolute_nonstaked_amount"]) } ?? current
            let delta = current - previous
            guard delta != 0 else { continue }

            let direction: TransactionDirection = delta > 0 ? .incoming : .outgoing
            let amount = delta < 0 ? -delta : delta
            let txHash = item["transaction_hash"] as? String
            let receipt = item["receipt_id"] as? String
            let id = txHash ?? receipt ?? eventIndex
            let status: TransactionStatus = (item["cause"] as? String) == "DELETE_ACCOUNT" ? .failed : .confirmed
            events.append(NearProbeHistoryEvent(
                id: eventIndex,
                txHash: id,
                direction: direction,
                amountRaw: decimalString(amount),
                tokenSymbol: "NEAR",
                tokenContract: nil,
                blockNumber: int64(item["block_height"]),
                occurredAt: dateFromNanoseconds(item["block_timestamp"]),
                status: status,
                counterparty: item["involved_account_id"] as? String ?? "",
                feeRaw: nil
            ))
        }
        return events
    }

    func ftEvents(accountId: String, token: NearTokenRegistry.Entry, limit: Int) async throws -> [NearProbeHistoryEvent] {
        let url = baseURL.appending(path: "v1/account/\(accountId)/ft-txns")
            .appending(queryItems: [
                URLQueryItem(name: "contract", value: token.tokenAccount),
                URLQueryItem(name: "per_page", value: String(limit)),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "order", value: "desc"),
            ])
        let data = try await get(url)
        let root = try object(data)
        let rows = try requiredArray(root["txns"], "txns").compactMap { $0 as? [String: Any] }

        return rows.compactMap { item in
            guard let eventIndex = item["event_index"] as? String,
                  let rawAmount = item["delta_amount"] as? String,
                  rawAmount != "0" else { return nil }
            let signed = Decimal(string: rawAmount) ?? 0
            let direction: TransactionDirection = signed < 0 ? .outgoing : .incoming
            let amount = signed < 0 ? -signed : signed
            let ft = item["ft"] as? [String: Any]
            let block = item["block"] as? [String: Any]
            let outcomes = item["outcomes"] as? [String: Any]
            let fee = (item["outcomes_agg"] as? [String: Any]).flatMap { decimal($0["transaction_fee"]) }
            return NearProbeHistoryEvent(
                id: eventIndex,
                txHash: item["transaction_hash"] as? String ?? eventIndex,
                direction: direction,
                amountRaw: decimalString(amount),
                tokenSymbol: (ft?["symbol"] as? String) ?? token.symbol,
                tokenContract: (ft?["contract"] as? String) ?? token.tokenAccount,
                blockNumber: int64(block?["block_height"]),
                occurredAt: dateFromNanoseconds(item["block_timestamp"]),
                status: (outcomes?["status"] as? Bool) == false ? .failed : .confirmed,
                counterparty: item["involved_account_id"] as? String ?? "",
                feeRaw: fee.map(decimalString)
            )
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NearProbeError.http(http.statusCode)
        }
        return data
    }
}

private enum NearProbeError: Error {
    case noEndpoint
    case http(Int)
    case missing(String)
    case malformed(String)
}

private func object(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NearProbeError.malformed("root")
    }
    if let error = root["error"] as? [String: Any] {
        throw NearProbeError.malformed(String(describing: error))
    }
    return root
}

private func requiredObject(_ value: Any?, _ field: String) throws -> [String: Any] {
    guard let object = value as? [String: Any] else { throw NearProbeError.missing(field) }
    return object
}

private func requiredArray(_ value: Any?, _ field: String) throws -> [Any] {
    guard let array = value as? [Any] else { throw NearProbeError.missing(field) }
    return array
}

private func requiredString(_ value: Any?, _ field: String) throws -> String {
    guard let string = value as? String else { throw NearProbeError.missing(field) }
    return string
}

private func int64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
}

private func decimal(_ value: Any?) -> Decimal? {
    if let value = value as? Decimal { return value }
    if let value = value as? String { return Decimal(string: value) }
    if let value = value as? NSNumber { return Decimal(string: value.stringValue) }
    return nil
}

private func dateFromNanoseconds(_ value: Any?) -> Date {
    if let string = value as? String, string.count >= 10 {
        return Date(timeIntervalSince1970: Double(String(string.prefix(10))) ?? 0)
    }
    if let number = int64(value) {
        return Date(timeIntervalSince1970: Double(number) / 1_000_000_000)
    }
    return Date(timeIntervalSince1970: 0)
}

private func decimalString(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}

@Suite("Polkadot balance + history probe")
struct PolkadotBalanceHistoryProbeTests {
    private static let treasuryAddress = "13UVJyLnbVp9RBZYFwFGyDvVd1y27Tt8tkntv6Q7JVPhFsTB"

    @Test("Polkadot relay RPC System.Account balance decodes plancks")
    func relayStorageAccountBalanceDecode() async throws {
        let client = PolkadotProbeRPCClient()
        let account = try await client.account(address: Self.treasuryAddress)

        #expect(Decimal(string: account.freePlancks) ?? 0 > 0)
        #expect(Decimal(string: account.totalPlancks) ?? 0 > 0)
        #expect(account.providers > 0)
    }

    @Test("Polkadot Statescan transfer history decodes native DOT rows")
    func statescanTransferHistoryDecode() async throws {
        let client = PolkadotProbeHistoryClient()
        let events = try await client.nativeTransfers(address: Self.treasuryAddress, limit: 10)

        #expect(!events.isEmpty)
        #expect(events.allSatisfy { !$0.txHash.isEmpty })
        #expect(events.allSatisfy { $0.tokenSymbol == "DOT" })
        #expect(events.contains { $0.direction == .incoming || $0.direction == .outgoing })
    }

    @Test("Live Polkadot scan gets balance and history in parallel")
    func livePolkadotBalanceAndHistory() async throws {
        let rpc = PolkadotProbeRPCClient()
        let history = PolkadotProbeHistoryClient()

        let started = ContinuousClock.now
        async let accountTask = rpc.account(address: Self.treasuryAddress)
        async let historyTask = history.nativeTransfers(address: Self.treasuryAddress, limit: 10)

        let (account, events) = try await (accountTask, historyTask)
        let elapsed = started.duration(to: .now)
        let elapsedMS = Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        #expect(Decimal(string: account.totalPlancks) ?? 0 > 0)
        #expect(!events.isEmpty)

        print("""
        [PolkadotProbe] address=\(Self.treasuryAddress) elapsedMS=\(elapsedMS)
        [PolkadotProbe] totalPlancks=\(account.totalPlancks) freePlancks=\(account.freePlancks) reservedPlancks=\(account.reservedPlancks)
        [PolkadotProbe] events=\(events.count) first=\(events.first?.txHash ?? "-")
        """)
    }
}

private actor PolkadotProbeRPCClient {
    private let endpoints = [
        URL(string: "https://rpc.polkadot.io")!,
        URL(string: "https://polkadot.api.onfinality.io/public")!,
    ]

    func account(address: String) async throws -> PolkadotProbeAccount {
        guard let accountId = SS58.decodeAccountId(address) else {
            throw PolkadotProbeError.invalidAddress(address)
        }
        let key = PolkadotProbeCodec.systemAccountStorageKey(accountId: accountId)

        var lastError: Error?
        for endpoint in endpoints {
            do {
                guard let storage = try await callStringOrNull(endpoint: endpoint, method: "state_getStorage", params: [key]) else {
                    return .zero()
                }
                return try PolkadotProbeCodec.decodeAccountInfo(hex: storage)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? PolkadotProbeError.noEndpoint
    }

    private func callStringOrNull(endpoint: URL, method: String, params: [Any]) async throws -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PolkadotProbeError.http(http.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolkadotProbeError.malformed("root")
        }
        if let error = root["error"] as? [String: Any] {
            throw PolkadotProbeError.malformed(String(describing: error))
        }
        if root["result"] is NSNull { return nil }
        guard let result = root["result"] as? String else {
            throw PolkadotProbeError.missing("result")
        }
        return result
    }
}

private actor PolkadotProbeHistoryClient {
    private let baseURL = URL(string: "https://polkadot-api.statescan.io")!

    func nativeTransfers(address: String, limit: Int) async throws -> [PolkadotProbeHistoryEvent] {
        let url = baseURL.appending(path: "accounts/\(address)/transfers")
            .appending(queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "pageSize", value: String(limit)),
            ])
        let data = try await get(url)
        let response = try JSONDecoder().decode(PolkadotProbeTransfersResponse.self, from: data)
        let nativeRows = response.items.filter { $0.isNativeAsset ?? true }

        let hashes = await extrinsicHashes(for: nativeRows)
        return nativeRows.compactMap { row in
            guard !row.balance.isEmpty, row.balance.allSatisfy(\.isNumber) else { return nil }
            let key = PolkadotProbeExtrinsicKey(row.indexer)
            let txHash = hashes[key] ?? row.syntheticHash
            let owner = address
            let direction: TransactionDirection
            let counterparty: String
            if row.from == owner, row.to == owner {
                direction = .internal
                counterparty = ""
            } else if row.from == owner {
                direction = .outgoing
                counterparty = row.to
            } else if row.to == owner {
                direction = .incoming
                counterparty = row.from
            } else {
                return nil
            }
            return PolkadotProbeHistoryEvent(
                txHash: txHash,
                direction: direction,
                amountRaw: EVMHexQuantity.displayAmount(
                    rawBalance: row.balance,
                    decimals: SupportedChain.polkadot.nativeDecimals
                ) ?? "0",
                tokenSymbol: "DOT",
                blockNumber: Int64(row.indexer.blockHeight),
                occurredAt: Date(timeIntervalSince1970: Double(row.indexer.blockTime) / 1_000),
                counterparty: counterparty
            )
        }
    }

    private func extrinsicHashes(for rows: [PolkadotProbeTransferRow]) async -> [PolkadotProbeExtrinsicKey: String] {
        await withTaskGroup(of: (PolkadotProbeExtrinsicKey, String)?.self) { group in
            var seen = Set<PolkadotProbeExtrinsicKey>()
            for row in rows {
                guard let key = PolkadotProbeExtrinsicKey.optional(row.indexer), !seen.contains(key) else { continue }
                seen.insert(key)
                group.addTask {
                    do {
                        let hash = try await self.extrinsicHash(key: key)
                        return (key, hash)
                    } catch {
                        return nil
                    }
                }
            }

            var result: [PolkadotProbeExtrinsicKey: String] = [:]
            for await value in group {
                if let (key, hash) = value {
                    result[key] = hash
                }
            }
            return result
        }
    }

    private func extrinsicHash(key: PolkadotProbeExtrinsicKey) async throws -> String {
        let data = try await get(baseURL.appending(path: "extrinsics/\(key.blockHeight)-\(key.extrinsicIndex)"))
        let response = try JSONDecoder().decode(PolkadotProbeExtrinsicResponse.self, from: data)
        return response.hash
    }

    private func get(_ url: URL) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 18
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    return Data(#"{"items":[]}"#.utf8)
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw PolkadotProbeError.http(http.statusCode)
                }
                return data
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? PolkadotProbeError.noEndpoint
    }
}

private enum PolkadotProbeCodec {
    static func systemAccountStorageKey(accountId: [UInt8]) -> String {
        var bytes: [UInt8] = []
        bytes.append(contentsOf: Twox.twox128(Array("System".utf8)))
        bytes.append(contentsOf: Twox.twox128(Array("Account".utf8)))
        bytes.append(contentsOf: BLAKE2b.hash(accountId, outlen: 16))
        bytes.append(contentsOf: accountId)
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decodeAccountInfo(hex: String) throws -> PolkadotProbeAccount {
        let bytes = try hexBytes(hex)
        guard bytes.count >= 64 else {
            throw PolkadotProbeError.malformed("System.Account storage too short: \(bytes.count) bytes")
        }
        let nonce = UInt32(littleEndianBytes: bytes[0..<4])
        let consumers = UInt32(littleEndianBytes: bytes[4..<8])
        let providers = UInt32(littleEndianBytes: bytes[8..<12])
        let sufficients = UInt32(littleEndianBytes: bytes[12..<16])
        let free = decimalStringLittleEndian(bytes[16..<32])
        let reserved = decimalStringLittleEndian(bytes[32..<48])
        let frozen = decimalStringLittleEndian(bytes[48..<64])
        let flags = bytes.count >= 80 ? decimalStringLittleEndian(bytes[64..<80]) : "0"
        return PolkadotProbeAccount(
            nonce: nonce,
            consumers: consumers,
            providers: providers,
            sufficients: sufficients,
            freePlancks: free,
            reservedPlancks: reserved,
            frozenPlancks: frozen,
            flagsPlancks: flags,
            totalPlancks: addDecimalStrings(free, reserved)
        )
    }

    private static func hexBytes(_ value: String) throws -> [UInt8] {
        let hex = value.hasPrefix("0x") || value.hasPrefix("0X") ? String(value.dropFirst(2)) : value
        guard hex.count.isMultiple(of: 2) else { throw PolkadotProbeError.malformed("odd hex length") }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw PolkadotProbeError.malformed("invalid hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func decimalStringLittleEndian(_ bytes: ArraySlice<UInt8>) -> String {
        let hex = bytes.reversed().map { String(format: "%02x", $0) }.joined()
        return (try? EVMHexQuantity.decimalString(from: hex)) ?? "0"
    }

    private static func addDecimalStrings(_ lhs: String, _ rhs: String) -> String {
        var a = lhs.reversed().map { Int(String($0)) ?? 0 }
        var b = rhs.reversed().map { Int(String($0)) ?? 0 }
        let count = max(a.count, b.count)
        while a.count < count { a.append(0) }
        while b.count < count { b.append(0) }
        var carry = 0
        var result: [Int] = []
        result.reserveCapacity(count + 1)
        for index in 0..<count {
            let sum = a[index] + b[index] + carry
            result.append(sum % 10)
            carry = sum / 10
        }
        if carry > 0 { result.append(carry) }
        while result.count > 1 && result.last == 0 { result.removeLast() }
        return result.reversed().map(String.init).joined()
    }
}

private struct PolkadotProbeAccount: Sendable {
    let nonce: UInt32
    let consumers: UInt32
    let providers: UInt32
    let sufficients: UInt32
    let freePlancks: String
    let reservedPlancks: String
    let frozenPlancks: String
    let flagsPlancks: String
    let totalPlancks: String

    static func zero() -> PolkadotProbeAccount {
        PolkadotProbeAccount(
            nonce: 0,
            consumers: 0,
            providers: 0,
            sufficients: 0,
            freePlancks: "0",
            reservedPlancks: "0",
            frozenPlancks: "0",
            flagsPlancks: "0",
            totalPlancks: "0"
        )
    }
}

private struct PolkadotProbeHistoryEvent: Sendable {
    let txHash: String
    let direction: TransactionDirection
    let amountRaw: String
    let tokenSymbol: String
    let blockNumber: Int64
    let occurredAt: Date
    let counterparty: String
}

private struct PolkadotProbeTransfersResponse: Decodable {
    let items: [PolkadotProbeTransferRow]
}

private struct PolkadotProbeTransferRow: Decodable {
    let indexer: PolkadotProbeIndexer
    let from: String
    let to: String
    let balance: String
    let isNativeAsset: Bool?

    var syntheticHash: String {
        let extrinsic = indexer.extrinsicIndex.map(String.init) ?? "none"
        return "\(indexer.blockHash):\(indexer.eventIndex):\(extrinsic)"
    }
}

private struct PolkadotProbeIndexer: Decodable {
    let blockHeight: Int
    let blockHash: String
    let blockTime: Int64
    let eventIndex: Int
    let extrinsicIndex: Int?
}

private struct PolkadotProbeExtrinsicKey: Hashable, Sendable {
    let blockHeight: Int
    let extrinsicIndex: Int

    init(_ indexer: PolkadotProbeIndexer) {
        self.blockHeight = indexer.blockHeight
        self.extrinsicIndex = indexer.extrinsicIndex ?? -1
    }

    static func optional(_ indexer: PolkadotProbeIndexer) -> PolkadotProbeExtrinsicKey? {
        guard let extrinsicIndex = indexer.extrinsicIndex else { return nil }
        return PolkadotProbeExtrinsicKey(blockHeight: indexer.blockHeight, extrinsicIndex: extrinsicIndex)
    }

    private init(blockHeight: Int, extrinsicIndex: Int) {
        self.blockHeight = blockHeight
        self.extrinsicIndex = extrinsicIndex
    }
}

private struct PolkadotProbeExtrinsicResponse: Decodable {
    let hash: String
}

private enum PolkadotProbeError: Error {
    case noEndpoint
    case invalidAddress(String)
    case http(Int)
    case missing(String)
    case malformed(String)
}

private extension UInt32 {
    init(littleEndianBytes bytes: ArraySlice<UInt8>) {
        var value: UInt32 = 0
        for (offset, byte) in bytes.enumerated() {
            value |= UInt32(byte) << UInt32(offset * 8)
        }
        self = value
    }
}
