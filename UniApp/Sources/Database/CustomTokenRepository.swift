import Foundation
import GRDB

final class CustomTokenRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func add(
        id: UUID = UUID(),
        chain: SupportedChain,
        contract: String,
        symbol: String,
        name: String,
        decimals: Int,
        metadataFromChain: Bool = true
    ) throws {
        let dedupKey = "\(chain.rawValue)|\(contract.lowercased())"
        try database.write { db in
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM custom_tokens WHERE dedup_key = ?", arguments: [dedupKey]) ?? 0
            if exists > 0 { throw CustomTokenError.duplicate }
            try db.execute(
                sql: """
                INSERT INTO custom_tokens
                (id, chain_raw, contract, symbol, name, decimals, icon_url, added_at_ms, metadata_from_chain, dedup_key)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString,
                    chain.rawValue,
                    contract,
                    symbol,
                    name,
                    decimals,
                    Date.databaseMilliseconds,
                    metadataFromChain,
                    dedupKey
                ]
            )
        }
    }

    func remove(id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM custom_tokens WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func fetchAll(chain: SupportedChain? = nil) throws -> [CustomTokenSnapshot] {
        try database.read { db in
            let rows: [Row]
            if let chain {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM custom_tokens WHERE chain_raw = ? ORDER BY symbol ASC",
                    arguments: [chain.rawValue]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM custom_tokens ORDER BY symbol ASC")
            }
            return rows.compactMap(CustomTokenSnapshot.init(row:))
        }
    }

    func fetchByContract(chain: SupportedChain, contract: String) throws -> CustomTokenSnapshot? {
        let dedupKey = "\(chain.rawValue)|\(contract.lowercased())"
        return try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM custom_tokens WHERE dedup_key = ?", arguments: [dedupKey]).flatMap(CustomTokenSnapshot.init(row:))
        }
    }
}

struct CustomTokenSnapshot: Sendable, Hashable, Identifiable {
    let id: UUID
    let chain: SupportedChain
    let contract: String
    let symbol: String
    let name: String
    let decimals: Int
    let addedAt: Date
    let metadataFromChain: Bool

    init(from record: CustomTokenRecord) {
        id = record.id
        chain = record.chain
        contract = record.contract
        symbol = record.symbol
        name = record.name
        decimals = record.decimals
        addedAt = record.addedAt
        metadataFromChain = record.metadataFromChain
    }

    init?(row: Row) {
        guard
            let id = UUID(uuidString: row["id"]),
            let chain = SupportedChain(rawValue: row["chain_raw"])
        else { return nil }
        self.id = id
        self.chain = chain
        contract = row["contract"]
        symbol = row["symbol"]
        name = row["name"]
        decimals = row["decimals"]
        addedAt = Date(databaseMilliseconds: row["added_at_ms"])
        metadataFromChain = (row["metadata_from_chain"] as Int) != 0
    }
}

enum CustomTokenError: Error, Sendable, Equatable {
    case duplicate
}
