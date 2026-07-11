import Combine
import Foundation
import GRDB
import OSLog

enum WalletAssetRouteTemplateFlow: String, Codable, Sendable {
    case receive
    case send
}

enum WalletAssetRouteTemplateAssetKind: String, Codable, Sendable {
    case native
    case token
}

enum WalletAssetRouteTemplateSource: String, Codable, Sendable {
    case catalog
    case custom
}

struct WalletAssetRouteTemplateRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let walletId: UUID
    let flow: WalletAssetRouteTemplateFlow
    let assetKind: WalletAssetRouteTemplateAssetKind
    let chain: SupportedChain
    let symbol: String
    let name: String
    let contract: String?
    let decimals: Int?
    let sourceRaw: String?
    let createdAt: Date
    let updatedAt: Date

    var isNative: Bool { assetKind == .native }

    var displayName: String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? symbol : cleaned
    }

    var subtitle: String {
        isNative ? symbol : "\(symbol) on \(chain.displayName)"
    }

    var logoContract: String? {
        isNative ? nil : contract
    }

    init?(_ row: Row) {
        guard
            let id = UUID(uuidString: row["id"]),
            let walletId = UUID(uuidString: row["wallet_id"]),
            let flow = WalletAssetRouteTemplateFlow(rawValue: row["flow_raw"]),
            let assetKind = WalletAssetRouteTemplateAssetKind(rawValue: row["asset_kind_raw"]),
            let chain = SupportedChain(rawValue: row["chain_raw"])
        else { return nil }
        self.id = id
        self.walletId = walletId
        self.flow = flow
        self.assetKind = assetKind
        self.chain = chain
        symbol = row["symbol"]
        name = row["name"]
        contract = row["contract"]
        decimals = row["decimals"]
        sourceRaw = row["source_raw"]
        createdAt = Date(databaseMilliseconds: row["created_at_ms"])
        updatedAt = Date(databaseMilliseconds: row["updated_at_ms"])
    }
}

final class WalletAssetRouteTemplateRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func upsertNative(
        walletId: UUID,
        flow: WalletAssetRouteTemplateFlow,
        chain: SupportedChain
    ) throws {
        try upsert(
            walletId: walletId,
            flow: flow,
            assetKind: .native,
            chain: chain,
            symbol: chain.ticker,
            name: chain.displayName,
            contract: nil,
            decimals: nil,
            sourceRaw: nil
        )
    }

    func upsertToken(
        walletId: UUID,
        flow: WalletAssetRouteTemplateFlow,
        chain: SupportedChain,
        symbol: String,
        name: String,
        contract: String?,
        decimals: Int?,
        sourceRaw: String?
    ) throws {
        try upsert(
            walletId: walletId,
            flow: flow,
            assetKind: .token,
            chain: chain,
            symbol: symbol,
            name: name,
            contract: contract,
            decimals: decimals,
            sourceRaw: sourceRaw
        )
    }

    func latest(
        walletId: UUID,
        flow: WalletAssetRouteTemplateFlow,
        limit: Int = 3
    ) throws -> [WalletAssetRouteTemplateRecord] {
        try database.read { db in
            try Self.latest(db, walletId: walletId, flow: flow, limit: limit)
        }
    }

    private func upsert(
        walletId: UUID,
        flow: WalletAssetRouteTemplateFlow,
        assetKind: WalletAssetRouteTemplateAssetKind,
        chain: SupportedChain,
        symbol: String,
        name: String,
        contract: String?,
        decimals: Int?,
        sourceRaw: String?
    ) throws {
        let normalizedSymbol = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalizedSymbol.isEmpty else { return }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = cleanName.isEmpty ? normalizedSymbol : cleanName
        let cleanContract = contract?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let dedupKey = Self.dedupKey(
            assetKind: assetKind,
            chain: chain,
            symbol: normalizedSymbol,
            contract: cleanContract
        )
        let now = Date.databaseMilliseconds
        var arguments: StatementArguments = []
        arguments += [
            UUID().uuidString,
            walletId.uuidString,
            flow.rawValue,
            assetKind.rawValue,
            chain.rawValue,
            normalizedSymbol,
            displayName
        ]
        arguments += [cleanContract]
        arguments += [decimals]
        arguments += [sourceRaw]
        arguments += [dedupKey, now, now]

        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallet_asset_route_templates
                (id, wallet_id, flow_raw, asset_kind_raw, chain_raw, symbol, name, contract,
                 decimals, source_raw, dedup_key, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(wallet_id, flow_raw, dedup_key) DO UPDATE SET
                    symbol = excluded.symbol,
                    name = excluded.name,
                    contract = excluded.contract,
                    decimals = excluded.decimals,
                    source_raw = excluded.source_raw,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: arguments
            )
        }
    }

    static func latest(
        _ db: Database,
        walletId: UUID,
        flow: WalletAssetRouteTemplateFlow,
        limit: Int = 3
    ) throws -> [WalletAssetRouteTemplateRecord] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT *
            FROM wallet_asset_route_templates
            WHERE wallet_id = ? AND flow_raw = ?
            ORDER BY updated_at_ms DESC
            LIMIT ?
            """,
            arguments: [walletId.uuidString, flow.rawValue, max(0, limit)]
        ).compactMap(WalletAssetRouteTemplateRecord.init)
    }

    private static func dedupKey(
        assetKind: WalletAssetRouteTemplateAssetKind,
        chain: SupportedChain,
        symbol: String,
        contract: String?
    ) -> String {
        switch assetKind {
        case .native:
            return "native|\(chain.rawValue)"
        case .token:
            let normalizedContract = contract.map {
                chain.family == .evm ? $0.lowercased() : $0
            } ?? ""
            return "token|\(chain.rawValue)|\(symbol.uppercased())|\(normalizedContract)"
        }
    }
}

@MainActor
final class WalletAssetRouteTemplatesObservation: ObservableObject {
    @Published private(set) var templates: [WalletAssetRouteTemplateRecord] = []
    @Published private(set) var lastError: Error?

    private let database: AppDatabase
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "asset-route-templates")
    private var walletId: UUID?
    private var flow: WalletAssetRouteTemplateFlow?
    private var cancellable: AnyDatabaseCancellable?

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    deinit {
        cancellable?.cancel()
    }

    func setScope(walletId newWalletId: UUID?, flow newFlow: WalletAssetRouteTemplateFlow) {
        guard walletId != newWalletId || flow != newFlow else { return }
        walletId = newWalletId
        flow = newFlow
        cancellable?.cancel()
        guard let newWalletId else {
            templates = []
            lastError = nil
            return
        }
        start(walletId: newWalletId, flow: newFlow)
    }

    private func start(walletId: UUID, flow: WalletAssetRouteTemplateFlow) {
        let observation = ValueObservation.tracking { db in
            try WalletAssetRouteTemplateRepository.latest(db, walletId: walletId, flow: flow, limit: 3)
        }
        cancellable = observation.start(
            in: database.pool,
            scheduling: .immediate,
            onError: { [weak self] error in
                self?.lastError = error
                self?.log.error("Route template observation failed: \(String(describing: error), privacy: .public)")
            },
            onChange: { [weak self] rows in
                self?.lastError = nil
                self?.templates = rows
            }
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
