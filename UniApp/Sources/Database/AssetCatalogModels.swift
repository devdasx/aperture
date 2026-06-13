import Foundation
import SwiftData

/// Local-first asset universe (Rule #27 §D). The supported chains and
/// tokens are SEEDED into the store from the static registries
/// (`AssetCatalog`) on launch, and the wallet UI reads the asset
/// universe from these rows — not from the compile-time registries
/// directly. The static `AssetCatalog` remains the seed source and a
/// cold-launch fallback; `AssetCatalogTests` pins that the seeded rows
/// are byte-for-byte identical to it, so nothing the user sees changes.
///
/// Both are brand-new entities with `.unique` keys → additive
/// lightweight migration, no touch to existing rows.

/// One supported chain (native coin). Mirrors a `SupportedChain` case.
@Model
final class ChainRecord {
    /// `SupportedChain.rawValue` — the stable identity.
    @Attribute(.unique) var chainRaw: String
    /// Native ticker (e.g. "ETH", "BTC") — denormalized for future
    /// remote-config; the UI still resolves the live `SupportedChain`.
    var ticker: String
    /// Display name (e.g. "Ethereum").
    var displayName: String
    /// Canonical ordering, mirroring `SupportedChain.allCases`.
    var sortIndex: Int

    init(chainRaw: String, ticker: String, displayName: String, sortIndex: Int) {
        self.chainRaw = chainRaw
        self.ticker = ticker
        self.displayName = displayName
        self.sortIndex = sortIndex
    }

    /// Reconstruct the registry-agnostic `CatalogChain`, or `nil` if the
    /// stored chain no longer maps to a known `SupportedChain` (defensive
    /// against a removed chain after an app downgrade).
    var catalogChain: CatalogChain? {
        guard let chain = SupportedChain(rawValue: chainRaw) else { return nil }
        return CatalogChain(chain: chain)
    }
}

/// One supported token across any chain. Mirrors a `CatalogAsset`.
@Model
final class AssetRecord {
    /// `CatalogAsset.id` — the stable display id (`"evm.<chain>.<contract>"`,
    /// `"sol.<mint>"`, …). Unique so the seeder upserts in place.
    @Attribute(.unique) var catalogId: String
    /// `SupportedChain.rawValue` the token lives on.
    var chainRaw: String
    var symbol: String
    var name: String
    /// On-chain identifier used for the held-balance lookup (contract /
    /// mint / denom / "currency.issuer" / assetId-as-string).
    var contract: String
    var decimals: Int

    init(catalogId: String, chainRaw: String, symbol: String, name: String, contract: String, decimals: Int) {
        self.catalogId = catalogId
        self.chainRaw = chainRaw
        self.symbol = symbol
        self.name = name
        self.contract = contract
        self.decimals = decimals
    }

    /// Reconstruct the registry-agnostic `CatalogAsset`, or `nil` if the
    /// stored chain no longer maps to a known `SupportedChain`.
    var catalogAsset: CatalogAsset? {
        guard let chain = SupportedChain(rawValue: chainRaw) else { return nil }
        return CatalogAsset(
            id: catalogId, chain: chain, symbol: symbol,
            name: name, contract: contract, decimals: decimals
        )
    }
}
