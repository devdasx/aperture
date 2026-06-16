import Foundation

/// App-wide bound on how many RPC/REST requests may be **in flight at
/// once** — globally and per upstream host. One process-wide instance,
/// held by `RPCClient`.
///
/// **Why this exists (2026-06-16 — the rate-limit storm + socket flood).**
/// The per-endpoint `RateLimiter` bounds the *rate* (requests per
/// second) at which we may dial a single endpoint, but it does NOT bound
/// how many requests are *simultaneously open*. A wallet refresh fans
/// out across ~25 chains via `withTaskGroup` (native balance + nonce +
/// Multicall3 token batch per chain), the transaction-history scan fans
/// out per-address in parallel, and the app-level poller fires the whole
/// thing on a timer. With no in-flight ceiling, that is a few hundred
/// `URLSession` data tasks opening at the same instant — which (a) is
/// the source of the OS `nw_protocol` UDP-socket flood the user saw, and
/// (b) compounds any provider throttle into a burst the provider's
/// per-IP limiter rejects all at once. Probes measured publicnode
/// tolerating ≥40 concurrent with zero 429, but several fallbacks are
/// far more fragile (xrplcluster 429s on ANY concurrent burst, toncenter
/// above ~1 rps, onfinality above ~10 concurrent, BlockCypher under any
/// concurrency). A per-host ceiling protects the fragile ones; a global
/// ceiling caps total open sockets so the OS isn't flooded.
///
/// **Counting actor.** `acquire(host:)` waits until both the global and
/// the host's in-flight count are below their caps, then increments both
/// and returns a `release` closure. `RPCClient` calls `acquire`
/// immediately before `session.data(for:)` and releases via a `defer`,
/// so the count is decremented even on throw / cancel. Waiters are woken
/// FIFO-by-eligibility as slots free up.
///
/// **Why actor, not `DispatchSemaphore`.** A blocking semaphore would
/// stall a cooperative-pool thread (the exact main-thread / throughput
/// hazard Rule #28 forbids). The actor suspends the caller with a
/// `CheckedContinuation` instead — no thread is blocked while waiting.
actor ConcurrencyGate {

    /// Process-wide shared gate. The cap must be enforced across every
    /// caller, so the instance is shared (like `RPCClient.shared`).
    static let shared = ConcurrencyGate()

    /// Max requests in flight across ALL hosts at once. Sized so a full
    /// refresh's fan-out can't open more than this many sockets
    /// simultaneously — the OS `nw_protocol` flood ceiling. 24 lets the
    /// ~24-chain native-balance fan-out proceed roughly one-per-chain
    /// while still bounding the absolute socket count well below the
    /// "hundreds" the un-capped fan-out produced.
    private let globalLimit: Int

    /// Max requests in flight to a SINGLE upstream host at once. Most of
    /// the refresh's volume lands on publicnode hosts (one per chain, so
    /// distinct hosts) — but token batches, history sweeps, and the
    /// poller can stack several reads on the same host. Probe-measured
    /// fragile hosts (xrplcluster, toncenter, BlockCypher, onfinality)
    /// 429 under concurrency, so 4-per-host keeps every host inside even
    /// the most fragile measured ceiling while letting the robust ones
    /// (publicnode tolerated ≥40) stay busy. The per-endpoint
    /// `RateLimiter` still throttles the *rate* on top of this.
    private let perHostLimit: Int

    private var globalInFlight = 0
    private var perHostInFlight: [String: Int] = [:]

    /// FIFO queue of suspended `acquire` callers, each tagged with the
    /// host it waits on and a stable id so a cancelled caller can remove
    /// exactly its own entry.
    private struct Waiter {
        let id: UInt64
        let host: String
        let resume: (Result<Void, Error>) -> Void
    }
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    init(globalLimit: Int = 24, perHostLimit: Int = 4) {
        self.globalLimit = max(1, globalLimit)
        self.perHostLimit = max(1, perHostLimit)
    }

    /// Wait until a global slot AND a slot for `host` are free, then
    /// reserve both. Returns a `@Sendable` closure the caller MUST invoke
    /// exactly once to free the slots (a `defer` is the canonical call
    /// site). Honors cancellation: a caller cancelled while waiting
    /// removes its place in the queue and throws `CancellationError`
    /// rather than holding a slot it will never use.
    func acquire(host: String) async throws -> @Sendable () -> Void {
        // Fast path — capacity available right now.
        if hasCapacity(for: host) {
            reserve(host: host)
            return makeRelease(host: host)
        }
        // Slow path — suspend until a `release` wakes us (or we're
        // cancelled). The id lets the cancellation handler prune exactly
        // this waiter. **The waker reserves the slot ON OUR BEHALF**
        // (see `wakeNextEligible`) so a fast-path caller can't race the
        // freed slot away in the window between our wake and our
        // re-entry — by the time the continuation resumes, the slot is
        // already counted as ours.
        let id = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, host: host) { cont.resume(with: $0) })
            }
        } onCancel: {
            Task { await self.removeWaiter(id: id) }
        }
        // Reservation already made by the waker — just hand back the
        // release token.
        return makeRelease(host: host)
    }

    /// Build the one-shot release closure. The `OnceBox` guard makes a
    /// stray double-call harmless. The closure hops back onto the actor
    /// to decrement and wake the next eligible waiter.
    private func makeRelease(host: String) -> @Sendable () -> Void {
        let box = OnceBox()
        return { [weak self] in
            guard let self else { return }
            Task { await self.releaseOnce(host: host, box: box) }
        }
    }

    private final class OnceBox: @unchecked Sendable {
        var fired = false
    }

    private func releaseOnce(host: String, box: OnceBox) {
        guard !box.fired else { return }
        box.fired = true
        globalInFlight = max(0, globalInFlight - 1)
        let n = (perHostInFlight[host] ?? 0) - 1
        if n <= 0 { perHostInFlight[host] = nil } else { perHostInFlight[host] = n }
        wakeNextEligible()
    }

    private func hasCapacity(for host: String) -> Bool {
        globalInFlight < globalLimit && (perHostInFlight[host] ?? 0) < perHostLimit
    }

    private func reserve(host: String) {
        globalInFlight += 1
        perHostInFlight[host, default: 0] += 1
    }

    /// Wake the first queued waiter whose host now has capacity,
    /// **reserving the slot on its behalf** before resuming so a
    /// fast-path caller can't steal the freed slot in the window between
    /// the wake and the woken task re-entering the actor. Walks the FIFO
    /// queue so an earlier waiter on a still-busy host doesn't
    /// head-of-line-block a later waiter on a free host, while preserving
    /// arrival order among waiters on the same host. May wake several
    /// waiters in one pass when a release frees capacity for more than
    /// one (e.g. a global slot opens and multiple distinct hosts are
    /// waiting).
    private func wakeNextEligible() {
        guard !waiters.isEmpty else { return }
        var index = 0
        while index < waiters.count {
            let waiter = waiters[index]
            if hasCapacity(for: waiter.host) {
                reserve(host: waiter.host)
                waiters.remove(at: index)
                waiter.resume(.success(()))
                // Don't advance `index` — the array shifted; continue
                // from the same position in case more waiters fit.
            } else {
                index += 1
            }
        }
    }

    /// Remove a cancelled waiter from the queue and resume it with a
    /// `CancellationError`. Then attempt to make progress in case its
    /// removal unblocks another waiter.
    private func removeWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.resume(.failure(CancellationError()))
        wakeNextEligible()
    }
}
