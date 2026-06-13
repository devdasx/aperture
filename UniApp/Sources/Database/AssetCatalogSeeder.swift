import Foundation
import SwiftData
import OSLog

/// Seeds the local-first asset universe (`ChainRecord` / `AssetRecord`)
/// from the static `AssetCatalog` (Rule #27 §D). Idempotent and
/// upserting: runs every launch, inserts what's missing, and updates a
/// row in place if the curated registry changed it across an app
/// version (e.g. a token's decimals or a chain rename) — so the DB
/// asset universe tracks the shipped registries without ever
/// duplicating. Removed assets are left in place (harmless: the UI only
/// renders what the held-balance index matches against; a stale extra
/// definition shows as an unheld 0-row, same as today's behavior).
enum AssetCatalogSeeder {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "asset-catalog")

    /// Seed/refresh both tables on `context`. One save. Safe to call on
    /// a background context during bootstrap — the static fallback in
    /// the display builders covers the pre-seed cold-launch window.
    static func seed(into context: ModelContext) throws {
        try seedChains(into: context)
        try seedAssets(into: context)
        if context.hasChanges {
            try context.save()
        }
    }

    private static func seedChains(into context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<ChainRecord>())
        var byRaw = Dictionary(existing.map { ($0.chainRaw, $0) }, uniquingKeysWith: { a, _ in a })
        for (index, catalogChain) in AssetCatalog.allChains.enumerated() {
            let chain = catalogChain.chain
            let raw = chain.rawValue
            if let row = byRaw[raw] {
                if row.ticker != chain.ticker
                    || row.displayName != chain.displayName
                    || row.sortIndex != index {
                    row.ticker = chain.ticker
                    row.displayName = chain.displayName
                    row.sortIndex = index
                }
            } else {
                context.insert(ChainRecord(
                    chainRaw: raw,
                    ticker: chain.ticker,
                    displayName: chain.displayName,
                    sortIndex: index
                ))
                byRaw[raw] = nil // inserted; not needed again
            }
        }
    }

    private static func seedAssets(into context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<AssetRecord>())
        let byId = Dictionary(existing.map { ($0.catalogId, $0) }, uniquingKeysWith: { a, _ in a })
        var inserted = 0
        var updated = 0
        for asset in AssetCatalog.allAssets {
            if let row = byId[asset.id] {
                if row.chainRaw != asset.chain.rawValue
                    || row.symbol != asset.symbol
                    || row.name != asset.name
                    || row.contract != asset.contract
                    || row.decimals != asset.decimals {
                    row.chainRaw = asset.chain.rawValue
                    row.symbol = asset.symbol
                    row.name = asset.name
                    row.contract = asset.contract
                    row.decimals = asset.decimals
                    updated += 1
                }
            } else {
                context.insert(AssetRecord(
                    catalogId: asset.id,
                    chainRaw: asset.chain.rawValue,
                    symbol: asset.symbol,
                    name: asset.name,
                    contract: asset.contract,
                    decimals: asset.decimals
                ))
                inserted += 1
            }
        }
        if inserted > 0 || updated > 0 {
            log.info("Asset catalog seeded: \(inserted, privacy: .public) inserted, \(updated, privacy: .public) updated.")
        }
    }
}
