import Foundation
import GRDB
import Testing
@testable import Aperture

@MainActor
@Suite struct PortfolioPnLTests {
    @Test("cash-flow-adjusted PnL excludes sent principal and keeps fees as loss")
    func outgoingPrincipalAndFees() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(24 * 60 * 60)
        let flowTime = start.addingTimeInterval(12 * 60 * 60)

        let principalOnly = PortfolioPnLCalculator.calculate(
            assets: [.init(assetKey: "bitcoin:native", chain: .bitcoin, startingValueUSD: 2_000, endingValueUSD: 1_450)],
            flows: [.init(assetKey: "bitcoin:native", signedValueUSD: -500, occurredAt: flowTime)],
            windowStart: start,
            windowEnd: end
        )
        #expect(principalOnly.changeUSD == -50)

        let withFee = PortfolioPnLCalculator.calculate(
            assets: [.init(assetKey: "bitcoin:native", chain: .bitcoin, startingValueUSD: 2_000, endingValueUSD: 1_440)],
            flows: [.init(assetKey: "bitcoin:native", signedValueUSD: -500, occurredAt: flowTime)],
            windowStart: start,
            windowEnd: end
        )
        #expect(withFee.changeUSD == -60)
    }

    @Test("incoming deposits are excluded and Modified Dietz time-weights flows")
    func incomingAndModifiedDietz() {
        let start = Date(timeIntervalSince1970: 2_000)
        let end = start.addingTimeInterval(24 * 60 * 60)
        let midpoint = start.addingTimeInterval(12 * 60 * 60)
        let result = PortfolioPnLCalculator.calculate(
            assets: [.init(assetKey: "ethereum:native", chain: .ethereum, startingValueUSD: 1_000, endingValueUSD: 1_600)],
            flows: [.init(assetKey: "ethereum:native", signedValueUSD: 500, occurredAt: midpoint)],
            windowStart: start,
            windowEnd: end
        )

        #expect(result.changeUSD == 100)
        #expect(result.returnPercent == 8)
    }

    @Test("Modified Dietz omits percentage when the denominator is non-positive")
    func nonPositiveDietzDenominator() {
        let start = Date(timeIntervalSince1970: 3_000)
        let end = start.addingTimeInterval(24 * 60 * 60)
        let result = PortfolioPnLCalculator.calculate(
            assets: [.init(assetKey: "bitcoin:native", chain: .bitcoin, startingValueUSD: 100, endingValueUSD: 20)],
            flows: [.init(assetKey: "bitcoin:native", signedValueUSD: -300, occurredAt: start)],
            windowStart: start,
            windowEnd: end
        )

        #expect(result.changeUSD == 220)
        #expect(result.returnPercent == nil)
    }

    @Test("flow classifier ignores self transfers and swaps and preserves ambiguous bridges")
    func flowClassification() {
        #expect(PortfolioFlowClassifier.classify(
            direction: .internal,
            kind: .selfTransfer,
            counterpartyOwned: false,
            hasIncomingLeg: false,
            hasOutgoingLeg: false
        ) == .internalTransfer)
        #expect(PortfolioFlowClassifier.classify(
            direction: .outgoing,
            kind: .transfer,
            counterpartyOwned: true,
            hasIncomingLeg: false,
            hasOutgoingLeg: false
        ) == .internalTransfer)
        #expect(PortfolioFlowClassifier.classify(
            direction: .outgoing,
            kind: .transfer,
            counterpartyOwned: false,
            hasIncomingLeg: true,
            hasOutgoingLeg: true
        ) == .swap)
        #expect(PortfolioFlowClassifier.classify(
            direction: .outgoing,
            kind: .bridge,
            counterpartyOwned: false,
            hasIncomingLeg: false,
            hasOutgoingLeg: false
        ) == .ambiguousBridge)
    }

    @Test("v6 schema creates indexed wallet-owned tables and wallet deletion cascades")
    func schemaAndCascade() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin])
        let repository = PortfolioPnLRepository(database: database)
        let runId = try repository.beginRun(walletId: walletId, trigger: .automatic, refreshMode: "full")
        try repository.completeRun(
            runId: runId,
            walletId: walletId,
            attemptedChains: [.bitcoin],
            successfulChains: [.bitcoin],
            failedChains: [],
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 100)],
            displayCurrencyCode: "USD",
            displayFXRate: 1,
            calculatePnL: true
        )

        let tables = [
            "portfolio_snapshot_runs", "portfolio_chain_results", "portfolio_asset_snapshots",
            "portfolio_asset_rollups", "portfolio_flow_valuations", "wallet_pnl_summaries"
        ]
        for table in tables {
            #expect(try TestAppDatabaseFactory.scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [table],
                database: database
            ) == 1)
        }
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_portfolio_asset_snapshots_wallet_asset_time'",
            database: database
        ) == 1)

        try database.write { db in
            try db.execute(sql: "DELETE FROM wallets WHERE id = ?", arguments: [walletId.uuidString])
        }
        for table in tables {
            #expect(try TestAppDatabaseFactory.count(table, database: database) == 0, "\(table) did not cascade")
        }
    }

    @Test("failed chains write explicit results but never zero snapshots")
    func failedChainDoesNotWriteZero() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin, .ethereum])
        let repository = PortfolioPnLRepository(database: database)
        let at = Date(timeIntervalSince1970: 100_000)
        try capture(
            repository: repository,
            walletId: walletId,
            at: at.addingTimeInterval(-24 * 60 * 60),
            balances: [
                pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 100),
                pricedBalance(chain: .ethereum, symbol: "ETH", raw: "1", usdValue: 100)
            ],
            calculatePnL: false
        )
        let runId = try repository.beginRun(walletId: walletId, trigger: .pullToRefresh, refreshMode: "full", at: at)
        try repository.completeRun(
            runId: runId,
            walletId: walletId,
            attemptedChains: [.bitcoin, .ethereum],
            successfulChains: [.bitcoin],
            failedChains: [.ethereum],
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 110)],
            displayCurrencyCode: "USD",
            displayFXRate: 1,
            calculatePnL: true,
            at: at
        )

        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT status_raw FROM portfolio_snapshot_runs WHERE id = ?",
            arguments: [runId.uuidString],
            database: database
        ) == "partial")
        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT status_raw FROM portfolio_chain_results WHERE run_id = ? AND chain_raw = ?",
            arguments: [runId.uuidString, SupportedChain.ethereum.rawValue],
            database: database
        ) == "failed")
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM portfolio_asset_snapshots WHERE run_id = ? AND chain_raw = ?",
            arguments: [runId.uuidString, SupportedChain.ethereum.rawValue],
            database: database
        ) == 0)
        let summary = try #require(try repository.latestSummary(walletId: walletId, preferCurrencyCode: "USD"))
        #expect(summary.state == .partial)
        #expect(summary.changeUSD == 10)
    }

    @Test("confirmed transaction source excludes pending and failed rows")
    func confirmedOnlyFlows() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.ethereum])
        let addressId = try firstAddressId(database, walletId: walletId, chain: .ethereum)
        let transactions = TransactionRepository(database: database)
        let now = Date()
        for (hash, status) in [("confirmed", TransactionStatus.confirmed), ("pending", .pending), ("failed", .failed)] {
            try transactions.upsertTransaction(
                addressId: addressId,
                txHash: hash,
                direction: .incoming,
                amountRaw: "1",
                tokenSymbol: "ETH",
                blockNumber: status == .pending ? nil : 1,
                occurredAt: now,
                status: status,
                counterparty: "0xexternal",
                feeRaw: nil
            )
        }

        let source = try PortfolioPnLRepository(database: database)
            .confirmedTransactions(walletId: walletId, since: now.addingTimeInterval(-60))
        #expect(source.rows.map(\.txHash) == ["confirmed"])
    }

    @Test("cancelled and failed refresh runs retain explicit terminal states")
    func runTerminalStates() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin])
        let repository = PortfolioPnLRepository(database: database)
        let cancelled = try repository.beginRun(walletId: walletId, trigger: .automatic, refreshMode: "full")
        let failed = try repository.beginRun(walletId: walletId, trigger: .background, refreshMode: "balancesOnly")

        try repository.markRunCancelled(cancelled)
        try repository.markRunFailed(failed)

        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT status_raw FROM portfolio_snapshot_runs WHERE id = ?",
            arguments: [cancelled.uuidString],
            database: database
        ) == "cancelled")
        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT status_raw FROM portfolio_snapshot_runs WHERE id = ?",
            arguments: [failed.uuidString],
            database: database
        ) == "failed")
    }

    @Test("an asset sent to zero remains in the union and does not become a loss")
    func sentToZeroAsset() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin])
        let addressId = try firstAddressId(database, walletId: walletId, chain: .bitcoin)
        let repository = PortfolioPnLRepository(database: database)
        let baseline = Date(timeIntervalSince1970: 150_000)
        let current = baseline.addingTimeInterval(24 * 60 * 60)

        try capture(
            repository: repository,
            walletId: walletId,
            at: baseline,
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 100)],
            calculatePnL: false
        )
        try insertFlow(
            database: database,
            repository: repository,
            walletId: walletId,
            addressId: addressId,
            chain: .bitcoin,
            symbol: "BTC",
            signedValueUSD: -100,
            occurredAt: baseline.addingTimeInterval(12 * 60 * 60),
            valuationStatus: "complete"
        )

        let runId = try repository.beginRun(walletId: walletId, trigger: .automatic, refreshMode: "full", at: current)
        try repository.completeRun(
            runId: runId,
            walletId: walletId,
            attemptedChains: [.bitcoin],
            successfulChains: [.bitcoin],
            failedChains: [],
            balances: [],
            displayCurrencyCode: "USD",
            displayFXRate: 1,
            calculatePnL: true,
            at: current
        )

        let summary = try #require(try repository.latestSummary(walletId: walletId, preferCurrencyCode: "USD"))
        #expect(summary.state == .complete)
        #expect(summary.changeUSD == 0)
        #expect(summary.relevantAssetCount == 1)
    }

    @Test("an unpriced external flow is unavailable instead of guessed")
    func missingHistoricalFlowPrice() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.ethereum])
        let addressId = try firstAddressId(database, walletId: walletId, chain: .ethereum)
        let repository = PortfolioPnLRepository(database: database)
        let baseline = Date(timeIntervalSince1970: 175_000)
        let current = baseline.addingTimeInterval(24 * 60 * 60)

        try capture(
            repository: repository,
            walletId: walletId,
            at: baseline,
            balances: [pricedBalance(chain: .ethereum, symbol: "ETH", raw: "1", usdValue: 100)],
            calculatePnL: false
        )
        try insertFlow(
            database: database,
            repository: repository,
            walletId: walletId,
            addressId: addressId,
            chain: .ethereum,
            symbol: "ETH",
            signedValueUSD: nil,
            occurredAt: baseline.addingTimeInterval(12 * 60 * 60),
            valuationStatus: "unavailable"
        )
        try capture(
            repository: repository,
            walletId: walletId,
            at: current,
            balances: [pricedBalance(chain: .ethereum, symbol: "ETH", raw: "1", usdValue: 110)],
            calculatePnL: true
        )

        let summary = try #require(try repository.latestSummary(walletId: walletId, preferCurrencyCode: "USD"))
        #expect(summary.state == .unavailable)
        #expect(summary.changeUSD == nil)
    }

    @Test("persisted 24-hour summary produces minus fifty and projects canonical USD")
    func persistedCashFlowAndCurrencyProjection() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin])
        let addressId = try firstAddressId(database, walletId: walletId, chain: .bitcoin)
        let repository = PortfolioPnLRepository(database: database)
        let baseline = Date(timeIntervalSince1970: 200_000)
        let current = baseline.addingTimeInterval(24 * 60 * 60)

        try capture(
            repository: repository,
            walletId: walletId,
            at: baseline,
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "2", usdValue: 2_000)],
            calculatePnL: false
        )

        let transactionId = UUID()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO transactions
                (id, address_id, tx_hash, direction_raw, amount_raw, token_symbol,
                 token_contract, block_number, occurred_at_ms, status_raw, counterparty, fee_raw, kind_raw)
                VALUES (?, ?, 'send-500', ?, '500', 'BTC', NULL, 1, ?, ?, 'external', '10', ?)
                """,
                arguments: [
                    transactionId.uuidString,
                    addressId.uuidString,
                    TransactionDirection.outgoing.rawValue,
                    baseline.addingTimeInterval(12 * 60 * 60).databaseMilliseconds,
                    TransactionStatus.confirmed.rawValue,
                    TransactionKind.transfer.rawValue
                ]
            )
        }
        try repository.upsertFlowValuations([.init(
            transactionId: transactionId,
            walletId: walletId,
            chain: .bitcoin,
            assetKey: "bitcoin:native",
            classification: PortfolioFlowClassification.externalOutgoing.rawValue,
            signedAmount: -500,
            occurredAt: baseline.addingTimeInterval(12 * 60 * 60),
            unitPriceUSD: 1,
            signedValueUSD: -500,
            priceSource: "test",
            priceAt: baseline.addingTimeInterval(12 * 60 * 60),
            valuationStatus: "complete"
        )])

        try capture(
            repository: repository,
            walletId: walletId,
            at: current,
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 1_450)],
            calculatePnL: true
        )

        let usd = try #require(try repository.latestSummary(walletId: walletId, preferCurrencyCode: "USD"))
        #expect(usd.state == .complete)
        #expect(usd.changeUSD == -50)
        #expect(usd.displayChange == -50)

        try repository.projectLatestSummary(
            walletId: walletId,
            displayCurrencyCode: "JOD",
            fxRateFromUSD: Decimal(string: "0.71")!
        )
        let jod = try #require(try repository.latestSummary(walletId: walletId, preferCurrencyCode: "JOD"))
        #expect(jod.changeUSD == -50)
        #expect(jod.displayChange == Decimal(string: "-35.5"))
    }

    @Test("identical snapshots deduplicate within five minutes")
    func snapshotDeduplication() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin])
        let repository = PortfolioPnLRepository(database: database)
        let at = Date(timeIntervalSince1970: 300_000)
        let balance = pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 100)

        try capture(repository: repository, walletId: walletId, at: at, balances: [balance], calculatePnL: false)
        try capture(repository: repository, walletId: walletId, at: at.addingTimeInterval(4 * 60), balances: [balance], calculatePnL: false)

        #expect(try TestAppDatabaseFactory.count("portfolio_asset_snapshots", database: database) == 1)
        #expect(try TestAppDatabaseFactory.count("portfolio_asset_rollups", database: database) == 2)
    }

    @Test("maintenance keeps daily history while pruning raw and hourly history")
    func retentionTiers() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin])
        let repository = PortfolioPnLRepository(database: database)
        let old = Date(timeIntervalSince1970: 400_000)
        let current = old.addingTimeInterval(100 * 24 * 60 * 60)

        try capture(
            repository: repository,
            walletId: walletId,
            at: old,
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 100)],
            calculatePnL: false
        )
        try capture(
            repository: repository,
            walletId: walletId,
            at: current,
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "2", usdValue: 200)],
            calculatePnL: false
        )

        #expect(try TestAppDatabaseFactory.count("portfolio_asset_snapshots", database: database) == 1)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM portfolio_asset_rollups WHERE resolution_raw = 'hourly'",
            database: database
        ) == 1)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM portfolio_asset_rollups WHERE resolution_raw = 'daily'",
            database: database
        ) == 2)
    }

    @Test("factory reset removes every portfolio history table")
    func factoryResetCoverage() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = try await insertWallet(database, chains: [.bitcoin])
        let repository = PortfolioPnLRepository(database: database)
        try capture(
            repository: repository,
            walletId: walletId,
            at: Date(),
            balances: [pricedBalance(chain: .bitcoin, symbol: "BTC", raw: "1", usdValue: 100)],
            calculatePnL: true
        )

        try FactoryReset.wipeResettableModels(database: database)
        for table in [
            "portfolio_snapshot_runs", "portfolio_chain_results", "portfolio_asset_snapshots",
            "portfolio_asset_rollups", "portfolio_flow_valuations", "wallet_pnl_summaries"
        ] {
            #expect(try TestAppDatabaseFactory.count(table, database: database) == 0, "\(table) survived reset")
        }
    }

    private func insertWallet(_ database: AppDatabase, chains: [SupportedChain]) async throws -> UUID {
        let id = UUID()
        try await WalletCommandRepository(database: database).insertWatchOnlyWallet(
            id: id,
            name: "PnL Test",
            colorTag: "gray",
            addresses: chains.map { ($0.rawValue, "\($0.rawValue)-\(id.uuidString)") }
        )
        return id
    }

    private func firstAddressId(
        _ database: AppDatabase,
        walletId: UUID,
        chain: SupportedChain
    ) throws -> UUID {
        let raw = try #require(try TestAppDatabaseFactory.scalarString(
            "SELECT id FROM wallet_addresses WHERE wallet_id = ? AND chain_raw = ? LIMIT 1",
            arguments: [walletId.uuidString, chain.rawValue],
            database: database
        ))
        return try #require(UUID(uuidString: raw))
    }

    private func pricedBalance(
        chain: SupportedChain,
        symbol: String,
        raw: String,
        usdValue: Decimal?
    ) -> PortfolioPnLRepository.PricedBalance {
        let source = PortfolioPnLRepository.BalanceSource(
            chain: chain,
            symbol: symbol,
            contract: nil,
            decimals: 0,
            rawBalance: raw,
            cachedFiat: usdValue ?? 0,
            cachedCurrencyCode: "USD",
            updatedAt: Date()
        )
        let quantity = source.quantity ?? 0
        let unitPrice = usdValue.flatMap { quantity > 0 ? $0 / quantity : nil }
        return .init(
            source: source,
            unitPriceUSD: unitPrice,
            usdValue: usdValue,
            priceSource: usdValue == nil ? nil : "test",
            priceAt: usdValue == nil ? nil : Date(),
            valuationStatus: usdValue == nil ? "unavailable" : "complete"
        )
    }

    private func insertFlow(
        database: AppDatabase,
        repository: PortfolioPnLRepository,
        walletId: UUID,
        addressId: UUID,
        chain: SupportedChain,
        symbol: String,
        signedValueUSD: Decimal?,
        occurredAt: Date,
        valuationStatus: String
    ) throws {
        let transactionId = UUID()
        let incoming = (signedValueUSD ?? 1) >= 0
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO transactions
                (id, address_id, tx_hash, direction_raw, amount_raw, token_symbol,
                 token_contract, block_number, occurred_at_ms, status_raw, counterparty, fee_raw, kind_raw)
                VALUES (?, ?, ?, ?, '1', ?, NULL, 1, ?, ?, 'external', NULL, ?)
                """,
                arguments: [
                    transactionId.uuidString,
                    addressId.uuidString,
                    "flow-\(transactionId.uuidString)",
                    incoming ? TransactionDirection.incoming.rawValue : TransactionDirection.outgoing.rawValue,
                    symbol,
                    occurredAt.databaseMilliseconds,
                    TransactionStatus.confirmed.rawValue,
                    TransactionKind.transfer.rawValue
                ]
            )
        }
        let classification = incoming
            ? PortfolioFlowClassification.externalIncoming
            : PortfolioFlowClassification.externalOutgoing
        try repository.upsertFlowValuations([.init(
            transactionId: transactionId,
            walletId: walletId,
            chain: chain,
            assetKey: "\(chain.rawValue):native",
            classification: classification.rawValue,
            signedAmount: incoming ? 1 : -1,
            occurredAt: occurredAt,
            unitPriceUSD: signedValueUSD.map { abs($0) },
            signedValueUSD: signedValueUSD,
            priceSource: signedValueUSD == nil ? nil : "test",
            priceAt: signedValueUSD == nil ? nil : occurredAt,
            valuationStatus: valuationStatus
        )])
    }

    private func capture(
        repository: PortfolioPnLRepository,
        walletId: UUID,
        at date: Date,
        balances: [PortfolioPnLRepository.PricedBalance],
        calculatePnL: Bool
    ) throws {
        let chains = Set(balances.map { $0.source.chain })
        let runId = try repository.beginRun(
            walletId: walletId,
            trigger: .automatic,
            refreshMode: "full",
            at: date
        )
        try repository.completeRun(
            runId: runId,
            walletId: walletId,
            attemptedChains: chains,
            successfulChains: chains,
            failedChains: [],
            balances: balances,
            displayCurrencyCode: "USD",
            displayFXRate: 1,
            calculatePnL: calculatePnL,
            at: date
        )
    }
}
