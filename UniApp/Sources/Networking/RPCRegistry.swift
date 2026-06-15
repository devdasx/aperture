import Foundation
import OSLog

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

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "rpc-registry")

    /// Endpoints for `chain`, sorted by `priority` (ascending).
    /// Empty array if no endpoints — callers throw `RPCError.noEndpoint`.
    /// Returns the pre-sorted, pre-validated array built once at
    /// registration — no per-call sorting.
    static func endpoints(for chain: SupportedChain) -> [RPCEndpoint] {
        endpointsByChain[chain] ?? []
    }

    /// Built once on first access: per-chain endpoint lists with
    /// malformed entries (unparseable URLs) compactMapped out and
    /// each list sorted by `priority` ascending. A typo in an
    /// endpoint URL degrades to "one fewer fallback" (with a fault
    /// logged by `jr`/`rs`), never a crash.
    private static let endpointsByChain: [SupportedChain: [RPCEndpoint]] = {
        var map: [SupportedChain: [RPCEndpoint]] = [:]
        for chain in SupportedChain.allCases {
            let raw: [RPCEndpoint?]
            switch chain {
            case .ethereum:    raw = ethereumEndpoints()
            case .arbitrum:    raw = arbitrumEndpoints()
            case .base:        raw = baseEndpoints()
            case .optimism:    raw = optimismEndpoints()
            case .scroll:      raw = scrollEndpoints()
            case .zkSync:      raw = zkSyncEndpoints()
            case .polygon:     raw = polygonEndpoints()
            case .bnbChain:    raw = bnbChainEndpoints()
            case .opBNB:       raw = opBNBEndpoints()
            case .avalanche:   raw = avalancheEndpoints()
            case .celo:        raw = celoEndpoints()
            case .kavaEvm:     raw = kavaEvmEndpoints()
            case .bitcoin:     raw = bitcoinEndpoints()
            case .bitcoinCash: raw = bitcoinCashEndpoints()
            case .litecoin:    raw = litecoinEndpoints()
            case .dogecoin:    raw = dogecoinEndpoints()
            case .solana:      raw = solanaEndpoints()
            case .ripple:      raw = rippleEndpoints()
            case .stellar:     raw = stellarEndpoints()
            case .near:        raw = nearEndpoints()
            case .ton:         raw = tonEndpoints()
            case .tron:        raw = tronEndpoints()
            case .polkadot:    raw = polkadotEndpoints()
            case .aptos:       raw = aptosEndpoints()
            case .sui:         raw = suiEndpoints()
            case .kava:        raw = kavaEndpoints()
            }
            map[chain] = raw
                .compactMap { $0 }
                .sorted { $0.priority < $1.priority }
        }
        return map
    }()

    // MARK: - EVM (12 chains)

    // **2026-06-09 — expanded EVM fallback lists.** Each chain now
    // carries 6–9 endpoints from independent providers (PublicNode,
    // LlamaRPC, Ankr, dRPC, 1RPC, Blast, BlockPI, OnFinality,
    // Cloudflare, Merkle, the chain's foundation/vendor). When one
    // provider rate-limits or returns a 429/timeout, RPCClient
    // rotates to the next. The diverse provider set means a single
    // provider's outage no longer blocks an entire chain.
    //
    // **2026-06-16 — 1rpc.io authentication + more fallbacks.**
    // The 1rpc endpoints now use the authenticated keyed path
    // (`https://1rpc.io/<KEY>/<slug>`) when `Secrets.hasOneRPCKey`,
    // and the public path (`https://1rpc.io/<slug>`) otherwise — see
    // `oneRPC(...)`. The public 1rpc tier caps at 200 requests/day
    // per IP and then returns JSON-RPC error `-32001` "You've reached
    // the usage limit for your current plan…" (HTTP 200, live-verified
    // 2026-06-16; doc: https://docs.1rpc.io/using-the-web3-api/errors).
    // That keyless quota is what rate-limited a swap broadcast and
    // surfaced as a terminal failure. The keyed path raises the limit
    // (live-verified: 30/30 keyed eth_blockNumber succeeded while the
    // same IP's public path returned -32001). Additional independent
    // public fallbacks (Tenderly public gateway, BNB dataseeds, etc.)
    // were added per chain after live-curl confirming the correct
    // chainId + a live block (eth_chainId + eth_blockNumber). The
    // broken `zksync-era-rpc.publicnode.com` (now HTTP 404 — publicnode
    // dropped zkSync Era) was removed.
    private static func ethereumEndpoints() -> [RPCEndpoint?] {
        [
            jr("eth-publicnode",  "https://ethereum-rpc.publicnode.com",          .ethereum, "publicnode",  .publicNode,  0),
            oneRPC("eth-1rpc",    slug: "eth",                                    .ethereum,                              1),
            jr("eth-llamarpc",    "https://eth.llamarpc.com",                     .ethereum, "llamarpc",    .moderate20,  2),
            jr("eth-drpc",        "https://eth.drpc.org",                         .ethereum, "drpc",        .moderate10,  3),
            jr("eth-tenderly",    "https://gateway.tenderly.co/public/mainnet",   .ethereum, "tenderly",    .moderate10,  4),
            jr("eth-cloudflare",  "https://cloudflare-eth.com",                   .ethereum, "cloudflare",  .moderate10,  5),
            jr("eth-ankr",        "https://rpc.ankr.com/eth",                     .ethereum, "ankr",        .moderate10,  6),
            jr("eth-blast",       "https://eth-mainnet.public.blastapi.io",       .ethereum, "blast",       .moderate10,  7),
            jr("eth-blockpi",     "https://ethereum.blockpi.network/v1/rpc/public", .ethereum, "blockpi",   .moderate10,  8),
            jr("eth-merkle",      "https://eth.merkle.io",                        .ethereum, "merkle",      .moderate10,  9),
        ]
    }
    private static func arbitrumEndpoints() -> [RPCEndpoint?] {
        [
            jr("arb-publicnode",  "https://arbitrum-one-rpc.publicnode.com",      .arbitrum, "publicnode",  .publicNode,  0),
            oneRPC("arb-1rpc",    slug: "arb",                                    .arbitrum,                              1),
            jr("arb-official",    "https://arb1.arbitrum.io/rpc",                 .arbitrum, "offchain-labs", .moderate20, 2),
            jr("arb-llamarpc",    "https://arbitrum.llamarpc.com",                .arbitrum, "llamarpc",    .moderate20,  3),
            jr("arb-drpc",        "https://arbitrum.drpc.org",                    .arbitrum, "drpc",        .moderate10,  4),
            jr("arb-tenderly",    "https://arbitrum.gateway.tenderly.co",         .arbitrum, "tenderly",    .moderate10,  5),
            jr("arb-ankr",        "https://rpc.ankr.com/arbitrum",                .arbitrum, "ankr",        .moderate10,  6),
            jr("arb-blast",       "https://arbitrum-one.public.blastapi.io",      .arbitrum, "blast",       .moderate10,  7),
            jr("arb-blockpi",     "https://arbitrum.blockpi.network/v1/rpc/public", .arbitrum, "blockpi",   .moderate10,  8),
        ]
    }
    private static func baseEndpoints() -> [RPCEndpoint?] {
        [
            jr("base-publicnode", "https://base-rpc.publicnode.com",              .base, "publicnode",      .publicNode,  0),
            oneRPC("base-1rpc",   slug: "base",                                   .base,                                  1),
            jr("base-official",   "https://mainnet.base.org",                     .base, "coinbase",        .moderate20,  2),
            jr("base-llamarpc",   "https://base.llamarpc.com",                    .base, "llamarpc",        .moderate20,  3),
            jr("base-drpc",       "https://base.drpc.org",                        .base, "drpc",            .moderate10,  4),
            jr("base-tenderly",   "https://base.gateway.tenderly.co",             .base, "tenderly",        .moderate10,  5),
            jr("base-ankr",       "https://rpc.ankr.com/base",                    .base, "ankr",            .moderate10,  6),
            jr("base-blast",      "https://base-mainnet.public.blastapi.io",      .base, "blast",           .moderate10,  7),
            jr("base-blockpi",    "https://base.blockpi.network/v1/rpc/public",   .base, "blockpi",         .moderate10,  8),
        ]
    }
    private static func optimismEndpoints() -> [RPCEndpoint?] {
        [
            jr("op-publicnode",   "https://optimism-rpc.publicnode.com",          .optimism, "publicnode",  .publicNode,  0),
            oneRPC("op-1rpc",     slug: "op",                                     .optimism,                              1),
            jr("op-official",     "https://mainnet.optimism.io",                  .optimism, "op-labs",     .moderate20,  2),
            jr("op-llamarpc",     "https://optimism.llamarpc.com",                .optimism, "llamarpc",    .moderate20,  3),
            jr("op-drpc",         "https://optimism.drpc.org",                    .optimism, "drpc",        .moderate10,  4),
            jr("op-tenderly",     "https://optimism.gateway.tenderly.co",         .optimism, "tenderly",    .moderate10,  5),
            jr("op-ankr",         "https://rpc.ankr.com/optimism",                .optimism, "ankr",        .moderate10,  6),
            jr("op-blast",        "https://optimism-mainnet.public.blastapi.io",  .optimism, "blast",       .moderate10,  7),
            jr("op-blockpi",      "https://optimism.blockpi.network/v1/rpc/public", .optimism, "blockpi",   .moderate10,  8),
        ]
    }
    private static func scrollEndpoints() -> [RPCEndpoint?] {
        [
            jr("scr-publicnode",  "https://scroll-rpc.publicnode.com",            .scroll, "publicnode",    .publicNode,  0),
            oneRPC("scr-1rpc",    slug: "scroll",                                 .scroll,                                1),
            jr("scr-scroll",      "https://rpc.scroll.io",                        .scroll, "scroll-foundation", .moderate20, 2),
            jr("scr-drpc",        "https://scroll.drpc.org",                      .scroll, "drpc",          .moderate10,  3),
            jr("scr-ankr",        "https://rpc.ankr.com/scroll",                  .scroll, "ankr",          .moderate10,  4),
            jr("scr-blockpi",     "https://scroll.blockpi.network/v1/rpc/public", .scroll, "blockpi",       .moderate10,  5),
        ]
    }
    private static func zkSyncEndpoints() -> [RPCEndpoint?] {
        // NOTE: `zksync-era-rpc.publicnode.com` was removed 2026-06-16 —
        // it now returns HTTP 404 (publicnode dropped zkSync Era).
        // `mainnet.era.zksync.io` (matter-labs official), `zksync.drpc.org`,
        // and keyed 1rpc (`zksync2-era`) were live-verified (chainId 0x144).
        [
            jr("zks-mainnet",     "https://mainnet.era.zksync.io",                .zkSync, "matter-labs",   .publicNode,  0),
            oneRPC("zks-1rpc",    slug: "zksync2-era",                            .zkSync,                                1),
            jr("zks-drpc",        "https://zksync.drpc.org",                      .zkSync, "drpc",          .moderate10,  2),
            jr("zks-ankr",        "https://rpc.ankr.com/zksync_era",              .zkSync, "ankr",          .moderate10,  3),
            jr("zks-blockpi",     "https://zksync-era.blockpi.network/v1/rpc/public", .zkSync, "blockpi",   .moderate10,  4),
        ]
    }
    private static func polygonEndpoints() -> [RPCEndpoint?] {
        [
            jr("pol-publicnode",  "https://polygon-bor-rpc.publicnode.com",       .polygon, "publicnode",   .publicNode,  0),
            oneRPC("pol-1rpc",    slug: "matic",                                  .polygon,                               1),
            jr("pol-llamarpc",    "https://polygon.llamarpc.com",                 .polygon, "llamarpc",     .moderate20,  2),
            jr("pol-drpc",        "https://polygon.drpc.org",                     .polygon, "drpc",         .moderate10,  3),
            jr("pol-tenderly",    "https://polygon.gateway.tenderly.co",          .polygon, "tenderly",     .moderate10,  4),
            jr("pol-ankr",        "https://rpc.ankr.com/polygon",                 .polygon, "ankr",         .moderate10,  5),
            jr("pol-blast",       "https://polygon-mainnet.public.blastapi.io",   .polygon, "blast",        .moderate10,  6),
            jr("pol-blockpi",     "https://polygon.blockpi.network/v1/rpc/public", .polygon, "blockpi",     .moderate10,  7),
            jr("pol-official",    "https://polygon-rpc.com",                      .polygon, "polygon",      .moderate10,  8),
        ]
    }
    private static func bnbChainEndpoints() -> [RPCEndpoint?] {
        [
            jr("bsc-publicnode",  "https://bsc-rpc.publicnode.com",               .bnbChain, "publicnode",  .publicNode,  0),
            oneRPC("bsc-1rpc",    slug: "bnb",                                    .bnbChain,                              1),
            jr("bsc-llamarpc",    "https://binance.llamarpc.com",                 .bnbChain, "llamarpc",    .moderate20,  2),
            jr("bsc-drpc",        "https://bsc.drpc.org",                         .bnbChain, "drpc",        .moderate10,  3),
            jr("bsc-ankr",        "https://rpc.ankr.com/bsc",                     .bnbChain, "ankr",        .moderate10,  4),
            jr("bsc-meowrpc",     "https://bsc.meowrpc.com",                      .bnbChain, "meowrpc",     .moderate10,  5),
            jr("bsc-blast",       "https://bsc-mainnet.public.blastapi.io",       .bnbChain, "blast",       .moderate10,  6),
            jr("bsc-blockpi",     "https://bsc.blockpi.network/v1/rpc/public",    .bnbChain, "blockpi",     .moderate10,  7),
            jr("bsc-dataseed1",   "https://bsc-dataseed1.binance.org",            .bnbChain, "binance",     .moderate10,  8),
            jr("bsc-dataseed2",   "https://bsc-dataseed2.binance.org",            .bnbChain, "binance",     .moderate10,  9),
            jr("bsc-dataseed3",   "https://bsc-dataseed3.binance.org",            .bnbChain, "binance",     .moderate10, 10),
            jr("bsc-dataseed4",   "https://bsc-dataseed4.binance.org",            .bnbChain, "binance",     .moderate10, 11),
        ]
    }
    private static func opBNBEndpoints() -> [RPCEndpoint?] {
        [
            jr("opbnb-publicnode","https://opbnb-rpc.publicnode.com",             .opBNB, "publicnode",     .publicNode,  0),
            oneRPC("opbnb-1rpc",  slug: "opbnb",                                  .opBNB,                                 1),
            jr("opbnb-bnbchain",  "https://opbnb-mainnet-rpc.bnbchain.org",       .opBNB, "bnbchain",       .moderate20,  2),
            jr("opbnb-drpc",      "https://opbnb.drpc.org",                       .opBNB, "drpc",           .moderate10,  3),
            jr("opbnb-ankr",      "https://rpc.ankr.com/opbnb",                   .opBNB, "ankr",           .moderate10,  4),
            jr("opbnb-blockpi",   "https://opbnb.blockpi.network/v1/rpc/public",  .opBNB, "blockpi",        .moderate10,  5),
        ]
    }
    private static func avalancheEndpoints() -> [RPCEndpoint?] {
        // NOTE: `ava-mainnet.public.blastapi.io` was removed 2026-06-16 —
        // it now returns HTTP 403 (Blast gated the public Avalanche path).
        [
            jr("avax-publicnode", "https://avalanche-c-chain-rpc.publicnode.com", .avalanche, "publicnode", .publicNode,  0),
            oneRPC("avax-1rpc",   slug: "avax/c",                                 .avalanche,                             1),
            jr("avax-ava-labs",   "https://api.avax.network/ext/bc/C/rpc",        .avalanche, "ava-labs",   .moderate20,  2),
            jr("avax-drpc",       "https://avalanche.drpc.org",                   .avalanche, "drpc",       .moderate10,  3),
            jr("avax-ankr",       "https://rpc.ankr.com/avalanche",               .avalanche, "ankr",       .moderate10,  4),
            jr("avax-blockpi",    "https://avalanche.blockpi.network/v1/rpc/public", .avalanche, "blockpi", .moderate10,  5),
        ]
    }
    private static func celoEndpoints() -> [RPCEndpoint?] {
        [
            jr("celo-publicnode", "https://celo-rpc.publicnode.com",              .celo, "publicnode",      .publicNode,  0),
            oneRPC("celo-1rpc",   slug: "celo",                                   .celo,                                  1),
            jr("celo-forno",      "https://forno.celo.org",                       .celo, "celo-foundation", .moderate20,  2),
            jr("celo-drpc",       "https://celo.drpc.org",                        .celo, "drpc",            .moderate10,  3),
            jr("celo-ankr",       "https://rpc.ankr.com/celo",                    .celo, "ankr",            .moderate10,  4),
            jr("celo-blockpi",    "https://celo.blockpi.network/v1/rpc/public",   .celo, "blockpi",         .moderate10,  5),
        ]
    }
    private static func kavaEvmEndpoints() -> [RPCEndpoint?] {
        [
            jr("kavaevm-evm",     "https://evm.kava.io",                          .kavaEvm, "kava-foundation", .moderate10, 0),
            jr("kavaevm-bdnodes", "https://kava-evm-rpc.bdnodes.net",             .kavaEvm, "bdnodes",        .moderate10, 1),
            jr("kavaevm-ankr",    "https://rpc.ankr.com/kava_evm",                .kavaEvm, "ankr",           .moderate10, 2),
            jr("kavaevm-drpc",    "https://kava.drpc.org",                        .kavaEvm, "drpc",           .moderate10, 3),
            jr("kavaevm-publicnode", "https://kava-evm-rpc.publicnode.com",       .kavaEvm, "publicnode",     .publicNode, 4),
        ]
    }

    // MARK: - Bitcoin family (4 chains, REST)

    private static func bitcoinEndpoints() -> [RPCEndpoint?] {
        [
            rs("btc-mempool",     "https://mempool.space/api",     .bitcoin, "mempool.space", .moderate10, 0),
            rs("btc-blockstream", "https://blockstream.info/api",  .bitcoin, "blockstream",   .moderate10, 1),
        ]
    }
    private static func bitcoinCashEndpoints() -> [RPCEndpoint?] {
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
    private static func litecoinEndpoints() -> [RPCEndpoint?] {
        [
            rs("ltc-litecoinspace", "https://litecoinspace.org/api",            .litecoin, "litecoinspace", .moderate10, 0),
            rs("ltc-blockcypher",   "https://api.blockcypher.com/v1/ltc/main",  .litecoin, "blockcypher",   .moderate10, 1),
        ]
    }
    private static func dogecoinEndpoints() -> [RPCEndpoint?] {
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

    private static func solanaEndpoints() -> [RPCEndpoint?] {
        [
            jr("sol-mainnet-beta", "https://api.mainnet-beta.solana.com", .solana, "solana-foundation", .moderate10, 0),
            jr("sol-publicnode",   "https://solana-rpc.publicnode.com",   .solana, "publicnode",        .publicNode, 1),
        ]
    }
    private static func rippleEndpoints() -> [RPCEndpoint?] {
        [
            jr("xrp-s1",          "https://s1.ripple.com:51234", .ripple, "ripple-labs", .moderate10, 0),
            jr("xrp-s2",          "https://s2.ripple.com:51234", .ripple, "ripple-labs", .moderate10, 1),
            jr("xrp-xrplcluster", "https://xrplcluster.com",     .ripple, "xrplcluster", .moderate10, 2),
        ]
    }
    private static func stellarEndpoints() -> [RPCEndpoint?] {
        [
            rs("xlm-horizon", "https://horizon.stellar.org", .stellar, "stellar-foundation", .moderate20, 0),
            rs("xlm-lobstr",  "https://horizon.lobstr.co",   .stellar, "lobstr",             .moderate10, 1),
        ]
    }
    private static func nearEndpoints() -> [RPCEndpoint?] {
        [
            jr("near-mainnet", "https://rpc.mainnet.near.org", .near, "near-foundation", .moderate20, 0),
            jr("near-lava",    "https://near.lava.build",      .near, "lava-network",    .moderate10, 1),
        ]
    }
    private static func tonEndpoints() -> [RPCEndpoint?] {
        [
            rs("ton-toncenter", "https://toncenter.com/api/v2", .ton, "toncenter", .conservative, 0),
            rs("ton-tonapi",    "https://tonapi.io/v2",         .ton, "tonapi",    .conservative, 1),
        ]
    }
    private static func tronEndpoints() -> [RPCEndpoint?] {
        [
            rs("trx-trongrid",  "https://api.trongrid.io",  .tron, "trongrid",  .moderate10, 0),
            rs("trx-tronstack", "https://api.tronstack.io", .tron, "tronstack", .moderate10, 1),
        ]
    }
    private static func polkadotEndpoints() -> [RPCEndpoint?] {
        [
            jr("dot-polkadot",   "https://rpc.polkadot.io",                    .polkadot, "polkadot-foundation", .moderate10, 0),
            jr("dot-onfinality", "https://polkadot.api.onfinality.io/public",  .polkadot, "onfinality",          .moderate10, 1),
        ]
    }
    private static func aptosEndpoints() -> [RPCEndpoint?] {
        [
            rs("apt-aptoslabs", "https://fullnode.mainnet.aptoslabs.com/v1", .aptos, "aptos-labs", .moderate20, 0),
            rs("apt-nodit",     "https://aptos-mainnet.nodit.io/v1",         .aptos, "nodit",      .moderate10, 1),
        ]
    }
    private static func suiEndpoints() -> [RPCEndpoint?] {
        [
            jr("sui-mainnet",     "https://fullnode.mainnet.sui.io",                .sui, "sui-foundation", .moderate20, 0),
            jr("sui-blockvision", "https://sui-mainnet-endpoint.blockvision.org",   .sui, "blockvision",    .moderate10, 1),
        ]
    }
    private static func kavaEndpoints() -> [RPCEndpoint?] {
        [
            rs("kava-api",      "https://api.data.kava.io",                .kava, "kava-foundation", .moderate20, 0),
            rs("kava-blastapi", "https://kava-mainnet.public.blastapi.io", .kava, "blastapi",        .moderate10, 1),
        ]
    }

    // MARK: - Constructors

    /// Optional factories — a typo in a hardcoded URL must degrade
    /// (entry dropped at registration, fault logged) rather than
    /// crash the app at first registry access.
    private static func jr(_ id: String, _ url: String, _ chain: SupportedChain, _ provider: String, _ limit: RPCEndpoint.RateLimit, _ pri: Int) -> RPCEndpoint? {
        guard let parsed = URL(string: url) else {
            log.fault("Dropped malformed JSON-RPC endpoint URL for \(id, privacy: .public)")
            return nil
        }
        return RPCEndpoint(id: id, url: parsed, kind: .jsonRPC, chain: chain, provider: provider, rateLimit: limit, priority: pri, weight: 1)
    }

    /// 1rpc.io endpoint factory. Builds the **authenticated keyed path**
    /// `https://1rpc.io/<KEY>/<slug>` when `Secrets.hasOneRPCKey`, and
    /// the **public path** `https://1rpc.io/<slug>` otherwise (honest
    /// degradation — Rule #16). `slug` is the 1rpc per-chain segment
    /// (live-verified 2026-06-16 against the keyed endpoint: `eth`,
    /// `arb`, `base`, `op`, `scroll`, `zksync2-era`, `matic`, `bnb`,
    /// `opbnb`, `avax/c`, `celo` — each returned its correct chainId).
    /// The keyed tier earns a higher rate-limit budget than the public
    /// tier's 200/day quota, so it sorts ahead of the keyless public
    /// 1rpc fallbacks (`moderate20` vs `moderate10`). The key never
    /// touches source — `Secrets.oneRPCKey` reads it from the build's
    /// Info.plist (injected from gitignored `Secrets.xcconfig`).
    private static func oneRPC(_ id: String, slug: String, _ chain: SupportedChain, _ pri: Int) -> RPCEndpoint? {
        let keyed = Secrets.hasOneRPCKey
        let url = keyed
            ? "https://1rpc.io/\(Secrets.oneRPCKey)/\(slug)"
            : "https://1rpc.io/\(slug)"
        guard let parsed = URL(string: url) else {
            log.fault("Dropped malformed 1rpc endpoint URL for \(id, privacy: .public)")
            return nil
        }
        // Keyed → generous budget; keyless public → conservative (the
        // 200/day public quota means we must not lean on it).
        let limit: RPCEndpoint.RateLimit = keyed ? .moderate20 : .moderate10
        return RPCEndpoint(id: id, url: parsed, kind: .jsonRPC, chain: chain, provider: "1rpc", rateLimit: limit, priority: pri, weight: 1)
    }

    private static func rs(_ id: String, _ url: String, _ chain: SupportedChain, _ provider: String, _ limit: RPCEndpoint.RateLimit, _ pri: Int) -> RPCEndpoint? {
        guard let parsed = URL(string: url) else {
            log.fault("Dropped malformed REST endpoint URL for \(id, privacy: .public)")
            return nil
        }
        return RPCEndpoint(id: id, url: parsed, kind: .rest, chain: chain, provider: provider, rateLimit: limit, priority: pri, weight: 1)
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
