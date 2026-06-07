import Foundation

/// App-wide actor-isolated rate limiter. One instance per `RPCClient`.
/// Maintains a `TokenBucket` per endpoint id; `acquire(for:)` returns
/// when the caller is permitted to send the next request to that
/// endpoint.
///
/// **Token-bucket model.** Each bucket starts full (`burstAllowance`).
/// Every call consumes one token. Tokens refill continuously at
/// `requestsPerSecond`. If the bucket is empty, `acquire` sleeps for
/// the time required to refill one token before returning.
///
/// **Why per-endpoint, not per-chain.** Two addresses on Ethereum
/// scanned in parallel both hit the same `eth_getBalance` endpoint;
/// the provider rate-limits per IP, not per address, so we must
/// rate-limit per endpoint. Chain-level limiting would over-throttle
/// (artificially limiting Ethereum reads because we made one Polygon
/// call that doesn't share quota).
///
/// **Why actor, not class+lock.** Pure Swift 6 concurrency. The
/// actor's serial mailbox guarantees one bucket per id without locks.
/// Callers `await` the actor's `acquire` method; the actor schedules
/// them in arrival order.
actor RateLimiter {
    private var buckets: [String: TokenBucket] = [:]

    /// Wait for permission to send the next request to `endpoint`.
    /// Returns immediately if the bucket has tokens; otherwise
    /// sleeps for the refill duration.
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

/// One token bucket per endpoint. Isolated actor — refill arithmetic
/// is non-trivial enough that ordering matters; the actor's mailbox
/// guarantees consume-then-refill ordering without explicit locks.
actor TokenBucket {
    private var availableTokens: Double
    private var lastRefill: Date
    private let limit: RPCEndpoint.RateLimit

    init(limit: RPCEndpoint.RateLimit) {
        self.limit = limit
        self.availableTokens = Double(limit.burstAllowance)
        self.lastRefill = Date()
    }

    /// Consume one token. If none available, sleep until refill
    /// produces one. Loops in case the sleep undershoots due to
    /// scheduler granularity (rare but possible).
    func consume() async {
        for _ in 0..<10 {  // safety bound: never loop more than 10 times
            refill()
            if availableTokens >= 1 {
                availableTokens -= 1
                return
            }
            // Time until the next token refills: (1 - available) /
            // refill-rate. e.g. if 0.3 tokens available and rate
            // is 5 req/s, we need 0.14 s.
            let neededTokens = 1 - availableTokens
            let waitSeconds = neededTokens / limit.requestsPerSecond
            // Cap the sleep so a misconfigured rate doesn't pin a
            // task forever. 60 s is well beyond any reasonable
            // single-request wait; after 60 s we fall through and
            // try again.
            let cappedWait = min(waitSeconds, 60)
            try? await Task.sleep(for: .seconds(cappedWait))
        }
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        let refilled = elapsed * limit.requestsPerSecond
        availableTokens = min(
            Double(limit.burstAllowance),
            availableTokens + refilled
        )
        lastRefill = now
    }
}
