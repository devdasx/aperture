import Foundation
import GRDB

enum PortfolioRefreshTrigger: String, Sendable {
    case walletOpen
    case automatic
    case pullToRefresh
    case background
}

enum PortfolioPnLState: String, Sendable, Equatable {
    case complete
    case partial
    case collecting
    case unavailable
}

enum PortfolioFlowClassification: String, Sendable, Equatable {
    case externalIncoming
    case externalOutgoing
    case internalTransfer
    case swap
    case ambiguousBridge
}

enum PortfolioFlowClassifier {
    static func classify(
        direction: TransactionDirection,
        kind: TransactionKind,
        counterpartyOwned: Bool,
        hasIncomingLeg: Bool,
        hasOutgoingLeg: Bool
    ) -> PortfolioFlowClassification {
        if direction == .internal || kind == .selfTransfer || counterpartyOwned {
            return .internalTransfer
        }
        if hasIncomingLeg && hasOutgoingLeg {
            return .swap
        }
        if kind == .bridge {
            return .ambiguousBridge
        }
        return direction == .incoming ? .externalIncoming : .externalOutgoing
    }
}

struct WalletPnLSummaryDTO: Sendable, Equatable {
    let walletId: UUID
    let displayCurrencyCode: String
    let state: PortfolioPnLState
    let changeUSD: Decimal?
    let displayChange: Decimal?
    let returnPercent: Decimal?
    let asOf: Date
    let windowStart: Date
    let comparedAssetCount: Int
    let relevantAssetCount: Int
    let missingChains: [SupportedChain]
}

struct PortfolioPnLAssetInput: Sendable, Equatable {
    let assetKey: String
    let chain: SupportedChain
    let startingValueUSD: Decimal
    let endingValueUSD: Decimal
}

struct PortfolioPnLFlowInput: Sendable, Equatable {
    let assetKey: String
    let signedValueUSD: Decimal
    let occurredAt: Date
}

struct PortfolioPnLCalculation: Sendable, Equatable {
    let changeUSD: Decimal
    let returnPercent: Decimal?
}

enum PortfolioPnLCalculator {
    static func calculate(
        assets: [PortfolioPnLAssetInput],
        flows: [PortfolioPnLFlowInput],
        windowStart: Date,
        windowEnd: Date
    ) -> PortfolioPnLCalculation {
        let duration = max(1, windowEnd.timeIntervalSince(windowStart))
        let startingValue = assets.reduce(Decimal.zero) { $0 + $1.startingValueUSD }
        let endingValue = assets.reduce(Decimal.zero) { $0 + $1.endingValueUSD }
        let signedCashFlow = flows.reduce(Decimal.zero) { $0 + $1.signedValueUSD }
        let change = endingValue - startingValue - signedCashFlow

        let weightedCashFlow = flows.reduce(Decimal.zero) { result, flow in
            let remaining = max(0, min(duration, windowEnd.timeIntervalSince(flow.occurredAt)))
            let weight = Decimal(remaining / duration)
            return result + flow.signedValueUSD * weight
        }
        let denominator = startingValue + weightedCashFlow
        let percent = denominator > 0 ? change / denominator * 100 : nil
        return PortfolioPnLCalculation(changeUSD: change, returnPercent: percent)
    }
}

final class PortfolioPnLRepository: @unchecked Sendable {
    private static let rawRetention: TimeInterval = 72 * 60 * 60
    private static let hourlyRetention: TimeInterval = 90 * 24 * 60 * 60
    private static let maintenanceInterval: TimeInterval = 24 * 60 * 60
    private static let deduplicationWindow: TimeInterval = 5 * 60
    private static let baselineTolerance: TimeInterval = 90 * 60
    private static let currentFreshness: TimeInterval = 30 * 60
    private static let maintenancePreferenceKey = "portfolioPnLMaintenanceAt"

    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    @discardableResult
    func beginRun(
        walletId: UUID,
        trigger: PortfolioRefreshTrigger,
        refreshMode: String,
        at date: Date = Date()
    ) throws -> UUID {
        let id = UUID()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO portfolio_snapshot_runs
                (id, wallet_id, trigger_raw, refresh_mode_raw, status_raw, started_at_ms)
                VALUES (?, ?, ?, ?, 'running', ?)
                """,
                arguments: [id.uuidString, walletId.uuidString, trigger.rawValue, refreshMode, date.databaseMilliseconds]
            )
        }
        return id
    }

    func markRunCancelled(_ runId: UUID, at date: Date = Date()) throws {
        try updateRun(
            runId,
            status: "cancelled",
            attemptedCount: 0,
            successfulCount: 0,
            completedAt: date
        )
    }

    func markRunFailed(_ runId: UUID, at date: Date = Date()) throws {
        try updateRun(
            runId,
            status: "failed",
            attemptedCount: 0,
            successfulCount: 0,
            completedAt: date
        )
    }

    struct BalanceSource: Sendable {
        let chain: SupportedChain
        let symbol: String
        let contract: String?
        let decimals: Int
        let rawBalance: String
        let cachedFiat: Decimal
        let cachedCurrencyCode: String
        let updatedAt: Date

        var assetKey: String {
            Self.assetKey(chain: chain, contract: contract)
        }

        var quantity: Decimal? {
            Self.quantity(rawBalance: rawBalance, decimals: decimals)
        }

        static func assetKey(chain: SupportedChain, contract: String?) -> String {
            let normalized: String
            if let contract, !contract.isEmpty {
                normalized = chain.family == .evm ? contract.lowercased() : contract
            } else {
                normalized = "native"
            }
            return "\(chain.rawValue):\(normalized)"
        }

        static func quantity(rawBalance: String, decimals: Int) -> Decimal? {
            guard let raw = Decimal(string: rawBalance), decimals >= 0 else { return nil }
            guard decimals > 0 else { return raw }
            var divisor: Decimal = 1
            for _ in 0..<decimals { divisor *= 10 }
            return raw / divisor
        }
    }

    func balanceSources(walletId: UUID, successfulChains: Set<SupportedChain>) throws -> [BalanceSource] {
        guard !successfulChains.isEmpty else { return [] }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT a.chain_raw, b.token_symbol, b.token_contract, b.decimals,
                       b.raw_balance, b.fiat_value_cached, b.fiat_currency_code, b.updated_at_ms
                FROM token_balances b
                JOIN wallet_addresses a ON a.id = b.address_id
                WHERE a.wallet_id = ?
                ORDER BY a.chain_raw, b.token_symbol, IFNULL(b.token_contract, '')
                """,
                arguments: [walletId.uuidString]
            ).compactMap { row in
                guard let chain = SupportedChain(rawValue: row["chain_raw"] as String),
                      successfulChains.contains(chain)
                else { return nil }
                return BalanceSource(
                    chain: chain,
                    symbol: (row["token_symbol"] as String).uppercased(),
                    contract: row["token_contract"],
                    decimals: row["decimals"],
                    rawBalance: row["raw_balance"],
                    cachedFiat: Decimal(string: row["fiat_value_cached"] as String) ?? 0,
                    cachedCurrencyCode: (row["fiat_currency_code"] as String).uppercased(),
                    updatedAt: Date(databaseMilliseconds: row["updated_at_ms"])
                )
            }
        }
    }

    struct PricedBalance: Sendable {
        let source: BalanceSource
        let unitPriceUSD: Decimal?
        let usdValue: Decimal?
        let priceSource: String?
        let priceAt: Date?
        let valuationStatus: String
    }

    func completeRun(
        runId: UUID,
        walletId: UUID,
        attemptedChains: Set<SupportedChain>,
        successfulChains: Set<SupportedChain>,
        failedChains: Set<SupportedChain>,
        balances: [PricedBalance],
        displayCurrencyCode: String,
        displayFXRate: Decimal?,
        calculatePnL: Bool,
        at date: Date = Date()
    ) throws {
        let unavailableAssetCount = balances.filter { $0.valuationStatus != "complete" }.count
        let runStatus: String
        if attemptedChains.isEmpty || successfulChains.isEmpty {
            runStatus = "failed"
        } else if !failedChains.isEmpty || unavailableAssetCount > 0 {
            runStatus = "partial"
        } else {
            runStatus = "complete"
        }

        try database.write { db in
            for chain in attemptedChains.sorted(by: { $0.rawValue < $1.rawValue }) {
                let succeeded = successfulChains.contains(chain)
                let assetCount = balances.lazy.filter { $0.source.chain == chain }.count
                try db.execute(
                    sql: """
                    INSERT INTO portfolio_chain_results
                    (run_id, wallet_id, chain_raw, status_raw, asset_count, captured_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(run_id, chain_raw) DO UPDATE SET
                        status_raw = excluded.status_raw,
                        asset_count = excluded.asset_count,
                        captured_at_ms = excluded.captured_at_ms
                    """,
                    arguments: [
                        runId.uuidString,
                        walletId.uuidString,
                        chain.rawValue,
                        succeeded ? "success" : "failed",
                        assetCount,
                        date.databaseMilliseconds
                    ]
                )
            }

            for balance in balances {
                try insertSnapshotIfNeeded(
                    db: db,
                    runId: runId,
                    walletId: walletId,
                    balance: balance,
                    capturedAt: date
                )
                try upsertRollup(db: db, walletId: walletId, balance: balance, resolution: "hourly", capturedAt: date)
                try upsertRollup(db: db, walletId: walletId, balance: balance, resolution: "daily", capturedAt: date)
            }

            try updateRun(
                runId,
                status: runStatus,
                attemptedCount: attemptedChains.count,
                successfulCount: successfulChains.count,
                completedAt: date,
                db: db
            )
        }

        if calculatePnL {
            try calculateAndStoreSummary(
                walletId: walletId,
                successfulChains: successfulChains,
                failedChains: failedChains,
                displayCurrencyCode: displayCurrencyCode,
                displayFXRate: displayFXRate,
                asOf: date
            )
        }
        try performMaintenanceIfNeeded(now: date)
    }

    func projectLatestSummary(
        walletId: UUID,
        displayCurrencyCode: String,
        fxRateFromUSD: Decimal,
        at date: Date = Date()
    ) throws {
        let source = try latestSummary(walletId: walletId, preferCurrencyCode: "USD")
            ?? latestSummary(walletId: walletId, preferCurrencyCode: nil)
        guard let source else { return }
        try storeSummary(
            walletId: walletId,
            displayCurrencyCode: displayCurrencyCode,
            state: source.state,
            changeUSD: source.changeUSD,
            displayChange: source.changeUSD.map { $0 * fxRateFromUSD },
            returnPercent: source.returnPercent,
            fxRateFromUSD: fxRateFromUSD,
            asOf: source.asOf,
            windowStart: source.windowStart,
            comparedAssetCount: source.comparedAssetCount,
            relevantAssetCount: source.relevantAssetCount,
            missingChains: source.missingChains,
            updatedAt: date
        )
    }

    func latestSummary(walletId: UUID, preferCurrencyCode: String?) throws -> WalletPnLSummaryDTO? {
        try database.read { db in
            var sql = "SELECT * FROM wallet_pnl_summaries WHERE wallet_id = ?"
            var arguments: StatementArguments = [walletId.uuidString]
            if let preferCurrencyCode {
                sql += " AND display_currency_code = ?"
                arguments += [preferCurrencyCode.uppercased()]
            }
            sql += " ORDER BY updated_at_ms DESC LIMIT 1"
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
            return Self.summary(row: row)
        }
    }

    func upsertFlowValuations(_ values: [PortfolioFlowValue]) throws {
        guard !values.isEmpty else { return }
        try database.write { db in
            for value in values {
                try db.execute(
                    sql: """
                    INSERT INTO portfolio_flow_valuations
                    (transaction_id, wallet_id, chain_raw, asset_key, classification_raw,
                     signed_amount, occurred_at_ms, unit_price_usd, unit_price_usd_numeric,
                     signed_value_usd, signed_value_usd_numeric, price_source, price_at_ms,
                     valuation_status_raw, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(transaction_id) DO UPDATE SET
                        classification_raw = excluded.classification_raw,
                        signed_amount = excluded.signed_amount,
                        unit_price_usd = excluded.unit_price_usd,
                        unit_price_usd_numeric = excluded.unit_price_usd_numeric,
                        signed_value_usd = excluded.signed_value_usd,
                        signed_value_usd_numeric = excluded.signed_value_usd_numeric,
                        price_source = excluded.price_source,
                        price_at_ms = excluded.price_at_ms,
                        valuation_status_raw = excluded.valuation_status_raw,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        value.transactionId.uuidString,
                        value.walletId.uuidString,
                        value.chain.rawValue,
                        value.assetKey,
                        value.classification,
                        value.signedAmount.databaseText,
                        value.occurredAt.databaseMilliseconds,
                        value.unitPriceUSD?.databaseText,
                        value.unitPriceUSD?.databaseDouble,
                        value.signedValueUSD?.databaseText,
                        value.signedValueUSD?.databaseDouble,
                        value.priceSource,
                        value.priceAt?.databaseMilliseconds,
                        value.valuationStatus,
                        Date.databaseMilliseconds
                    ]
                )
            }
        }
    }

    struct TransactionSource: Sendable {
        let id: UUID
        let chain: SupportedChain
        let txHash: String
        let direction: TransactionDirection
        let kind: TransactionKind
        let amount: Decimal
        let symbol: String
        let contract: String?
        let occurredAt: Date
        let counterparty: String

        var assetKey: String { BalanceSource.assetKey(chain: chain, contract: contract) }
    }

    func confirmedTransactions(walletId: UUID, since: Date) throws -> (rows: [TransactionSource], ownedAddresses: Set<String>) {
        try database.read { db in
            let addresses = Set(try String.fetchAll(
                db,
                sql: "SELECT address FROM wallet_addresses WHERE wallet_id = ?",
                arguments: [walletId.uuidString]
            ).map { $0.lowercased() })
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT t.*, a.chain_raw
                FROM transactions t
                JOIN wallet_addresses a ON a.id = t.address_id
                WHERE a.wallet_id = ?
                  AND t.status_raw = ?
                  AND t.occurred_at_ms >= ?
                ORDER BY t.occurred_at_ms ASC
                """,
                arguments: [walletId.uuidString, TransactionStatus.confirmed.rawValue, since.databaseMilliseconds]
            ).compactMap { row -> TransactionSource? in
                guard let id = UUID(uuidString: row["id"] as String),
                      let chain = SupportedChain(rawValue: row["chain_raw"] as String),
                      let amount = Decimal(string: row["amount_raw"] as String)
                else { return nil }
                let directionRaw: String = row["direction_raw"]
                return TransactionSource(
                    id: id,
                    chain: chain,
                    txHash: row["tx_hash"],
                    direction: TransactionDirection(rawValue: directionRaw) ?? .incoming,
                    kind: TransactionKind.effectiveKind(kindRaw: row["kind_raw"], directionRaw: directionRaw),
                    amount: amount,
                    symbol: (row["token_symbol"] as String).uppercased(),
                    contract: row["token_contract"],
                    occurredAt: Date(databaseMilliseconds: row["occurred_at_ms"]),
                    counterparty: row["counterparty"]
                )
            }
            return (rows, addresses)
        }
    }

    private func calculateAndStoreSummary(
        walletId: UUID,
        successfulChains: Set<SupportedChain>,
        failedChains: Set<SupportedChain>,
        displayCurrencyCode: String,
        displayFXRate: Decimal?,
        asOf: Date
    ) throws {
        let windowStart = asOf.addingTimeInterval(-24 * 60 * 60)
        let currentRows = try snapshotRows(
            walletId: walletId,
            chains: successfulChains,
            from: asOf.addingTimeInterval(-Self.currentFreshness),
            through: asOf,
            target: asOf
        )
        let baselineRows = try snapshotRows(
            walletId: walletId,
            chains: successfulChains,
            from: windowStart.addingTimeInterval(-Self.baselineTolerance),
            through: windowStart.addingTimeInterval(Self.baselineTolerance),
            target: windowStart
        )
        let baselineCoveredChains = try coveredChains(
            walletId: walletId,
            around: windowStart,
            tolerance: Self.baselineTolerance
        )

        let earliestSnapshot = try database.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MIN(captured_at_ms) FROM portfolio_asset_snapshots WHERE wallet_id = ?",
                arguments: [walletId.uuidString]
            )
        }.map(Date.init(databaseMilliseconds:))

        let flowRows = try flowRows(walletId: walletId, from: windowStart, through: asOf)
        let keys = Set(currentRows.keys).union(baselineRows.keys).union(flowRows.map(\.assetKey))
        let flowChainsByKey = Dictionary(grouping: flowRows, by: \.assetKey).compactMapValues { $0.first?.chain }
        var assets: [PortfolioPnLAssetInput] = []
        var completeFlows: [PortfolioPnLFlowInput] = []
        var incompleteKeys = Set<String>()
        var missingChains = failedChains

        for key in keys {
            guard let chain = currentRows[key]?.chain ?? baselineRows[key]?.chain ?? flowChainsByKey[key] else {
                incompleteKeys.insert(key)
                continue
            }

            let ending: Decimal?
            if let current = currentRows[key] {
                ending = current.usdValue
            } else {
                ending = successfulChains.contains(chain) ? 0 : nil
            }

            let starting: Decimal?
            if let baseline = baselineRows[key] {
                starting = baseline.usdValue
            } else {
                starting = baselineCoveredChains.contains(chain) ? 0 : nil
            }

            guard let ending, let starting else {
                incompleteKeys.insert(key)
                missingChains.insert(chain)
                continue
            }
            assets.append(PortfolioPnLAssetInput(
                assetKey: key,
                chain: chain,
                startingValueUSD: starting,
                endingValueUSD: ending
            ))
        }

        for flow in flowRows {
            guard flow.classification == "externalIncoming" || flow.classification == "externalOutgoing" else {
                if flow.valuationStatus != "complete" { incompleteKeys.insert(flow.assetKey) }
                continue
            }
            guard flow.valuationStatus == "complete", let value = flow.signedValueUSD else {
                incompleteKeys.insert(flow.assetKey)
                missingChains.insert(flow.chain)
                continue
            }
            completeFlows.append(PortfolioPnLFlowInput(
                assetKey: flow.assetKey,
                signedValueUSD: value,
                occurredAt: flow.occurredAt
            ))
        }

        let comparableAssets = assets.filter { !incompleteKeys.contains($0.assetKey) }
        let state: PortfolioPnLState
        let calculation: PortfolioPnLCalculation?
        if comparableAssets.isEmpty {
            let stillCollecting = !successfulChains.isEmpty
                && (baselineCoveredChains.isEmpty
                    || earliestSnapshot.map { $0 > windowStart.addingTimeInterval(-Self.baselineTolerance) } ?? true)
            state = stillCollecting ? .collecting : .unavailable
            calculation = nil
        } else {
            calculation = PortfolioPnLCalculator.calculate(
                assets: comparableAssets,
                flows: completeFlows.filter { !incompleteKeys.contains($0.assetKey) },
                windowStart: windowStart,
                windowEnd: asOf
            )
            state = incompleteKeys.isEmpty && failedChains.isEmpty && comparableAssets.count == keys.count ? .complete : .partial
        }

        let displayChange = calculation.flatMap { calculation in
            displayFXRate.map { calculation.changeUSD * $0 }
        }
        try storeSummary(
            walletId: walletId,
            displayCurrencyCode: displayCurrencyCode,
            state: state,
            changeUSD: calculation?.changeUSD,
            displayChange: displayChange,
            returnPercent: calculation?.returnPercent,
            fxRateFromUSD: displayFXRate,
            asOf: asOf,
            windowStart: windowStart,
            comparedAssetCount: comparableAssets.count,
            relevantAssetCount: keys.count,
            missingChains: Array(missingChains),
            updatedAt: asOf
        )

        if displayCurrencyCode.uppercased() != "USD" {
            try storeSummary(
                walletId: walletId,
                displayCurrencyCode: "USD",
                state: state,
                changeUSD: calculation?.changeUSD,
                displayChange: calculation?.changeUSD,
                returnPercent: calculation?.returnPercent,
                fxRateFromUSD: 1,
                asOf: asOf,
                windowStart: windowStart,
                comparedAssetCount: comparableAssets.count,
                relevantAssetCount: keys.count,
                missingChains: Array(missingChains),
                updatedAt: asOf
            )
        }
    }

    private struct SnapshotValue {
        let assetKey: String
        let chain: SupportedChain
        let usdValue: Decimal?
        let capturedAt: Date
    }

    private func snapshotRows(
        walletId: UUID,
        chains: Set<SupportedChain>,
        from: Date,
        through: Date,
        target: Date
    ) throws -> [String: SnapshotValue] {
        guard !chains.isEmpty else { return [:] }
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_key, chain_raw, usd_value, valuation_status_raw, captured_at_ms
                FROM portfolio_asset_snapshots
                WHERE wallet_id = ? AND captured_at_ms >= ? AND captured_at_ms <= ?
                ORDER BY captured_at_ms ASC
                """,
                arguments: [walletId.uuidString, from.databaseMilliseconds, through.databaseMilliseconds]
            )
            var best: [String: (value: SnapshotValue, delta: TimeInterval)] = [:]
            for row in rows {
                guard let chain = SupportedChain(rawValue: row["chain_raw"] as String), chains.contains(chain) else { continue }
                let capturedAt = Date(databaseMilliseconds: row["captured_at_ms"])
                let delta = abs(capturedAt.timeIntervalSince(target))
                let key: String = row["asset_key"]
                let value = SnapshotValue(
                    assetKey: key,
                    chain: chain,
                    usdValue: (row["usd_value"] as String?).flatMap { Decimal(string: $0) },
                    capturedAt: capturedAt
                )
                if best[key] == nil || delta < best[key]!.delta {
                    best[key] = (value, delta)
                }
            }
            return best.mapValues(\.value)
        }
    }

    private func coveredChains(
        walletId: UUID,
        around target: Date,
        tolerance: TimeInterval
    ) throws -> Set<SupportedChain> {
        let lower = target.addingTimeInterval(-tolerance).databaseMilliseconds
        let upper = target.addingTimeInterval(tolerance).databaseMilliseconds
        return try database.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT chain_raw
                FROM portfolio_chain_results
                WHERE wallet_id = ?
                  AND status_raw = 'success'
                  AND captured_at_ms BETWEEN ? AND ?
                """,
                arguments: [walletId.uuidString, lower, upper]
            ).compactMap { SupportedChain(rawValue: $0) })
        }
    }

    private struct StoredFlow {
        let assetKey: String
        let chain: SupportedChain
        let classification: String
        let signedValueUSD: Decimal?
        let valuationStatus: String
        let occurredAt: Date
    }

    private func flowRows(walletId: UUID, from: Date, through: Date) throws -> [StoredFlow] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT asset_key, chain_raw, classification_raw, signed_value_usd,
                       valuation_status_raw, occurred_at_ms
                FROM portfolio_flow_valuations
                WHERE wallet_id = ? AND occurred_at_ms >= ? AND occurred_at_ms <= ?
                ORDER BY occurred_at_ms ASC
                """,
                arguments: [walletId.uuidString, from.databaseMilliseconds, through.databaseMilliseconds]
            ).compactMap { row -> StoredFlow? in
                guard let chain = SupportedChain(rawValue: row["chain_raw"] as String) else { return nil }
                return StoredFlow(
                    assetKey: row["asset_key"],
                    chain: chain,
                    classification: row["classification_raw"],
                    signedValueUSD: (row["signed_value_usd"] as String?).flatMap { Decimal(string: $0) },
                    valuationStatus: row["valuation_status_raw"],
                    occurredAt: Date(databaseMilliseconds: row["occurred_at_ms"])
                )
            }
        }
    }

    private func storeSummary(
        walletId: UUID,
        displayCurrencyCode: String,
        state: PortfolioPnLState,
        changeUSD: Decimal?,
        displayChange: Decimal?,
        returnPercent: Decimal?,
        fxRateFromUSD: Decimal?,
        asOf: Date,
        windowStart: Date,
        comparedAssetCount: Int,
        relevantAssetCount: Int,
        missingChains: [SupportedChain],
        updatedAt: Date
    ) throws {
        let currency = displayCurrencyCode.uppercased()
        let lookupKey = "\(walletId.uuidString)|\(currency)"
        let encodedChains = (try? JSONEncoder().encode(missingChains.map(\.rawValue).sorted())) ?? Data("[]".utf8)
        let chainsJSON = String(data: encodedChains, encoding: .utf8) ?? "[]"
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallet_pnl_summaries
                (id, lookup_key, wallet_id, display_currency_code, state_raw,
                 change_usd, change_usd_numeric, display_change, display_change_numeric,
                 return_percent, return_percent_numeric, fx_rate_from_usd,
                 as_of_ms, window_start_ms, compared_asset_count, relevant_asset_count,
                 missing_chains_json, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(lookup_key) DO UPDATE SET
                    state_raw = excluded.state_raw,
                    change_usd = excluded.change_usd,
                    change_usd_numeric = excluded.change_usd_numeric,
                    display_change = excluded.display_change,
                    display_change_numeric = excluded.display_change_numeric,
                    return_percent = excluded.return_percent,
                    return_percent_numeric = excluded.return_percent_numeric,
                    fx_rate_from_usd = excluded.fx_rate_from_usd,
                    as_of_ms = excluded.as_of_ms,
                    window_start_ms = excluded.window_start_ms,
                    compared_asset_count = excluded.compared_asset_count,
                    relevant_asset_count = excluded.relevant_asset_count,
                    missing_chains_json = excluded.missing_chains_json,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    UUID().uuidString,
                    lookupKey,
                    walletId.uuidString,
                    currency,
                    state.rawValue,
                    changeUSD?.databaseText,
                    changeUSD?.databaseDouble,
                    displayChange?.databaseText,
                    displayChange?.databaseDouble,
                    returnPercent?.databaseText,
                    returnPercent?.databaseDouble,
                    fxRateFromUSD?.databaseText,
                    asOf.databaseMilliseconds,
                    windowStart.databaseMilliseconds,
                    comparedAssetCount,
                    relevantAssetCount,
                    chainsJSON,
                    updatedAt.databaseMilliseconds
                ]
            )
        }
    }

    private func insertSnapshotIfNeeded(
        db: Database,
        runId: UUID,
        walletId: UUID,
        balance: PricedBalance,
        capturedAt: Date
    ) throws {
        let cutoff = capturedAt.addingTimeInterval(-Self.deduplicationWindow).databaseMilliseconds
        let duplicate = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM portfolio_asset_snapshots
                WHERE wallet_id = ? AND asset_key = ? AND captured_at_ms >= ?
                  AND raw_balance = ? AND valuation_status_raw = ?
                  AND IFNULL(usd_value, '') = IFNULL(?, '')
            )
            """,
            arguments: [
                walletId.uuidString,
                balance.source.assetKey,
                cutoff,
                balance.source.rawBalance,
                balance.valuationStatus,
                balance.usdValue?.databaseText
            ]
        ) ?? false
        guard !duplicate, let quantity = balance.source.quantity else { return }
        try db.execute(
            sql: """
            INSERT INTO portfolio_asset_snapshots
            (id, run_id, wallet_id, chain_raw, asset_key, token_symbol, token_contract,
             decimals, raw_balance, quantity, unit_price_usd, unit_price_usd_numeric,
             usd_value, usd_value_numeric, price_source, price_at_ms,
             valuation_status_raw, captured_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString,
                runId.uuidString,
                walletId.uuidString,
                balance.source.chain.rawValue,
                balance.source.assetKey,
                balance.source.symbol,
                balance.source.contract,
                balance.source.decimals,
                balance.source.rawBalance,
                quantity.databaseText,
                balance.unitPriceUSD?.databaseText,
                balance.unitPriceUSD?.databaseDouble,
                balance.usdValue?.databaseText,
                balance.usdValue?.databaseDouble,
                balance.priceSource,
                balance.priceAt?.databaseMilliseconds,
                balance.valuationStatus,
                capturedAt.databaseMilliseconds
            ]
        )
    }

    private func upsertRollup(
        db: Database,
        walletId: UUID,
        balance: PricedBalance,
        resolution: String,
        capturedAt: Date
    ) throws {
        guard let quantity = balance.source.quantity else { return }
        let calendar = Calendar(identifier: .gregorian)
        let bucket: Date
        if resolution == "hourly" {
            bucket = calendar.dateInterval(of: .hour, for: capturedAt)?.start ?? capturedAt
        } else {
            bucket = calendar.dateInterval(of: .day, for: capturedAt)?.start ?? capturedAt
        }
        try db.execute(
            sql: """
            INSERT INTO portfolio_asset_rollups
            (wallet_id, chain_raw, asset_key, resolution_raw, bucket_start_ms,
             token_symbol, token_contract, decimals, raw_balance, quantity,
             unit_price_usd, unit_price_usd_numeric, usd_value, usd_value_numeric,
             valuation_status_raw, source_captured_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(wallet_id, asset_key, resolution_raw, bucket_start_ms) DO UPDATE SET
                raw_balance = excluded.raw_balance,
                quantity = excluded.quantity,
                unit_price_usd = excluded.unit_price_usd,
                unit_price_usd_numeric = excluded.unit_price_usd_numeric,
                usd_value = excluded.usd_value,
                usd_value_numeric = excluded.usd_value_numeric,
                valuation_status_raw = excluded.valuation_status_raw,
                source_captured_at_ms = excluded.source_captured_at_ms
            """,
            arguments: [
                walletId.uuidString,
                balance.source.chain.rawValue,
                balance.source.assetKey,
                resolution,
                bucket.databaseMilliseconds,
                balance.source.symbol,
                balance.source.contract,
                balance.source.decimals,
                balance.source.rawBalance,
                quantity.databaseText,
                balance.unitPriceUSD?.databaseText,
                balance.unitPriceUSD?.databaseDouble,
                balance.usdValue?.databaseText,
                balance.usdValue?.databaseDouble,
                balance.valuationStatus,
                capturedAt.databaseMilliseconds
            ]
        )
    }

    private func performMaintenanceIfNeeded(now: Date) throws {
        try database.write { db in
            let last = try Int64.fetchOne(
                db,
                sql: "SELECT int_value FROM app_preferences WHERE key = ?",
                arguments: [Self.maintenancePreferenceKey]
            ).map(Date.init(databaseMilliseconds:))
            guard last == nil || now.timeIntervalSince(last!) >= Self.maintenanceInterval else { return }

            let rawCutoff = now.addingTimeInterval(-Self.rawRetention).databaseMilliseconds
            let hourlyCutoff = now.addingTimeInterval(-Self.hourlyRetention).databaseMilliseconds
            try db.execute(sql: "DELETE FROM portfolio_asset_snapshots WHERE captured_at_ms < ?", arguments: [rawCutoff])
            try db.execute(sql: "DELETE FROM portfolio_snapshot_runs WHERE completed_at_ms IS NOT NULL AND completed_at_ms < ?", arguments: [rawCutoff])
            try db.execute(
                sql: "DELETE FROM portfolio_asset_rollups WHERE resolution_raw = 'hourly' AND bucket_start_ms < ?",
                arguments: [hourlyCutoff]
            )
            try db.execute(
                sql: """
                INSERT INTO app_preferences (key, value_type, int_value, updated_at_ms)
                VALUES (?, 'int', ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_type = 'int', int_value = excluded.int_value, updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [Self.maintenancePreferenceKey, now.databaseMilliseconds, now.databaseMilliseconds]
            )
        }
    }

    private func updateRun(
        _ runId: UUID,
        status: String,
        attemptedCount: Int,
        successfulCount: Int,
        completedAt: Date
    ) throws {
        try database.write { db in
            try updateRun(
                runId,
                status: status,
                attemptedCount: attemptedCount,
                successfulCount: successfulCount,
                completedAt: completedAt,
                db: db
            )
        }
    }

    private func updateRun(
        _ runId: UUID,
        status: String,
        attemptedCount: Int,
        successfulCount: Int,
        completedAt: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE portfolio_snapshot_runs
            SET status_raw = ?, completed_at_ms = ?, attempted_chain_count = ?, successful_chain_count = ?
            WHERE id = ?
            """,
            arguments: [status, completedAt.databaseMilliseconds, attemptedCount, successfulCount, runId.uuidString]
        )
    }

    static func summary(row: Row) -> WalletPnLSummaryDTO? {
        guard let walletId = UUID(uuidString: row["wallet_id"] as String) else { return nil }
        let chainRaws: [String]
        if let data = (row["missing_chains_json"] as String).data(using: .utf8) {
            chainRaws = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            chainRaws = []
        }
        return WalletPnLSummaryDTO(
            walletId: walletId,
            displayCurrencyCode: row["display_currency_code"],
            state: PortfolioPnLState(rawValue: row["state_raw"] as String) ?? .unavailable,
            changeUSD: (row["change_usd"] as String?).flatMap { Decimal(string: $0) },
            displayChange: (row["display_change"] as String?).flatMap { Decimal(string: $0) },
            returnPercent: (row["return_percent"] as String?).flatMap { Decimal(string: $0) },
            asOf: Date(databaseMilliseconds: row["as_of_ms"]),
            windowStart: Date(databaseMilliseconds: row["window_start_ms"]),
            comparedAssetCount: row["compared_asset_count"],
            relevantAssetCount: row["relevant_asset_count"],
            missingChains: chainRaws.compactMap(SupportedChain.init(rawValue:))
        )
    }
}

struct PortfolioFlowValue: Sendable {
    let transactionId: UUID
    let walletId: UUID
    let chain: SupportedChain
    let assetKey: String
    let classification: String
    let signedAmount: Decimal
    let occurredAt: Date
    let unitPriceUSD: Decimal?
    let signedValueUSD: Decimal?
    let priceSource: String?
    let priceAt: Date?
    let valuationStatus: String
}

actor PortfolioHistoryCoordinator {
    static let shared = PortfolioHistoryCoordinator()

    func beginRun(
        walletId: UUID,
        trigger: PortfolioRefreshTrigger,
        refreshMode: String,
        database: AppDatabase
    ) -> UUID? {
        try? PortfolioPnLRepository(database: database).beginRun(
            walletId: walletId,
            trigger: trigger,
            refreshMode: refreshMode
        )
    }

    func cancelRun(_ runId: UUID?, database: AppDatabase) {
        guard let runId else { return }
        try? PortfolioPnLRepository(database: database).markRunCancelled(runId)
    }

    func failRun(_ runId: UUID?, database: AppDatabase) {
        guard let runId else { return }
        try? PortfolioPnLRepository(database: database).markRunFailed(runId)
    }

    func finishRun(
        runId: UUID?,
        walletId: UUID,
        refreshMode: String,
        attemptedChains: Set<SupportedChain>,
        successfulChains: Set<SupportedChain>,
        failedChains: Set<SupportedChain>,
        displayCurrencyCode: String,
        database: AppDatabase
    ) async {
        guard let runId else { return }
        let repository = PortfolioPnLRepository(database: database)
        do {
            await TokenPricingEngine.shared.configure(database: database)
            let sources = try repository.balanceSources(walletId: walletId, successfulChains: successfulChains)
            let prices = await TokenPricingEngine.shared.unitPrices(
                symbols: Array(Set(sources.map(\.symbol))),
                currencyCode: "USD"
            )
            let cachedCross: Decimal?
            if displayCurrencyCode.uppercased() == "USD" {
                cachedCross = 1
            } else {
                cachedCross = await TokenPricingEngine.shared.crossRate(from: displayCurrencyCode, to: "USD")
            }
            let displayRate: Decimal?
            if displayCurrencyCode.uppercased() == "USD" {
                displayRate = 1
            } else {
                displayRate = await TokenPricingEngine.shared.crossRate(from: "USD", to: displayCurrencyCode)
            }
            let now = Date()
            let priced = sources.map { source -> PortfolioPnLRepository.PricedBalance in
                guard let quantity = source.quantity else {
                    return .init(source: source, unitPriceUSD: nil, usdValue: nil, priceSource: nil, priceAt: nil, valuationStatus: "unavailable")
                }
                if quantity == 0 {
                    return .init(source: source, unitPriceUSD: nil, usdValue: 0, priceSource: "zero balance", priceAt: now, valuationStatus: "complete")
                }
                if let resolved = prices[source.symbol], !resolved.isStale, resolved.amount > 0 {
                    return .init(
                        source: source,
                        unitPriceUSD: resolved.amount,
                        usdValue: quantity * resolved.amount,
                        priceSource: resolved.source,
                        priceAt: now,
                        valuationStatus: "complete"
                    )
                }
                if refreshMode == "full", source.cachedFiat > 0,
                   let cachedCross, source.cachedCurrencyCode == displayCurrencyCode.uppercased() {
                    let value = source.cachedFiat * cachedCross
                    return .init(
                        source: source,
                        unitPriceUSD: value / quantity,
                        usdValue: value,
                        priceSource: "scanner quote · FX",
                        priceAt: source.updatedAt,
                        valuationStatus: "complete"
                    )
                }
                return .init(source: source, unitPriceUSD: nil, usdValue: nil, priceSource: nil, priceAt: nil, valuationStatus: "unavailable")
            }

            if refreshMode == "full" {
                try await resolveFlows(walletId: walletId, repository: repository)
            }
            try repository.completeRun(
                runId: runId,
                walletId: walletId,
                attemptedChains: attemptedChains,
                successfulChains: successfulChains,
                failedChains: failedChains,
                balances: priced,
                displayCurrencyCode: displayCurrencyCode,
                displayFXRate: displayRate,
                calculatePnL: refreshMode == "full",
                at: now
            )
        } catch {
            try? repository.markRunFailed(runId)
            DiagnosticsLogStore.shared.record(
                .warning,
                category: "portfolio-pnl",
                message: "Portfolio history capture failed",
                metadata: ["walletId": walletId.uuidString, "error": String(describing: error)]
            )
        }
    }

    private func resolveFlows(walletId: UUID, repository: PortfolioPnLRepository) async throws {
        let since = Date().addingTimeInterval(-27 * 60 * 60)
        let source = try repository.confirmedTransactions(walletId: walletId, since: since)
        let grouped = Dictionary(grouping: source.rows, by: { "\($0.chain.rawValue)|\($0.txHash)" })
        var values: [PortfolioFlowValue] = []
        for transaction in source.rows {
            let group = grouped["\(transaction.chain.rawValue)|\(transaction.txHash)"] ?? []
            let hasIncoming = group.contains { $0.direction == .incoming }
            let hasOutgoing = group.contains { $0.direction == .outgoing }
            let counterpartyOwned = source.ownedAddresses.contains(transaction.counterparty.lowercased())

            let classification = PortfolioFlowClassifier.classify(
                direction: transaction.direction,
                kind: transaction.kind,
                counterpartyOwned: counterpartyOwned,
                hasIncomingLeg: hasIncoming,
                hasOutgoingLeg: hasOutgoing
            )

            if classification == .internalTransfer || classification == .swap {
                values.append(.init(
                    transactionId: transaction.id,
                    walletId: walletId,
                    chain: transaction.chain,
                    assetKey: transaction.assetKey,
                    classification: classification.rawValue,
                    signedAmount: 0,
                    occurredAt: transaction.occurredAt,
                    unitPriceUSD: nil,
                    signedValueUSD: 0,
                    priceSource: nil,
                    priceAt: nil,
                    valuationStatus: "complete"
                ))
                continue
            }
            guard classification != .ambiguousBridge else {
                values.append(.init(
                    transactionId: transaction.id,
                    walletId: walletId,
                    chain: transaction.chain,
                    assetKey: transaction.assetKey,
                    classification: classification.rawValue,
                    signedAmount: 0,
                    occurredAt: transaction.occurredAt,
                    unitPriceUSD: nil,
                    signedValueUSD: nil,
                    priceSource: nil,
                    priceAt: nil,
                    valuationStatus: "ambiguous"
                ))
                continue
            }

            let sign: Decimal = transaction.direction == .incoming ? 1 : -1
            let signedAmount = transaction.amount * sign
            let historical = await TokenPricingEngine.shared.historicalUSDPrice(
                symbol: transaction.symbol,
                at: transaction.occurredAt
            )
            values.append(.init(
                transactionId: transaction.id,
                walletId: walletId,
                chain: transaction.chain,
                assetKey: transaction.assetKey,
                classification: classification.rawValue,
                signedAmount: signedAmount,
                occurredAt: transaction.occurredAt,
                unitPriceUSD: historical?.amount,
                signedValueUSD: historical.map { signedAmount * $0.amount },
                priceSource: historical?.source,
                priceAt: historical?.at,
                valuationStatus: historical == nil ? "unavailable" : "complete"
            ))
        }
        try repository.upsertFlowValuations(values)
    }
}
