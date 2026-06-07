# RPC Architecture — Plan + Reference

> Aperture's on-chain reader stack: how every balance, transaction
> history, and address-activity check actually hits the network.
> **Per-chain providers · multi-RPC fallback · actor-isolated rate
> limiting · token-bucket per provider · circuit breaker per endpoint ·
> SwiftData persistence on every successful read.**
>
> User direction 2026-06-06: "make all function real, RPCs, real
> history check, real balance check, please use publicnode.com for all
> chains that this website support it, and for other chains that
> doesn't have in publicnode, use different RPCs, with real fallbacks,
> and for all chains add fallback RPCs … if current RPCs accept 10
> calls/second, it shouldn't be called more than 10 times a second."

This document is the **canonical plan**. The foundation files
(`UniApp/Sources/Networking/*.swift`) implement what it describes.
Per-chain implementations land in phased follow-ups; this doc names
the contract every chain follows.

## 1. Goals & non-goals

### Goals

1. **Real on-chain reads** for all 24 supported chains
   (`SUPPORTED_ASSETS.md`).
2. **Per-chain primary + ≥ 2 fallback RPCs.** Fallback order is
   deterministic; a failing primary trips a circuit breaker before
   the next call selects the fallback.
3. **Per-endpoint rate limiting** — token-bucket per endpoint
   honoring documented limits (req/s, req/min). Hard cap on
   bursts; smooth refill on the time horizon.
4. **Unified action surface.** One `RPCClient.call(endpoint,
   method, params)` — the same code path for `eth_getBalance`,
   `getBlockNumber`, `mempool.space/address/X`, etc. Chain-family
   adapters translate domain calls (`fetchBalance(chain, address)`)
   to the underlying provider call.
5. **SwiftData persistence on every successful read.** Balance →
   `TokenBalanceRecord`. Transaction → `TransactionRecord`. Price →
   `CachedPriceRecord`. Address scan completion → `WalletAddressRecord.lastScannedAt`.
6. **Honest failure UX.** When all fallbacks fail or all rate
   limits are exhausted, the UI surfaces "Couldn't reach the chain"
   per Rule #16 §A.5 — never a fake `$—` or a silent zero.
7. **No third-party SPM dependencies** (Rule #3). Pure URLSession
   + JSONSerialization + actor-isolated state.
8. **No Aperture servers** (Rule #16 §A.5). Every read goes
   directly from the device to the public RPC. The user's IP +
   query are visible to the provider; Aperture itself records
   nothing about who asked what.

### Non-goals

- **No write paths in v1.** Send / sign / broadcast = T-048 (Send
  flow). This doc is read-only RPC.
- **No archive-node history.** First-N transactions from each
  chain's explorer-equivalent endpoint; deeper history defers to a
  future "Load more" pagination.
- **No private RPC keys.** Public endpoints only. If a chain has no
  free public RPC with reasonable limits, it ships as "history +
  balance unavailable on this build" and the chain row in the UI
  says so honestly (rather than fake-displaying 0).

## 2. The four foundation files (`UniApp/Sources/Networking/`)

### 2.1 `RPCEndpoint.swift` — single endpoint description

```swift
struct RPCEndpoint: Sendable, Hashable {
    let id: String              // stable identifier ("eth-publicnode-1")
    let url: URL                // base URL for JSON-RPC OR REST root
    let kind: Kind              // .jsonRPC or .rest
    let chain: SupportedChain
    let provider: String        // "publicnode" / "ankr" / "mempool.space"
    let rateLimit: RateLimit    // documented per-endpoint quota
    let priority: Int           // lower = tried first; primary = 0, fallback = 1, 2, …
    let weight: Int             // share when multiple endpoints have the same priority

    enum Kind: Sendable { case jsonRPC; case rest }

    struct RateLimit: Sendable, Hashable {
        let requestsPerSecond: Double
        let requestsPerMinute: Int
        let requestsPerDay: Int?      // nil = no daily cap
        let burstAllowance: Int       // token-bucket bucket size
    }
}
```

A single chain has multiple endpoints. They share the same `chain`
but differ on `provider` / `priority` / `rateLimit`.

### 2.2 `RPCRegistry.swift` — per-chain endpoint catalog

```swift
enum RPCRegistry {
    static let endpoints: [SupportedChain: [RPCEndpoint]] = [
        .ethereum: [
            // Primary
            RPCEndpoint(id: "eth-publicnode-1",
                        url: URL(string: "https://ethereum.publicnode.com")!,
                        kind: .jsonRPC, chain: .ethereum,
                        provider: "publicnode",
                        rateLimit: .init(requestsPerSecond: 100, requestsPerMinute: 6_000,
                                         requestsPerDay: nil, burstAllowance: 20),
                        priority: 0, weight: 1),
            // Fallback 1
            RPCEndpoint(id: "eth-llamarpc-1",
                        url: URL(string: "https://eth.llamarpc.com")!,
                        kind: .jsonRPC, chain: .ethereum,
                        provider: "llamarpc",
                        rateLimit: .init(requestsPerSecond: 50, requestsPerMinute: 3_000,
                                         requestsPerDay: nil, burstAllowance: 10),
                        priority: 1, weight: 1),
            // Fallback 2
            RPCEndpoint(id: "eth-cloudflare-1",
                        url: URL(string: "https://cloudflare-eth.com")!,
                        kind: .jsonRPC, chain: .ethereum,
                        provider: "cloudflare",
                        rateLimit: .init(requestsPerSecond: 25, requestsPerMinute: 1_500,
                                         requestsPerDay: nil, burstAllowance: 5),
                        priority: 2, weight: 1),
        ],
        // … 23 more chains
    ]

    static func endpoints(for chain: SupportedChain) -> [RPCEndpoint] {
        endpoints[chain]?.sorted { $0.priority < $1.priority } ?? []
    }
}
```

#### 2.2.1 PublicNode coverage (per `https://www.publicnode.com`)

Chains where PublicNode is the primary (free, no auth, generous
limits, listed on their site):

- ethereum, arbitrum, base, optimism, polygon, bnbChain, opBNB,
  avalanche, celo, scroll, zkSync (Era), kavaEvm

Chains where PublicNode does NOT serve and we use alternative
primaries:

- bitcoin / bitcoinCash / dogecoin / litecoin → `mempool.space` family
  (BTC) + Blockstream Esplora siblings (BCH/LTC/DOGE via
  `blockchain.info` / `bch.loping.net` / `dogechain.info` / similar)
- solana → `https://api.mainnet-beta.solana.com`
  (Solana Foundation, public, rate-limited)
- aptos → `https://fullnode.mainnet.aptoslabs.com/v1`
- near → `https://rpc.mainnet.near.org`
- polkadot → `https://rpc.polkadot.io` + Subscan REST fallback
- ripple → `https://s1.ripple.com:51234` + `s2.ripple.com:51234`
- stellar → `https://horizon.stellar.org`
- sui → `https://fullnode.mainnet.sui.io`
- ton → `https://toncenter.com/api/v2/`
- tron → `https://api.trongrid.io`
- kava (Cosmos) → `https://api.data.kava.io` (REST)

Every entry has ≥ 2 fallbacks. Final fallback for EVM chains is
`https://rpc.ankr.com/<chain>` (Ankr's public free tier, rate-limited
but well-tested).

### 2.3 `RateLimiter.swift` — actor-isolated token bucket per endpoint

```swift
actor RateLimiter {
    private var buckets: [String: TokenBucket] = [:]      // keyed by endpoint.id

    /// Returns when the caller is permitted to send the next request
    /// to `endpoint`. If the bucket has tokens available, returns
    /// immediately; otherwise awaits the time until the next refill.
    func acquire(for endpoint: RPCEndpoint) async {
        let bucket = bucket(for: endpoint)
        await bucket.consume()
    }

    private func bucket(for endpoint: RPCEndpoint) -> TokenBucket {
        if let existing = buckets[endpoint.id] { return existing }
        let new = TokenBucket(limit: endpoint.rateLimit)
        buckets[endpoint.id] = new
        return new
    }
}

actor TokenBucket {
    private var availableTokens: Double
    private var lastRefill: Date
    private let limit: RPCEndpoint.RateLimit

    init(limit: RPCEndpoint.RateLimit) {
        self.limit = limit
        self.availableTokens = Double(limit.burstAllowance)
        self.lastRefill = Date()
    }

    func consume() async {
        while true {
            refill()
            if availableTokens >= 1 {
                availableTokens -= 1
                return
            }
            let neededTime = (1 - availableTokens) / limit.requestsPerSecond
            try? await Task.sleep(for: .seconds(neededTime))
        }
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let refilled = elapsed * limit.requestsPerSecond
        availableTokens = min(
            Double(limit.burstAllowance),
            availableTokens + refilled
        )
        lastRefill = now
    }
}
```

### 2.4 `RPCClient.swift` — dispatcher with fallback + retry + circuit breaker

```swift
actor RPCClient {
    private let session: URLSession
    private let rateLimiter: RateLimiter
    private var breakers: [String: CircuitBreaker] = [:]   // keyed by endpoint.id
    private let log: Logger

    init(session: URLSession = .shared, rateLimiter: RateLimiter = RateLimiter()) {
        self.session = session
        self.rateLimiter = rateLimiter
        self.log = Logger(subsystem: "com.thuglife.aperture", category: "rpc")
    }

    /// Dispatch a JSON-RPC call against the registry's primary endpoint
    /// for `chain`. On rate-limit-wait completion, sends the request;
    /// on failure, rotates to the next-priority endpoint. Circuit
    /// breaker opens after N consecutive failures within window;
    /// half-open after cooldown; closed after a successful call.
    func callJSON(chain: SupportedChain, method: String, params: [Any]) async throws -> Any {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: Error?
        for endpoint in endpoints {
            if let breaker = breakers[endpoint.id], breaker.isOpen {
                continue   // skip — endpoint is in circuit-breaker timeout
            }
            await rateLimiter.acquire(for: endpoint)
            do {
                let result = try await dispatch(endpoint, method: method, params: params)
                breakers[endpoint.id]?.recordSuccess()
                return result
            } catch {
                breakers[endpoint.id, default: CircuitBreaker()].recordFailure()
                lastError = error
                log.error("RPC failed on \(endpoint.id, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
        }
        throw lastError ?? RPCError.allEndpointsFailed(chain)
    }

    // …private dispatch(_: method:params:) builds the JSON-RPC envelope,
    // hits the URL, decodes the response, throws on non-200 / RPC-error.
    // Exponential backoff with jitter on transient errors (5xx, timeout).
}
```

#### Circuit breaker contract

```swift
struct CircuitBreaker {
    private(set) var consecutiveFailures: Int = 0
    private(set) var openUntil: Date?
    static let failureThreshold = 5
    static let openDuration: TimeInterval = 60     // 1 minute timeout

    var isOpen: Bool {
        guard let openUntil else { return false }
        return Date() < openUntil
    }
    mutating func recordSuccess() { consecutiveFailures = 0; openUntil = nil }
    mutating func recordFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold {
            openUntil = Date().addingTimeInterval(Self.openDuration)
        }
    }
}
```

### 2.5 `RPCError.swift` — typed throws across the stack

```swift
enum RPCError: Error, Sendable {
    case noEndpoint(SupportedChain)
    case allEndpointsFailed(SupportedChain)
    case network(URLError)
    case rateLimited(Date)             // retry after
    case invalidResponse(String)
    case decodingFailed(String)
    case rpcError(code: Int, message: String)
}
```

## 3. Domain layer — chain-family adapters

The networking layer is provider-agnostic. The **chain-family
adapters** translate domain calls (`fetchNativeBalance`,
`fetchTransactionHistory`, `fetchTokenBalance`) into provider
calls per family.

### 3.1 EVM family

**One adapter handles all 12 EVM chains** because every EVM RPC
implements the standard JSON-RPC surface:

- `eth_getBalance(address, "latest")` → native balance in wei
- `eth_getTransactionCount(address, "latest")` → `isUsed` heuristic
- `eth_call({to: tokenContract, data: "0x70a08231" + address}, "latest")` → ERC-20 balance
- `eth_getLogs({fromBlock, toBlock, address, topics})` → transfer history

```swift
struct EVMChainAdapter: ChainAdapter {
    let chain: SupportedChain
    let client: RPCClient

    func fetchNativeBalance(address: String) async throws -> Decimal {
        let hex = try await client.callJSON(chain: chain, method: "eth_getBalance",
                                            params: [address, "latest"]) as! String
        // wei → Decimal divided by 10^18 (or chain.nativeDecimals)
    }

    func fetchTokenBalance(address: String, contract: String) async throws -> Decimal {
        let data = "0x70a08231" + address.paddedHex
        let result = try await client.callJSON(chain: chain, method: "eth_call",
                                                params: [["to": contract, "data": data], "latest"]) as! String
        // hex → Decimal divided by 10^decimals
    }

    func fetchRecentTransactions(address: String, limit: Int) async throws -> [TxRecord] {
        // Combine eth_getLogs with explorer REST API for usable history.
        // First cut: just fetch last N blocks of logs that include the
        // address as topic. Pagination via fromBlock/toBlock.
    }
}
```

### 3.2 Bitcoin family

`mempool.space` REST is the canonical pattern:

```swift
struct BitcoinFamilyAdapter: ChainAdapter {
    let chain: SupportedChain        // .bitcoin / .bitcoinCash / .litecoin / .dogecoin
    let client: RPCClient

    func fetchNativeBalance(address: String) async throws -> Decimal {
        // GET https://mempool.space/api/address/{address}
        // → { chain_stats: { funded_txo_sum, spent_txo_sum }, mempool_stats: { ... } }
        // Balance = funded - spent (in satoshis); divide by 10^8.
    }
}
```

### 3.3 Other families

One adapter per family (`Solana`, `XRP`, `Cosmos`, `NEAR`, `TON`,
`TRON`, `Polkadot`, `Aptos`, `Sui`, `Stellar`). Each is ~80-120
lines. The phased delivery in TODO names them.

## 4. Persistence integration

Every successful read writes to SwiftData via the existing
repositories:

- `TransactionRepository.upsertBalance(...)` for `TokenBalanceRecord`
- `TransactionRepository.upsertTransaction(...)` for `TransactionRecord`
- `TransactionRepository.markScanComplete(addressId:isUsed:)` to
  update `WalletAddressRecord.lastScannedAt`
- `PriceCacheRepository.upsert(...)` for `CachedPriceRecord`

The repositories are `@ModelActor`s that run isolated from the main
actor; the chain adapter awaits the repository call on its own
isolation, then the SwiftUI `@Query` on the wallet-home re-renders
reactively.

## 5. Concurrency model

```
WalletRefreshCoordinator (called from .refreshable on wallet home,
                          and from BGTaskScheduler T-041)
        │
        ├── per-address fan-out via withTaskGroup
        │       │
        │       ├── ChainAdapter.fetchNativeBalance(address)
        │       │      └── RPCClient.callJSON
        │       │             └── RateLimiter.acquire(endpoint)
        │       │             └── URLSession.data(for: request)
        │       │             └── circuit breaker bookkeeping
        │       │
        │       └── ChainAdapter.fetchRecentTransactions(address, limit: 25)
        │              └── … same path
        │
        └── after all fan-outs return:
              upsert all to repositories
              mark addresses scanComplete
              touch WalletAddressRecord.lastScannedAt
```

Rate limiting is **per-endpoint**, not per-chain. If two addresses
on Ethereum scan in parallel, both call `eth_getBalance` against
the same endpoint, both go through the SAME `TokenBucket` for that
endpoint. The bucket smooths their requests at the documented
provider limit.

Circuit breaker is also per-endpoint. If `ethereum.publicnode.com`
returns 500 five times consecutively, the breaker opens for 60 s;
all subsequent calls in that window skip publicnode and go to the
LlamaRPC fallback.

## 6. Failure modes & UX

| Failure                            | Behavior                                               | UX surface                            |
|------------------------------------|--------------------------------------------------------|---------------------------------------|
| Endpoint returns 500               | breaker increments, request retries on next endpoint   | invisible                             |
| Endpoint returns 429 (rate limit)  | `RPCError.rateLimited` honored by sleep; retry         | invisible                             |
| All endpoints in breaker-open      | `RPCError.allEndpointsFailed`                           | row shows "Refresh failed" + retry button |
| Network offline                    | `RPCError.network(URLError.notConnected)`               | screen-level banner "You're offline"  |
| Decoding fails                     | `RPCError.decodingFailed`                              | row shows "Unknown balance" footnote  |
| Chain has no registered endpoints  | `RPCError.noEndpoint(chain)`                            | chain row hidden / "Not available"   |

## 7. Honesty (Rule #16)

- Every chain row's footer names the provider that just served the
  read: "Last synced via publicnode.com 2m ago." User sees who the
  data came from.
- Per Settings → Privacy "Background refresh" toggle (T-041): when
  off, the coordinator only runs on explicit pull-to-refresh.
- Settings → About → Network providers (new T-XXX): full per-chain
  provider list with primary + fallbacks named, in honest order.

## 8. Phased delivery (this turn writes the foundation)

| Phase | Scope                                                              | Status                          |
|-------|--------------------------------------------------------------------|---------------------------------|
| 0     | This doc + 4 foundation files                                       | **THIS TURN**                   |
| 1     | EVM family adapter + Ethereum-only RPC registry entry              | **THIS TURN** (reference impl)  |
| 2     | All 12 EVM chains' RPC entries + adapter wired into refresh         | T-053 (next turn)               |
| 3     | Bitcoin-family adapter + mempool.space registry entries             | T-054                           |
| 4     | Solana / XRP / Stellar adapters                                     | T-055                           |
| 5     | NEAR / TON / TRON / Polkadot / Aptos / Sui / Cosmos adapters         | T-056                           |
| 6     | Transaction-history pass for each adapter (logs, REST tx pages)     | T-057                           |
| 7     | UI polish — "Last synced via X 2m ago" footers, retry buttons       | T-058                           |
| 8     | BGTaskScheduler hookup (T-041) using the new coordinator            | T-041 (already filed)           |
| 9     | Settings → About → Network providers screen                         | T-059                           |

## 9. Testing checklist

For each chain adapter, before declaring "Phase N complete":

1. Real address with known on-chain balance returns the right value
   in the wallet-home's hero balance.
2. Force-fail the primary (block its DNS, or change the URL to
   `localhost`) — the fallback kicks in within `consecutiveFailures
   × ~latency`, breaker opens at `failureThreshold`, and the next 60 s
   of calls skip the primary cleanly.
3. Burst-test: fire 100 balance calls at once for the same address;
   the token bucket throttles to the documented rate; no request
   gets a 429 from the provider.
4. Network-off test: airplane mode → calls return
   `RPCError.network` quickly → UI banner appears.
5. Decoding-error test: stub a response with malformed JSON →
   adapter throws `decodingFailed` cleanly → UI footnote appears.

## 10. References (not bundled — for the implementer)

- PublicNode docs: `https://www.publicnode.com/`
- Ethereum JSON-RPC spec: `https://ethereum.org/en/developers/docs/apis/json-rpc/`
- Mempool.space API: `https://mempool.space/docs/api/rest`
- Solana JSON-RPC: `https://docs.solana.com/api/http`
- XRPL JSON-RPC: `https://xrpl.org/public-api-methods.html`
- Aptos REST API: `https://aptos.dev/apis/fullnode-rest-api/`
