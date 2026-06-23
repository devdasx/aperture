import Foundation

/// **The fleet dispatcher.** Maps a `SupportedChain` to its independent
/// `ChainConnector`. One switch, one connector per chain.
///
/// **Data fetching is disabled for some chains (2026-06-21 user direction).**
/// Every chain with `SupportedChain.fetchingDisabled == true` — the EVM family,
/// the Bitcoin family (BTC / BCH / LTC / DOGE), and Tron — routes to
/// `DisabledChainConnector`, a no-op that returns zero balance, no tokens, and
/// no history without a network call. Their per-chain fetch connectors (and the
/// Alchemy connector/service) were deleted. Addresses stay derivable (receive),
/// and Send / dApp keep signing + broadcasting through their own RPC
/// path, not through this dispatcher.
///
/// Every still-active `SupportedChain` case routes to its own connector
/// (`SolanaConnector`, `RippleConnector`, `StellarConnector`, the long-tail
/// set). The switch is EXHAUSTIVE with no `default`.
///
/// **Contract.** Returns `any ChainConnector` — the caller works against the
/// protocol, never a concrete type.
enum ChainConnectorRegistry {

    /// The connector for `chain`. Exhaustive: every chain resolves to a
    /// concrete connector value, no trap, no `default`.
    static func connector(for chain: SupportedChain) -> any ChainConnector {
        switch chain {
        // MARK: - Data fetching DISABLED — no-op connector (2026-06-21).
        // EVM family + Bitcoin family + Tron. Their per-chain fetch connectors
        // were deleted; addresses + Send still work (Send fetches UTXOs /
        // signs through its own path).
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo,
             .bitcoin, .bitcoinCash, .litecoin, .dogecoin,
             .tron, .solana, .stellar:
            return DisabledChainConnector(chain: chain)

        // MARK: - Active connectors (each its own per-chain connector)
        case .ripple:   return RippleConnector()
        case .near:     return NearConnector()
        case .ton:      return TonConnector()
        case .polkadot: return PolkadotConnector()
        case .aptos:    return AptosConnector()
        case .sui:      return SuiConnector()
        }
    }
}
