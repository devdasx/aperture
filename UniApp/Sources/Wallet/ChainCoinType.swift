import Foundation
import WalletCore

/// Maps a `SupportedChain` to its wallet-core `CoinType`. The single
/// source of truth for "which curve / address format does this chain
/// use" — mirrors `WalletCoreKeyImportService`'s derivation map (Trust
/// Wallet's SLIP-44 registry ids). Used for real per-chain address
/// validation (`CoinType.validate(address:)`) and any signing-adjacent
/// derivation the Send flow needs.
enum ChainCoinType {

    /// Trust Wallet `CoinType` raw id per chain (same map the importer
    /// derives addresses from, so validation matches derivation exactly).
    private static let coinIdForChain: [SupportedChain: UInt32] = [
        .bitcoin: 0, .bitcoinCash: 145, .litecoin: 2, .dogecoin: 3,
        .ethereum: 60, .arbitrum: 10042221, .base: 8453, .optimism: 10000070,
        .scroll: 534352, .zkSync: 10000324, .polygon: 966, .bnbChain: 20000714,
        .opBNB: 204, .avalanche: 10009000, .celo: 52752, .kavaEvm: 10002222,
        .solana: 501, .ripple: 144, .stellar: 148, .near: 397, .ton: 607,
        .tron: 195, .polkadot: 354, .aptos: 637, .sui: 784, .kava: 459,
    ]

    static func coinType(for chain: SupportedChain) -> CoinType? {
        guard let id = coinIdForChain[chain] else { return nil }
        return CoinType(rawValue: id)
    }
}
