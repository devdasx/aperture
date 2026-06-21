import Foundation

/// **The fleet dispatcher.** Maps a `SupportedChain` to its independent
/// `ChainConnector`. One switch, one connector per chain.
///
/// **EVM data fetching is disabled (2026-06-21 user direction).** Every EVM
/// chain routes to `DisabledEVMConnector` — a no-op that returns zero balance,
/// no tokens, and no history without a network call. The per-chain EVM
/// connectors and the Alchemy connector/service were deleted. EVM addresses
/// stay derivable (receive), and Send / Swap / dApp keep signing + broadcasting
/// through their own RPC path, not through this dispatcher.
///
/// Every non-EVM `SupportedChain` case routes to its own connector — the
/// Bitcoin family each to its own copy of the Bitcoin template
/// (`LitecoinConnector`, `DogecoinConnector`, …), and every other L1 to its
/// own per-family connector (`SolanaConnector`, `RippleConnector`,
/// `StellarConnector`, `TronConnector`, the long-tail set). The switch is
/// EXHAUSTIVE with no `default`.
///
/// **Contract.** Returns `any ChainConnector` — the caller works against the
/// protocol, never a concrete type.
enum ChainConnectorRegistry {

    /// The connector for `chain`. Exhaustive: every chain resolves to a
    /// concrete connector value, no trap, no `default`.
    static func connector(for chain: SupportedChain) -> any ChainConnector {
        switch chain {
        // MARK: - EVM family — data fetching DISABLED (no-op connector)
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo:
            return DisabledEVMConnector(chain: chain)

        // MARK: - Bitcoin family (each its own copy of BitcoinConnector)
        case .bitcoin:     return BitcoinConnector()
        case .bitcoinCash: return BitcoinCashConnector()
        case .litecoin:    return LitecoinConnector()
        case .dogecoin:    return DogecoinConnector()

        // MARK: - Other L1 families (each its own per-chain connector)
        case .solana:   return SolanaConnector()
        case .ripple:   return RippleConnector()
        case .stellar:  return StellarConnector()
        case .near:     return NearConnector()
        case .ton:      return TonConnector()
        case .tron:     return TronConnector()
        case .polkadot: return PolkadotConnector()
        case .aptos:    return AptosConnector()
        case .sui:      return SuiConnector()
        }
    }
}
