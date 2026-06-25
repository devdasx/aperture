import Foundation
import OSLog

/// WalletConnect boundary. The SDK integration is intentionally disabled
/// until its Swift package resolves cleanly and the real WalletKit calls are
/// wired; pairing fails honestly instead of pretending a session exists.
///
/// Project ID retained for the future SDK integration:
/// `9c08a06e7615d64e7e86ea0197777a96`.
///
/// **Why a wrapper.** Reown's SDK is large (60k+ LOC). Feature code
/// reaches through this single class for three reasons:
/// 1. Future-proofing — when Reown ships v3 the breaking changes hit
///    here, not every call site.
/// 2. Testability — a stub `WalletConnectClient` can be injected in
///    test mode.
/// 3. Audit surface — every WalletConnect call routes through one
///    file the security reviewer can read end-to-end.
///
/// **Honesty (Rule #16).** Every WalletConnect session request the
/// user wasn't authenticated for goes through the same confirmation
/// sheets as in-app browser requests. No WalletConnect-specific
/// short-circuit. The user reads the dApp identity, the request
/// payload, and the network fee before signing.
///
/// **Pairing.** Call `pair(uri:)` with a `wc:` URI scanned from a
/// QR code or pasted from a deep link. The SDK establishes the
/// session; the router decides what to do with each incoming request.
@MainActor
@Observable
final class WalletConnectClient {
    static let shared = WalletConnectClient()

    /// The user-supplied project ID. Stored once, read by the SDK
    /// initialization path the moment the browser tab loads.
    static let projectID = "9c08a06e7615d64e7e86ea0197777a96"

    @ObservationIgnored private let log = Logger(subsystem: "com.thuglife.aperture", category: "walletconnect")

    /// Active sessions, exposed for the BrowserHomeView's "Connected"
    /// section. Updated as the SDK reports session lifecycle events.
    ///
    /// **2026-06-10 — `@Observable`-tracked** (was `@Published` with
    /// no `ObservableObject` conformance — which doesn't compile in
    /// Swift 6). The class is now `@Observable` to match the rest
    /// of Aperture's observable surface (Rule #2 §C) so SwiftUI
    /// reads of `activeSessions` from `BrowserHomeView` /
    /// `BrowserSettingsView` subscribe automatically.
    private(set) var activeSessions: [Session] = []

    @ObservationIgnored private var isConfigured: Bool = false

    private init() {}

    /// Configure the SDK with the project's metadata. Currently a no-op:
    /// without a working WalletKit dependency, this client must stay
    /// unconfigured so pair attempts fail instead of faking success.
    func configureIfNeeded() async {
        guard !isConfigured else { return }
        log.info("WalletConnect SDK unavailable; pairing remains disabled")
    }

    /// Pair with a `wc:` URI. Throws if the URI is malformed or the
    /// SDK fails to establish the pairing.
    func pair(uri: String) async throws {
        await configureIfNeeded()
        guard uri.hasPrefix("wc:") else {
            throw WalletConnectError.invalidURI
        }
        log.info("WalletConnect pair rejected because SDK is unavailable for \(uri.prefix(64), privacy: .public)…")
        throw WalletConnectError.sdkUnavailable
    }

    /// Disconnect an active session.
    func disconnect(sessionId: String) async {
        log.info("WalletConnect disconnect requested for session \(sessionId, privacy: .public)")
        // try await WalletKit.instance.disconnect(topic: sessionId)
        activeSessions.removeAll { $0.id == sessionId }
    }

    /// Lightweight session model. Mirrors the future SDK `Session` so the
    /// view layer does not need to change when WalletConnect is re-enabled.
    struct Session: Identifiable, Sendable {
        let id: String          // SDK topic id
        let name: String
        let url: String
        let iconURL: String?
        let chain: SupportedChain
        let connectedAt: Date
    }
}

enum WalletConnectError: Error {
    case invalidURI
    case notConfigured
    case sdkUnavailable
    case pairingFailed(String)
    case sessionExpired
}
