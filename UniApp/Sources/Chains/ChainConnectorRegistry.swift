import Foundation

/// **The fleet dispatcher.** Maps a `SupportedChain` to its independent
/// `ChainConnector`. One switch, one connector per chain.
///
/// **Fully wired (Integrate phase).** Every `SupportedChain` case routes
/// to its own connector — the EVM family each to its own copy of the
/// Ethereum template (`ArbitrumConnector`, `BaseConnector`, …), the
/// Bitcoin family each to its own copy of the Bitcoin template
/// (`LitecoinConnector`, `DogecoinConnector`, …), and every other L1 to
/// its own per-family connector (`SolanaConnector`, `RippleConnector`,
/// `StellarConnector`, `TronConnector`, the long-tail set). The switch
/// is EXHAUSTIVE with no `default` — adding a new `SupportedChain` case
/// is a compile error here until its connector is wired, by design.
///
/// **Contract.** Returns `any ChainConnector` — the caller works against
/// the protocol, never a concrete type, so a chain's connector can be
/// swapped without touching call sites. Connectors are zero-arg
/// constructible (`init(client: RPCClient = .shared)`), so the default
/// shared `RPCClient` (rotation + rate-limit + circuit-breaking +
/// ConcurrencyGate) backs every read.
enum ChainConnectorRegistry {

    /// The connector for `chain`. Exhaustive: every chain resolves to a
    /// concrete connector value, no trap, no `default`.
    static func connector(for chain: SupportedChain) -> any ChainConnector {
        switch chain {
        // MARK: - EVM family (each its own copy of EthereumConnector)
        case .ethereum:  return EthereumConnector()
        case .arbitrum:  return ArbitrumConnector()
        case .base:      return BaseConnector()
        case .optimism:  return OptimismConnector()
        case .scroll:    return ScrollConnector()
        case .zkSync:    return ZkSyncConnector()
        case .polygon:   return PolygonConnector()
        case .bnbChain:  return BnbChainConnector()
        case .opBNB:     return OpBNBConnector()
        case .avalanche: return AvalancheConnector()
        case .celo:      return CeloConnector()

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
