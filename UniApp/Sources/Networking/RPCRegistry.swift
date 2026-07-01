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
    /// Infura network slugs for the EVM chains the user's PAID key serves
    /// (live-verified 2026-06-16): `mainnet` for Ethereum, `<chain>-mainnet`
    /// for the rest. Chains NOT listed (every non-EVM chain)
    /// get no Infura endpoint and keep their existing primaries. The keyed
    /// URL is built by `infura(_:slug:_:)`.
    private static let infuraSlug: [SupportedChain: String] = [
        .ethereum: "mainnet",
        .polygon: "polygon-mainnet",
        .arbitrum: "arbitrum-mainnet",
        .optimism: "optimism-mainnet",
        .base: "base-mainnet",
        .bnbChain: "bsc-mainnet",
        .avalanche: "avalanche-mainnet",
        .celo: "celo-mainnet",
        .scroll: "scroll-mainnet",
        .zkSync: "zksync-mainnet",
        .opBNB: "opbnb-mainnet",
    ]

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
            }
            var resolved = raw.compactMap { $0 }
            // **Infura is the EVM PAID PRIMARY (2026-06-16).** When the
            // user's INFURA_API_KEY is set, add the keyed Infura endpoint
            // (priority -2 → sorts AHEAD of keyed 1rpc at -1 and publicnode
            // at 0) for every chain Infura serves. EVM-only: non-EVM chains
            // aren't in `infuraSlug`, so they're untouched. No key → nil →
            // the chain's existing primaries stand.
            if let slug = infuraSlug[chain],
               let inf = infura("\(chain.rawValue)-infura", slug: slug, chain) {
                resolved.append(inf)
            }
            map[chain] = resolved.sorted { $0.priority < $1.priority }
        }
        return map
    }()

    // MARK: - EVM (12 chains)

    // **2026-06-09 — expanded EVM fallback lists.** Each chain now
    // carries 6–9 endpoints from independent providers (PublicNode,
    // dRPC, 1RPC, Blast, OnFinality,
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
    // 2026-06-16).
    // That keyless quota is what rate-limited a transaction broadcast and
    // surfaced as a terminal failure. The keyed path raises the limit
    // (live-verified: 30/30 keyed eth_blockNumber succeeded while the
    // same IP's public path returned -32001). Additional independent
    // public fallbacks (Tenderly public gateway, BNB dataseeds, etc.)
    // were added per chain after live-curl confirming the correct
    // chainId + a live block (eth_chainId + eth_blockNumber). The
    // broken `zksync-era-rpc.publicnode.com` (now HTTP 404 — publicnode
    // dropped zkSync Era) was removed.
    private static func ethereumEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified).**
        // REMOVED: `eth-cloudflare` (HTTP 200 envelope but every state
        // read — eth_getBalance/eth_call/eth_blockNumber — returns
        // -32603 "Internal error" / -32046; only chainId works, so a
        // chainId health-check falsely reports it alive while real reads
        // fail). `eth-merkle` (Cloudflare-fronted, IP-throttled: HTTP 429
        // "error code: 1015" after one state read from a server IP, plus
        // a 15s connect hang). `eth-blast` (state reads OK but eth_getLogs
        // is hard-capped to a 10-block range — -32600 HTTP 400 — which
        // breaks the history scanner that sweeps thousands of blocks; this
        // registry feeds one list to both balance and history, so a
        // 10-block-capped endpoint cannot stay in rotation).
        // PROMOTED: `eth-tenderly` (the only keyless endpoint verified to
        // do full state reads AND unrestricted, correctly-shaped
        // eth_getLogs with no per-burst 429) and `eth-drpc` (25/25
        // concurrent state reads OK). NOTE: drpc returns a malformed blob
        // for eth_getLogs — the history scanner must not route getLogs to
        // it; balance/state only.
        [
            jr("eth-publicnode",  "https://ethereum-rpc.publicnode.com",          .ethereum, "publicnode",  .publicNode,  0),
            jr("eth-tenderly",    "https://gateway.tenderly.co/public/mainnet",   .ethereum, "tenderly",    .moderate20,  1),
            jr("eth-drpc",        "https://eth.drpc.org",                         .ethereum, "drpc",        .moderate10,  2),
            oneRPC("eth-1rpc",    slug: "eth",                                    .ethereum,                              3),
        ]
    }
    private static func arbitrumEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified).**
        // REMOVED: `arb-blast` (state reads OK but eth_getLogs hard-capped
        // to a 10-block range — -32600 HTTP 400 — same as eth-blast; breaks
        // the history scanner). PROMOTED: `arb-tenderly` (full state reads +
        // unrestricted getLogs). NOTE: arb-drpc shares eth-drpc's malformed
        // getLogs shape — balance/state only, never history.
        [
            jr("arb-publicnode",  "https://arbitrum-one-rpc.publicnode.com",      .arbitrum, "publicnode",  .publicNode,  0),
            jr("arb-tenderly",    "https://arbitrum.gateway.tenderly.co",         .arbitrum, "tenderly",    .moderate20,  1),
            jr("arb-official",    "https://arb1.arbitrum.io/rpc",                 .arbitrum, "offchain-labs", .moderate20, 2),
            jr("arb-drpc",        "https://arbitrum.drpc.org",                    .arbitrum, "drpc",        .moderate10,  3),
            oneRPC("arb-1rpc",    slug: "arb",                                    .arbitrum,                              4),
        ]
    }
    private static func baseEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified).**
        // base-blast stays (Blast retired only its Optimism endpoint;
        // the Base endpoint still serves chainId 0x2105). ADDED:
        // `base-meowrpc` (https://base.meowrpc.com — HTTP 200, real
        // balance; clean keyless extra). DEMOTED: keyless `base-1rpc`
        // to lowest priority — its public tier is a ~5 req/min + ~200/day
        // quota (Tatum-fronted) that exhausts almost immediately and then
        // returns persistent -32001/429; it is the dominant rate-limit
        // spam source as a keyless primary. The keyed path (when
        // ONERPC_API_KEY is present) raises the limit; keyless is a
        // last-resort fallback only.
        [
            jr("base-publicnode", "https://base-rpc.publicnode.com",              .base, "publicnode",      .publicNode,  0),
            jr("base-official",   "https://mainnet.base.org",                     .base, "coinbase",        .moderate20,  1),
            jr("base-drpc",       "https://base.drpc.org",                        .base, "drpc",            .moderate10,  2),
            jr("base-tenderly",   "https://base.gateway.tenderly.co",             .base, "tenderly",        .moderate10,  3),
            jr("base-blast",      "https://base-mainnet.public.blastapi.io",      .base, "blast",           .moderate10,  4),
            jr("base-meowrpc",    "https://base.meowrpc.com",                     .base, "meowrpc",         .moderate10,  5),
            oneRPC("base-1rpc",   slug: "base",                                   .base,                                  9),
        ]
    }
    private static func optimismEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified).**
        // REMOVED: `op-blast` (Blast's Optimism API is permanently
        // decommissioned — every call incl. chainId returns -32000
        // "Blast API is no longer available … use Alchemy"). ADDED:
        // `op-gateway-fm` (https://optimism-mainnet.gateway.tatum.io —
        // HTTP 200, chainId 0xa, real balance) to refill the slot.
        // DEMOTED: keyless `op-1rpc` (Tatum-fronted ~5 req/min + ~200/day
        // quota; persistent -32001/429 once exhausted — the dominant
        // rate-limit spam source as a keyless primary).
        [
            jr("op-publicnode",   "https://optimism-rpc.publicnode.com",          .optimism, "publicnode",  .publicNode,  0),
            jr("op-official",     "https://mainnet.optimism.io",                  .optimism, "op-labs",     .moderate20,  1),
            jr("op-drpc",         "https://optimism.drpc.org",                    .optimism, "drpc",        .moderate10,  2),
            jr("op-tenderly",     "https://optimism.gateway.tenderly.co",         .optimism, "tenderly",    .moderate10,  3),
            jr("op-gateway-fm",   "https://optimism-mainnet.gateway.tatum.io",    .optimism, "tatum",       .moderate10,  4),
            oneRPC("op-1rpc",     slug: "op",                                     .optimism,                              9),
        ]
    }
    private static func scrollEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe (curl-verified).** All four healthy.
        // The keyless `scr-1rpc` public path is quota-dead (-32001) but
        // the keyed path is fine; demoted below the always-keyless
        // publicnode/official/drpc so an exhausted keyless 1rpc isn't a
        // primary.
        [
            jr("scr-publicnode",  "https://scroll-rpc.publicnode.com",            .scroll, "publicnode",    .publicNode,  0),
            jr("scr-scroll",      "https://rpc.scroll.io",                        .scroll, "scroll-foundation", .moderate20, 1),
            jr("scr-drpc",        "https://scroll.drpc.org",                      .scroll, "drpc",          .moderate10,  2),
            oneRPC("scr-1rpc",    slug: "scroll",                                 .scroll,                                9),
        ]
    }
    private static func zkSyncEndpoints() -> [RPCEndpoint?] {
        // NOTE: `zksync-era-rpc.publicnode.com` was removed 2026-06-16 —
        // it now returns HTTP 404 (publicnode dropped zkSync Era).
        // `mainnet.era.zksync.io` (matter-labs official), `zksync.drpc.org`,
        // and keyed 1rpc (`zksync2-era`) were live-verified (chainId 0x144).
        // **2026-06-16 — live-probe (curl-verified, chainId 0x144).**
        // All three healthy; keyless `zks-1rpc` public path is quota-dead
        // (-32001) but keyed is fine — demoted below the keyless-always
        // mainnet/drpc.
        [
            jr("zks-mainnet",     "https://mainnet.era.zksync.io",                .zkSync, "matter-labs",   .publicNode,  0),
            jr("zks-drpc",        "https://zksync.drpc.org",                      .zkSync, "drpc",          .moderate10,  1),
            oneRPC("zks-1rpc",    slug: "zksync2-era",                            .zkSync,                                9),
        ]
    }
    private static func polygonEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified, chainId 0x89).**
        // REMOVED: `pol-blast` (HTTP 403 / -32000 "Blast API is no longer
        // available" — Blast dropped Polygon specifically; eth/bsc Blast
        // endpoints still work). ADDED: `pol-nodies`
        // (https://polygon-pokt.nodies.app — robust, 20/20 concurrent) and
        // `pol-onfinality` (https://polygon.api.onfinality.io/public —
        // healthy but ~10-concurrent ceiling, so low priority). DEMOTED:
        // keyless `pol-1rpc` (public 200/day quota exhausts to -32001 and
        // caps eth_getLogs to 50 blocks — unusable for history; keyed path
        // fine). pol-publicnode getLogs cap is 10000 blocks; pol-tenderly
        // accepts topic-only getLogs.
        [
            jr("pol-publicnode",  "https://polygon-bor-rpc.publicnode.com",       .polygon, "publicnode",   .publicNode,  0),
            jr("pol-drpc",        "https://polygon.drpc.org",                     .polygon, "drpc",         .moderate10,  1),
            jr("pol-tenderly",    "https://polygon.gateway.tenderly.co",          .polygon, "tenderly",     .moderate10,  2),
            jr("pol-nodies",      "https://polygon-pokt.nodies.app",              .polygon, "nodies",       .moderate20,  3),
            jr("pol-onfinality",  "https://polygon.api.onfinality.io/public",     .polygon, "onfinality",   .moderate10,  5),
            oneRPC("pol-1rpc",    slug: "matic",                                  .polygon,                               9),
        ]
    }
    private static func bnbChainEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified, chainId 0x38).**
        // REMOVED: `bsc-meowrpc` (does NOT support eth_call — -32000
        // "method eth_call is not supported" — so every ERC-20 balanceOf
        // fails; plus eth_getBalance 429). `bsc-drpc` (HTTP 429 + JSON-RPC
        // code 15 "Too many request" on EVERY request — drpc's free tier
        // is saturated for BSC; pol-drpc is fine, the issue is BSC-only).
        // ADDED: `bsc-dataseed-bnbchain` (https://bsc-dataseed.bnbchain.org
        // — official BNB Chain dataseed, 20/20 concurrent, supports
        // eth_call) and `bsc-nodies` (https://bsc-pokt.nodies.app — robust,
        // supports eth_call). bsc-blast stays (alive). DEMOTED: keyless
        // `bsc-1rpc` (public 200/day quota → -32001; keyed fine).
        // bsc-publicnode getLogs cap is 50000 blocks.
        [
            jr("bsc-publicnode",      "https://bsc-rpc.publicnode.com",          .bnbChain, "publicnode",  .publicNode,  0),
            jr("bsc-dataseed1",       "https://bsc-dataseed1.binance.org",       .bnbChain, "binance",     .moderate10,  1),
            jr("bsc-dataseed2",       "https://bsc-dataseed2.binance.org",       .bnbChain, "binance",     .moderate10,  2),
            jr("bsc-dataseed3",       "https://bsc-dataseed3.binance.org",       .bnbChain, "binance",     .moderate10,  3),
            jr("bsc-dataseed4",       "https://bsc-dataseed4.binance.org",       .bnbChain, "binance",     .moderate10,  4),
            jr("bsc-dataseed-bnbchain","https://bsc-dataseed.bnbchain.org",      .bnbChain, "bnbchain",    .moderate20,  5),
            jr("bsc-nodies",          "https://bsc-pokt.nodies.app",             .bnbChain, "nodies",      .moderate20,  6),
            jr("bsc-blast",           "https://bsc-mainnet.public.blastapi.io",  .bnbChain, "blast",       .moderate10,  7),
            oneRPC("bsc-1rpc",        slug: "bnb",                               .bnbChain,                              9),
        ]
    }
    private static func opBNBEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe (curl-verified, chainId 0xcc).** All
        // four healthy; keyless `opbnb-1rpc` public path is quota-dead
        // (-32001), keyed fine — demoted below the always-keyless trio.
        [
            jr("opbnb-publicnode","https://opbnb-rpc.publicnode.com",             .opBNB, "publicnode",     .publicNode,  0),
            jr("opbnb-bnbchain",  "https://opbnb-mainnet-rpc.bnbchain.org",       .opBNB, "bnbchain",       .moderate20,  1),
            jr("opbnb-drpc",      "https://opbnb.drpc.org",                       .opBNB, "drpc",           .moderate10,  2),
            oneRPC("opbnb-1rpc",  slug: "opbnb",                                  .opBNB,                                 9),
        ]
    }
    private static func avalancheEndpoints() -> [RPCEndpoint?] {
        // NOTE: `ava-mainnet.public.blastapi.io` was removed 2026-06-16 —
        // it now returns HTTP 403 (Blast gated the public Avalanche path).
        // **2026-06-16 — live-probe (curl-verified, chainId 0xa86a).** All
        // four healthy; keyless `avax-1rpc` public path is quota-dead
        // (-32001), keyed fine — demoted below the always-keyless trio.
        [
            jr("avax-publicnode", "https://avalanche-c-chain-rpc.publicnode.com", .avalanche, "publicnode", .publicNode,  0),
            jr("avax-ava-labs",   "https://api.avax.network/ext/bc/C/rpc",        .avalanche, "ava-labs",   .moderate20,  1),
            jr("avax-drpc",       "https://avalanche.drpc.org",                   .avalanche, "drpc",       .moderate10,  2),
            oneRPC("avax-1rpc",   slug: "avax/c",                                 .avalanche,                             9),
        ]
    }
    private static func celoEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe (curl-verified, chainId 0xa4ec).** All
        // four healthy; keyless `celo-1rpc` public path is quota-dead
        // (-32001), keyed fine — demoted below the always-keyless trio.
        [
            jr("celo-publicnode", "https://celo-rpc.publicnode.com",              .celo, "publicnode",      .publicNode,  0),
            jr("celo-forno",      "https://forno.celo.org",                       .celo, "celo-foundation", .moderate20,  1),
            jr("celo-drpc",       "https://celo.drpc.org",                        .celo, "drpc",            .moderate10,  2),
            oneRPC("celo-1rpc",   slug: "celo",                                   .celo,                                  9),
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
        // imaginary.cash) started serving anti-bot HTML to plain HTTP
        // User-Agents — they don't return JSON anymore. Switched to
        // Haskoin which returns `{confirmed, unconfirmed, …}` for
        // `/bch/address/{addr}/balance` and is the canonical free
        // BCH index API.
        //
        // **2026-06-16 — live-probe cleanup (curl-verified).** REMOVED
        // `bch-blockbook` (bchblockexplorer.com): it serves a Blockbook
        // web-UI HTML page (not JSON) for the adapter's Haskoin-shaped
        // `/bch/address/{addr}/balance` path, and its real Blockbook API
        // rejects BCH cashaddr/legacy with HTTP 400 — it can never satisfy
        // `fetchHaskoinBCH`. The BitcoinFamilyAdapter only ever calls
        // Haskoin for BCH, so the entry was unreachable dead weight. No
        // healthy keyless BCH second source was found this run (Trezor bch1
        // serves Cloudflare HTML; bchblockexplorer's API 400s on cashaddr),
        // so BCH runs on Haskoin alone — honest, and Haskoin is robust
        // (20-req burst, zero 429).
        [
            rs("bch-haskoin",   "https://api.haskoin.com",    .bitcoinCash, "haskoin.com", .moderate10, 0),
        ]
    }
    private static func litecoinEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — BlockCypher rate-limit fix (curl-verified).**
        // The LTC fallback shares BlockCypher's fragile keyless tier
        // (~100 req/hr, 429 under any concurrency) with the DOGE primary
        // — dropped from `.moderate10` (10 req/s) to `.blockCypherKeyless`
        // (~0.5 req/s) so it doesn't burn the shared hourly cap. The
        // litecoinspace primary (Esplora, ~2.8 req/s clean) carries the
        // load; BlockCypher is only dialed when litecoinspace fails.
        [
            rs("ltc-litecoinspace", "https://litecoinspace.org/api",            .litecoin, "litecoinspace", .moderate10,          0),
            rs("ltc-blockcypher",   "https://api.blockcypher.com/v1/ltc/main",  .litecoin, "blockcypher",   .blockCypherKeyless, 1),
        ]
    }
    private static func dogecoinEndpoints() -> [RPCEndpoint?] {
        // BlockCypher promoted to primary 2026-06-06 after
        // dogechain.info started gating all plain HTTP requests
        // through Cloudflare (returns interstitial HTML instead of JSON).
        //
        // **2026-06-16 — live-probe cleanup (curl-verified).** REMOVED
        // `doge-dogechain` (dogechain.info): re-confirmed HTTP 403
        // Cloudflare interstitial, never returns JSON to a plain HTTP UA —
        // it gave DOGE the *illusion* of a fallback while providing none.
        // No clean keyless DOGE replacement exists (blockchair = keyed,
        // sochain/dogeblocks = 502, bitaps has no DOGE, Trezor doge1 =
        // Cloudflare HTML), so DOGE runs on BlockCypher alone. BlockCypher's
        // keyless tier is fragile (~100 req/hr, 429s under concurrency) —
        // the real fix is a free BlockCypher / NOWNodes API token, flagged
        // for the team; out of scope for a keyless endpoint registry pass.
        // **2026-06-16 — BlockCypher rate-limit fix (curl-verified).**
        // DOGE runs on BlockCypher alone, and its keyless tier is the
        // most fragile UTXO source measured (7/15 reqs 429 at ~2.35
        // req/s, 20/20 429 under parallel burst, ~100/hr cap that stays
        // locked once spent). Dropped from `.moderate10` (10 req/s) to
        // `.blockCypherKeyless` (~0.5 req/s, burst 1) so the limiter
        // self-throttles below the hourly cap; the per-host
        // `ConcurrencyGate` slot (4) additionally prevents the
        // parallel-burst 429. A free BlockCypher / NOWNodes token is the
        // real fix for DOGE redundancy (flagged for the team).
        [
            rs("doge-blockcypher", "https://api.blockcypher.com/v1/doge/main", .dogecoin, "blockcypher", .blockCypherKeyless, 0),
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
        // **2026-06-16 — live-probe (curl-verified).** s1/s2.ripple.com
        // (Ripple Labs clio) took 25–40 parallel server_info with zero
        // 429 — they stay the burst-tolerant primaries. `xrp-xrplcluster`
        // returns HTTP 429 + "Rate limited … Dhali" HTML on ANY concurrent
        // burst (only ~1.6 req/s sequential survives), so it stays
        // last-resort AND gets a tight `.slow15` budget so the limiter
        // self-throttles before tripping the provider's 429.
        [
            jr("xrp-s1",          "https://s1.ripple.com:51234", .ripple, "ripple-labs", .moderate10, 0),
            jr("xrp-s2",          "https://s2.ripple.com:51234", .ripple, "ripple-labs", .moderate10, 1),
            jr("xrp-xrplcluster", "https://xrplcluster.com",     .ripple, "xrplcluster", .slow15,      2),
        ]
    }
    private static func stellarEndpoints() -> [RPCEndpoint?] {
        // **2026-06-29 — Horizon failover refresh.** Keep SDF Horizon as
        // fallback, not primary. LOBSTR is a public Horizon provider, and
        // Ankr's Horizon proxy live-probed fastest for `/fee_stats`; SDF
        // remains the final canonical fallback before the scanner's direct
        // last-resort Horizon call.
        [
            rs("xlm-ankr",    "https://rpc.ankr.com/http/stellar_horizon",    .stellar, "ankr",               .moderate10, 0),
            rs("xlm-lobstr",  "https://horizon.stellar.lobstr.co",           .stellar, "lobstr",             .moderate10, 1),
            rs("xlm-tatum",   "https://stellar-mainnet.gateway.tatum.io",     .stellar, "tatum",              .moderate10, 2),
            rs("xlm-horizon", "https://horizon.stellar.org",                  .stellar, "stellar-foundation", .moderate20, 3),
        ]
    }
    private static func nearEndpoints() -> [RPCEndpoint?] {
        [
            jr("near-mainnet", "https://rpc.mainnet.near.org", .near, "near-foundation", .moderate20, 0),
            jr("near-lava",    "https://near.lava.build",      .near, "lava-network",    .moderate10, 1),
        ]
    }
    private static func tonEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — toncenter rate-limit fix (curl-verified).**
        // toncenter's keyless tier 429s ("Ratelimit exceed") on any
        // burst above ~1 rps (6/15 reqs were 429 over 5.67s) — it was
        // `.conservative` (5 req/s), which is what tripped the 429.
        // Dropped to `.slow1` (~1 req/s) so the limiter self-throttles
        // below toncenter's ceiling; tonapi is more burst-tolerant and
        // stays the fallback.
        [
            rs("ton-toncenter", "https://toncenter.com/api/v2", .ton, "toncenter", .slow1,        0),
            rs("ton-tonapi",    "https://tonapi.io/v2",         .ton, "tonapi",    .conservative, 1),
        ]
    }
    private static func tronEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified).** REMOVED
        // `trx-tronstack` (api.tronstack.io): `/v1/accounts` → 404,
        // `/wallet/getaccount` → timeout, `/wallet/getnowblock` → 502 —
        // the Tron API is decommissioned (it was the only Tron fallback,
        // so Tron ran single-endpoint). ADDED: `trx-publicnode`
        // (https://tron-rpc.publicnode.com — live-verified wallet/getaccount
        // + wallet/triggerconstantcontract, 20/20 burst, no 429). CAVEAT:
        // publicnode serves the full-node `wallet/*` JSON API but NOT
        // TronGrid's `/v1/accounts` HTTP-API path (404) — so it's a real
        // failover for the TRC-20 `wallet/triggerconstantcontract` balanceOf
        // path, but the native-balance (`v1/accounts/{addr}`) and history
        // (`v1/accounts/{addr}/transactions[/trc20]`) paths are TronGrid
        // extensions publicnode can't serve. It sits BELOW trongrid so
        // trongrid (which serves every path) is tried first; routing the
        // wallet/* calls to publicnode is an adapter migration left for the
        // chain-data pass. RATE LIMIT: trongrid's keyless cap is
        // `allowed_rps(3)` (verbatim from its 429 body), so it's rated
        // `.slow3` here (was wrongly `.moderate10`); publicnode tolerates
        // ~2.6 rps serial keyless.
        [
            rs("trx-trongrid",   "https://api.trongrid.io",         .tron, "trongrid",   .slow3,      0),
            rs("trx-publicnode", "https://tron-rpc.publicnode.com", .tron, "publicnode", .moderate10, 1),
        ]
    }
    private static func polkadotEndpoints() -> [RPCEndpoint?] {
        [
            jr("dot-polkadot",   "https://rpc.polkadot.io",                    .polkadot, "polkadot-foundation", .moderate10, 0),
            jr("dot-onfinality", "https://polkadot.api.onfinality.io/public",  .polkadot, "onfinality",          .moderate10, 1),
        ]
    }
    private static func aptosEndpoints() -> [RPCEndpoint?] {
        // **2026-06-16 — live-probe cleanup (curl-verified).** REMOVED
        // `apt-nodit` (aptos-mainnet.nodit.io): HTTP 401
        // "NO_AUTHENTICATION_FOUND" — key-only, so it was a non-functional
        // fallback (Aptos ran effectively single-endpoint). ADDED:
        // `apt-aptoslabs-api` (https://api.mainnet.aptoslabs.com/v1 —
        // live-verified keyless POST /v1/view 0x1::coin::balance). It's the
        // same Aptos Labs infra/shape as the primary (a redundancy/
        // availability fallback sharing the anonymous quota, not a separate
        // rate-limit budget) — no truly independent keyless Aptos fullnode
        // exists (publicnode 403, drpc 400, 1rpc 429 all failed).
        [
            rs("apt-aptoslabs",     "https://fullnode.mainnet.aptoslabs.com/v1", .aptos, "aptos-labs", .moderate20, 0),
            rs("apt-aptoslabs-api", "https://api.mainnet.aptoslabs.com/v1",      .aptos, "aptos-labs", .moderate20, 1),
        ]
    }
    private static func suiEndpoints() -> [RPCEndpoint?] {
        [
            jr("sui-mainnet",     "https://fullnode.mainnet.sui.io",                .sui, "sui-foundation", .moderate20, 0),
            jr("sui-blockvision", "https://sui-mainnet-endpoint.blockvision.org",   .sui, "blockvision",    .moderate10, 1),
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
    /// `https://1rpc.io/<KEY>/<slug>` when `Secrets.hasOneRPCKey`.
    /// `slug` is the 1rpc per-chain segment (live-verified 2026-06-16
    /// against the keyed endpoint: `eth`, `arb`, `base`, `op`, `scroll`,
    /// `zksync2-era`, `matic`, `bnb`, `opbnb`, `avax/c`, `celo` — each
    /// returned its correct chainId). The key never touches source —
    /// `Secrets.oneRPCKey` reads it from the build's Info.plist (injected
    /// from gitignored `Secrets.xcconfig`).
    ///
    /// **2026-06-16 — keyless 1rpc is DROPPED, not degraded.** The
    /// keyless public path `https://1rpc.io/<slug>` is dead-on-arrival
    /// for state reads: once its ~200/day per-IP quota is spent it
    /// returns JSON-RPC `-32001` "You've reached the usage limit" (HTTP
    /// 200) on EVERY metered call, re-confirmed live this run (5/5
    /// `eth_getBalance` → -32001). Registering it as a fallback meant
    /// every refresh cycle dialed a guaranteed-failing endpoint, logged
    /// "RPC rate-limited", and rotated — the dominant source of the
    /// rate-limit-spam the user reported, compounded by the 10 s poller
    /// re-firing it. So when there's no key we return `nil` and drop the
    /// endpoint outright. Every EVM chain that referenced keyless 1rpc
    /// retains ≥2 always-keyless healthy endpoints (publicnode +
    /// drpc/official/tenderly/dataseed), so dropping it loses no real
    /// coverage — only the spam. The keyed path (current production
    /// build has `ONERPC_API_KEY`) stays a real, generous-budget
    /// fallback.
    /// Infura keyed EVM endpoint — the PAID PRIMARY (2026-06-16). The user
    /// supplied a paid `INFURA_API_KEY`, so EVM reads route through Infura
    /// first: priority -2 sorts it AHEAD of keyed 1rpc (-1) and publicnode
    /// (0). `slug` is Infura's network slug (`mainnet` for Ethereum,
    /// `<chain>-mainnet` for the rest). Returns nil when no key is set, so
    /// the chain falls back to 1rpc/publicnode/etc. unchanged.
    private static func infura(_ id: String, slug: String, _ chain: SupportedChain) -> RPCEndpoint? {
        guard Secrets.hasInfuraKey else { return nil }
        let url = "https://\(slug).infura.io/v3/\(Secrets.infuraAPIKey)"
        guard let parsed = URL(string: url) else {
            log.fault("Dropped malformed Infura endpoint URL for \(id, privacy: .public)")
            return nil
        }
        return RPCEndpoint(id: id, url: parsed, kind: .jsonRPC, chain: chain, provider: "infura", rateLimit: .infura, priority: -2, weight: 1)
    }

    private static func oneRPC(_ id: String, slug: String, _ chain: SupportedChain, _ pri: Int) -> RPCEndpoint? {
        guard Secrets.hasOneRPCKey else {
            // No key → the public tier is a guaranteed -32001 wall.
            // Drop it rather than spam-rotate through it every cycle.
            log.debug("Dropped keyless 1rpc endpoint \(id, privacy: .public) (no ONERPC_API_KEY; public tier is quota-dead)")
            return nil
        }
        let url = "https://1rpc.io/\(Secrets.oneRPCKey)/\(slug)"
        guard let parsed = URL(string: url) else {
            log.fault("Dropped malformed 1rpc endpoint URL for \(id, privacy: .public)")
            return nil
        }
        // **2026-06-16 — keyed 1rpc is the PRIVACY PRIMARY.** The user
        // supplied ONERPC_API_KEY explicitly so on-chain reads route
        // through 1rpc.io, which strips client IP/metadata and does not
        // log queries — the reason to use it for a wallet. The keyed path
        // is verified healthy with a generous budget (the ~200/day quota
        // wall is the KEYLESS public tier only — a distinct path this was
        // previously confused with, which is why the key looked "unused").
        // Priority -1 sorts it AHEAD of publicnode's 0, so it is the
        // primary on every chain it's configured for; publicnode (0,
        // unlimited) is the immediate fallback if the keyed quota ever
        // exhausts (-32001 → clean rotate, no breaker strike). The
        // per-call-site `pri` argument is intentionally ignored for the
        // keyed endpoint — keyed 1rpc is always primary.
        _ = pri
        return RPCEndpoint(id: id, url: parsed, kind: .jsonRPC, chain: chain, provider: "1rpc", rateLimit: .moderate20, priority: -1, weight: 1)
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

    /// 10 req/s sustained, 5 burst. For stricter endpoints (some providers'
    /// lower tier, Cloudflare, mempool.space, etc.).
    static let moderate10 = RPCEndpoint.RateLimit(
        requestsPerSecond: 10, requestsPerMinute: 600, requestsPerDay: nil, burstAllowance: 5
    )

    /// ~3 req/s, no burst. TronGrid's keyless tier caps at
    /// `allowed_rps(3)` (verbatim from its 429 body, live-verified
    /// 2026-06-16) and then suspends the IP for several seconds — so the
    /// limiter must self-throttle below 3 rps to avoid the storm.
    static let slow3 = RPCEndpoint.RateLimit(
        requestsPerSecond: 3, requestsPerMinute: 180, requestsPerDay: nil, burstAllowance: 1
    )

    /// ~1.5 req/s, no burst. xrplcluster.com 429s ("Rate limited … Dhali")
    /// on ANY concurrent burst but tolerated ~1.6 req/s sequential
    /// (live-verified 2026-06-16) — keep it strictly serialized so the
    /// limiter trips before the provider does.
    static let slow15 = RPCEndpoint.RateLimit(
        requestsPerSecond: 1.5, requestsPerMinute: 90, requestsPerDay: nil, burstAllowance: 1
    )

    /// ~1 req/s, no burst. TON `toncenter.com` keyless 429s
    /// ("Ratelimit exceed", code 429) on ANY burst above ~1 rps —
    /// live-verified 2026-06-16: 15 reqs over 5.67s returned 6× 429.
    /// Its sustained ceiling is ~1 req/s, so the limiter must
    /// self-throttle there (was `.conservative` = 5 req/s, which is
    /// what tripped its 429). `tonapi` is more tolerant and stays the
    /// fallback.
    static let slow1 = RPCEndpoint.RateLimit(
        requestsPerSecond: 1, requestsPerMinute: 60, requestsPerDay: nil, burstAllowance: 1
    )

    /// ~0.5 req/s, no burst, ~100/hr cap. BlockCypher's keyless tier
    /// (DOGE primary, LTC fallback) is the most fragile UTXO source —
    /// live-verified 2026-06-16: 7/15 reqs were HTTP 429 at ~2.35 req/s
    /// sequential, 20/20 were 429 under a parallel burst, and the
    /// ~100-req/hour cap stays locked once spent. The per-host
    /// `ConcurrencyGate` slot (4) already prevents the parallel-burst
    /// 429; this rate keeps the sustained dial below where the hourly
    /// cap burns out mid-session (was `.moderate10` = 10 req/s, far
    /// above the measured clean rate). `requestsPerDay` encodes the
    /// ~2000/day keyless envelope as the sanity guard.
    static let blockCypherKeyless = RPCEndpoint.RateLimit(
        requestsPerSecond: 0.5, requestsPerMinute: 30, requestsPerDay: 2_000, burstAllowance: 1
    )
}
