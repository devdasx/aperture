import Foundation

/// Per-chain endpoint catalog. All 24 supported chains populated
/// with primary + ≥ 1 fallback endpoints. Per
/// `docs/RPC-ARCHITECTURE.md` §2.2.1, PublicNode is the primary for
/// every EVM chain it covers; alternative providers fill the gaps.
///
/// **Why a switch + per-chain helpers instead of one big dict.**
/// The Swift type-checker times out on a 24-chain dict-literal full
/// of nested initializers. Splitting into per-chain helper functions
/// is the idiomatic workaround and keeps the per-chain list
/// inspectable in isolation.
enum RPCRegistry {

    /// Endpoints for `chain`, sorted by `priority` (ascending).
    /// Empty array if no endpoints — callers throw `RPCError.noEndpoint`.
    static func endpoints(for chain: SupportedChain) -> [RPCEndpoint] {
        let endpoints: [RPCEndpoint]
        switch chain {
        case .ethereum:    endpoints = ethereumEndpoints()
        case .arbitrum:    endpoints = arbitrumEndpoints()
        case .base:        endpoints = baseEndpoints()
        case .optimism:    endpoints = optimismEndpoints()
        case .scroll:      endpoints = scrollEndpoints()
        case .zkSync:      endpoints = zkSyncEndpoints()
        case .polygon:     endpoints = polygonEndpoints()
        case .bnbChain:    endpoints = bnbChainEndpoints()
        case .opBNB:       endpoints = opBNBEndpoints()
        case .avalanche:   endpoints = avalancheEndpoints()
        case .celo:        endpoints = celoEndpoints()
        case .kavaEvm:     endpoints = kavaEvmEndpoints()
        case .bitcoin:     endpoints = bitcoinEndpoints()
        case .bitcoinCash: endpoints = bitcoinCashEndpoints()
        case .litecoin:    endpoints = litecoinEndpoints()
        case .dogecoin:    endpoints = dogecoinEndpoints()
        case .solana:      endpoints = solanaEndpoints()
        case .ripple:      endpoints = rippleEndpoints()
        case .stellar:     endpoints = stellarEndpoints()
        case .near:        endpoints = nearEndpoints()
        case .ton:         endpoints = tonEndpoints()
        case .tron:        endpoints = tronEndpoints()
        case .polkadot:    endpoints = polkadotEndpoints()
        case .aptos:       endpoints = aptosEndpoints()
        case .sui:         endpoints = suiEndpoints()
        case .kava:        endpoints = kavaEndpoints()
        }
        return endpoints.sorted { $0.priority < $1.priority }
    }

    // MARK: - EVM (12 chains)

    private static func ethereumEndpoints() -> [RPCEndpoint] {
        [
            jr("eth-publicnode", "https://ethereum.publicnode.com", .ethereum, "publicnode", .publicNode, 0),
            jr("eth-llamarpc",   "https://eth.llamarpc.com",        .ethereum, "llamarpc",   .moderate20, 1),
            jr("eth-cloudflare", "https://cloudflare-eth.com",      .ethereum, "cloudflare", .moderate10, 2),
        ]
    }
    private static func arbitrumEndpoints() -> [RPCEndpoint] {
        [
            jr("arb-publicnode", "https://arbitrum-one.publicnode.com", .arbitrum, "publicnode", .publicNode, 0),
            jr("arb-llamarpc",   "https://arbitrum.llamarpc.com",       .arbitrum, "llamarpc",   .moderate20, 1),
            jr("arb-ankr",       "https://rpc.ankr.com/arbitrum",       .arbitrum, "ankr",       .moderate10, 2),
        ]
    }
    private static func baseEndpoints() -> [RPCEndpoint] {
        [
            jr("base-publicnode", "https://base.publicnode.com",   .base, "publicnode", .publicNode, 0),
            jr("base-llamarpc",   "https://base.llamarpc.com",     .base, "llamarpc",   .moderate20, 1),
            jr("base-ankr",       "https://rpc.ankr.com/base",     .base, "ankr",       .moderate10, 2),
        ]
    }
    private static func optimismEndpoints() -> [RPCEndpoint] {
        [
            jr("op-publicnode", "https://optimism.publicnode.com", .optimism, "publicnode", .publicNode, 0),
            jr("op-llamarpc",   "https://optimism.llamarpc.com",   .optimism, "llamarpc",   .moderate20, 1),
            jr("op-ankr",       "https://rpc.ankr.com/optimism",   .optimism, "ankr",       .moderate10, 2),
        ]
    }
    private static func scrollEndpoints() -> [RPCEndpoint] {
        [
            jr("scr-publicnode", "https://scroll.publicnode.com", .scroll, "publicnode",        .publicNode, 0),
            jr("scr-scroll",     "https://rpc.scroll.io",         .scroll, "scroll-foundation", .moderate10, 1),
            jr("scr-ankr",       "https://rpc.ankr.com/scroll",   .scroll, "ankr",              .moderate10, 2),
        ]
    }
    private static func zkSyncEndpoints() -> [RPCEndpoint] {
        [
            jr("zks-publicnode", "https://zksync-era.publicnode.com", .zkSync, "publicnode",   .publicNode, 0),
            jr("zks-mainnet",    "https://mainnet.era.zksync.io",     .zkSync, "matter-labs",  .moderate10, 1),
            jr("zks-ankr",       "https://rpc.ankr.com/zksync_era",   .zkSync, "ankr",         .moderate10, 2),
        ]
    }
    private static func polygonEndpoints() -> [RPCEndpoint] {
        [
            jr("pol-publicnode", "https://polygon-bor.publicnode.com", .polygon, "publicnode", .publicNode, 0),
            jr("pol-llamarpc",   "https://polygon.llamarpc.com",       .polygon, "llamarpc",   .moderate20, 1),
            jr("pol-ankr",       "https://rpc.ankr.com/polygon",       .polygon, "ankr",       .moderate10, 2),
        ]
    }
    private static func bnbChainEndpoints() -> [RPCEndpoint] {
        [
            jr("bsc-publicnode", "https://bsc.publicnode.com",   .bnbChain, "publicnode", .publicNode, 0),
            jr("bsc-llamarpc",   "https://binance.llamarpc.com", .bnbChain, "llamarpc",   .moderate20, 1),
            jr("bsc-ankr",       "https://rpc.ankr.com/bsc",     .bnbChain, "ankr",       .moderate10, 2),
        ]
    }
    private static func opBNBEndpoints() -> [RPCEndpoint] {
        [
            jr("opbnb-bnbchain",  "https://opbnb-mainnet-rpc.bnbchain.org", .opBNB, "bnbchain",   .moderate10, 0),
            jr("opbnb-publicnode","https://opbnb.publicnode.com",           .opBNB, "publicnode", .publicNode, 1),
        ]
    }
    private static func avalancheEndpoints() -> [RPCEndpoint] {
        [
            jr("avax-publicnode", "https://avalanche-c-chain.publicnode.com", .avalanche, "publicnode", .publicNode, 0),
            jr("avax-ava-labs",   "https://api.avax.network/ext/bc/C/rpc",    .avalanche, "ava-labs",   .moderate20, 1),
            jr("avax-ankr",       "https://rpc.ankr.com/avalanche",           .avalanche, "ankr",       .moderate10, 2),
        ]
    }
    private static func celoEndpoints() -> [RPCEndpoint] {
        [
            jr("celo-publicnode", "https://celo.publicnode.com", .celo, "publicnode",      .publicNode, 0),
            jr("celo-forno",      "https://forno.celo.org",      .celo, "celo-foundation", .moderate10, 1),
        ]
    }
    private static func kavaEvmEndpoints() -> [RPCEndpoint] {
        [
            jr("kavaevm-bdnodes", "https://kava-evm-rpc.bdnodes.net", .kavaEvm, "bdnodes",         .moderate10, 0),
            jr("kavaevm-evm",     "https://evm.kava.io",              .kavaEvm, "kava-foundation", .moderate10, 1),
        ]
    }

    // MARK: - Bitcoin family (4 chains, REST)

    private static func bitcoinEndpoints() -> [RPCEndpoint] {
        [
            rs("btc-mempool",     "https://mempool.space/api",     .bitcoin, "mempool.space", .moderate10, 0),
            rs("btc-blockstream", "https://blockstream.info/api",  .bitcoin, "blockstream",   .moderate10, 1),
        ]
    }
    private static func bitcoinCashEndpoints() -> [RPCEndpoint] {
        // 2026-06-06: both Esplora-style BCH endpoints (loping.net,
        // imaginary.cash) started serving anti-bot HTML to non-browser
        // User-Agents — they don't return JSON anymore. Switched to
        // Haskoin which returns `{confirmed, unconfirmed, …}` for
        // `/bch/address/{addr}/balance` and is the canonical free
        // BCH index API.
        [
            rs("bch-haskoin",   "https://api.haskoin.com",    .bitcoinCash, "haskoin.com", .moderate10, 0),
            rs("bch-blockbook", "https://bchblockexplorer.com", .bitcoinCash, "blockbook",   .moderate10, 1),
        ]
    }
    private static func litecoinEndpoints() -> [RPCEndpoint] {
        [
            rs("ltc-litecoinspace", "https://litecoinspace.org/api",            .litecoin, "litecoinspace", .moderate10, 0),
            rs("ltc-blockcypher",   "https://api.blockcypher.com/v1/ltc/main",  .litecoin, "blockcypher",   .moderate10, 1),
        ]
    }
    private static func dogecoinEndpoints() -> [RPCEndpoint] {
        // BlockCypher promoted to primary 2026-06-06 after
        // dogechain.info started gating all non-browser requests
        // through Cloudflare (returns interstitial HTML instead of
        // JSON). dogechain stays as fallback in case the gate is
        // dropped later.
        [
            rs("doge-blockcypher", "https://api.blockcypher.com/v1/doge/main", .dogecoin, "blockcypher", .moderate10, 0),
            rs("doge-dogechain",   "https://dogechain.info/api/v1",            .dogecoin, "dogechain",   .moderate10, 1),
        ]
    }

    // MARK: - Non-EVM L1s (10 chains)

    private static func solanaEndpoints() -> [RPCEndpoint] {
        [
            jr("sol-mainnet-beta", "https://api.mainnet-beta.solana.com", .solana, "solana-foundation", .moderate10, 0),
            jr("sol-publicnode",   "https://solana-rpc.publicnode.com",   .solana, "publicnode",        .publicNode, 1),
        ]
    }
    private static func rippleEndpoints() -> [RPCEndpoint] {
        [
            jr("xrp-s1",          "https://s1.ripple.com:51234", .ripple, "ripple-labs", .moderate10, 0),
            jr("xrp-s2",          "https://s2.ripple.com:51234", .ripple, "ripple-labs", .moderate10, 1),
            jr("xrp-xrplcluster", "https://xrplcluster.com",     .ripple, "xrplcluster", .moderate10, 2),
        ]
    }
    private static func stellarEndpoints() -> [RPCEndpoint] {
        [
            rs("xlm-horizon", "https://horizon.stellar.org", .stellar, "stellar-foundation", .moderate20, 0),
            rs("xlm-lobstr",  "https://horizon.lobstr.co",   .stellar, "lobstr",             .moderate10, 1),
        ]
    }
    private static func nearEndpoints() -> [RPCEndpoint] {
        [
            jr("near-mainnet", "https://rpc.mainnet.near.org", .near, "near-foundation", .moderate20, 0),
            jr("near-lava",    "https://near.lava.build",      .near, "lava-network",    .moderate10, 1),
        ]
    }
    private static func tonEndpoints() -> [RPCEndpoint] {
        [
            rs("ton-toncenter", "https://toncenter.com/api/v2", .ton, "toncenter", .conservative, 0),
            rs("ton-tonapi",    "https://tonapi.io/v2",         .ton, "tonapi",    .conservative, 1),
        ]
    }
    private static func tronEndpoints() -> [RPCEndpoint] {
        [
            rs("trx-trongrid",  "https://api.trongrid.io",  .tron, "trongrid",  .moderate10, 0),
            rs("trx-tronstack", "https://api.tronstack.io", .tron, "tronstack", .moderate10, 1),
        ]
    }
    private static func polkadotEndpoints() -> [RPCEndpoint] {
        [
            jr("dot-polkadot",   "https://rpc.polkadot.io",                    .polkadot, "polkadot-foundation", .moderate10, 0),
            jr("dot-onfinality", "https://polkadot.api.onfinality.io/public",  .polkadot, "onfinality",          .moderate10, 1),
        ]
    }
    private static func aptosEndpoints() -> [RPCEndpoint] {
        [
            rs("apt-aptoslabs", "https://fullnode.mainnet.aptoslabs.com/v1", .aptos, "aptos-labs", .moderate20, 0),
            rs("apt-nodit",     "https://aptos-mainnet.nodit.io/v1",         .aptos, "nodit",      .moderate10, 1),
        ]
    }
    private static func suiEndpoints() -> [RPCEndpoint] {
        [
            jr("sui-mainnet",     "https://fullnode.mainnet.sui.io",                .sui, "sui-foundation", .moderate20, 0),
            jr("sui-blockvision", "https://sui-mainnet-endpoint.blockvision.org",   .sui, "blockvision",    .moderate10, 1),
        ]
    }
    private static func kavaEndpoints() -> [RPCEndpoint] {
        [
            rs("kava-api",      "https://api.data.kava.io",                .kava, "kava-foundation", .moderate20, 0),
            rs("kava-blastapi", "https://kava-mainnet.public.blastapi.io", .kava, "blastapi",        .moderate10, 1),
        ]
    }

    // MARK: - Constructors

    private static func jr(_ id: String, _ url: String, _ chain: SupportedChain, _ provider: String, _ limit: RPCEndpoint.RateLimit, _ pri: Int) -> RPCEndpoint {
        RPCEndpoint(id: id, url: URL(string: url)!, kind: .jsonRPC, chain: chain, provider: provider, rateLimit: limit, priority: pri, weight: 1)
    }

    private static func rs(_ id: String, _ url: String, _ chain: SupportedChain, _ provider: String, _ limit: RPCEndpoint.RateLimit, _ pri: Int) -> RPCEndpoint {
        RPCEndpoint(id: id, url: URL(string: url)!, kind: .rest, chain: chain, provider: provider, rateLimit: limit, priority: pri, weight: 1)
    }
}

// MARK: - Common rate-limit presets

extension RPCEndpoint.RateLimit {
    /// 20 req/s sustained, 10 burst. For community mirrors with
    /// generous limits (LlamaRPC, chain-foundation public RPCs).
    static let moderate20 = RPCEndpoint.RateLimit(
        requestsPerSecond: 20, requestsPerMinute: 1_200, requestsPerDay: nil, burstAllowance: 10
    )

    /// 10 req/s sustained, 5 burst. For stricter endpoints (Ankr's
    /// lower tier, Cloudflare, mempool.space, etc.).
    static let moderate10 = RPCEndpoint.RateLimit(
        requestsPerSecond: 10, requestsPerMinute: 600, requestsPerDay: nil, burstAllowance: 5
    )
}
