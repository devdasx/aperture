import Foundation
import GRDB
import OSLog

enum AssetCatalogSeeder {
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "asset-catalog")

    @MainActor
    static func seed(database: AppDatabase) throws {
        try database.write { db in
            for (index, catalogChain) in AssetCatalog.allChains.enumerated() {
                let chain = catalogChain.chain
                try db.execute(
                    sql: """
                    INSERT INTO chains (chain_raw, ticker, display_name, sort_index)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(chain_raw) DO UPDATE SET
                        ticker = excluded.ticker,
                        display_name = excluded.display_name,
                        sort_index = excluded.sort_index
                    """,
                    arguments: [chain.rawValue, chain.ticker, chain.displayName, index]
                )
            }

            for asset in AssetCatalog.allAssets {
                try db.execute(
                    sql: """
                    INSERT INTO assets (catalog_id, chain_raw, symbol, name, contract, decimals)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(catalog_id) DO UPDATE SET
                        chain_raw = excluded.chain_raw,
                        symbol = excluded.symbol,
                        name = excluded.name,
                        contract = excluded.contract,
                        decimals = excluded.decimals
                    """,
                    arguments: [
                        asset.id,
                        asset.chain.rawValue,
                        asset.symbol,
                        asset.name,
                        asset.contract,
                        asset.decimals
                    ]
                )
            }
        }
        log.info("Asset catalog seed finished.")
    }
}
