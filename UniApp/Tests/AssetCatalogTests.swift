import Testing
import Foundation
import SwiftData
@testable import Aperture

/// The safety net for the registries → DB migration (Rule #27 §D): the
/// seeded `AssetRecord` / `ChainRecord` rows must be **byte-for-byte
/// identical** to the static `AssetCatalog`, and the display builders
/// must produce the same asset list from either source. As long as
/// these pass, moving the wallet's asset universe into the database
/// changes nothing the user sees — it just makes the DB the source of
/// truth (with the static catalog as the seed + cold-launch fallback).
@Suite struct AssetCatalogTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ApertureSchemaV1.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("seeded AssetRecord set equals the static AssetCatalog exactly")
    func seededAssetsEqualStatic() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AssetCatalogSeeder.seed(into: context)

        let seeded = try context.fetch(FetchDescriptor<AssetRecord>())
        #expect(seeded.count == AssetCatalog.allAssets.count)
        #expect(Set(seeded.compactMap { $0.catalogAsset }) == Set(AssetCatalog.allAssets))
    }

    @Test("seeded ChainRecord set equals the static AssetCatalog chains")
    func seededChainsEqualStatic() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AssetCatalogSeeder.seed(into: context)

        let seeded = try context.fetch(FetchDescriptor<ChainRecord>())
        #expect(seeded.count == AssetCatalog.allChains.count)
        #expect(Set(seeded.compactMap { $0.catalogChain }) == Set(AssetCatalog.allChains))
    }

    @Test("seeding twice is idempotent — no duplicate rows")
    func seedIdempotent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AssetCatalogSeeder.seed(into: context)
        try AssetCatalogSeeder.seed(into: context)

        let assets = try context.fetch(FetchDescriptor<AssetRecord>())
        let chains = try context.fetch(FetchDescriptor<ChainRecord>())
        #expect(assets.count == AssetCatalog.allAssets.count)
        #expect(chains.count == AssetCatalog.allChains.count)
    }

    @Test("display builders produce the identical asset list from DB vs static")
    func buildersIdenticalAcrossSources() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AssetCatalogSeeder.seed(into: context)
        let dbAssets = try context.fetch(FetchDescriptor<AssetRecord>()).compactMap { $0.catalogAsset }
        let dbChains = try context.fetch(FetchDescriptor<ChainRecord>())
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { $0.catalogChain }

        let tokensStatic = WalletSupportedRowBuilders.tokenRows(heldRows: [], currencyCode: "USD")
        let tokensDB = WalletSupportedRowBuilders.tokenRows(heldRows: [], currencyCode: "USD", assets: dbAssets)
        #expect(tokensStatic.count == tokensDB.count)
        #expect(Set(tokensStatic.map { $0.id }) == Set(tokensDB.map { $0.id }))

        let coinsStatic = WalletSupportedRowBuilders.coinRows(heldRows: [], currencyCode: "USD")
        let coinsDB = WalletSupportedRowBuilders.coinRows(heldRows: [], currencyCode: "USD", chains: dbChains)
        #expect(coinsStatic.count == coinsDB.count)
        #expect(coinsStatic.map { $0.chain } == coinsDB.map { $0.chain }) // order preserved
    }

    @Test("Send + Receive asset lists are identical from DB vs static catalog")
    func sendReceiveAssetListsIdenticalAcrossSources() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AssetCatalogSeeder.seed(into: context)
        let dbAssets = try context.fetch(FetchDescriptor<AssetRecord>()).compactMap { $0.catalogAsset }
        let chains = Set(SupportedChain.allCases)

        // Receive: folded multi-network token rows.
        let recvStatic = ReceiveAsset.tokens(availableChains: chains)
        let recvDB = ReceiveAsset.tokens(availableChains: chains, catalogAssets: dbAssets)
        #expect(recvStatic.count == recvDB.count)
        #expect(Set(recvStatic.map { $0.id }) == Set(recvDB.map { $0.id }))

        // Send: per-network expanded rows (the user's "send screen reads
        // from the DB" path).
        let sendStatic = SendAsset.sendable(availableChains: chains)
        let sendDB = SendAsset.sendable(availableChains: chains, catalogAssets: dbAssets)
        #expect(sendStatic.count == sendDB.count)
        #expect(Set(sendStatic.map { $0.id }) == Set(sendDB.map { $0.id }))
    }
}
