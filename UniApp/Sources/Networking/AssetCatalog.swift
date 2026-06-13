import Foundation

/// Registry-agnostic view of one supported asset (coin or token) — the
/// normalized shape that BOTH the static registries and the seeded
/// `AssetRecord` rows resolve to.
///
/// The per-registry enumeration used to live inline inside
/// `WalletSupportedRowBuilders.tokenRows`. Centralizing it here gives
/// the local-first migration (Rule #27 §D) one seed source AND a static
/// fallback that is *provably identical* to the DB rows
/// (`AssetCatalogTests` pins the equivalence). So the wallet home reads
/// the asset universe from the database, and a cold-launch window before
/// the seed lands falls back to this identical static list — zero
/// regression possible.
struct CatalogAsset: Sendable, Hashable, Identifiable {
    /// Stable display id, e.g. `"evm.ethereum.0x…"` / `"sol.<mint>"`.
    let id: String
    let chain: SupportedChain
    let symbol: String
    let name: String
    /// On-chain identifier used for the held-balance lookup: EVM
    /// contract / SPL mint / TRC-20 contract / NEP-141 account / Aptos
    /// metadata / Polkadot assetId (as string) / XRPL "currency.issuer"
    /// / TON master contract / Cosmos denom.
    let contract: String
    let decimals: Int
}

/// Registry-agnostic view of one supported chain (native coin).
struct CatalogChain: Sendable, Hashable, Identifiable {
    let chain: SupportedChain
    var id: String { chain.rawValue }
}

/// The single, authoritative enumeration of every supported chain +
/// token across the curated registries. Feeds the `AssetRecord` /
/// `ChainRecord` seeder (the DB source of truth, Rule #27 §D) and the
/// static fallback the display builders use until the seed lands.
enum AssetCatalog {

    /// Every supported chain, in `SupportedChain.allCases` order.
    static var allChains: [CatalogChain] {
        SupportedChain.allCases.map { CatalogChain(chain: $0) }
    }

    /// Every supported token across all 9 registries, normalized. The
    /// `id` + `contract` schemes mirror exactly what
    /// `WalletSupportedRowBuilders.tokenRows` produced inline, so the
    /// rendered list is byte-for-byte the same whether sourced from here
    /// or from the seeded `AssetRecord` rows.
    static var allAssets: [CatalogAsset] {
        var rows: [CatalogAsset] = []
        rows.reserveCapacity(400)

        // EVM tokens (per EVM chain).
        for chain in SupportedChain.allCases where chain.family == .evm {
            for entry in EVMTokenRegistry.tokens(for: chain) {
                rows.append(CatalogAsset(
                    id: "evm.\(chain.rawValue).\(entry.contract)",
                    chain: chain, symbol: entry.symbol, name: entry.name,
                    contract: entry.contract, decimals: entry.decimals
                ))
            }
        }
        // Solana SPL mints.
        for (mint, entry) in SolanaTokenRegistry.mints {
            rows.append(CatalogAsset(
                id: "sol.\(mint)", chain: .solana, symbol: entry.symbol,
                name: entry.name, contract: mint, decimals: entry.decimals
            ))
        }
        // TRON (TRC-20).
        for entry in TronTokenRegistry.tokens {
            rows.append(CatalogAsset(
                id: "trc.\(entry.contract)", chain: .tron, symbol: entry.symbol,
                name: entry.name, contract: entry.contract, decimals: entry.decimals
            ))
        }
        // NEAR (NEP-141).
        for entry in NearTokenRegistry.tokens {
            rows.append(CatalogAsset(
                id: "nep.\(entry.tokenAccount)", chain: .near, symbol: entry.symbol,
                name: entry.name, contract: entry.tokenAccount, decimals: entry.decimals
            ))
        }
        // Aptos (fungible asset).
        for entry in AptosTokenRegistry.tokens {
            rows.append(CatalogAsset(
                id: "apt.\(entry.contract)", chain: .aptos, symbol: entry.symbol,
                name: entry.name, contract: entry.contract, decimals: entry.decimals
            ))
        }
        // Polkadot Asset Hub.
        for entry in PolkadotAssetRegistry.tokens {
            let assetIdString = String(entry.assetId)
            rows.append(CatalogAsset(
                id: "dot.\(assetIdString)", chain: .polkadot, symbol: entry.symbol,
                name: entry.name, contract: assetIdString, decimals: entry.decimals
            ))
        }
        // XRPL IOUs — joined (currency, issuer) is the contract id.
        for entry in XRPLTokenRegistry.tokens {
            let contract = "\(entry.currency).\(entry.issuer)"
            rows.append(CatalogAsset(
                id: "xrpl.\(contract)", chain: .ripple, symbol: entry.symbol,
                name: entry.name, contract: contract, decimals: entry.decimals
            ))
        }
        // TON Jettons.
        for entry in TONJettonRegistry.tokens {
            rows.append(CatalogAsset(
                id: "ton.\(entry.masterContract)", chain: .ton, symbol: entry.symbol,
                name: entry.name, contract: entry.masterContract, decimals: entry.decimals
            ))
        }
        // Kava (Cosmos IBC).
        for entry in KavaCosmosTokenRegistry.tokens {
            rows.append(CatalogAsset(
                id: "kava.\(entry.denom)", chain: .kava, symbol: entry.symbol,
                name: entry.name, contract: entry.denom, decimals: entry.decimals
            ))
        }
        return rows
    }
}
