import Foundation
import OSLog

/// One per-chain balance snapshot. `nativeBalance` is in the chain's
/// base unit (e.g. BTC, ETH, SOL — not satoshis/wei/lamports).
///
/// `fiatBalance` is **optional** so the UI can honestly distinguish
/// "zero balance × known price = $0.00" from "I couldn't get the
/// price — `nil`". A `0` fiat is real $0.00; only `nil` triggers the
/// "Price unavailable" row.
struct ChainBalance: Hashable, Sendable {
    let chain: SupportedChain
    let address: String
    let nativeBalance: Decimal
    let fiatBalance: Decimal?
    let fiatCurrencyCode: String
    let isUsed: Bool
    let lastUpdated: Date
}

/// Enabled EVM balance refresh is live: the native coin plus every supported
/// ERC-20 is read through JSON-RPC using `eth_getBalance` and ERC-20
/// `balanceOf(address)`. Chain-specific history can be layered onto the same
/// background pipeline where a public, keyless endpoint exposes enough data.
actor WalletDataRefreshCoordinator {
    static let shared = WalletDataRefreshCoordinator()

    /// BUG-015: both modes always refresh prices so new balances get fiat
    /// immediately. History (Subscan / Electrum history / explorers) is the
    /// only heavy work gated by `.full`.
    enum RefreshMode: String, Sendable {
        /// Balances + unit prices + UTXOs. No transaction-history fetches.
        case balancesOnly
        /// Balances + prices + history for every wired chain.
        case full

        /// Always true — prices are not optional on any refresh mode.
        var includesPrices: Bool { true }

        /// History is full-mode only (expensive explorer / Electrum history).
        var includesHistory: Bool { self == .full }
    }

    private let enabledEVMChains: [SupportedChain] = [.ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync, .polygon, .bnbChain, .avalanche, .celo, .opBNB]
    private let scanner = PublicNodeEVMBalanceScanner()
    private let bitcoinScanner = BitcoinElectrumBalanceScanner()
    private let bitcoinCashScanner = BitcoinCashElectrumBalanceScanner()
    private let bitcoinFamilyRESTScanner = BitcoinFamilyRESTBalanceScanner()
    private let nearScanner = NearBalanceHistoryScanner()
    private let stellarScanner = StellarBalanceHistoryScanner()
    private let polkadotScanner = PolkadotBalanceHistoryScanner()
    private let solanaScanner = SolanaBalanceHistoryScanner()
    private let aptosScanner = AptosBalanceHistoryScanner()
    private let tronScanner = TronBalanceHistoryScanner()
    private let tonScanner = TonBalanceHistoryScanner()
    private let rippleScanner = RippleBalanceHistoryScanner()
    private let suiScanner = SuiBalanceHistoryScanner()

    private struct RefreshSlot {
        let token: UUID
        let task: Task<Void, Never>
    }
    private struct ChainScanResult: Sendable {
        let chain: SupportedChain
        let succeeded: Bool
    }

    private var refreshSlots: [UUID: RefreshSlot] = [:]

    func refresh(
        walletId: UUID,
        currencyCode: String,
        database: AppDatabase,
        userInitiated: Bool = false,
        mode: RefreshMode = .full,
        trigger: PortfolioRefreshTrigger = .automatic
    ) async {
        if let existing = refreshSlots[walletId] {
            if userInitiated {
                existing.task.cancel()
                await existing.task.value
                if refreshSlots[walletId]?.token == existing.token {
                    refreshSlots[walletId] = nil
                }
            } else {
                await existing.task.value
                return
            }
        }

        if Task.isCancelled {
            return
        }

        if let existing = refreshSlots[walletId] {
            await existing.task.value
            return
        }

        let token = UUID()
        let task = Task { [walletId, currencyCode, database, userInitiated, mode, trigger] in
            await self.performRefresh(
                walletId: walletId,
                currencyCode: currencyCode,
                database: database,
                userInitiated: userInitiated,
                mode: mode,
                trigger: trigger
            )
        }
        refreshSlots[walletId] = RefreshSlot(token: token, task: task)
        await task.value
        if refreshSlots[walletId]?.token == token {
            refreshSlots[walletId] = nil
        }
    }

    private func performRefresh(
        walletId: UUID,
        currencyCode: String,
        database: AppDatabase,
        userInitiated: Bool = false,
        mode: RefreshMode = .full,
        trigger: PortfolioRefreshTrigger = .automatic
    ) async {
        let refreshStart = Date()
        let portfolioRunId = await PortfolioHistoryCoordinator.shared.beginRun(
            walletId: walletId,
            trigger: trigger,
            refreshMode: mode.rawValue,
            database: database
        )
        let normalizedCurrency = currencyCode.uppercased()
        // BUG-015: never skip prices on balances-only — new deposits must
        // resolve fiat (disk USD×FX or live) without waiting for a full
        // history pass. History stays full-mode only.
        let includePrices = mode.includesPrices
        let includeHistory = mode.includesHistory
        var failedChains: Set<SupportedChain> = []
        var attemptedChains: Set<SupportedChain> = []
        var refreshedChains: Set<SupportedChain> = []
        DiagnosticsLogStore.shared.record(
            .info,
            category: "scanner",
            message: "Wallet data refresh started",
            metadata: [
                "walletId": walletId.uuidString,
                "currency": normalizedCurrency,
                "userInitiated": "\(userInitiated)",
                "mode": mode.rawValue
            ]
        )

        let walletRepository = WalletRepository(database: database)
        let addressLoadStart = Date()
        let addressSnapshots = (try? walletRepository.addresses(walletId: walletId)) ?? []
        let addressByChain = Dictionary(addressSnapshots.map { ($0.chain, $0) }, uniquingKeysWith: { first, _ in first })
        let customTokens = (try? CustomTokenRepository(database: database).fetchAll()) ?? []
        let customTokensByChain = Dictionary(grouping: customTokens, by: \.chain)
        DiagnosticsLogStore.shared.record(
            .debug,
            category: "scanner",
            message: "Wallet refresh addresses loaded",
            metadata: [
                "walletId": walletId.uuidString,
                "currency": normalizedCurrency,
                "mode": mode.rawValue,
                "addressRows": "\(addressSnapshots.count)",
                "addressChains": "\(addressByChain.count)",
                "customTokens": "\(customTokens.count)",
                "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: addressLoadStart)
            ]
        )

        let bitcoinScanner = self.bitcoinScanner
        let bitcoinCashScanner = self.bitcoinCashScanner
        let bitcoinFamilyRESTScanner = self.bitcoinFamilyRESTScanner
        let nearScanner = self.nearScanner
        let stellarScanner = self.stellarScanner
        let polkadotScanner = self.polkadotScanner
        let solanaScanner = self.solanaScanner
        let aptosScanner = self.aptosScanner
        let tronScanner = self.tronScanner
        let tonScanner = self.tonScanner
        let rippleScanner = self.rippleScanner
        let suiScanner = self.suiScanner
        let scanner = self.scanner
        var scanJobs: [@Sendable () async -> ChainScanResult] = []

        func appendScan(
            chain: SupportedChain,
            source: String,
            operation: @escaping @Sendable () async throws -> Void
        ) {
            attemptedChains.insert(chain)
            scanJobs.append {
                let succeeded = await Self.runScan(
                    chain: chain,
                    walletId: walletId,
                    currencyCode: normalizedCurrency,
                    userInitiated: userInitiated,
                    source: source,
                    operation: operation
                )
                return ChainScanResult(chain: chain, succeeded: succeeded)
            }
        }

        if addressByChain[.bitcoin] != nil {
            appendScan(
                chain: .bitcoin,
                source: "BitcoinElectrumBalanceScanner"
            ) {
                try await bitcoinScanner.scanAndPersist(
                    walletId: walletId,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if addressByChain[.bitcoinCash] != nil {
            appendScan(
                chain: .bitcoinCash,
                source: "BitcoinCashElectrumBalanceScanner"
            ) {
                try await bitcoinCashScanner.scanAndPersist(
                    walletId: walletId,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        for chain in [SupportedChain.litecoin, .dogecoin] {
            if let address = addressByChain[chain] {
                appendScan(
                    chain: chain,
                    source: "BitcoinFamilyRESTBalanceScanner"
                ) {
                    try await bitcoinFamilyRESTScanner.scanAndPersist(
                        walletId: walletId,
                        address: address,
                        currencyCode: normalizedCurrency,
                        database: database,
                        includePrices: includePrices,
                        includeHistory: includeHistory
                    )
                }
            }
        }

        if let address = addressByChain[.near] {
            appendScan(
                chain: .near,
                source: "NearBalanceHistoryScanner"
            ) {
                try await nearScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.stellar] {
            appendScan(
                chain: .stellar,
                source: "StellarBalanceHistoryScanner"
            ) {
                try await stellarScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.polkadot] {
            appendScan(
                chain: .polkadot,
                source: "PolkadotBalanceHistoryScanner"
            ) {
                try await polkadotScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.solana] {
            appendScan(
                chain: .solana,
                source: "SolanaBalanceHistoryScanner"
            ) {
                try await solanaScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    customTokens: customTokensByChain[.solana] ?? [],
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.aptos] {
            appendScan(
                chain: .aptos,
                source: "AptosBalanceHistoryScanner"
            ) {
                try await aptosScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.tron] {
            appendScan(
                chain: .tron,
                source: "TronBalanceHistoryScanner"
            ) {
                try await tronScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    customTokens: customTokensByChain[.tron] ?? [],
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.ton] {
            appendScan(
                chain: .ton,
                source: "TonBalanceHistoryScanner"
            ) {
                try await tonScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.ripple] {
            appendScan(
                chain: .ripple,
                source: "RippleBalanceHistoryScanner"
            ) {
                try await rippleScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        if let address = addressByChain[.sui] {
            appendScan(
                chain: .sui,
                source: "SuiBalanceHistoryScanner"
            ) {
                try await suiScanner.scanAndPersist(
                    walletId: walletId,
                    address: address,
                    currencyCode: normalizedCurrency,
                    database: database,
                    includePrices: includePrices,
                    includeHistory: includeHistory
                )
            }
        }

        for chain in enabledEVMChains {
            if let address = addressByChain[chain] {
                appendScan(
                    chain: chain,
                    source: "PublicNodeEVMBalanceScanner"
                ) {
                    try await scanner.scanAndPersist(
                        walletId: walletId,
                        address: address,
                        currencyCode: normalizedCurrency,
                        database: database,
                        customTokens: customTokensByChain[chain] ?? [],
                        includePrices: includePrices,
                        includeHistory: includeHistory
                    )
                }
            }
        }

        let scanBatchStart = Date()
        DiagnosticsLogStore.shared.record(
            .debug,
            category: "scanner",
            message: "Wallet chain scan batch started",
            metadata: [
                "walletId": walletId.uuidString,
                "currency": normalizedCurrency,
                "mode": mode.rawValue,
                "jobCount": "\(scanJobs.count)",
                "chains": attemptedChains.map { String(describing: $0) }.sorted().joined(separator: ",")
            ]
        )
        await withTaskGroup(of: ChainScanResult.self) { group in
            for job in scanJobs {
                group.addTask(operation: job)
            }
            for await result in group {
                if result.succeeded {
                    refreshedChains.insert(result.chain)
                } else {
                    failedChains.insert(result.chain)
                }
            }
        }
        DiagnosticsLogStore.shared.record(
            .info,
            category: "scanner",
            message: "Wallet chain scan batch finished",
            metadata: [
                "walletId": walletId.uuidString,
                "currency": normalizedCurrency,
                "mode": mode.rawValue,
                "jobCount": "\(scanJobs.count)",
                "refreshedChains": "\(refreshedChains.count)",
                "failedChains": failedChains.map { String(describing: $0) }.sorted().joined(separator: ","),
                "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: scanBatchStart)
            ]
        )

        if Task.isCancelled {
            await PortfolioHistoryCoordinator.shared.cancelRun(portfolioRunId, database: database)
            DiagnosticsLogStore.shared.record(
                .info,
                category: "scanner",
                message: "Wallet data refresh cancelled",
                metadata: [
                    "walletId": walletId.uuidString,
                    "currency": normalizedCurrency,
                    "mode": mode.rawValue,
                    "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: refreshStart)
                ]
            )
            return
        }

        if !attemptedChains.isEmpty {
            let rebuildStart = Date()
            let rebuilt = try? ChainStateRepository(database: database).rebuild(
                walletId: walletId,
                fiatCurrencyCode: normalizedCurrency,
                onlyChains: attemptedChains,
                failedChains: failedChains,
                interim: false
            )
            DiagnosticsLogStore.shared.record(
                rebuilt == nil ? .warning : .debug,
                category: "scanner",
                message: "Wallet chain state rebuild finished",
                metadata: [
                    "walletId": walletId.uuidString,
                    "currency": normalizedCurrency,
                    "mode": mode.rawValue,
                    "chainCount": "\(attemptedChains.count)",
                    "failedChains": failedChains.map { String(describing: $0) }.sorted().joined(separator: ","),
                    "outcome": rebuilt == nil ? "failed" : "succeeded",
                    "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: rebuildStart)
                ]
            )
        }
        await PortfolioHistoryCoordinator.shared.finishRun(
            runId: portfolioRunId,
            walletId: walletId,
            refreshMode: mode.rawValue,
            attemptedChains: attemptedChains,
            successfulChains: refreshedChains,
            failedChains: failedChains,
            displayCurrencyCode: normalizedCurrency,
            database: database
        )
        await PendingTransactionMonitor.shared.kick(database: database)
        DiagnosticsLogStore.shared.record(
            .info,
            category: "scanner",
            message: "Wallet data refresh finished",
            metadata: [
                "walletId": walletId.uuidString,
                "currency": normalizedCurrency,
                "addressChains": "\(addressByChain.count)",
                "attemptedChains": "\(attemptedChains.count)",
                "refreshedChains": "\(refreshedChains.count)",
                "failedChains": failedChains.map { String(describing: $0) }.sorted().joined(separator: ","),
                "mode": mode.rawValue,
                "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: refreshStart)
            ]
        )
    }

    private nonisolated static func runScan(
        chain: SupportedChain,
        walletId: UUID,
        currencyCode: String,
        userInitiated: Bool,
        source: String,
        operation: @Sendable () async throws -> Void
    ) async -> Bool {
        let start = Date()
        let chainName = String(describing: chain)
        DiagnosticsLogStore.shared.record(
            .info,
            category: "scanner",
            message: "Chain scan started",
            metadata: [
                "walletId": walletId.uuidString,
                "chain": chainName,
                "currency": currencyCode,
                "source": source,
                "userInitiated": "\(userInitiated)"
            ]
        )
        do {
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
            DiagnosticsLogStore.shared.record(
                .info,
                category: "scanner",
                message: "Chain scan finished",
                metadata: [
                    "walletId": walletId.uuidString,
                    "chain": chainName,
                    "currency": currencyCode,
                    "source": source,
                    "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: start)
                ]
            )
            return true
        } catch is CancellationError {
            DiagnosticsLogStore.shared.record(
                .info,
                category: "scanner",
                message: "Chain scan cancelled",
                metadata: [
                    "walletId": walletId.uuidString,
                    "chain": chainName,
                    "currency": currencyCode,
                    "source": source,
                    "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: start)
                ]
            )
            return false
        } catch {
            DiagnosticsLogStore.shared.record(
                .error,
                category: "scanner",
                message: "Chain scan failed",
                metadata: [
                    "walletId": walletId.uuidString,
                    "chain": chainName,
                    "currency": currencyCode,
                    "source": source,
                    "elapsedMs": DiagnosticsLogStore.elapsedMilliseconds(since: start),
                    "error": String(describing: error)
                ]
            )
            return false
        }
    }
}

private actor StellarBalanceHistoryScanner {
    private let client = RPCClient.shared
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "stellar-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .stellar else { return }

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: [SupportedChain.stellar.ticker],
                currencyCode: currencyCode
            )
            : [:]
        async let accountTask = account(address: address.address)
        async let paymentsTask: [StellarPaymentRecord] = includeHistory
            ? safePayments(address: address.address)
            : []
        async let transactionsTask: [StellarTransactionRecord] = includeHistory
            ? safeTransactions(address: address.address)
            : []

        let account = try await accountTask
        let priceMap = await pricesTask
        let payments = await paymentsTask
        let transactions = await transactionsTask

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.stellar.ticker,
            tokenContract: nil,
            decimals: SupportedChain.stellar.nativeDecimals,
            rawBalance: account.rawBalance,
            fiatValueCached: fiatValue(rawBalance: account.rawBalance, prices: priceMap),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = account.accountExists || EVMHexQuantity.isPositiveDecimalString(account.rawBalance)
        let txByHash = Dictionary(uniqueKeysWithValues: transactions.map { ($0.hash, $0) })
        let events = payments
            .compactMap { decode(payment: $0, owner: address.address, transactions: txByHash) }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(50)

        if !events.isEmpty {
            isUsed = true
        }
        for event in events {
            try txRepo.upsertTransaction(
                addressId: address.id,
                txHash: event.txHash,
                direction: event.direction,
                amountRaw: event.amount,
                tokenSymbol: event.tokenSymbol,
                tokenContract: nil,
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
            onlyChains: [.stellar],
            failedChains: [],
            interim: false
        )
    }

    private func account(address: String) async throws -> StellarAccountBalance {
        do {
            let data = try await horizonGET(path: "accounts/\(address)")
            let response = try JSONDecoder().decode(StellarAccountResponse.self, from: data)
            let native = response.balances.first { $0.assetType == "native" }?.balance ?? "0"
            return StellarAccountBalance(
                rawBalance: Self.rawUnits(decimalAmount: native, decimals: SupportedChain.stellar.nativeDecimals),
                accountExists: true
            )
        } catch {
            if Self.isHorizonNotFound(error) {
                return StellarAccountBalance(rawBalance: "0", accountExists: false)
            }
            throw error
        }
    }

    private func safePayments(address: String) async -> [StellarPaymentRecord] {
        do {
            let data = try await horizonGET(
                path: "accounts/\(address)/payments",
                query: [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "order", value: "desc")
                ]
            )
            let response = try JSONDecoder().decode(StellarPaymentsResponse.self, from: data)
            return response.embedded.records
        } catch {
            if !Self.isHorizonNotFound(error) {
                log.debug("Stellar payments failed: \(String(describing: error), privacy: .public)")
            }
            return []
        }
    }

    private func safeTransactions(address: String) async -> [StellarTransactionRecord] {
        do {
            let data = try await horizonGET(
                path: "accounts/\(address)/transactions",
                query: [
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "order", value: "desc")
                ]
            )
            let response = try JSONDecoder().decode(StellarTransactionsResponse.self, from: data)
            return response.embedded.records
        } catch {
            if !Self.isHorizonNotFound(error) {
                log.debug("Stellar transactions failed: \(String(describing: error), privacy: .public)")
            }
            return []
        }
    }

    private func horizonGET(path: String, query: [URLQueryItem] = []) async throws -> Data {
        do {
            return try await client.callREST(chain: .stellar, path: path, query: query)
        } catch {
            log.debug("Stellar registered endpoint failed, falling back to SDF Horizon: \(String(describing: error), privacy: .public)")
            return try await directHorizonGET(path: path, query: query)
        }
    }

    private func directHorizonGET(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: "https://horizon.stellar.org")
        components?.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw RPCError.invalidResponse("Failed to compose Stellar Horizon URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.apertureData(
            for: request,
            family: "histories",
            operation: "Stellar Horizon \(path)",
            metadata: ["chain": "stellar", "source": "StellarBalanceHistoryScanner"]
        )
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404 {
                throw RPCError.invalidResponse("HTTP 404 from xlm-horizon")
            }
            if [408, 429, 502, 503, 504].contains(http.statusCode)
                || (520...527).contains(http.statusCode) {
                throw RPCError.network("HTTP \(http.statusCode) from xlm-horizon")
            }
            throw RPCError.invalidResponse("HTTP \(http.statusCode) from xlm-horizon")
        }
        return data
    }

    private func decode(
        payment: StellarPaymentRecord,
        owner: String,
        transactions: [String: StellarTransactionRecord]
    ) -> StellarHistoryEvent? {
        guard payment.transactionSuccessful ?? true else { return nil }

        let owner = owner.uppercased()
        let from: String?
        let to: String?
        let amount: String?

        switch payment.type {
        case "payment", "path_payment_strict_receive", "path_payment_strict_send":
            guard payment.assetType == nil || payment.assetType == "native" else { return nil }
            from = payment.from
            to = payment.to
            amount = payment.amount
        case "create_account":
            from = payment.funder
            to = payment.account
            amount = payment.startingBalance
        default:
            return nil
        }

        guard let txHash = payment.transactionHash,
              let rawAmount = amount,
              Decimal(string: rawAmount) ?? 0 > 0 else {
            return nil
        }

        let normalizedFrom = from?.uppercased()
        let normalizedTo = to?.uppercased()
        let direction: TransactionDirection
        let counterparty: String
        if normalizedFrom == owner, normalizedTo == owner {
            direction = .internal
            counterparty = ""
        } else if normalizedFrom == owner {
            direction = .outgoing
            counterparty = to ?? ""
        } else if normalizedTo == owner {
            direction = .incoming
            counterparty = from ?? ""
        } else {
            return nil
        }

        let tx = transactions[txHash]
        return StellarHistoryEvent(
            txHash: txHash,
            direction: direction,
            amount: Self.normalizedDecimal(rawAmount),
            tokenSymbol: SupportedChain.stellar.ticker,
            blockNumber: tx?.ledger ?? payment.ledgerFromOperationID,
            occurredAt: payment.createdAtDate ?? tx?.createdAtDate ?? Date(),
            status: (tx?.successful ?? true) ? .confirmed : .failed,
            counterparty: counterparty,
            fee: tx?.feeNative
        )
    }

    private func fiatValue(
        rawBalance: String,
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) -> Decimal? {
        guard let price = prices[SupportedChain.stellar.ticker] else { return nil }
        guard let amount = EVMHexQuantity.decimalAmount(
            rawBalance: rawBalance,
            decimals: SupportedChain.stellar.nativeDecimals
        ) else { return nil }
        return amount * price.amount
    }

    private static func rawUnits(decimalAmount: String, decimals: Int) -> String {
        guard let amount = Decimal(string: decimalAmount) else { return "0" }
        var scale = Decimal(1)
        for _ in 0..<max(0, decimals) { scale *= 10 }
        let value = amount * scale
        return NSDecimalNumber(decimal: value).rounding(
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

    private static func normalizedDecimal(_ value: String) -> String {
        guard let decimal = Decimal(string: value) else { return value }
        return NSDecimalNumber(decimal: decimal).stringValue
    }

    private static func isHorizonNotFound(_ error: any Error) -> Bool {
        if RPCError.isHTTPNotFound(error) { return true }
        guard let rpc = error as? RPCError,
              case .invalidResponse(let message) = rpc else { return false }
        let lower = message.lowercased()
        return lower.contains("resource missing") || lower.contains("not found")
    }
}

private struct StellarAccountBalance: Sendable {
    let rawBalance: String
    let accountExists: Bool
}

private struct StellarHistoryEvent: Sendable {
    let txHash: String
    let direction: TransactionDirection
    let amount: String
    let tokenSymbol: String
    let blockNumber: Int64?
    let occurredAt: Date
    let status: TransactionStatus
    let counterparty: String
    let fee: String?
}

private struct StellarAccountResponse: Decodable {
    let balances: [StellarBalanceRecord]
}

private struct StellarBalanceRecord: Decodable {
    let balance: String
    let assetType: String

    enum CodingKeys: String, CodingKey {
        case balance
        case assetType = "asset_type"
    }
}

private struct StellarPaymentsResponse: Decodable {
    let embedded: Embedded

    enum CodingKeys: String, CodingKey {
        case embedded = "_embedded"
    }

    struct Embedded: Decodable {
        let records: [StellarPaymentRecord]
    }
}

private struct StellarPaymentRecord: Decodable, Sendable {
    let id: String
    let type: String
    let createdAt: String
    let transactionHash: String?
    let transactionSuccessful: Bool?
    let sourceAccount: String?
    let from: String?
    let to: String?
    let funder: String?
    let account: String?
    let amount: String?
    let startingBalance: String?
    let assetType: String?

    var createdAtDate: Date? {
        ISO8601DateFormatter.apertureStellarDate(from: createdAt)
    }

    var ledgerFromOperationID: Int64? {
        guard let raw = Int64(id) else { return nil }
        return raw >> 32
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case createdAt = "created_at"
        case transactionHash = "transaction_hash"
        case transactionSuccessful = "transaction_successful"
        case sourceAccount = "source_account"
        case from
        case to
        case funder
        case account
        case amount
        case startingBalance = "starting_balance"
        case assetType = "asset_type"
    }
}

private struct StellarTransactionsResponse: Decodable {
    let embedded: Embedded

    enum CodingKeys: String, CodingKey {
        case embedded = "_embedded"
    }

    struct Embedded: Decodable {
        let records: [StellarTransactionRecord]
    }
}

private struct StellarTransactionRecord: Decodable, Sendable {
    let hash: String
    let ledger: Int64?
    let createdAt: String
    let successful: Bool?
    let feeCharged: String?

    var createdAtDate: Date? {
        ISO8601DateFormatter.apertureStellarDate(from: createdAt)
    }

    var feeNative: String? {
        guard let feeCharged, let fee = Decimal(string: feeCharged) else { return nil }
        let native = fee / Decimal(10_000_000)
        return NSDecimalNumber(decimal: native).stringValue
    }

    enum CodingKeys: String, CodingKey {
        case hash
        case ledger
        case createdAt = "created_at"
        case successful
        case feeCharged = "fee_charged"
    }
}

private extension ISO8601DateFormatter {
    static func apertureStellarDate(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

private actor PolkadotBalanceHistoryScanner {
    private let history = PolkadotStatescanClient()
    private let assetHub = PolkadotAssetHubBalanceClient()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "polkadot-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .polkadot else { return }

        let assetTokens = PolkadotAssetRegistry.tokens.sorted { $0.symbol < $1.symbol }
        let symbols = Array(Set(([SupportedChain.polkadot.ticker] + assetTokens.map(\.symbol)).map { $0.uppercased() })).sorted()

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let assetHubNativeTask = safeAssetHubNativeAccount(address: address.address)
        async let assetHubTask = safeAssetHubBalances(address: address.address, assets: assetTokens)
        async let historyTask: [PolkadotHistoryEvent] = includeHistory
            ? safeHistory(address: address.address)
            : []

        let assetHubNative = await assetHubNativeTask
        let assetHubBalances = await assetHubTask
        let priceMap = await pricesTask
        let events = await historyTask
        // The send path targets Polkadot Asset Hub. Do not report relay-chain
        // DOT as spendable here, or the send flow can offer funds it cannot
        // submit with the Asset Hub signer/broadcaster.
        let nativeTotalPlancks = assetHubNative.totalPlancks

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.polkadot.ticker,
            tokenContract: nil,
            decimals: SupportedChain.polkadot.nativeDecimals,
            rawBalance: nativeTotalPlancks,
            fiatValueCached: fiatValue(
                rawBalance: nativeTotalPlancks,
                decimals: SupportedChain.polkadot.nativeDecimals,
                symbol: SupportedChain.polkadot.ticker,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = assetHubNative.accountExists
            || EVMHexQuantity.isPositiveDecimalString(nativeTotalPlancks)
            || !events.isEmpty
        for balance in assetHubBalances {
            if EVMHexQuantity.isPositiveDecimalString(balance.rawBalance) {
                isUsed = true
            }
            try txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: balance.entry.symbol,
                tokenContract: String(balance.entry.assetId),
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

        for event in events.prefix(50) {
            try txRepo.upsertTransaction(
                addressId: address.id,
                txHash: event.txHash,
                direction: event.direction,
                amountRaw: event.amount,
                tokenSymbol: SupportedChain.polkadot.ticker,
                tokenContract: nil,
                blockNumber: event.blockNumber,
                occurredAt: event.occurredAt,
                status: .confirmed,
                counterparty: event.counterparty,
                feeRaw: nil,
                save: false
            )
        }

        try txRepo.markScanComplete(addressId: address.id, isUsed: isUsed, save: false)
        try txRepo.flush()

        _ = try ChainStateRepository(database: database).rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: [.polkadot],
            failedChains: [],
            interim: false
        )
    }

    private func safeHistory(address: String) async -> [PolkadotHistoryEvent] {
        do {
            return try await history.nativeTransfers(address: address, limit: 50)
        } catch {
            log.debug("Polkadot history failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func safeAssetHubBalances(
        address: String,
        assets: [PolkadotAssetRegistry.Entry]
    ) async -> [PolkadotAssetHubBalance] {
        do {
            return try await assetHub.balances(address: address, assets: assets)
        } catch {
            log.debug("Polkadot Asset Hub balances failed: \(String(describing: error), privacy: .public)")
            return assets.map { PolkadotAssetHubBalance(entry: $0, rawBalance: "0") }
        }
    }

    private func safeAssetHubNativeAccount(address: String) async -> PolkadotAccountState {
        do {
            return try await assetHub.nativeAccount(address: address)
        } catch {
            log.debug("Polkadot Asset Hub native DOT failed: \(String(describing: error), privacy: .public)")
            return .zero(accountExists: false)
        }
    }

    private func fiatValue(
        rawBalance: String,
        decimals: Int,
        symbol: String,
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) -> Decimal? {
        guard let price = prices[symbol.uppercased()] else { return nil }
        guard let amount = EVMHexQuantity.decimalAmount(
            rawBalance: rawBalance,
            decimals: decimals
        ) else { return nil }
        return amount * price.amount
    }
}

private actor PolkadotAssetHubBalanceClient {
    private let endpoints = [
        URL(string: "https://polkadot-asset-hub-rpc.polkadot.io")!,
        URL(string: "https://statemint.api.onfinality.io/public")!,
        URL(string: "https://asset-hub-polkadot-rpc.n.dwellir.com")!,
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
            configuration.httpMaximumConnectionsPerHost = 6
            self.session = URLSession(configuration: configuration)
        }
    }

    func nativeAccount(address: String) async throws -> PolkadotAccountState {
        guard let accountId = SS58.decodeAccountId(address) else {
            throw PolkadotBalanceHistoryError.invalidAddress(address)
        }
        let storageKey = PolkadotCodec.systemAccountStorageKey(accountId: accountId)
        guard let storage = try await stateGetStorage(
            storageKey,
            operation: "Polkadot Asset Hub native DOT state_getStorage"
        ) else {
            return .zero(accountExists: false)
        }
        var decoded = try PolkadotCodec.decodeAccountInfo(hex: storage)
        decoded.accountExists = true
        return decoded
    }

    func balances(
        address: String,
        assets: [PolkadotAssetRegistry.Entry]
    ) async throws -> [PolkadotAssetHubBalance] {
        guard let accountId = SS58.decodeAccountId(address) else {
            throw PolkadotBalanceHistoryError.invalidAddress(address)
        }

        return try await withThrowingTaskGroup(of: PolkadotAssetHubBalance.self) { group in
            for asset in assets {
                group.addTask {
                    let raw = try await self.balance(accountId: accountId, asset: asset)
                    return PolkadotAssetHubBalance(entry: asset, rawBalance: raw)
                }
            }

            var rows: [PolkadotAssetHubBalance] = []
            rows.reserveCapacity(assets.count)
            for try await row in group {
                rows.append(row)
            }
            return rows.sorted { $0.entry.symbol < $1.entry.symbol }
        }
    }

    private func balance(
        accountId: [UInt8],
        asset: PolkadotAssetRegistry.Entry
    ) async throws -> String {
        let storageKey = assetAccountStorageKey(assetId: asset.assetId, accountId: accountId)
        guard let storage = try await stateGetStorage(
            storageKey,
            operation: "Polkadot Asset Hub \(asset.symbol) state_getStorage"
        ) else { return "0" }
        let bytes = try hexBytes(storage)
        guard bytes.count >= 16 else {
            throw PolkadotBalanceHistoryError.malformed("Asset Hub account storage too short: \(bytes.count) bytes")
        }
        return decimalStringLittleEndian(Array(bytes[0..<16]))
    }

    private func assetAccountStorageKey(assetId: UInt32, accountId: [UInt8]) -> String {
        var bytes: [UInt8] = []
        let assetBytes = [
            UInt8(assetId & 0xff),
            UInt8((assetId >> 8) & 0xff),
            UInt8((assetId >> 16) & 0xff),
            UInt8((assetId >> 24) & 0xff),
        ]
        bytes.reserveCapacity(32 + 16 + assetBytes.count + 16 + accountId.count)
        bytes.append(contentsOf: Twox.twox128(Array("Assets".utf8)))
        bytes.append(contentsOf: Twox.twox128(Array("Account".utf8)))
        bytes.append(contentsOf: BLAKE2b.hash(assetBytes, outlen: 16))
        bytes.append(contentsOf: assetBytes)
        bytes.append(contentsOf: BLAKE2b.hash(accountId, outlen: 16))
        bytes.append(contentsOf: accountId)
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func stateGetStorage(_ key: String, operation: String) async throws -> String? {
        var lastError: Error?
        for endpoint in endpoints {
            do {
                requestID += 1
                let body: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "method": "state_getStorage",
                    "params": [key],
                ]
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await session.apertureData(
                    for: request,
                    family: "balances",
                    operation: operation,
                    metadata: [
                        "chain": "polkadot",
                        "source": "PolkadotAssetHubBalanceClient",
                        "endpoint": endpoint.host ?? endpoint.absoluteString
                    ]
                )
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw PolkadotBalanceHistoryError.http(http.statusCode)
                }
                let decoded = try JSONDecoder().decode(PolkadotRPCStorageResponse.self, from: data)
                if let error = decoded.error {
                    throw PolkadotBalanceHistoryError.malformed(error.message)
                }
                return decoded.result
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PolkadotBalanceHistoryError.noEndpoint
    }

    private func hexBytes(_ hex: String) throws -> [UInt8] {
        var cleaned = hex
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        guard cleaned.count.isMultiple(of: 2) else {
            throw PolkadotBalanceHistoryError.malformed("odd hex length")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                throw PolkadotBalanceHistoryError.malformed("invalid hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private func decimalStringLittleEndian(_ bytes: [UInt8]) -> String {
        let hex = bytes.reversed().map { String(format: "%02x", $0) }.joined()
        return (try? EVMHexQuantity.decimalString(from: hex)) ?? "0"
    }
}

private actor PolkadotStatescanClient {
    private let baseURL = URL(string: "https://polkadot-api.statescan.io")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 25
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 8
            self.session = URLSession(configuration: configuration)
        }
    }

    func account(address: String) async throws -> PolkadotAccountState {
        let response = try await get(
            PolkadotStatescanAccountResponse.self,
            path: "accounts/\(address)"
        )
        let free = response.data?.free ?? "0"
        let reserved = response.data?.reserved ?? "0"
        let total = PolkadotCodec.addDecimalStrings(free, reserved)
        let exists = EVMHexQuantity.isPositiveDecimalString(total)
            || (response.detail?.providers ?? 0) > 0
            || (response.transfersCount ?? 0) > 0
            || (response.extrinsicsCount ?? 0) > 0
        return PolkadotAccountState(
            totalPlancks: total,
            freePlancks: free,
            reservedPlancks: reserved,
            nonce: response.detail?.nonce ?? 0,
            consumers: response.detail?.consumers ?? 0,
            providers: response.detail?.providers ?? 0,
            sufficients: response.detail?.sufficients ?? 0,
            accountExists: exists
        )
    }

    func nativeTransfers(address: String, limit: Int) async throws -> [PolkadotHistoryEvent] {
        let pageSize = min(max(limit, 1), 100)
        let response = try await get(
            PolkadotTransfersResponse.self,
            path: "accounts/\(address)/transfers",
            query: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "pageSize", value: "\(pageSize)")
            ]
        )
        let nativeRows = response.items.filter { $0.isNativeAsset ?? true }
        let hashes = await extrinsicHashes(for: nativeRows)
        let owner = address.lowercased()

        return nativeRows.compactMap { row in
            guard EVMHexQuantity.isPositiveDecimalString(row.balance) else { return nil }

            let from = row.from?.lowercased()
            let to = row.to?.lowercased()
            let direction: TransactionDirection
            let counterparty: String
            if from == owner, to == owner {
                direction = .internal
                counterparty = ""
            } else if from == owner {
                direction = .outgoing
                counterparty = row.to ?? ""
            } else if to == owner {
                direction = .incoming
                counterparty = row.from ?? ""
            } else {
                return nil
            }

            let key = PolkadotExtrinsicKey.optional(row.indexer)
            let txHash = key.flatMap { hashes[$0] } ?? row.syntheticID
            return PolkadotHistoryEvent(
                txHash: txHash,
                direction: direction,
                amount: EVMHexQuantity.displayAmount(
                    rawBalance: row.balance,
                    decimals: SupportedChain.polkadot.nativeDecimals
                ) ?? row.balance,
                blockNumber: row.indexer.blockHeight,
                occurredAt: row.indexer.date,
                counterparty: counterparty
            )
        }
        .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func extrinsicHashes(for rows: [PolkadotTransferRow]) async -> [PolkadotExtrinsicKey: String] {
        await withTaskGroup(of: (PolkadotExtrinsicKey, String)?.self) { group in
            var seen = Set<PolkadotExtrinsicKey>()
            for row in rows {
                guard let key = PolkadotExtrinsicKey.optional(row.indexer),
                      seen.insert(key).inserted else {
                    continue
                }
                group.addTask {
                    do {
                        let hash = try await self.extrinsicHash(key: key)
                        return (key, hash)
                    } catch {
                        return nil
                    }
                }
            }

            var result: [PolkadotExtrinsicKey: String] = [:]
            for await item in group {
                if let item {
                    result[item.0] = item.1
                }
            }
            return result
        }
    }

    private func extrinsicHash(key: PolkadotExtrinsicKey) async throws -> String {
        let response = try await get(
            PolkadotExtrinsicResponse.self,
            path: "extrinsics/\(key.blockHeight)-\(key.extrinsicIndex)"
        )
        guard let hash = response.hash, !hash.isEmpty else {
            throw PolkadotBalanceHistoryError.missing("extrinsic.hash")
        }
        return hash
    }

    private func get<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                components?.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                components?.queryItems = query.isEmpty ? nil : query
                guard let url = components?.url else {
                    throw PolkadotBalanceHistoryError.malformed("Failed to compose Statescan URL")
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await session.apertureData(
                    for: request,
                    family: "histories",
                    operation: "Statescan \(path)",
                    metadata: [
                        "chain": "polkadot",
                        "source": "PolkadotStatescanClient",
                        "attempt": "\(attempt + 1)"
                    ]
                )
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw PolkadotBalanceHistoryError.http(http.statusCode)
                }
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? PolkadotBalanceHistoryError.noEndpoint
    }
}

private enum PolkadotCodec {
    static func systemAccountStorageKey(accountId: [UInt8]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16 + 16 + 16 + accountId.count)
        bytes.append(contentsOf: Twox.twox128(Array("System".utf8)))
        bytes.append(contentsOf: Twox.twox128(Array("Account".utf8)))
        bytes.append(contentsOf: BLAKE2b.hash(accountId, outlen: 16))
        bytes.append(contentsOf: accountId)
        return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decodeAccountInfo(hex: String) throws -> PolkadotAccountState {
        let bytes = try hexBytes(hex)
        guard bytes.count >= 64 else {
            throw PolkadotBalanceHistoryError.malformed("System.Account storage too short: \(bytes.count) bytes")
        }

        let nonce = UInt32(littleEndianBytes: Array(bytes[0..<4]))
        let consumers = UInt32(littleEndianBytes: Array(bytes[4..<8]))
        let providers = UInt32(littleEndianBytes: Array(bytes[8..<12]))
        let sufficients = UInt32(littleEndianBytes: Array(bytes[12..<16]))
        let free = decimalStringLittleEndian(Array(bytes[16..<32]))
        let reserved = decimalStringLittleEndian(Array(bytes[32..<48]))
        let total = addDecimalStrings(free, reserved)
        return PolkadotAccountState(
            totalPlancks: total,
            freePlancks: free,
            reservedPlancks: reserved,
            nonce: nonce,
            consumers: consumers,
            providers: providers,
            sufficients: sufficients,
            accountExists: EVMHexQuantity.isPositiveDecimalString(total)
                || nonce > 0
                || consumers > 0
                || providers > 0
                || sufficients > 0
        )
    }

    static func addDecimalStrings(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.reversed().map { Int(String($0)) ?? 0 }
        let right = rhs.reversed().map { Int(String($0)) ?? 0 }
        let count = max(left.count, right.count)
        var carry = 0
        var result: [Int] = []
        result.reserveCapacity(count + 1)
        for index in 0..<count {
            let sum = (index < left.count ? left[index] : 0)
                + (index < right.count ? right[index] : 0)
                + carry
            result.append(sum % 10)
            carry = sum / 10
        }
        while carry > 0 {
            result.append(carry % 10)
            carry /= 10
        }
        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result.reversed().map(String.init).joined()
    }

    private static func decimalStringLittleEndian(_ bytes: [UInt8]) -> String {
        let hex = bytes.reversed().map { String(format: "%02x", $0) }.joined()
        return (try? EVMHexQuantity.decimalString(from: hex)) ?? "0"
    }

    private static func hexBytes(_ hex: String) throws -> [UInt8] {
        var cleaned = hex
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        guard cleaned.count.isMultiple(of: 2) else {
            throw PolkadotBalanceHistoryError.malformed("odd hex length")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                throw PolkadotBalanceHistoryError.malformed("invalid hex")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

private struct PolkadotAccountState: Sendable {
    let totalPlancks: String
    let freePlancks: String
    let reservedPlancks: String
    let nonce: UInt32
    let consumers: UInt32
    let providers: UInt32
    let sufficients: UInt32
    var accountExists: Bool

    static func zero(accountExists: Bool) -> PolkadotAccountState {
        PolkadotAccountState(
            totalPlancks: "0",
            freePlancks: "0",
            reservedPlancks: "0",
            nonce: 0,
            consumers: 0,
            providers: 0,
            sufficients: 0,
            accountExists: accountExists
        )
    }
}

private struct PolkadotAssetHubBalance: Sendable {
    let entry: PolkadotAssetRegistry.Entry
    let rawBalance: String
}

private struct PolkadotHistoryEvent: Sendable {
    let txHash: String
    let direction: TransactionDirection
    let amount: String
    let blockNumber: Int64?
    let occurredAt: Date
    let counterparty: String
}

private struct PolkadotRPCStorageResponse: Decodable {
    let result: String?
    let error: PolkadotRPCErrorResponse?
}

private struct PolkadotRPCErrorResponse: Decodable {
    let message: String
}

private struct PolkadotStatescanAccountResponse: Decodable {
    let data: DataBody?
    let detail: DetailBody?
    let transfersCount: Int?
    let extrinsicsCount: Int?

    struct DataBody: Decodable {
        let free: String?
        let reserved: String?
    }

    struct DetailBody: Decodable {
        let nonce: UInt32?
        let consumers: UInt32?
        let providers: UInt32?
        let sufficients: UInt32?
    }
}

private struct PolkadotTransfersResponse: Decodable {
    let items: [PolkadotTransferRow]
}

private struct PolkadotTransferRow: Decodable, Sendable {
    let indexer: PolkadotIndexer
    let from: String?
    let to: String?
    let balance: String
    let isNativeAsset: Bool?

    var syntheticID: String {
        "\(indexer.blockHash):\(indexer.eventIndex ?? -1):\(indexer.extrinsicIndex ?? -1)"
    }
}

private struct PolkadotIndexer: Decodable, Sendable {
    let blockHeight: Int64
    let blockHash: String
    let blockTime: Int64?
    let eventIndex: Int?
    let extrinsicIndex: Int?

    var date: Date {
        if let blockTime, blockTime > 0 {
            return Date(timeIntervalSince1970: TimeInterval(blockTime) / 1_000)
        }
        return Date()
    }
}

private struct PolkadotExtrinsicKey: Hashable, Sendable {
    let blockHeight: Int64
    let extrinsicIndex: Int

    static func optional(_ indexer: PolkadotIndexer) -> PolkadotExtrinsicKey? {
        guard let extrinsicIndex = indexer.extrinsicIndex else { return nil }
        return PolkadotExtrinsicKey(blockHeight: indexer.blockHeight, extrinsicIndex: extrinsicIndex)
    }
}

private struct PolkadotExtrinsicResponse: Decodable {
    let hash: String?
}

private enum PolkadotBalanceHistoryError: Error, CustomStringConvertible {
    case noEndpoint
    case invalidAddress(String)
    case http(Int)
    case missing(String)
    case malformed(String)

    var description: String {
        switch self {
        case .noEndpoint:
            return "No Polkadot endpoint returned a response"
        case .invalidAddress(let address):
            return "Invalid Polkadot address: \(address)"
        case .http(let status):
            return "Polkadot HTTP \(status)"
        case .missing(let field):
            return "Missing Polkadot field: \(field)"
        case .malformed(let reason):
            return "Malformed Polkadot response: \(reason)"
        }
    }
}

private actor SolanaBalanceHistoryScanner {
    private let rpc = RPCClient.shared
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "solana-balance-history")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        customTokens: [CustomTokenSnapshot] = [],
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        guard address.chain == .solana else { return }

        let tokens = await supportedTokens(customTokens: customTokens)
        let symbols = Array(Set(([SupportedChain.solana.ticker] + tokens.map(\.entry.symbol)).map { $0.uppercased() })).sorted()

        async let pricesTask: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let nativeTask = nativeBalance(address: address.address)
        async let tokenTask = tokenBalances(owner: address.address, tokens: tokens)

        let native = try await nativeTask
        let tokenBalances = await tokenTask
        async let historyTask: [SolanaHistoryEvent] = includeHistory
            ? safeHistory(
                owner: address.address,
                activeTokenAccounts: tokenBalances.flatMap(\.tokenAccounts),
                tokens: tokens
            )
            : []

        let priceMap = await pricesTask
        let events = await historyTask

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: SupportedChain.solana.ticker,
            tokenContract: nil,
            decimals: SupportedChain.solana.nativeDecimals,
            rawBalance: native.lamports,
            fiatValueCached: fiatValue(
                rawBalance: native.lamports,
                decimals: SupportedChain.solana.nativeDecimals,
                symbol: SupportedChain.solana.ticker,
                prices: priceMap
            ),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = native.accountExists || EVMHexQuantity.isPositiveDecimalString(native.lamports)
        for balance in tokenBalances {
            if EVMHexQuantity.isPositiveDecimalString(balance.rawBalance) {
                isUsed = true
            }
            try txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: balance.token.entry.symbol,
                tokenContract: balance.token.mint,
                decimals: balance.token.entry.decimals,
                rawBalance: balance.rawBalance,
                fiatValueCached: fiatValue(
                    rawBalance: balance.rawBalance,
                    decimals: balance.token.entry.decimals,
                    symbol: balance.token.entry.symbol,
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
            onlyChains: [.solana],
            failedChains: [],
            interim: false
        )
    }

    private func nativeBalance(address: String) async throws -> SolanaNativeBalance {
        let data = try await rpc.callJSONResultData(
            chain: .solana,
            method: "getBalance",
            params: [address, ["commitment": "confirmed"]]
        )
        let response = try JSONDecoder().decode(SolanaGetBalanceResult.self, from: data)
        return SolanaNativeBalance(
            lamports: String(response.value),
            accountExists: response.value > 0
        )
    }

    private func supportedTokens(customTokens: [CustomTokenSnapshot]) async -> [SolanaSupportedToken] {
        var byMint: [String: SolanaSupportedToken] = [:]
        byMint.reserveCapacity(SolanaTokenRegistry.mints.count + customTokens.count)

        for (mint, entry) in SolanaTokenRegistry.mints {
            byMint[mint] = SolanaSupportedToken(mint: mint, entry: entry)
        }

        let customRows = await customSolanaTokens(customTokens)
        for token in customRows where byMint[token.mint] == nil {
            byMint[token.mint] = token
        }

        return byMint.values.sorted {
            if $0.entry.symbol == $1.entry.symbol { return $0.mint < $1.mint }
            return $0.entry.symbol < $1.entry.symbol
        }
    }

    private func customSolanaTokens(_ customTokens: [CustomTokenSnapshot]) async -> [SolanaSupportedToken] {
        let solanaTokens = customTokens.filter { $0.chain == .solana }
        guard !solanaTokens.isEmpty else { return [] }
        let adapter = SolanaChainAdapter(client: rpc)

        return await withTaskGroup(of: SolanaSupportedToken?.self) { group in
            for token in solanaTokens {
                group.addTask {
                    let mintInfo = try? await adapter.fetchMintInfo(mint: token.contract)
                    let standard = mintInfo?.standard ?? .splToken
                    return SolanaSupportedToken(
                        mint: token.contract,
                        entry: SolanaTokenRegistry.Entry(
                            symbol: token.symbol,
                            name: token.name,
                            decimals: token.decimals,
                            standard: standard
                        )
                    )
                }
            }

            var rows: [SolanaSupportedToken] = []
            rows.reserveCapacity(solanaTokens.count)
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows
        }
    }

    private func tokenBalances(
        owner: String,
        tokens: [SolanaSupportedToken]
    ) async -> [SolanaTokenRead] {
        let groupedByProgram = Dictionary(grouping: tokens) {
            SolanaTokenRegistry.tokenProgramId(for: $0.mint)
        }

        return await withTaskGroup(of: [SolanaTokenRead].self) { group in
            for (programId, programTokens) in groupedByProgram {
                group.addTask {
                    do {
                        return try await self.tokenBalances(
                            owner: owner,
                            programId: programId,
                            tokens: programTokens
                        )
                    } catch {
                        await self.logTokenProgramFailure(programId: programId, error: error)
                        return await self.tokenBalancesByMintFallback(owner: owner, tokens: programTokens)
                    }
                }
            }

            var rows: [SolanaTokenRead] = []
            rows.reserveCapacity(tokens.count)
            for await chunk in group {
                rows.append(contentsOf: chunk)
            }
            return rows.sorted { $0.token.entry.symbol < $1.token.entry.symbol }
        }
    }

    private func tokenBalances(
        owner: String,
        programId: String,
        tokens: [SolanaSupportedToken]
    ) async throws -> [SolanaTokenRead] {
        let options: [String: Sendable] = [
            "encoding": "jsonParsed",
            "commitment": "confirmed"
        ]
        let data = try await rpc.callJSONResultData(
            chain: .solana,
            method: "getTokenAccountsByOwner",
            params: [owner, ["programId": programId], options]
        )
        let result = try JSONDecoder().decode(SolanaTokenAccountsResult.self, from: data)
        let supportedByMint = Dictionary(uniqueKeysWithValues: tokens.map { ($0.mint, $0) })

        var rawByMint: [String: String] = [:]
        var accountsByMint: [String: [String]] = [:]
        for row in result.value {
            if let accountOwner = row.account.owner, accountOwner != programId {
                continue
            }
            let info = row.account.data.parsed.info
            guard info.owner == nil || info.owner == owner else { continue }
            guard supportedByMint[info.mint] != nil else { continue }
            rawByMint[info.mint] = SolanaDecimalString.add(
                rawByMint[info.mint] ?? "0",
                info.tokenAmount.amount
            )
            accountsByMint[info.mint, default: []].append(row.pubkey)
        }

        return tokens.map { token in
            SolanaTokenRead(
                token: token,
                rawBalance: rawByMint[token.mint] ?? "0",
                tokenAccounts: accountsByMint[token.mint] ?? []
            )
        }
    }

    private func tokenBalancesByMintFallback(
        owner: String,
        tokens: [SolanaSupportedToken]
    ) async -> [SolanaTokenRead] {
        await withTaskGroup(of: SolanaTokenRead.self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        return try await self.tokenBalance(owner: owner, token: token)
                    } catch {
                        await self.logTokenFailure(symbol: token.entry.symbol, error: error)
                        return SolanaTokenRead(token: token, rawBalance: "0", tokenAccounts: [])
                    }
                }
            }

            var rows: [SolanaTokenRead] = []
            rows.reserveCapacity(tokens.count)
            for await row in group {
                rows.append(row)
            }
            return rows
        }
    }

    private func tokenBalance(owner: String, token: SolanaSupportedToken) async throws -> SolanaTokenRead {
        let options: [String: Sendable] = [
            "encoding": "jsonParsed",
            "commitment": "confirmed"
        ]
        let data = try await rpc.callJSONResultData(
            chain: .solana,
            method: "getTokenAccountsByOwner",
            params: [owner, ["mint": token.mint], options]
        )
        let result = try JSONDecoder().decode(SolanaTokenAccountsResult.self, from: data)

        var rawBalance = "0"
        var accounts: [String] = []
        for row in result.value {
            guard row.account.data.parsed.info.mint == token.mint else { continue }
            if let accountOwner = row.account.owner,
               accountOwner != SolanaTokenRegistry.tokenProgramId(for: token.mint) {
                continue
            }
            if let tokenOwner = row.account.data.parsed.info.owner, tokenOwner != owner {
                continue
            }
            let amount = row.account.data.parsed.info.tokenAmount.amount
            rawBalance = SolanaDecimalString.add(rawBalance, amount)
            accounts.append(row.pubkey)
        }
        return SolanaTokenRead(token: token, rawBalance: rawBalance, tokenAccounts: accounts)
    }

    private func safeHistory(
        owner: String,
        activeTokenAccounts: [String],
        tokens: [SolanaSupportedToken]
    ) async -> [SolanaHistoryEvent] {
        do {
            return try await history(owner: owner, activeTokenAccounts: activeTokenAccounts, tokens: tokens)
        } catch {
            log.debug("Solana history failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func history(
        owner: String,
        activeTokenAccounts: [String],
        tokens: [SolanaSupportedToken]
    ) async throws -> [SolanaHistoryEvent] {
        let signatureRequests: [(address: String, limit: Int)] =
            [(owner, 25)] + Array(Set(activeTokenAccounts)).sorted().map { ($0, 12) }
        let signatures = await signatures(for: signatureRequests)
        let latest = signatures
            .sorted {
                if ($0.blockTime ?? 0) == ($1.blockTime ?? 0) { return $0.slot > $1.slot }
                return ($0.blockTime ?? 0) > ($1.blockTime ?? 0)
            }
            .prefix(60)

        let knownTokenAccounts = Set(activeTokenAccounts)
        let tokenByMint = Dictionary(uniqueKeysWithValues: tokens.map { ($0.mint, $0.entry) })
        let tokenMints = Set(tokenByMint.keys)

        return await withTaskGroup(of: [SolanaHistoryEvent].self) { group in
            for item in latest {
                group.addTask {
                    do {
                        return try await self.transactionEvents(
                            signature: item.signature,
                            owner: owner,
                            tokenMints: tokenMints,
                            tokenByMint: tokenByMint,
                            knownTokenAccounts: knownTokenAccounts,
                            fallbackBlockTime: item.blockTime
                        )
                    } catch {
                        return []
                    }
                }
            }

            var rows: [SolanaHistoryEvent] = []
            for await chunk in group {
                rows.append(contentsOf: chunk)
            }

            var seen = Set<String>()
            let deduped = rows.filter { row in
                let key = "\(row.txHash)|\(row.tokenContract ?? "native")|\(row.direction.rawValue)|\(row.amount)"
                return seen.insert(key).inserted
            }
            return deduped.sorted { $0.occurredAt > $1.occurredAt }
        }
    }

    private func signatures(for requests: [(address: String, limit: Int)]) async -> [SolanaSignatureInfo] {
        await withTaskGroup(of: [SolanaSignatureInfo].self) { group in
            for request in requests {
                group.addTask {
                    do {
                        return try await self.signatures(address: request.address, limit: request.limit)
                    } catch {
                        return []
                    }
                }
            }

            var bySignature: [String: SolanaSignatureInfo] = [:]
            for await chunk in group {
                for item in chunk {
                    if let existing = bySignature[item.signature] {
                        if (item.blockTime ?? 0) > (existing.blockTime ?? 0) {
                            bySignature[item.signature] = item
                        }
                    } else {
                        bySignature[item.signature] = item
                    }
                }
            }
            return Array(bySignature.values)
        }
    }

    private func signatures(address: String, limit: Int) async throws -> [SolanaSignatureInfo] {
        let options: [String: Sendable] = ["limit": limit, "commitment": "confirmed"]
        let data = try await rpc.callJSONResultData(
            chain: .solana,
            method: "getSignaturesForAddress",
            params: [address, options]
        )
        return try JSONDecoder().decode([SolanaSignatureInfo].self, from: data)
    }

    private func transactionEvents(
        signature: String,
        owner: String,
        tokenMints: Set<String>,
        tokenByMint: [String: SolanaTokenRegistry.Entry],
        knownTokenAccounts: Set<String>,
        fallbackBlockTime: Int64?
    ) async throws -> [SolanaHistoryEvent] {
        let options: [String: Sendable] = [
            "encoding": "jsonParsed",
            "commitment": "confirmed",
            "maxSupportedTransactionVersion": 0
        ]
        let data = try await rpc.callJSONResultData(
            chain: .solana,
            method: "getTransaction",
            params: [signature, options]
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SolanaBalanceHistoryError.malformed("transaction root")
        }
        let slot = SolanaJSON.int64(root["slot"])
        let blockTime = SolanaJSON.int64(root["blockTime"]) ?? fallbackBlockTime
        let occurredAt = blockTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        let meta = root["meta"] as? [String: Any] ?? [:]
        let failed = SolanaJSON.isNonNull(meta["err"])
        let feeLamports = SolanaJSON.int64(meta["fee"]) ?? 0
        let fee = feeLamports > 0
            ? EVMHexQuantity.displayAmount(
                rawBalance: String(feeLamports),
                decimals: SupportedChain.solana.nativeDecimals
            )
            : nil

        let transaction = root["transaction"] as? [String: Any] ?? [:]
        let message = transaction["message"] as? [String: Any] ?? [:]
        var accountKeys = SolanaJSON.accountKeys(message["accountKeys"])
        if let loaded = meta["loadedAddresses"] as? [String: Any] {
            accountKeys += SolanaJSON.accountKeys(loaded["writable"])
            accountKeys += SolanaJSON.accountKeys(loaded["readonly"])
        }

        var events: [SolanaHistoryEvent] = []
        if let native = nativeEvent(
            txHash: signature,
            owner: owner,
            meta: meta,
            accountKeys: accountKeys,
            slot: slot,
            occurredAt: occurredAt,
            status: failed ? .failed : .confirmed,
            feeLamports: feeLamports,
            feeDisplay: fee
        ) {
            events.append(native)
        }
        events.append(contentsOf: tokenEvents(
            txHash: signature,
            owner: owner,
            tokenMints: tokenMints,
            tokenByMint: tokenByMint,
            knownTokenAccounts: knownTokenAccounts,
            meta: meta,
            accountKeys: accountKeys,
            slot: slot,
            occurredAt: occurredAt,
            status: failed ? .failed : .confirmed,
            fee: fee
        ))
        return events
    }

    private func nativeEvent(
        txHash: String,
        owner: String,
        meta: [String: Any],
        accountKeys: [String],
        slot: Int64?,
        occurredAt: Date,
        status: TransactionStatus,
        feeLamports: Int64,
        feeDisplay: String?
    ) -> SolanaHistoryEvent? {
        guard let ownerIndex = accountKeys.firstIndex(of: owner),
              let pre = SolanaJSON.int64Array(meta["preBalances"]),
              let post = SolanaJSON.int64Array(meta["postBalances"]),
              ownerIndex < pre.count,
              ownerIndex < post.count else {
            return nil
        }
        let delta = Decimal(post[ownerIndex]) - Decimal(pre[ownerIndex])
        // Solana fee payer is always account key 0. Only then does the
        // balance delta include the fee (BUG-014).
        let ownerIsFeePayer = ownerIndex == 0
        guard let resolved = SolanaNativeActivityAmount.resolve(
            balanceDeltaLamports: delta,
            feeLamports: feeLamports,
            ownerIsFeePayer: ownerIsFeePayer
        ) else {
            return nil
        }
        let raw = NSDecimalNumber(decimal: resolved.amountLamports).stringValue
        guard let displayAmount = EVMHexQuantity.displayAmount(
            rawBalance: raw,
            decimals: SupportedChain.solana.nativeDecimals
        ) else {
            return nil
        }

        return SolanaHistoryEvent(
            txHash: txHash,
            direction: resolved.direction,
            amount: displayAmount,
            tokenSymbol: SupportedChain.solana.ticker,
            tokenContract: nil,
            blockNumber: slot,
            occurredAt: occurredAt,
            status: status,
            counterparty: nativeCounterparty(
                ownerIndex: ownerIndex,
                ownerDelta: delta,
                pre: pre,
                post: post,
                accountKeys: accountKeys
            ),
            // Fee only meaningful when this address paid it.
            fee: ownerIsFeePayer ? feeDisplay : nil
        )
    }

    private func tokenEvents(
        txHash: String,
        owner: String,
        tokenMints: Set<String>,
        tokenByMint: [String: SolanaTokenRegistry.Entry],
        knownTokenAccounts: Set<String>,
        meta: [String: Any],
        accountKeys: [String],
        slot: Int64?,
        occurredAt: Date,
        status: TransactionStatus,
        fee: String?
    ) -> [SolanaHistoryEvent] {
        let changes = SolanaJSON.tokenBalanceDeltas(
            meta: meta,
            accountKeys: accountKeys,
            tokenMints: tokenMints
        )
        var grouped: [String: Decimal] = [:]
        for change in changes where change.owner == owner || knownTokenAccounts.contains(change.tokenAccount) {
            grouped[change.mint, default: 0] += change.deltaRaw
        }

        return grouped.compactMap { mint, delta in
            guard delta != 0, let registry = tokenByMint[mint] else { return nil }
            let direction: TransactionDirection = delta > 0 ? .incoming : .outgoing
            let amount = delta < 0 ? -delta : delta
            let raw = NSDecimalNumber(decimal: amount).stringValue
            guard let displayAmount = EVMHexQuantity.displayAmount(
                rawBalance: raw,
                decimals: registry.decimals
            ) else {
                return nil
            }
            return SolanaHistoryEvent(
                txHash: txHash,
                direction: direction,
                amount: displayAmount,
                tokenSymbol: registry.symbol,
                tokenContract: mint,
                blockNumber: slot,
                occurredAt: occurredAt,
                status: status,
                counterparty: tokenCounterparty(
                    owner: owner,
                    mint: mint,
                    ownerDelta: delta,
                    changes: changes
                ),
                fee: fee
            )
        }
    }

    private func nativeCounterparty(
        ownerIndex: Int,
        ownerDelta: Decimal,
        pre: [Int64],
        post: [Int64],
        accountKeys: [String]
    ) -> String {
        guard ownerDelta != 0 else { return "" }
        for index in 0..<min(pre.count, post.count) where index != ownerIndex {
            let delta = Decimal(post[index]) - Decimal(pre[index])
            guard delta != 0, (delta > 0) != (ownerDelta > 0), index < accountKeys.count else { continue }
            return accountKeys[index]
        }
        return ""
    }

    private func tokenCounterparty(
        owner: String,
        mint: String,
        ownerDelta: Decimal,
        changes: [SolanaTokenDelta]
    ) -> String {
        for change in changes where change.mint == mint && change.owner != owner {
            guard change.deltaRaw != 0, (change.deltaRaw > 0) != (ownerDelta > 0) else { continue }
            return change.owner ?? change.tokenAccount
        }
        return ""
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

    private func logTokenFailure(symbol: String, error: Error) {
        log.debug("Solana token balance failed for \(symbol, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    private func logTokenProgramFailure(programId: String, error: Error) {
        log.debug("Solana token program balance failed for \(programId, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}

private struct SolanaNativeBalance: Sendable {
    let lamports: String
    let accountExists: Bool
}

private struct SolanaSupportedToken: Sendable, Hashable {
    let mint: String
    let entry: SolanaTokenRegistry.Entry
}

private struct SolanaTokenRead: Sendable {
    let token: SolanaSupportedToken
    let rawBalance: String
    let tokenAccounts: [String]
}

private struct SolanaHistoryEvent: Sendable {
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

/// BUG-014: pure SOL activity amount math.
///
/// Solana `preBalances`/`postBalances` deltas for the fee payer include
/// the network fee. Activity already stores fee separately, so outgoing
/// native amount must be `max(0, |delta| − fee)` — same idea as Bitcoin
/// Electrum (`spent − received − fee`). Token (SPL) amounts are unchanged
/// (fee is always paid in SOL).
enum SolanaNativeActivityAmount {
    struct Resolved: Sendable, Equatable {
        let direction: TransactionDirection
        /// Absolute amount in lamports (not including fee when subtracted).
        let amountLamports: Decimal
    }

    /// - Parameters:
    ///   - balanceDeltaLamports: `post − pre` for the owner (signed).
    ///   - feeLamports: `meta.fee` (always ≥ 0).
    ///   - ownerIsFeePayer: fee payer is account key index 0 on Solana.
    static func resolve(
        balanceDeltaLamports: Decimal,
        feeLamports: Int64,
        ownerIsFeePayer: Bool
    ) -> Resolved? {
        guard balanceDeltaLamports != 0 else { return nil }
        let direction: TransactionDirection = balanceDeltaLamports > 0 ? .incoming : .outgoing
        var amount = balanceDeltaLamports < 0 ? -balanceDeltaLamports : balanceDeltaLamports
        if direction == .outgoing, ownerIsFeePayer, feeLamports > 0 {
            amount = max(0, amount - Decimal(feeLamports))
        }
        // Drop pure-fee rows (no transfer) so activity doesn't show "0 SOL".
        guard amount > 0 else { return nil }
        return Resolved(direction: direction, amountLamports: amount)
    }
}

private struct SolanaGetBalanceResult: Decodable {
    let value: UInt64
}

private struct SolanaSignatureInfo: Decodable, Sendable {
    let signature: String
    let slot: Int64
    let blockTime: Int64?
}

private struct SolanaTokenAccountsResult: Decodable {
    let value: [SolanaTokenAccountRow]
}

private struct SolanaTokenAccountRow: Decodable {
    let pubkey: String
    let account: AccountBody

    struct AccountBody: Decodable {
        let owner: String?
        let data: DataBody
    }

    struct DataBody: Decodable {
        let parsed: ParsedBody
    }

    struct ParsedBody: Decodable {
        let info: InfoBody
    }

    struct InfoBody: Decodable {
        let mint: String
        let owner: String?
        let tokenAmount: TokenAmountBody
    }

    struct TokenAmountBody: Decodable {
        let amount: String
        let decimals: Int
    }
}

private struct SolanaTokenDelta: Sendable {
    let owner: String?
    let tokenAccount: String
    let mint: String
    let deltaRaw: Decimal
}

private enum SolanaJSON {
    static func isNonNull(_ value: Any?) -> Bool {
        guard let value else { return false }
        return !(value is NSNull)
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func int64Array(_ value: Any?) -> [Int64]? {
        guard let array = value as? [Any] else { return nil }
        return array.compactMap(int64)
    }

    static func accountKeys(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { item in
            if let value = item as? String { return value }
            if let object = item as? [String: Any] { return object["pubkey"] as? String }
            return nil
        }
    }

    static func tokenBalanceDeltas(
        meta: [String: Any],
        accountKeys: [String],
        tokenMints: Set<String>
    ) -> [SolanaTokenDelta] {
        let pre = tokenBalances(meta["preTokenBalances"], accountKeys: accountKeys, tokenMints: tokenMints)
        let post = tokenBalances(meta["postTokenBalances"], accountKeys: accountKeys, tokenMints: tokenMints)
        var keys = Set<SolanaTokenBalanceKey>()
        pre.keys.forEach { keys.insert($0) }
        post.keys.forEach { keys.insert($0) }

        return keys.compactMap { key in
            let before = pre[key]?.raw ?? 0
            let after = post[key]?.raw ?? 0
            let delta = after - before
            guard delta != 0 else { return nil }
            return SolanaTokenDelta(
                owner: key.owner,
                tokenAccount: key.tokenAccount,
                mint: key.mint,
                deltaRaw: delta
            )
        }
    }

    private static func tokenBalances(
        _ raw: Any?,
        accountKeys: [String],
        tokenMints: Set<String>
    ) -> [SolanaTokenBalanceKey: SolanaRawTokenAmount] {
        var result: [SolanaTokenBalanceKey: SolanaRawTokenAmount] = [:]
        for entry in raw as? [[String: Any]] ?? [] {
            guard let mint = entry["mint"] as? String,
                  tokenMints.contains(mint),
                  let ui = entry["uiTokenAmount"] as? [String: Any],
                  let amountString = ui["amount"] as? String,
                  let amount = Decimal(string: amountString) else {
                continue
            }
            let accountIndex = int(entry["accountIndex"])
            let tokenAccount = accountIndex.flatMap { index in
                accountKeys.indices.contains(index) ? accountKeys[index] : nil
            } ?? ""
            let owner = entry["owner"] as? String
            let key = SolanaTokenBalanceKey(owner: owner, tokenAccount: tokenAccount, mint: mint)
            result[key, default: SolanaRawTokenAmount(raw: 0)].raw += amount
        }
        return result
    }
}

private struct SolanaTokenBalanceKey: Hashable {
    let owner: String?
    let tokenAccount: String
    let mint: String
}

private struct SolanaRawTokenAmount {
    var raw: Decimal
}

private enum SolanaDecimalString {
    static func add(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.reversed().map { Int(String($0)) ?? 0 }
        let right = rhs.reversed().map { Int(String($0)) ?? 0 }
        let count = max(left.count, right.count)
        var carry = 0
        var result: [Int] = []
        result.reserveCapacity(count + 1)
        for index in 0..<count {
            let sum = (index < left.count ? left[index] : 0)
                + (index < right.count ? right[index] : 0)
                + carry
            result.append(sum % 10)
            carry = sum / 10
        }
        while carry > 0 {
            result.append(carry % 10)
            carry /= 10
        }
        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result.reversed().map(String.init).joined()
    }
}

private enum SolanaBalanceHistoryError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case .malformed(let reason):
            return "Malformed Solana response: \(reason)"
        }
    }
}

private extension UInt32 {
    init(littleEndianBytes bytes: [UInt8]) {
        var value: UInt32 = 0
        for (index, byte) in bytes.prefix(4).enumerated() {
            value |= UInt32(byte) << UInt32(index * 8)
        }
        self = value
    }
}

private actor PublicNodeEVMBalanceScanner {
    private let client = PublicNodeEVMRPCClient.shared
    private let historyClient = EVMTransactionHistoryClient()
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "evm-balances")

    func scanAndPersist(
        walletId: UUID,
        address: WalletRepository.AddressSnapshot,
        currencyCode: String,
        database: AppDatabase,
        customTokens: [CustomTokenSnapshot] = [],
        includePrices: Bool = true,
        includeHistory: Bool = true
    ) async throws {
        let chain = address.chain
        guard client.supports(chain: chain) else { return }

        let tokens = supportedTokens(chain: chain, customTokens: customTokens)
        let symbols = Array(Set(([chain.ticker] + tokens.map(\.symbol)).map { $0.uppercased() }))

        async let prices: [String: TokenPricingEngine.ResolvedPrice] = includePrices
            ? TokenPricingEngine.shared.unitPrices(
                symbols: symbols,
                currencyCode: currencyCode
            )
            : [:]
        async let nativeHex = client.nativeBalance(chain: chain, address: address.address)
        async let tokenReads = readTokenBalances(chain: chain, holder: address.address, tokens: tokens)
        async let transactionCount: Int64 = includeHistory
            ? safeTransactionCount(chain: chain, address: address.address)
            : 0
        async let transactionHistory: [EVMHistoryEvent] = includeHistory
            ? safeTransactionHistory(chain: chain, holder: address.address, tokens: tokens)
            : []

        let nativeRaw = try EVMHexQuantity.decimalString(from: await nativeHex)
        let tokenBalances = await tokenReads
        let priceMap = await prices
        let txCount = await transactionCount
        let historyEvents = await transactionHistory

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: address.id,
            tokenSymbol: chain.ticker,
            tokenContract: nil,
            decimals: chain.nativeDecimals,
            rawBalance: nativeRaw,
            fiatValueCached: fiatValue(rawBalance: nativeRaw, decimals: chain.nativeDecimals, symbol: chain.ticker, prices: priceMap),
            fiatCurrencyCode: currencyCode,
            save: false
        )

        var isUsed = EVMHexQuantity.isPositiveDecimalString(nativeRaw) || txCount > 0 || !historyEvents.isEmpty
        for token in tokenBalances {
            if EVMHexQuantity.isPositiveDecimalString(token.rawBalance) {
                isUsed = true
            }
            try txRepo.upsertBalance(
                addressId: address.id,
                tokenSymbol: token.entry.symbol,
                tokenContract: token.entry.contract.lowercased(),
                decimals: token.entry.decimals,
                rawBalance: token.rawBalance,
                fiatValueCached: fiatValue(rawBalance: token.rawBalance, decimals: token.entry.decimals, symbol: token.entry.symbol, prices: priceMap),
                fiatCurrencyCode: currencyCode,
                save: false
            )
        }

        for event in historyEvents {
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
            onlyChains: [chain],
            failedChains: [],
            interim: false
        )
    }

    private func readTokenBalances(
        chain: SupportedChain,
        holder: String,
        tokens: [EVMTokenRegistry.Entry]
    ) async -> [TokenRead] {
        await withTaskGroup(of: TokenRead?.self) { group in
            for entry in tokens {
                group.addTask {
                    do {
                        let hex = try await self.client.tokenBalance(
                            chain: chain,
                            contract: entry.contract,
                            holder: holder
                        )
                        return try TokenRead(
                            entry: entry,
                            rawBalance: EVMHexQuantity.decimalString(from: hex)
                        )
                    } catch {
                        await self.logTokenFailure(symbol: entry.symbol, error: error)
                        return nil
                    }
                }
            }

            var rows: [TokenRead] = []
            rows.reserveCapacity(tokens.count)
            for await row in group {
                if let row { rows.append(row) }
            }
            return rows.sorted { $0.entry.symbol < $1.entry.symbol }
        }
    }

    private func supportedTokens(
        chain: SupportedChain,
        customTokens: [CustomTokenSnapshot]
    ) -> [EVMTokenRegistry.Entry] {
        var rows = EVMTokenRegistry.tokens(for: chain)
        var seen = Set(rows.map { $0.contract.lowercased() })
        for token in customTokens where token.chain == chain {
            let key = token.contract.lowercased()
            guard seen.insert(key).inserted else { continue }
            rows.append(EVMTokenRegistry.Entry(
                contract: token.contract,
                symbol: token.symbol,
                name: token.name,
                decimals: token.decimals
            ))
        }
        return rows.sorted {
            if $0.symbol == $1.symbol { return $0.contract.lowercased() < $1.contract.lowercased() }
            return $0.symbol < $1.symbol
        }
    }

    private func safeTransactionCount(chain: SupportedChain, address: String) async -> Int64 {
        do {
            let hex = try await client.transactionCount(chain: chain, address: address)
            return try EVMHexQuantity.int64(from: hex)
        } catch {
            log.debug("EVM transaction count failed for \(chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private func safeTransactionHistory(
        chain: SupportedChain,
        holder: String,
        tokens: [EVMTokenRegistry.Entry]
    ) async -> [EVMHistoryEvent] {
        await historyClient.recentEvents(chain: chain, holder: holder, tokens: tokens)
    }

    private func logTokenFailure(symbol: String, error: Error) {
        log.debug("EVM token balance failed for \(symbol, privacy: .public): \(String(describing: error), privacy: .public)")
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

    private struct TokenRead: Sendable {
        let entry: EVMTokenRegistry.Entry
        let rawBalance: String
    }
}

actor PublicNodeEVMRPCClient {
    static let shared = PublicNodeEVMRPCClient()

    private let session: URLSession
    private let concurrencyGate: ConcurrencyGate
    private var requestID = 0

    init(session: URLSession? = nil, concurrencyGate: ConcurrencyGate = .shared) {
        self.concurrencyGate = concurrencyGate
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

    func nativeBalance(chain: SupportedChain, address: String) async throws -> String {
        try await callString(chain: chain, method: "eth_getBalance", params: [address, "latest"])
    }

    func transactionCount(chain: SupportedChain, address: String) async throws -> String {
        try await callString(chain: chain, method: "eth_getTransactionCount", params: [address, "latest"])
    }

    func tokenBalance(chain: SupportedChain, contract: String, holder: String) async throws -> String {
        let call: [String: String] = [
            "to": contract,
            "data": EVMTokenRegistry.balanceOfCallData(holder: holder)
        ]
        return try await callString(chain: chain, method: "eth_call", params: [call, "latest"])
    }

    nonisolated func supports(chain: SupportedChain) -> Bool {
        endpoint(for: chain) != nil
    }

    private func callString(chain: SupportedChain, method: String, params: [Any]) async throws -> String {
        guard let endpoint = endpoint(for: chain) else {
            throw PublicNodeEVMRPCError.unsupportedChain(chain.rawValue)
        }

        requestID += 1
        let id = requestID
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])

        let gateHost = endpoint.host ?? endpoint.absoluteString
        let gateStart = Date()
        let release = try await concurrencyGate.acquire(host: gateHost)
        defer { release() }
        var latencyMetadata = [
            "chain": chain.rawValue,
            "source": "PublicNodeEVMRPCClient",
            "gateHost": gateHost,
            "gateWaitMs": DiagnosticsLogStore.elapsedMilliseconds(since: gateStart)
        ]
        if let host = endpoint.host {
            latencyMetadata["host"] = host
        }
        let (data, response) = try await session.apertureData(
            for: request,
            family: "balances",
            operation: method,
            metadata: latencyMetadata
        )
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PublicNodeEVMRPCError.httpStatus(http.statusCode)
        }
        let envelope = try JSONDecoder().decode(JSONRPCStringEnvelope.self, from: data)
        if let error = envelope.error {
            throw PublicNodeEVMRPCError.rpc(code: error.code, message: error.message)
        }
        guard let result = envelope.result else {
            throw PublicNodeEVMRPCError.missingResult(method)
        }
        return result
    }

    private nonisolated func endpoint(for chain: SupportedChain) -> URL? {
        switch chain {
        case .ethereum:
            return URL(string: "https://ethereum-rpc.publicnode.com")
        case .arbitrum:
            return URL(string: "https://arbitrum-one-rpc.publicnode.com")
        case .base:
            return URL(string: "https://base-rpc.publicnode.com")
        case .optimism:
            return URL(string: "https://optimism-rpc.publicnode.com")
        case .scroll:
            return URL(string: "https://scroll-rpc.publicnode.com")
        case .zkSync:
            // PublicNode removed zkSync Era (the old endpoint is HTTP 404).
            // dRPC was the fastest healthy keyless fallback in 2026-07-10 probes;
            // keyless 1RPC returns -32001 quota errors.
            return URL(string: "https://zksync.drpc.org")
        case .polygon:
            return URL(string: "https://polygon-bor-rpc.publicnode.com")
        case .bnbChain:
            return URL(string: "https://bsc-rpc.publicnode.com")
        case .avalanche:
            return URL(string: "https://avalanche-c-chain-rpc.publicnode.com")
        case .celo:
            return URL(string: "https://celo-rpc.publicnode.com")
        case .opBNB:
            return URL(string: "https://opbnb-rpc.publicnode.com")
        default:
            return nil
        }
    }
}

private struct JSONRPCStringEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: Int
        let message: String
    }

    let result: String?
    let error: ErrorBody?
}

private enum PublicNodeEVMRPCError: Error, CustomStringConvertible {
    case unsupportedChain(String)
    case httpStatus(Int)
    case rpc(code: Int, message: String)
    case missingResult(String)

    var description: String {
        switch self {
        case .unsupportedChain(let chain):
            return "PublicNode EVM balance scanner does not support \(chain)"
        case .httpStatus(let status):
            return "PublicNode HTTP \(status)"
        case .rpc(let code, let message):
            return "PublicNode JSON-RPC \(code): \(message)"
        case .missingResult(let method):
            return "PublicNode \(method) returned no result"
        }
    }
}

enum EVMHexQuantity {
    enum ParseError: Error, CustomStringConvertible {
        case invalidHex(String)

        var description: String {
            switch self {
            case .invalidHex(let value):
                return "Invalid hex quantity: \(value)"
            }
        }
    }

    static func decimalString(from hex: String) throws -> String {
        let trimmed = hex.hasPrefix("0x") || hex.hasPrefix("0X")
            ? String(hex.dropFirst(2))
            : hex
        guard !trimmed.isEmpty else { return "0" }

        var decimalDigitsLittleEndian = [0]
        for scalar in trimmed.unicodeScalars {
            let digit: Int
            switch scalar.value {
            case 48...57:
                digit = Int(scalar.value - 48)
            case 65...70:
                digit = Int(scalar.value - 55)
            case 97...102:
                digit = Int(scalar.value - 87)
            default:
                throw ParseError.invalidHex(hex)
            }

            var carry = digit
            for index in decimalDigitsLittleEndian.indices {
                let next = decimalDigitsLittleEndian[index] * 16 + carry
                decimalDigitsLittleEndian[index] = next % 10
                carry = next / 10
            }
            while carry > 0 {
                decimalDigitsLittleEndian.append(carry % 10)
                carry /= 10
            }
        }

        while decimalDigitsLittleEndian.count > 1 && decimalDigitsLittleEndian.last == 0 {
            decimalDigitsLittleEndian.removeLast()
        }
        return decimalDigitsLittleEndian.reversed().map(String.init).joined()
    }

    static func int64(from hex: String) throws -> Int64 {
        let decimal = try decimalString(from: hex)
        guard let value = Int64(decimal) else {
            throw ParseError.invalidHex(hex)
        }
        return value
    }

    static func hexQuantity(_ value: Int64) -> String {
        "0x" + String(value, radix: 16)
    }

    static func isPositiveDecimalString(_ value: String) -> Bool {
        value.contains { $0 != "0" }
    }

    static func decimalAmount(rawBalance: String, decimals: Int) -> Decimal? {
        // BUG-025: build display via integer-string first, then parse Decimal
        // for UI math. Full-width raw strings stay exact in `displayAmount`.
        guard let display = displayAmount(rawBalance: rawBalance, decimals: decimals) else {
            return nil
        }
        return Decimal(string: display, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Raw integer base units → display string with `decimals` places.
    /// Digit-wise (no Decimal product) so balances wider than 38
    /// significant digits remain exact on screen (BUG-025).
    static func displayAmount(rawBalance: String, decimals: Int) -> String? {
        let trimmed = rawBalance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        let raw = stripLeadingZeros(trimmed)
        let scale = max(0, decimals)
        if scale == 0 { return raw }

        if raw == "0" { return "0" }

        if raw.count <= scale {
            let pad = String(repeating: "0", count: scale - raw.count)
            let frac = pad + raw
            return "0." + frac
        }
        let split = raw.index(raw.endIndex, offsetBy: -scale)
        let intPart = String(raw[..<split])
        let fracPart = String(raw[split...])
        // Trim trailing zeros in the fractional part for readability, but
        // keep at least one digit after the point only when needed.
        let trimmedFrac = fracPart.reversed().drop(while: { $0 == "0" }).reversed()
        if trimmedFrac.isEmpty {
            return intPart
        }
        return intPart + "." + String(trimmedFrac)
    }

    static func decimalString(_ value: Decimal) -> String {
        ComposeDecimal.plainDecimalString(value)
    }

    private static func stripLeadingZeros(_ digits: String) -> String {
        let stripped = digits.drop { $0 == "0" }
        return stripped.isEmpty ? "0" : String(stripped)
    }
}

/// Cancellable, wallet-scoped background work entrypoint for the wallet home.
/// Views enqueue work here and render from the database; this actor owns
/// cancellation, latency diagnostics, and stale-result protection.
actor WalletBackgroundWorkCoordinator {
    static let shared = WalletBackgroundWorkCoordinator()

    enum JobType: String, Sendable {
        case balances
        case fullRefresh
        case prices
        case markets
        case chainKeys
    }

    private struct JobSlot {
        let token: UUID
        let task: Task<Void, Never>
        let queuedAt: Date
    }

    private var jobs: [String: JobSlot] = [:]

    /// Refresh spendable balances (and prices). Awaits only the balances
    /// pipeline so pull-to-refresh can end when balances land.
    ///
    /// BUG-015 / PTR UX: always uses `.balancesOnly` (balances + prices,
    /// no history). User-initiated pulls then kick off a **background**
    /// `.full` pass for history / Electrum history / explorers so the
    /// spinner does not wait on those RPCs.
    func refreshBalances(
        walletId: UUID,
        currencyCode: String,
        database: AppDatabase,
        userInitiated: Bool,
        trigger: PortfolioRefreshTrigger = .background
    ) async {
        await runReplacing(
            type: .balances,
            walletId: walletId,
            waitsForCompletion: true
        ) {
            await TokenPricingEngine.shared.configure(database: database)
            await WalletDataRefreshCoordinator.shared.refresh(
                walletId: walletId,
                currencyCode: currencyCode,
                database: database,
                userInitiated: userInitiated,
                mode: .balancesOnly,
                trigger: trigger
            )
        }

        // History keeps running after the balances await returns (PTR ends).
        // Do not cancel mid-flight history when a non-user job is coalescing;
        // only user pulls replace via startFullRefresh's job key.
        if userInitiated {
            startFullRefresh(
                walletId: walletId,
                currencyCode: currencyCode,
                database: database,
                trigger: trigger
            )
        }
    }

    func startFullRefresh(
        walletId: UUID,
        currencyCode: String,
        database: AppDatabase,
        trigger: PortfolioRefreshTrigger = .automatic
    ) {
        Task {
            await runReplacing(
                type: .fullRefresh,
                walletId: walletId,
                waitsForCompletion: false
            ) {
                await TokenPricingEngine.shared.configure(database: database)
                await WalletDataRefreshCoordinator.shared.refresh(
                    walletId: walletId,
                    currencyCode: currencyCode,
                    database: database,
                    userInitiated: false,
                    mode: .full,
                    trigger: trigger
                )
            }
        }
    }

    func refreshFull(
        walletId: UUID,
        currencyCode: String,
        database: AppDatabase,
        trigger: PortfolioRefreshTrigger = .automatic
    ) async {
        await runReplacing(
            type: .fullRefresh,
            walletId: walletId,
            waitsForCompletion: true
        ) {
            await TokenPricingEngine.shared.configure(database: database)
            await WalletDataRefreshCoordinator.shared.refresh(
                walletId: walletId,
                currencyCode: currencyCode,
                database: database,
                userInitiated: false,
                mode: .full,
                trigger: trigger
            )
        }
    }

    func startPriceRefresh(
        walletId: UUID,
        symbols: [String],
        currencyCode: String,
        database: AppDatabase
    ) {
        Task {
            await runReplacing(
                type: .prices,
                walletId: walletId,
                waitsForCompletion: false
            ) {
                await TokenPricingEngine.shared.configure(database: database)
                _ = await TokenPricingEngine.shared.unitPrices(symbols: symbols, currencyCode: currencyCode)
            }
        }
    }

    func startChainKeyBackfill(walletId: UUID, database: AppDatabase) {
        Task {
            await runReplacing(
                type: .chainKeys,
                walletId: walletId,
                waitsForCompletion: false
            ) {
                try? WalletRepository(database: database)
                    .backfillEncryptedChainKeysFromStoredSecrets()
            }
        }
    }

    private func runReplacing(
        type: JobType,
        walletId: UUID,
        waitsForCompletion: Bool,
        operation: @escaping @Sendable () async -> Void
    ) async {
        let key = jobKey(type: type, walletId: walletId)
        if let existing = jobs[key] {
            existing.task.cancel()
            if waitsForCompletion {
                await existing.task.value
            }
            jobs[key] = nil
        }

        let queuedAt = Date()
        let token = UUID()
        let task = Task {
            let startedAt = Date()
            await Self.record(
                .info,
                type: type,
                walletId: walletId,
                message: "Background job started",
                queuedAt: queuedAt,
                startedAt: startedAt
            )
            await operation()
            let cancelled = Task.isCancelled
            await Self.record(
                .info,
                type: type,
                walletId: walletId,
                message: cancelled ? "Background job cancelled" : "Background job finished",
                queuedAt: queuedAt,
                startedAt: startedAt,
                finishedAt: Date(),
                cancelled: cancelled
            )
        }
        jobs[key] = JobSlot(token: token, task: task, queuedAt: queuedAt)
        if waitsForCompletion {
            await task.value
            if jobs[key]?.token == token {
                jobs[key] = nil
            }
        } else {
            Task {
                await task.value
                self.clearJob(key: key, token: token)
            }
        }
    }

    private func clearJob(key: String, token: UUID) {
        if jobs[key]?.token == token {
            jobs[key] = nil
        }
    }

    private func jobKey(type: JobType, walletId: UUID) -> String {
        "\(walletId.uuidString)|\(type.rawValue)"
    }

    private nonisolated static func record(
        _ level: DiagnosticsLogLevel,
        type: JobType,
        walletId: UUID,
        message: String,
        queuedAt: Date,
        startedAt: Date,
        finishedAt: Date? = nil,
        cancelled: Bool = false,
        metadata: [String: String] = [:]
    ) async {
        var payload = metadata
        payload["jobType"] = type.rawValue
        payload["walletId"] = walletId.uuidString
        payload["queuedMs"] = DiagnosticsLogStore.elapsedMilliseconds(from: queuedAt, to: startedAt)
        payload["cancelled"] = "\(cancelled)"
        if let finishedAt {
            payload["totalElapsedMs"] = DiagnosticsLogStore.elapsedMilliseconds(from: queuedAt, to: finishedAt)
            payload["operationMs"] = DiagnosticsLogStore.elapsedMilliseconds(from: startedAt, to: finishedAt)
        }
        DiagnosticsLogStore.shared.record(
            level,
            category: "background-job",
            message: message,
            metadata: payload
        )
    }
}
