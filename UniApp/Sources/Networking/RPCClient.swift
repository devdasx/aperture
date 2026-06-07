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
///    endpoint on any non-cancellation error.
/// 3. **Circuit breaker** — after N consecutive failures, skip the
///    endpoint for 60 s.
/// 4. **Honest errors** — `RPCError` is typed throws; UI surfaces
///    them per Rule #16's "name what we couldn't do."
///
/// **Rule #3 compliance.** Pure `URLSession` + `JSONSerialization`.
/// No third-party packages.
actor RPCClient {
    private let session: URLSession
    private let rateLimiter: RateLimiter
    private var breakers: [String: CircuitBreaker] = [:]
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "rpc")

    init(session: URLSession? = nil, rateLimiter: RateLimiter = RateLimiter()) {
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
            self.session = URLSession(configuration: config)
        }
        self.rateLimiter = rateLimiter
    }

    // MARK: - JSON-RPC

    /// Typed wrapper for JSON-RPC calls whose `result` is a JSON
    /// string (the common case for EVM: `eth_getBalance`,
    /// `eth_getTransactionCount`, `eth_chainId`, `eth_blockNumber`).
    /// Returns Sendable `String` so it crosses actor boundaries.
    func callJSONString(
        chain: SupportedChain,
        method: String,
        params: [Sendable]
    ) async throws(RPCError) -> String {
        let result = try await callJSON(chain: chain, method: method, params: params)
        guard let str = result as? String else {
            throw .invalidResponse("\(method) result was not a string")
        }
        return str
    }

    /// JSON-RPC calls whose `result` is a JSON object or array.
    /// Returns the `result` field **re-serialized as `Data`** so
    /// the caller can decode it in its own isolation —
    /// `[String: Any]` and `[Any]` aren't Sendable across actor
    /// boundaries under Swift 6 strict concurrency. Adapters call
    /// `JSONSerialization.jsonObject(with: data)` to get back the
    /// dict / array shape.
    func callJSONResultData(
        chain: SupportedChain,
        method: String,
        params: [Sendable]
    ) async throws(RPCError) -> Data {
        let result = try await callJSON(chain: chain, method: method, params: params)
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
    func callJSONResultData(
        chain: SupportedChain,
        method: String,
        paramsObject: [String: Sendable]
    ) async throws(RPCError) -> Data {
        let result = try await callJSONNamedParams(
            chain: chain,
            method: method,
            paramsObject: paramsObject
        )
        guard let data = try? JSONSerialization.data(withJSONObject: result) else {
            throw .decodingFailed("Could not re-serialize \(method) result")
        }
        return data
    }

    private func callJSONNamedParams(
        chain: SupportedChain,
        method: String,
        paramsObject: [String: Sendable]
    ) async throws(RPCError) -> Any {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .jsonRPC {
            if isOpen(for: endpoint.id) { continue }
            await rateLimiter.acquire(for: endpoint)
            do {
                let result = try await dispatchJSONNamedParams(
                    endpoint: endpoint,
                    method: method,
                    paramsObject: paramsObject
                )
                recordSuccess(for: endpoint.id)
                return result
            } catch let error as RPCError {
                lastError = error
                recordFailure(for: endpoint.id)
                if case .cancelled = error { throw error }
                continue
            } catch {
                lastError = .network(String(describing: error))
                recordFailure(for: endpoint.id)
                continue
            }
        }
        throw lastError
    }

    private func dispatchJSONNamedParams(
        endpoint: RPCEndpoint,
        method: String,
        paramsObject: [String: Any]
    ) async throws(RPCError) -> Any {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
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
            (responseData, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
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
            throw .rpcError(code: code, message: message)
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
        params: [Sendable]
    ) async throws(RPCError) -> Any {
        let endpoints = RPCRegistry.endpoints(for: chain)
        guard !endpoints.isEmpty else { throw RPCError.noEndpoint(chain) }

        var lastError: RPCError = .allEndpointsFailed(chain)
        for endpoint in endpoints where endpoint.kind == .jsonRPC {
            if isOpen(for: endpoint.id) {
                log.debug("Circuit open for \(endpoint.id, privacy: .public), skipping")
                continue
            }
            await rateLimiter.acquire(for: endpoint)
            do {
                let result = try await dispatchJSON(
                    endpoint: endpoint,
                    method: method,
                    params: params
                )
                recordSuccess(for: endpoint.id)
                return result
            } catch let error as RPCError {
                lastError = error
                recordFailure(for: endpoint.id)
                log.error("RPC failed on \(endpoint.id, privacy: .public): \(String(describing: error), privacy: .public)")
                if case .cancelled = error { throw error }
                continue
            } catch {
                lastError = .network(String(describing: error))
                recordFailure(for: endpoint.id)
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
            if isOpen(for: endpoint.id) { continue }
            await rateLimiter.acquire(for: endpoint)
            do {
                let data = try await dispatchRESTPost(
                    endpoint: endpoint,
                    path: path,
                    body: body
                )
                recordSuccess(for: endpoint.id)
                return data
            } catch let error as RPCError {
                lastError = error
                recordFailure(for: endpoint.id)
                if case .cancelled = error { throw error }
                continue
            } catch {
                lastError = .network(String(describing: error))
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
        request.httpBody = bodyData

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
                throw .invalidResponse("HTTP \(http.statusCode) from \(endpoint.id)")
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
            if isOpen(for: endpoint.id) { continue }
            await rateLimiter.acquire(for: endpoint)
            do {
                let data = try await dispatchREST(
                    endpoint: endpoint,
                    path: path,
                    query: query
                )
                recordSuccess(for: endpoint.id)
                return data
            } catch let error as RPCError {
                lastError = error
                recordFailure(for: endpoint.id)
                if case .cancelled = error { throw error }
                continue
            } catch {
                lastError = .network(String(describing: error))
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
        params: [Any]
    ) async throws(RPCError) -> Any {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
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
            (responseData, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let retryAfter = retryAfterDate(from: http)
                throw .rateLimited(retryAfter: retryAfter)
            }
            if !(200..<300).contains(http.statusCode) {
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
            throw .rpcError(code: code, message: message)
        }
        guard let result = dict["result"] else {
            throw .invalidResponse("JSON-RPC response missing `result`")
        }
        return result
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

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw .cancelled }
            throw .network(urlError.localizedDescription)
        } catch {
            throw .network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw .rateLimited(retryAfter: retryAfterDate(from: http))
            }
            if !(200..<300).contains(http.statusCode) {
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
    private(set) var openUntil: Date?

    static let failureThreshold = 5
    static let openDuration: TimeInterval = 60

    var isOpen: Bool {
        guard let openUntil else { return false }
        return Date() < openUntil
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = nil
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold {
            openUntil = Date().addingTimeInterval(Self.openDuration)
        }
    }
}
