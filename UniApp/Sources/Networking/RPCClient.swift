import Foundation
import OSLog

/// The unified networking dispatcher. Every Aperture on-chain read —
/// `eth_getBalance`, `getBlockNumber`, `mempool.space/address/X`,
/// future write methods — goes through this actor.
///
/// **Per-chain contract.** Call `callJSON(chain:method:params:)` to
/// dispatch a JSON-RPC 2.0 request to `chain`'s primary endpoint,
/// rotating to fallbacks on failure. `callREST(chain:path:query:)`
/// for REST endpoints (mempool.space, Aptos REST, etc.).
///
/// **Reliability mechanisms (per `docs/RPC-ARCHITECTURE.md` §2.4):**
/// 1. **Rate limiting** — every dispatch awaits a token from the
///    endpoint's per-bucket `RateLimiter`. Honest about provider
///    quotas.
/// 2. **Fallback rotation** — fails over to the next-priority
///    endpoint on transport-level failures. Cancellation propagates
///    as cancellation, and deterministic JSON-RPC method errors
///    (`eth_call` revert, unknown method) throw immediately — every
///    healthy node would answer those identically (2026-06-11).
/// 3. **Circuit breaker** — after N consecutive transport failures,
///    skip the endpoint for 60 s. Server-returned JSON-RPC error
///    envelopes prove the endpoint is alive and never count.
/// 4. **Honest errors** — `RPCError` is typed throws; UI surfaces
///    them per Rule #16's "name what we couldn't do."
///
/// **Rule #3 compliance.** Pure `URLSession` + `JSONSerialization`.
/// No third-party packages.
actor RPCClient {
    private let session: URLSession
    private let rateLimiter: RateLimiter
    /// Bounds how many requests are in flight at once — globally and
    /// per host (2026-06-16). The `RateLimiter` caps the *rate* per
    /// endpoint; this caps simultaneous open sockets so a refresh's
    /// fan-out can't flood the OS network stack or burst a provider's
    /// per-IP limiter. See `ConcurrencyGate`.
    private let concurrencyGate: ConcurrencyGate
    private var breakers: [String: CircuitBreaker] = [:]
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "rpc")

    /// Per-instance incrementing JSON-RPC request id. Actor-isolated
    /// state, so concurrent calls each get a unique id; the response
    /// envelope's `id` is validated against it before the `result`
    /// is extracted (a mismatched / cached / cross-wired response is
    /// rejected instead of silently consumed).
    private var requestIDCounter: Int = 0

    private func nextRequestID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    /// Process-wide shared client (2026-06-11). The reliability
    /// layer — the per-endpoint token buckets in `RateLimiter` and
    /// the `CircuitBreaker` map — is **instance** state. Building a
    /// throwaway `RPCClient()` per scan resets that state to zero
    /// and defeats both mechanisms: N concurrent scans each get a
    /// fresh full burst against the same provider, and a dead
    /// endpoint is re-probed (and timed out on, 10 s each) by every
    /// caller instead of being skipped. It also churns one
    /// `URLSession` connection pool per instance, defeating the
    /// keep-alive rationale documented in `init`. Production call
    /// sites use this shared instance; pass a custom instance only
    /// in tests.
    static let shared = RPCClient()

    init(
        session: URLSession? = nil,
        rateLimiter: RateLimiter = RateLimiter(),
        concurrencyGate: ConcurrencyGate = .shared
    ) {
        if let session {
            self.session = session
        } else {
            // Default session config: 10 s timeout, no caching (we
            // want fresh on-chain reads), keep-alive enabled so
            // burst calls reuse connections.
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 20
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            // **Bound HTTP/1.1 connections per host (2026-06-16).** Even
            // behind the `ConcurrencyGate`, `URLSession`'s default of 6
            // connections-per-host can open a fresh socket per concurrent
            // request to the same host. Capping it at 4 (matching the
            // gate's per-host ceiling) means burst reads to one host
            // reuse a small keep-alive pool instead of spawning the
            // `nw_protocol` socket flood the user saw in the OS log.
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config)
        }
        self.rateLimiter = rateLimiter
        self.concurrencyGate = concurrencyGate
    }

    /// The upstream host key for an endpoint's URL — the
    /// `ConcurrencyGate`'s per-host bucket key. Falls back to the
    /// endpoint id when a URL somehow has no host (never for our
    /// registered endpoints, which all parse with a host).
    private static func gateHost(for endpoint: RPCEndpoint) -> String {
        endpoint.url.host ?? endpoint.id
    }

    private func rpcAttemptStarted(
        kind: String,
        chain: SupportedChain,
        endpoint: RPCEndpoint,
        operation: String
    ) -> Date {
        let start = Date()
        DiagnosticsLogStore.shared.record(
            .debug,
            category: "rpc",
            message: "\(kind) started",
            metadata: rpcMetadata(
                chain: chain,
                endpoint: endpoint,
                operation: operation
            )
        )
        return start
    }

    private func rpcAttemptFinished(
        level: DiagnosticsLogLevel,
        kind: String,
        outcome: String,
        chain: SupportedChain,
        endpoint: RPCEndpoint,
        operation: String,
        start: Date,
        error: (any Error)? = nil
    ) {
        var metadata = rpcMetadata(
            chain: chain,
            endpoint: endpoint,
            operation: operation
        )
        metadata["outcome"] = outcome
        metadata["elapsedMs"] = DiagnosticsLogStore.elapsedMilliseconds(since: start)
        if let error {
            metadata["error"] = String(describing: error)
        }
        DiagnosticsLogStore.shared.record(
            level,
            category: "rpc",
            message: "\(kind) \(outcome)",
            metadata: metadata
        )
    }

    private func rpcAttemptSkipped(
        kind: String,
        chain: SupportedChain,
        endpoint: RPCEndpoint,
        operation: String,
        reason: String
    ) {
        var metadata = rpcMetadata(
            chain: chain,
            endpoint: endpoint,
            operation: operation
        )
        metadata["reason"] = reason
        DiagnosticsLogStore.shared.record(
            .warning,
            category: "rpc",
            message: "\(kind) skipped",
            metadata: metadata
        )
    }

    private func rpcMetadata(
        chain: SupportedChain,
        endpoint: RPCEndpoint,
        operation: String
    ) -> [String: String] {
        [
            "chain": String(describing: chain),
            "endpoint": endpoint.id,
            "host": endpoint.url.host ?? "",
            "operation": operation
        ]
    }

    /// Run one `URLSession` request **inside the `ConcurrencyGate`** —
    /// the single in-flight chokepoint every dispatch path funnels
    /// through (2026-06-16). Acquires a global + per-host slot before
    /// dialing and releases it via `defer` so the slot is freed on
    /// success, throw, or cancellation. The gate `acquire` throws
    /// `CancellationError` if the task is cancelled while waiting for a
    /// slot; callers map that to `RPCError.cancelled`. The actual
    /// network call is unchanged — this only bounds how many run at once.
    private func performGated(
        _ request: URLRequest,
        host: String
    ) async throws -> (Data, URLResponse) {
        let release = try await concurrencyGate.acquire(host: host)
        defer { release() }
        return try await session.data(for: request)
    }

    // MARK: - JSON-RPC

    /// Typed wrapper for JSON-RPC calls whose `result` is a JSON
    /// string (the common case for EVM: `eth_getBalance`,
    /// `eth_getTransactionCount`, `eth_chainId`, `eth_blockNumber`).
    /// Returns Sendable `String` so it crosses actor boundaries.
    ///
    /// - Parameter validatesIDEcho: Pass `false` for upstreams that
    ///   are JSON-RPC-shaped but do **not** echo the request `id` —
    ///   rippled's HTTP API (XRPL) omits the `id` field entirely, so
    ///   the default id-echo validation would reject every response.
    ///   Defaults to `true`; leave it on for every spec-compliant
    ///   JSON-RPC 2.0 endpoint.
    func callJSONString(
        chain: SupportedChain,
        method: String,
        params: [Sendable],
        validatesIDEcho: Bool = true
    ) async throws(RPCError) -> String {
        let result = try await callJSON(
            chain: chain,
            method: method,
            params: params,
            validatesIDEcho: validatesIDEcho
        )
        guard let str = result as? String else {
            throw .invalidResponse("\(method) result was not a string")
        }
        return str
    }

    /// Like `callJSONString`, but a JSON `null` result resolves to
    /// `nil` instead of throwing.
    ///
    /// **2026-06-16 — Polkadot zero-balance fix.** Substrate's
    /// `state_getStorage` returns `{"result":null}` for an account
    /// that has no `System::Account` entry — i.e. an account that has
    /// never held a balance. That is the normal "zero balance" answer,
    /// NOT an error. The plain `callJSONString` mapped it to
    /// `.invalidResponse("state_getStorage result was not a string")`,
    /// which the Polkadot adapter logged at `.error` and treated as a
    /// fetch failure (log spam for every unfunded DOT address). This
    /// wrapper distinguishes the two: a `null` result → `nil` (the
    /// caller maps it to zero), a real hex string → `.some(str)`, and a
    /// genuinely malformed result (number, object) still throws.
    /// Verified live (2026-06-16): `rpc.polkadot.io state_getStorage`
    /// on an empty System::Account key returns `{"jsonrpc":"2.0",
    /// "id":1,"result":null}`.
    func callJSONStringOrNull(
        chain: SupportedChain,
        method: String,
        params: [Sendable],
        validatesIDEcho: Bool = true
    ) async throws(RPCError) -> String? {
        let result = try await callJSON(
            chain: chain,
            method: method,
            params: params,
            validatesIDEcho: validatesIDEcho
        )
        if result is NSNull { return nil }
        guard let str = result as? String else {
            throw .invalidResponse("\(method) result was not a string")
        }
        return str
    }

    /// Typed wrapper for JSON-RPC calls whose `result` is a bare JSON
    /// number (e.g. Substrate's `system_accountNextIndex` → the account
    /// nonce as an integer). Returns `UInt64`; throws if the result isn't
    /// a non-negative number. Bridges the gap left by `callJSONString`
    /// (string result) and `callJSONResultData` (object/array result).
    func callJSONUInt64(
        chain: SupportedChain,
        method: String,
        params: [Sendable],
        validatesIDEcho: Bool = true
    ) async throws(RPCError) -> UInt64 {
        let result = try await callJSON(
            chain: chain, method: method, params: params, validatesIDEcho: validatesIDEcho
        )
        if let n = result as? NSNumber { return n.uint64Value }
        if let s = result as? String, let n = UInt64(s) { return n }
        throw .invalidResponse("\(method) result was not a number")
    }

    /// JSON-RPC calls whose `result` is a JSON object or array.
    /// Returns the `result` field **re-serialized as `Data`** so
    /// the caller can decode it in its own isolation —
    /// `[String: Any]` and `[Any]` aren't Sendable across actor
    /// boundaries under Swift 6 strict concurrency. Adapters call
    /// `JSONSerialization.jsonObject(with: data)` to get back the
    /// dict / array shape.
    ///
    /// - Parameter validatesIDEcho: Pass `false` for upstreams that
    ///   are JSON-RPC-shaped but do **not** echo the request `id` —
    ///   rippled's HTTP API (XRPL) omits the `id` field entirely, so
    ///   the default id-echo validation would reject every response
    ///   (XRPL adapters must pass `false` here). Defaults to `true`;
    ///   leave it on for every spec-compliant JSON-RPC 2.0 endpoint.
    func callJSONResultData(
        chain: SupportedChain,
        method: String,
        params: [Sendable],
        validatesIDEcho: Bool = true
    ) async throws(RPCError) -> Data {
        let result = try await callJSON(
            chain: chain,
            method: method,
            params: params,
            validatesIDEcho: validatesIDEcho
        )
        // **2026-06-09 crash fix.** `JSONSerialization.data(withJSONObject:)`
        // raises an Objective-C `NSException` (not a Swift `throws`)
        // when the top-level value is anything other than `NSDictionary`
        // or `NSArray`. `try?` cannot catch NSException, so a `null`
        // / `String` / `Number` result here was killing the app with
        // SIGABRT. Several RPC methods *do* legitimately return `null`
        // — `eth_getBlockByNumber` on a pruned block, `getAccountInfo`
        // on a closed account, `eth_call` on a non-deployed contract.
        // Convert those to a typed error so the caller can fall back
        // cleanly.
        if result is NSNull {
            throw .decodingFailed("\(method) returned null")
        }
        guard JSONSerialization.isValidJSONObject(result) else {
            throw .decodingFailed("\(method) result is not a JSON object/array")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result) else {
            throw .decodingFailed("Could not re-serialize \(method) result")
        }
        return data
    }

    /// Same as `callJSONResultData(chain:method:params:)` but accepts
    /// the JSON-RPC `params` field as a **named-object** (`[String: Any]`)
    /// instead of an array. NEAR's `query` method, Polkadot's
    /// state_call variants, and a handful of other Substrate-derived
    /// chains require the named-object form — passing an array
    /// triggers `"expected struct, got sequence"` at the upstream.
    ///
    /// - Parameter validatesIDEcho: Pass `false` for upstreams that
    ///   are JSON-RPC-shaped but do **not** echo the request `id` —
    ///   rippled's HTTP API (XRPL) omits the `id` field entirely, so
    ///   the default id-echo validation would reject every response.
    ///   Defaults to `true`; leave it on for every spec-compliant
    ///   JSON-RPC 2.0 endpoint.
    func callJSONResultData(
        chain: SupportedChain,
        method: String,
        paramsObject: [String: Sendable],
        validatesIDEcho: Bool = true
    ) async throws(RPCError) -> Data {
        let result = try await callJSONNamedParams(
            chain: chain,
            method: method,
            paramsObject: paramsObject,
            validatesIDEcho: validatesIDEcho
        )
        // Same NSException guard as the positional-params variant
        // above — see the 2026-06-09 comment there for rationale.
        if result is NSNull {
            throw .decodingFailed("\(method) returned null")
        }
        guard JSONSerialization.isValidJSONObject(result) else {
            throw .decodingFailed("\(method) result is not a JSON object/array")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result) else {
            throw .decodingFailed("Could not re-serialize \(method) result")
        }
        return data
    }

    private func callJSONNamedParams(
        chain: SupportedChain,
        method: String,
        paramsObject: [String: Sendable],
        validatesIDEcho: Bool = true
    ) async throws(RPCError) -> Any {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .jsonRPC {
            if isOpen(for: endpoint.id) {
                rpcAttemptSkipped(
                    kind: "JSON-RPC named params",
                    chain: chain,
                    endpoint: endpoint,
                    operation: method,
                    reason: "circuitOpen"
                )
                continue
            }
            let rpcStart = rpcAttemptStarted(
                kind: "JSON-RPC named params",
                chain: chain,
                endpoint: endpoint,
                operation: method
            )
            do {
                try await rateLimiter.acquire(for: endpoint)
                let result = try await dispatchJSONNamedParams(
                    endpoint: endpoint,
                    method: method,
                    paramsObject: paramsObject,
                    validatesIDEcho: validatesIDEcho
                )
                recordSuccess(for: endpoint.id)
                rpcAttemptFinished(
                    level: .info,
                    kind: "JSON-RPC named params",
                    outcome: "succeeded",
                    chain: chain,
                    endpoint: endpoint,
                    operation: method,
                    start: rpcStart
                )
                return result
            } catch {
                rpcAttemptFinished(
                    level: .warning,
                    kind: "JSON-RPC named params",
                    outcome: "failed",
                    chain: chain,
                    endpoint: endpoint,
                    operation: method,
                    start: rpcStart,
                    error: error
                )
                // Typed throws — everything in this block throws
                // `RPCError`, so one catch covers it (a generic
                // fallback clause would be dead code).
                //
                // **2026-06-11 — error classification.**
                // 1. Cancellation propagates AS cancellation, before
                //    any breaker bookkeeping — a user navigating away
                //    mid-refresh must never count as an endpoint
                //    failure.
                // 2. A server-returned JSON-RPC error envelope proves
                //    the endpoint is alive — it never counts toward
                //    the circuit breaker. Deterministic method errors
                //    throw immediately instead of rotating; see
                //    `shouldRotate(rpcErrorCode:message:)`.
                if case .cancelled = error { throw error }
                if case .rpcError(let code, let message) = error {
                    guard Self.shouldRotate(rpcErrorCode: code, message: message) else {
                        throw error
                    }
                    lastError = error
                    continue
                }
                // 3. Rate limiting (provider 429 OR the local
                //    limiter's bounded-wait bailout) proves the
                //    endpoint is alive — just saturated. Rotate to a
                //    fallback, but never record a breaker failure:
                //    on the shared client a transient throttle would
                //    otherwise latch healthy endpoints open for whole
                //    cooldown windows.
                if case .rateLimited = error {
                    lastError = error
                    continue
                }
                lastError = error
                recordFailure(for: endpoint.id)
                continue
            }
        }
        throw lastError
    }

    private func dispatchJSONNamedParams(
        endpoint: RPCEndpoint,
        method: String,
        paramsObject: [String: Any],
        validatesIDEcho: Bool
    ) async throws(RPCError) -> Any {
        let requestID = nextRequestID()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": paramsObject,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw .invalidResponse("Failed to encode JSON-RPC envelope")
        }

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performGated(request, host: Self.gateHost(for: endpoint))
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
                // 408 / 502 / 503 / 504 and Cloudflare 520–527 are
                // TRANSIENT — the endpoint is reachable but timed out or is
                // briefly unavailable (drpc.org returns 408 under load; a
                // Cloudflare-fronted node returns 521 when its origin is
                // momentarily down). Classify them as a network timeout so
                // they read honestly in logs and rotate to a healthy
                // fallback like any timeout — not as an "invalid response"
                // (which sounds like a permanent fault). The circuit breaker
                // still trips after repeated failures, so a consistently-bad
                // endpoint gets skipped.
                if [408, 502, 503, 504].contains(http.statusCode)
                    || (520...527).contains(http.statusCode) {
                    throw .network("HTTP \(http.statusCode) (timeout) from \(endpoint.id)")
                }
                throw .invalidResponse("HTTP \(http.statusCode) from \(endpoint.id)")
            }
        }

        guard let decoded = try? JSONSerialization.jsonObject(with: responseData) else {
            throw .decodingFailed("Body did not parse as JSON")
        }
        guard let dict = decoded as? [String: Any] else {
            throw .invalidResponse("Top-level JSON was not an object")
        }
        if let errorDict = dict["error"] as? [String: Any] {
            let code = errorDict["code"] as? Int ?? -1
            let message = errorDict["message"] as? String ?? "unknown"
            // See the matching block in `dispatchJSON` (2026-06-16):
            // a provider throttle delivered as a JSON-RPC error envelope
            // at HTTP 200 rotates as `.rateLimited`, never a terminal
            // method error.
            if Self.rateLimit(forCode: code, message: message) {
                log.debug("RPC usage/rate limit on \(endpoint.id, privacy: .public) (code \(code)) — rotating")
                throw .rateLimited(retryAfter: Date().addingTimeInterval(60))
            }
            throw .rpcError(code: code, message: message)
        }
        // Skipped for upstreams that never echo the id (rippled) —
        // see `validatesIDEcho` on the public wrappers.
        if validatesIDEcho {
            guard Self.responseID(in: dict, matches: requestID) else {
                throw .invalidResponse("JSON-RPC response id does not match request id \(requestID)")
            }
        }
        guard let result = dict["result"] else {
            throw .invalidResponse("JSON-RPC response missing `result`")
        }
        return result
    }

    /// Dispatch a JSON-RPC 2.0 call against `chain`'s registered
    /// endpoints. Iterates in priority order, skipping endpoints in
    /// circuit-breaker timeout, rotating to the next on failure.
    /// Returns the decoded `result` field — actor-isolated `Any`,
    /// so callers must consume it inside the same actor or use the
    /// typed wrappers (`callJSONString`, future `callJSONArray`).
    private func callJSON(
        chain: SupportedChain,
        method: String,
        params: [Sendable],
        validatesIDEcho: Bool = true
    ) async throws(RPCError) -> Any {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .jsonRPC {
            if isOpen(for: endpoint.id) {
                log.debug("Circuit open for \(endpoint.id, privacy: .public), skipping")
                rpcAttemptSkipped(
                    kind: "JSON-RPC",
                    chain: chain,
                    endpoint: endpoint,
                    operation: method,
                    reason: "circuitOpen"
                )
                continue
            }
            let rpcStart = rpcAttemptStarted(
                kind: "JSON-RPC",
                chain: chain,
                endpoint: endpoint,
                operation: method
            )
            do {
                try await rateLimiter.acquire(for: endpoint)
                let result = try await dispatchJSON(
                    endpoint: endpoint,
                    method: method,
                    params: params,
                    validatesIDEcho: validatesIDEcho
                )
                recordSuccess(for: endpoint.id)
                rpcAttemptFinished(
                    level: .info,
                    kind: "JSON-RPC",
                    outcome: "succeeded",
                    chain: chain,
                    endpoint: endpoint,
                    operation: method,
                    start: rpcStart
                )
                return result
            } catch {
                rpcAttemptFinished(
                    level: .warning,
                    kind: "JSON-RPC",
                    outcome: "failed",
                    chain: chain,
                    endpoint: endpoint,
                    operation: method,
                    start: rpcStart,
                    error: error
                )
                // Typed throws — everything in this block throws
                // `RPCError`, so one catch covers it.
                //
                // **2026-06-11 — error classification.**
                // 1. Cancellation propagates AS cancellation, before
                //    any breaker bookkeeping — a user navigating away
                //    mid-refresh must never count as an endpoint
                //    failure or open a breaker against a healthy host.
                // 2. A server-returned JSON-RPC error envelope proves
                //    the endpoint is alive — it never counts toward
                //    the circuit breaker. Deterministic method errors
                //    (`eth_call` revert, unknown method, invalid
                //    params) throw immediately: every healthy node
                //    answers them identically, so rotating would just
                //    replay the same failure N times and poison every
                //    endpoint's breaker. Only plausibly endpoint-
                //    specific codes rotate; see
                //    `shouldRotate(rpcErrorCode:message:)`.
                if case .cancelled = error { throw error }
                if case .rpcError(let code, let message) = error {
                    guard Self.shouldRotate(rpcErrorCode: code, message: message) else {
                        throw error
                    }
                    lastError = error
                    log.error("RPC failed on \(endpoint.id, privacy: .public): \(String(describing: error), privacy: .public)")
                    continue
                }
                // Rate limiting (429 / local limiter bailout) — the
                // endpoint is alive, just saturated. Rotate without
                // breaker bookkeeping (see dispatchJSON).
                if case .rateLimited = error {
                    lastError = error
                    log.debug("RPC rate-limited on \(endpoint.id, privacy: .public) — rotating")
                    continue
                }
                lastError = error
                recordFailure(for: endpoint.id)
                log.error("RPC failed on \(endpoint.id, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
        }
        throw lastError
    }

    // MARK: - REST

    /// Dispatch a REST POST against `chain`'s registered REST
    /// endpoints with a JSON body. Used by adapters whose upstream
    /// requires POST (Aptos view function, Polkadot Subscan, etc.).
    /// Same fallback rotation + circuit breaker as `callREST`.
    func callRESTPost(
        chain: SupportedChain,
        path: String,
        body: [String: Sendable]
    ) async throws(RPCError) -> Data {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .rest {
            if isOpen(for: endpoint.id) {
                rpcAttemptSkipped(
                    kind: "REST POST",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    reason: "circuitOpen"
                )
                continue
            }
            let rpcStart = rpcAttemptStarted(
                kind: "REST POST",
                chain: chain,
                endpoint: endpoint,
                operation: path
            )
            do {
                try await rateLimiter.acquire(for: endpoint)
                let data = try await dispatchRESTPost(
                    endpoint: endpoint,
                    path: path,
                    body: body
                )
                recordSuccess(for: endpoint.id)
                rpcAttemptFinished(
                    level: .info,
                    kind: "REST POST",
                    outcome: "succeeded",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart
                )
                return data
            } catch {
                rpcAttemptFinished(
                    level: .warning,
                    kind: "REST POST",
                    outcome: "failed",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart,
                    error: error
                )
                // Typed throws — everything in this block throws
                // `RPCError`, so one catch covers it (a generic
                // fallback clause would be dead code). Cancellation
                // propagates FIRST (2026-06-11) — it must never be
                // recorded as an endpoint failure.
                if case .cancelled = error { throw error }
                // Rate limiting (429 / local limiter bailout) — the
                // endpoint is alive, just saturated. Rotate without
                // breaker bookkeeping (see dispatchJSON).
                if case .rateLimited = error {
                    lastError = error
                    continue
                }
                lastError = error
                recordFailure(for: endpoint.id)
                continue
            }
        }
        throw lastError
    }

    private func dispatchRESTPost(
        endpoint: RPCEndpoint,
        path: String,
        body: [String: Any]
    ) async throws(RPCError) -> Data {
        // `appendingPathComponent` is the canonical way to extend
        // the endpoint's URL — `URL(string:relativeTo:)` would
        // REPLACE the last path component when the base lacks a
        // trailing slash (e.g. Aptos base `https://…/v1` + `view`
        // → `https://…/view` instead of `https://…/v1/view`).
        let url = endpoint.url.appendingPathComponent(path)
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw .invalidResponse("Failed to encode REST POST body")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performGated(request, host: Self.gateHost(for: endpoint))
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
                // 408 / 502 / 503 / 504 and Cloudflare 520–527 are
                // TRANSIENT — the endpoint is reachable but timed out or is
                // briefly unavailable (drpc.org returns 408 under load; a
                // Cloudflare-fronted node returns 521 when its origin is
                // momentarily down). Classify them as a network timeout so
                // they read honestly in logs and rotate to a healthy
                // fallback like any timeout — not as an "invalid response"
                // (which sounds like a permanent fault). The circuit breaker
                // still trips after repeated failures, so a consistently-bad
                // endpoint gets skipped.
                if [408, 502, 503, 504].contains(http.statusCode)
                    || (520...527).contains(http.statusCode) {
                    throw .network("HTTP \(http.statusCode) (timeout) from \(endpoint.id)")
                }
                throw .invalidResponse("HTTP \(http.statusCode) from \(endpoint.id)")
            }
        }
        return responseData
    }

    /// Dispatch a REST POST with a **raw string body** (and an explicit
    /// `Content-Type`) against `chain`'s registered REST endpoints, with
    /// the same fallback rotation + circuit breaker as `callREST`.
    ///
    /// Used by the Bitcoin-family broadcast path: Esplora
    /// (mempool.space / blockstream / litecoinspace) `POST /tx` wants the
    /// raw transaction HEX as a `text/plain` body and returns the txid
    /// as plain text (live-verified 2026-06-15 — a malformed body
    /// returns `sendrawtransaction RPC error: TX decode failed`,
    /// HTTP 400). Distinct from `callRESTPost`, which encodes a JSON
    /// dictionary body for BlockCypher's `{"tx":hex}` push shape.
    ///
    /// Returns the raw response `Data` (the broadcaster parses it: txid
    /// as plain text for Esplora). Per-endpoint 4xx is surfaced as
    /// `.invalidResponse` so the broadcaster can read the provider's
    /// reason — a broadcast rejection (e.g. "min relay fee not met") is
    /// a deterministic property of the tx, not an endpoint fault.
    func callRESTPostRaw(
        chain: SupportedChain,
        path: String,
        body: String,
        contentType: String
    ) async throws(RPCError) -> Data {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .rest {
            if isOpen(for: endpoint.id) {
                rpcAttemptSkipped(
                    kind: "REST POST raw",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    reason: "circuitOpen"
                )
                continue
            }
            let rpcStart = rpcAttemptStarted(
                kind: "REST POST raw",
                chain: chain,
                endpoint: endpoint,
                operation: path
            )
            do {
                try await rateLimiter.acquire(for: endpoint)
                let data = try await dispatchRESTPostRaw(
                    endpoint: endpoint,
                    path: path,
                    body: body,
                    contentType: contentType
                )
                recordSuccess(for: endpoint.id)
                rpcAttemptFinished(
                    level: .info,
                    kind: "REST POST raw",
                    outcome: "succeeded",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart
                )
                return data
            } catch {
                rpcAttemptFinished(
                    level: .warning,
                    kind: "REST POST raw",
                    outcome: "failed",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart,
                    error: error
                )
                if case .cancelled = error { throw error }
                if case .rateLimited = error {
                    lastError = error
                    continue
                }
                // A 4xx from a broadcast is a deterministic property of
                // the tx (the SAME malformed/underpriced tx fails on
                // every node), so DON'T trip the breaker — but DO carry
                // the provider's body up so the caller surfaces the
                // honest reason. We still rotate to the next endpoint in
                // case THIS provider is the one being difficult.
                if case .invalidResponse = error {
                    lastError = error
                    continue
                }
                lastError = error
                recordFailure(for: endpoint.id)
                continue
            }
        }
        throw lastError
    }

    private func dispatchRESTPostRaw(
        endpoint: RPCEndpoint,
        path: String,
        body: String,
        contentType: String
    ) async throws(RPCError) -> Data {
        let url = endpoint.url.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performGated(request, host: Self.gateHost(for: endpoint))
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
                // Surface the provider's body so the broadcaster can read
                // the rejection reason (e.g. "min relay fee not met").
                let reason = String(data: responseData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HTTP \(http.statusCode)"
                throw .invalidResponse(reason)
            }
        }
        return responseData
    }

    /// Dispatch a REST POST with a **binary `Data` body** (and an
    /// explicit `Content-Type`) against `chain`'s registered REST
    /// endpoints, with the same fallback rotation + circuit breaker as
    /// `callRESTPostRaw`. Distinct from `callRESTPostRaw` (which sends a
    /// UTF-8 string) because a binary payload (Aptos BCS-serialized
    /// signed transaction, `Content-Type:
    /// application/x.aptos.signed_transaction+bcs`) must NOT be passed
    /// through `String(_:.utf8)` — that mangles non-UTF-8 bytes. Used by
    /// the Aptos broadcast path (`POST /v1/transactions` with the
    /// wallet-core `output.encoded` BCS bytes). Live-verified 2026-06-15:
    /// a truncated BCS body returns `Failed to deserialize input into
    /// SignedTransaction` (HTTP 400), proving the endpoint + content-type.
    func callRESTPostData(
        chain: SupportedChain,
        path: String,
        body: Data,
        contentType: String
    ) async throws(RPCError) -> Data {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .rest {
            if isOpen(for: endpoint.id) {
                rpcAttemptSkipped(
                    kind: "REST POST data",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    reason: "circuitOpen"
                )
                continue
            }
            let rpcStart = rpcAttemptStarted(
                kind: "REST POST data",
                chain: chain,
                endpoint: endpoint,
                operation: path
            )
            do {
                try await rateLimiter.acquire(for: endpoint)
                let data = try await dispatchRESTPostData(
                    endpoint: endpoint,
                    path: path,
                    body: body,
                    contentType: contentType
                )
                recordSuccess(for: endpoint.id)
                rpcAttemptFinished(
                    level: .info,
                    kind: "REST POST data",
                    outcome: "succeeded",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart
                )
                return data
            } catch {
                rpcAttemptFinished(
                    level: .warning,
                    kind: "REST POST data",
                    outcome: "failed",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart,
                    error: error
                )
                if case .cancelled = error { throw error }
                if case .rateLimited = error {
                    lastError = error
                    continue
                }
                // A 4xx from a broadcast is deterministic (same tx fails
                // on every node) — surface the provider's reason, rotate,
                // but don't trip the breaker (mirror callRESTPostRaw).
                if case .invalidResponse = error {
                    lastError = error
                    continue
                }
                lastError = error
                recordFailure(for: endpoint.id)
                continue
            }
        }
        throw lastError
    }

    private func dispatchRESTPostData(
        endpoint: RPCEndpoint,
        path: String,
        body: Data,
        contentType: String
    ) async throws(RPCError) -> Data {
        let url = endpoint.url.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performGated(request, host: Self.gateHost(for: endpoint))
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
                let reason = String(data: responseData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HTTP \(http.statusCode)"
                throw .invalidResponse(reason)
            }
        }
        return responseData
    }

    /// Dispatch a REST GET against `chain`'s registered REST
    /// endpoints. Path is appended to each endpoint's URL.
    /// Query items added to the URL. Body is the raw `Data`
    /// returned by the server — the adapter decodes per its own
    /// model.
    func callREST(
        chain: SupportedChain,
        path: String,
        query: [URLQueryItem] = []
    ) async throws(RPCError) -> Data {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .rest {
            if isOpen(for: endpoint.id) {
                rpcAttemptSkipped(
                    kind: "REST GET",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    reason: "circuitOpen"
                )
                continue
            }
            let rpcStart = rpcAttemptStarted(
                kind: "REST GET",
                chain: chain,
                endpoint: endpoint,
                operation: path
            )
            do {
                try await rateLimiter.acquire(for: endpoint)
                let data = try await dispatchREST(
                    endpoint: endpoint,
                    path: path,
                    query: query
                )
                recordSuccess(for: endpoint.id)
                rpcAttemptFinished(
                    level: .info,
                    kind: "REST GET",
                    outcome: "succeeded",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart
                )
                return data
            } catch {
                rpcAttemptFinished(
                    level: .warning,
                    kind: "REST GET",
                    outcome: "failed",
                    chain: chain,
                    endpoint: endpoint,
                    operation: path,
                    start: rpcStart,
                    error: error
                )
                // Typed throws — everything in this block throws
                // `RPCError`, so one catch covers it (a generic
                // fallback clause would be dead code). Cancellation
                // propagates FIRST (2026-06-11) — it must never be
                // recorded as an endpoint failure.
                if case .cancelled = error { throw error }
                // Rate limiting (429 / local limiter bailout) — the
                // endpoint is alive, just saturated. Rotate without
                // breaker bookkeeping (see dispatchJSON).
                if case .rateLimited = error {
                    lastError = error
                    continue
                }
                lastError = error
                recordFailure(for: endpoint.id)
                continue
            }
        }
        throw lastError
    }

    // MARK: - Internals: JSON-RPC dispatch

    private func dispatchJSON(
        endpoint: RPCEndpoint,
        method: String,
        params: [Any],
        validatesIDEcho: Bool
    ) async throws(RPCError) -> Any {
        let requestID = nextRequestID()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw .invalidResponse("Failed to encode JSON-RPC envelope")
        }

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performGated(request, host: Self.gateHost(for: endpoint))
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let retryAfter = retryAfterDate(from: http)
                throw .rateLimited(retryAfter: retryAfter)
            }
            if !(200..<300).contains(http.statusCode) {
                // 408 / 502 / 503 / 504 and Cloudflare 520–527 are
                // TRANSIENT — the endpoint is reachable but timed out or is
                // briefly unavailable (drpc.org returns 408 under load; a
                // Cloudflare-fronted node returns 521 when its origin is
                // momentarily down). Classify them as a network timeout so
                // they read honestly in logs and rotate to a healthy
                // fallback like any timeout — not as an "invalid response"
                // (which sounds like a permanent fault). The circuit breaker
                // still trips after repeated failures, so a consistently-bad
                // endpoint gets skipped.
                if [408, 502, 503, 504].contains(http.statusCode)
                    || (520...527).contains(http.statusCode) {
                    throw .network("HTTP \(http.statusCode) (timeout) from \(endpoint.id)")
                }
                throw .invalidResponse("HTTP \(http.statusCode) from \(endpoint.id)")
            }
        }

        guard let decoded = try? JSONSerialization.jsonObject(with: responseData) else {
            throw .decodingFailed("Body did not parse as JSON")
        }
        guard let dict = decoded as? [String: Any] else {
            throw .invalidResponse("Top-level JSON was not an object")
        }
        if let errorDict = dict["error"] as? [String: Any] {
            let code = errorDict["code"] as? Int ?? -1
            let message = errorDict["message"] as? String ?? "unknown"
            // **2026-06-16 — rate-limit re-classification.** A provider
            // throttle delivered as a JSON-RPC error envelope at HTTP 200
            // (the 1rpc `-32001` "usage limit" case) must rotate to a
            // healthy endpoint, never surface as a terminal method error
            // on a swap broadcast. Convert it to `.rateLimited` so it
            // takes the "alive but saturated — rotate, no breaker" path
            // and is never retained as the terminal `lastError`.
            if Self.rateLimit(forCode: code, message: message) {
                log.debug("RPC usage/rate limit on \(endpoint.id, privacy: .public) (code \(code)) — rotating")
                throw .rateLimited(retryAfter: Date().addingTimeInterval(60))
            }
            throw .rpcError(code: code, message: message)
        }
        // Skipped for upstreams that never echo the id (rippled) —
        // see `validatesIDEcho` on the public wrappers.
        if validatesIDEcho {
            guard Self.responseID(in: dict, matches: requestID) else {
                throw .invalidResponse("JSON-RPC response id does not match request id \(requestID)")
            }
        }
        guard let result = dict["result"] else {
            throw .invalidResponse("JSON-RPC response missing `result`")
        }
        return result
    }

    /// Validate the JSON-RPC envelope's `id` against the request id.
    /// Servers echo the id as a JSON number (the common case) or a
    /// string; anything else — or a missing id — is a mismatch.
    private static func responseID(in dict: [String: Any], matches requestID: Int) -> Bool {
        if let number = dict["id"] as? NSNumber {
            return number.intValue == requestID
        }
        if let string = dict["id"] as? String {
            return Int(string) == requestID
        }
        return false
    }

    /// Classify a server-returned JSON-RPC error envelope (2026-06-11):
    /// `true` when the failure is plausibly endpoint-specific
    /// (provider throttle, internal node fault, out-of-sync state)
    /// and replaying the identical request on the next endpoint
    /// could succeed; `false` when the error is a deterministic
    /// property of the REQUEST itself — an `eth_call` to a reverting
    /// contract, an unknown method, invalid params — which every
    /// healthy node answers identically. Deterministic errors throw
    /// immediately instead of rotating, and no `.rpcError` of either
    /// kind ever counts toward a circuit breaker (the endpoint
    /// answered; it is alive).
    private static func shouldRotate(rpcErrorCode code: Int, message: String) -> Bool {
        switch code {
        case -32700, -32600, -32601, -32602:
            // Parse error / invalid request / method not found /
            // invalid params — all functions of what we sent.
            //
            // **2026-06-16 — narrow carve-out.** Some providers
            // overload the standard `-32600`/`-32602` codes to carry
            // a rate-limit / capacity message (e.g. a gateway that
            // wraps "request limit exceeded" in `-32600`). Those are
            // already re-classified to `.rateLimited` upstream in
            // `dispatchJSON` (see `rateLimit(forCode:message:)`), so
            // a `.rpcError` reaching here with one of these codes is a
            // genuine request-shape error — do NOT rotate.
            return false
        case 3:
            // Geth-style `eth_call` execution revert (code 3 with
            // revert data).
            return false
        default:
            // The implementation-defined server range
            // (-32000...-32099) is a mixed bag: geth uses -32000
            // for "execution reverted" AND for transient node state
            // ("header not found", "missing trie node"). A revert
            // is deterministic; everything else gets the benefit of
            // the doubt and rotates (-32005 limit-exceeded and
            // -32603 internal-error included).
            return !message.lowercased().contains("revert")
        }
    }

    /// Classify a JSON-RPC error envelope as a **rate-limit / usage-quota**
    /// failure (2026-06-16). When `true`, the dispatcher converts the
    /// envelope to `.rateLimited` instead of `.rpcError`, so it rotates to
    /// the next endpoint WITHOUT tripping the circuit breaker AND without
    /// the limit message being retained as the terminal `lastError` — the
    /// real defect behind the failed swap.
    ///
    /// **Why this is needed.** Some providers return their throttle as a
    /// JSON-RPC error envelope at **HTTP 200**, so the `429` branch in
    /// `dispatchJSON` never fires and the failure looks like a method
    /// error. The canonical case (live-verified 2026-06-16; doc:
    /// https://docs.1rpc.io/using-the-web3-api/errors): the unauthenticated
    /// 1rpc.io tier returns
    /// `{"error":{"code":-32001,"message":"You've reached the usage limit
    /// for your current plan…"}}` once its 200/day quota is spent. Without
    /// this classifier that surfaced verbatim as
    /// "The network rejected the transaction: You've reached the usage
    /// limit…" on a swap broadcast, instead of rotating to a healthy
    /// endpoint.
    ///
    /// Matches by **code** (`-32001`/`-32005`/`-32029` — known
    /// limit/over-capacity codes across providers) OR by **message**
    /// substring (provider-agnostic: "usage limit", "rate limit",
    /// "ratelimit", "too many requests", "request limit", "exceeded your",
    /// "current plan", "capacity", "throttle", "upgrade here"). Substring
    /// matching is the robust path because the code is not standardized.
    static func rateLimit(forCode code: Int, message: String) -> Bool {
        // Never mis-classify an `eth_call` revert as a rate limit.
        let lower = message.lowercased()
        if lower.contains("revert") { return false }
        switch code {
        case -32001, -32005, -32029:
            // -32001 = 1rpc usage-limit; -32005 = geth/Infura
            // "limit exceeded"; -32029 = Alchemy/others over-capacity.
            return true
        default:
            break
        }
        let needles = [
            "usage limit", "rate limit", "ratelimit", "rate-limit",
            "too many requests", "request limit", "exceeded your",
            "current plan", "capacity", "throttle", "upgrade here",
            "over rate", "quota",
        ]
        return needles.contains { lower.contains($0) }
    }

    // MARK: - Internals: REST dispatch

    private func dispatchREST(
        endpoint: RPCEndpoint,
        path: String,
        query: [URLQueryItem]
    ) async throws(RPCError) -> Data {
        var components = URLComponents(
            url: endpoint.url.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw .invalidResponse("Failed to compose URL for REST call")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performGated(request, host: Self.gateHost(for: endpoint))
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
                // 408 / 502 / 503 / 504 and Cloudflare 520–527 are
                // TRANSIENT — the endpoint is reachable but timed out or is
                // briefly unavailable (drpc.org returns 408 under load; a
                // Cloudflare-fronted node returns 521 when its origin is
                // momentarily down). Classify them as a network timeout so
                // they read honestly in logs and rotate to a healthy
                // fallback like any timeout — not as an "invalid response"
                // (which sounds like a permanent fault). The circuit breaker
                // still trips after repeated failures, so a consistently-bad
                // endpoint gets skipped.
                if [408, 502, 503, 504].contains(http.statusCode)
                    || (520...527).contains(http.statusCode) {
                    throw .network("HTTP \(http.statusCode) (timeout) from \(endpoint.id)")
                }
                throw .invalidResponse("HTTP \(http.statusCode) from \(endpoint.id)")
            }
        }

        return responseData
    }

    // MARK: - Circuit breaker

    private func isOpen(for endpointId: String) -> Bool {
        breakers[endpointId]?.isOpen ?? false
    }

    private func recordSuccess(for endpointId: String) {
        breakers[endpointId]?.recordSuccess()
    }

    private func recordFailure(for endpointId: String) {
        var breaker = breakers[endpointId] ?? CircuitBreaker()
        breaker.recordFailure()
        breakers[endpointId] = breaker
    }

    private func retryAfterDate(from response: HTTPURLResponse) -> Date {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header) {
            return Date().addingTimeInterval(seconds)
        }
        return Date().addingTimeInterval(60)
    }
}

/// One circuit breaker per endpoint. After
/// `failureThreshold` consecutive failures, the breaker opens for
/// `openDuration`. Subsequent requests skip the endpoint; the
/// dispatcher rotates to the next fallback.
struct CircuitBreaker: Sendable {
    private(set) var consecutiveFailures: Int = 0
    /// Monotonic deadline (2026-06-11) — `ContinuousClock` instead
    /// of wall-clock `Date`, so an NTP correction or manual clock
    /// change can neither pin a breaker open nor expire its window
    /// early.
    private(set) var openUntil: ContinuousClock.Instant?

    static let failureThreshold = 5
    static let openDuration: Duration = .seconds(60)

    var isOpen: Bool {
        guard let openUntil else { return false }
        return ContinuousClock().now < openUntil
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold {
            openUntil = ContinuousClock().now + Self.openDuration
        }
    }
}
