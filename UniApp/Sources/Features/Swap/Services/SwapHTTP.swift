import Foundation
import OSLog

/// Minimal off-main HTTP layer for the two fixed swap-provider hosts
/// (`li.quest`, `lite-api.jup.ag`). These are NOT chain RPC endpoints
/// (so they don't belong in `RPCRegistry`/`RPCClient`, which is keyed by
/// `SupportedChain`), but they follow the same discipline: pure
/// `URLSession` (Rule #3 — no third-party), a bounded timeout, no
/// caching (fresh quotes), and every call runs off the main actor
/// (Rule #28). Decoding happens on the background executor; only the
/// `Sendable` decoded value crosses back.
///
/// The actor serializes nothing heavy — `URLSession` is already
/// concurrent — but isolating the `JSONDecoder` + the shared session
/// here keeps the call sites clean and the type `Sendable`.
actor SwapHTTP {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "swap")

    static let shared = SwapHTTP()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 25
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.decoder = JSONDecoder()
    }

    /// Perform a GET and decode the JSON body into `T`. Throws typed
    /// `SwapError`. Maps non-2xx via `SwapError.from(status:body:)` so
    /// the caller gets `.noRoute` / `.amountTooSmall` / etc. honestly.
    func getJSON<T: Decodable & Sendable>(
        _ type: T.Type,
        url: URL,
        headers: [String: String] = [:]
    ) async throws(SwapError) -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(type, request: request)
    }

    /// Perform a POST with a JSON body and decode the response into `T`.
    /// Reserved for the future execute step (Li.Fi `/quote` is GET;
    /// Jupiter `/swap` is POST). Included now so the seam is real, not a
    /// stub.
    func postJSON<T: Decodable & Sendable, Body: Encodable & Sendable>(
        _ type: T.Type,
        url: URL,
        body: Body,
        headers: [String: String] = [:]
    ) async throws(SwapError) -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw .invalidResponse("failed to encode request body")
        }
        return try await perform(type, request: request)
    }

    // MARK: - Core

    private func perform<T: Decodable & Sendable>(
        _ type: T.Type,
        request: URLRequest
    ) async throws(SwapError) -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw .cancelled
        } catch let urlError as URLError {
            throw .network(Self.urlErrorLabel(urlError))
        } catch {
            throw .network("request failed")
        }

        guard let http = response as? HTTPURLResponse else {
            throw .invalidResponse("no HTTP response")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SwapError.from(status: http.statusCode, body: body)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            log.error("swap decode failed: \(String(describing: error), privacy: .public)")
            throw .invalidResponse("couldn't parse the swap response")
        }
    }

    private static func urlErrorLabel(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "you're offline"
        case .timedOut:
            return "the request timed out"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "couldn't reach the swap service"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "secure connection failed"
        default:
            return "network error"
        }
    }
}
