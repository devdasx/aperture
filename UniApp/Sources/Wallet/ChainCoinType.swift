import Foundation
import WalletCore

/// Maps a `SupportedChain` to its wallet-core `CoinType`.
///
/// **EVM (BUG-002):** every EVM chain uses **Ethereum** (`CoinType` raw id
/// `60`, path `m/44'/60'/0'/0/0`). That matches MetaMask, Rabby, Coinbase
/// Wallet, and Aperture's own private-key / watch-only import — one `0x`
/// address on every L2. Per-L2 Trust Wallet SLIP-44 coin ids are **not**
/// used for derivation (they produced empty L2 balances for users who
/// funded the standard Ethereum address).
///
/// Non-EVM chains keep their Trust Wallet registry coin ids.
enum ChainCoinType {

    /// Ethereum SLIP-44 / WalletCore coin id — shared by every EVM chain.
    static let evmCoinId: UInt32 = 60

    private static let nonEVMCoinIdForChain: [SupportedChain: UInt32] = [
        .bitcoin: 0, .bitcoinCash: 145, .litecoin: 2, .dogecoin: 3,
        .solana: 501, .ripple: 144, .stellar: 148, .near: 397, .ton: 607,
        .tron: 195, .polkadot: 354, .aptos: 637, .sui: 784,
    ]

    static func coinType(for chain: SupportedChain) -> CoinType? {
        if chain.family == .evm {
            return CoinType(rawValue: evmCoinId)
        }
        guard let id = nonEVMCoinIdForChain[chain] else { return nil }
        return CoinType(rawValue: id)
    }

    /// WalletCore coin used for EVM key derivation and address encoding.
    static var evm: CoinType { CoinType(rawValue: evmCoinId)! }
}
