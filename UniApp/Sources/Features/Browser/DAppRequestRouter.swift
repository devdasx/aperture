import Foundation
import OSLog
import SwiftData
import SwiftUI

/// Result of a dApp JSON-RPC call. `success` carries any
/// JSON-serializable native value (`String`, `Int`, `[Any]`,
/// `[String: Any]`, `NSNull`); the JS bridge re-serializes it for
/// the page. `failure` carries an EIP-1474 / standard JSON-RPC error
/// envelope.
enum DAppRequestResult: Sendable {
    case success(any Sendable)
    case failure(DAppRequestError)
}

struct DAppRequestError: Error, Sendable {
    let code: Int
    let message: String

    static let userRejected = DAppRequestError(code: 4001, message: "User rejected the request")
    static let unauthorized = DAppRequestError(code: 4100, message: "Unauthorized — connect first")
    static let unsupportedMethod = DAppRequestError(code: 4200, message: "Method not supported")
    static let disconnected = DAppRequestError(code: 4900, message: "Wallet disconnected")
    static let internalError = DAppRequestError(code: -32603, message: "Internal error")
    static let invalidParams = DAppRequestError(code: -32602, message: "Invalid params")

    static func failed(_ message: String) -> DAppRequestError {
        DAppRequestError(code: -32603, message: message)
    }
}

/// Single source of truth for every dApp request — EIP-1193 EVM,
/// Solana wallet-adapter, AND WalletConnect-relayed equivalents. Owns
/// the in-flight confirmation sheet state (`pendingRequest`) so the
/// view layer can present sheets reactively.
///
/// **Confirmation flow.** Every signing call (`personal_sign`,
/// `eth_sendTransaction`, `signMessage`, `signTransaction`,
/// `signAndSendTransaction`, `eth_signTypedData_v4`) goes through one
/// of four sheets: `DAppConnectSheet`, `DAppSignMessageSheet`,
/// `DAppSignTypedDataSheet`, `DAppSendTransactionSheet`. The user's
/// approval / cancellation flips through a `CheckedContinuation` so
/// the call returns the right promise resolution on the page.
///
/// **Honesty (Rule #16).** Every request the user wasn't authenticated
/// for goes through a biometric prompt (`BiometricService`) before the
/// native signer runs. Signing failures throw — they don't get
/// converted into fake successes.
@MainActor
@Observable
final class DAppRequestRouter {
    static let shared = DAppRequestRouter()

    /// Currently presented confirmation. SwiftUI binds a `.sheet(item:)`
    /// to this; the user's choice resolves the in-flight continuation.
    var pendingRequest: PendingRequest?

    /// Connection state per security origin (`scheme://host[:port]`).
    /// Host-only grants let `http://example.com` inherit a grant made to
    /// `https://example.com`; the wallet bridge must not do that.
    private var connectedOriginKeys: Set<String> = []

    /// SwiftData context for persisting in-app-browser connections to
    /// `ConnectedDAppRecord`. Set once from the browser session view's
    /// `.task` via `setModelContext(_:)` using its
    /// `@Environment(\.modelContext)`. `nil` until then — every write
    /// path guards on it, so an unset context degrades to the prior
    /// in-memory-only behaviour (the connection still works for the
    /// session; it just isn't surfaced in settings) rather than
    /// crashing. `@ObservationIgnored` because the context is plumbing,
    /// not view-observable state.
    @ObservationIgnored private var modelContext: ModelContext?

    /// FIFO queue of awaiting requests. The head is the one currently
    /// presented via `pendingRequest`; later arrivals wait their turn
    /// instead of being dropped. Every resolution path removes the
    /// entry from the queue BEFORE resuming so a continuation can
    /// never be resumed twice.
    private var pendingQueue: [(request: PendingRequest, continuation: CheckedContinuation<DAppRequestResult, Never>)] = []

    /// The chain a dApp last switched the browser to via
    /// `wallet_switchEthereumChain`. Overrides the wallet's default
    /// until the session ends.
    private var selectedEVMChain: SupportedChain?

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "dapp-router")

    private init() {}

    // MARK: - Entry point

    /// Resolve a dApp request. `channel` is `"eth"` or `"sol"`; the
    /// router dispatches per method. Async — most calls touch the
    /// confirmation sheet which awaits user input.
    func handle(
        channel: String,
        method: String,
        params: [Any],
        pageURL: URL?,
        pageTitle: String?
    ) async -> DAppRequestResult {
        let origin = DAppOrigin(
            host: pageURL?.host ?? "(unknown)",
            url: pageURL?.absoluteString ?? "",
            title: pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? pageURL?.host ?? "dApp",
            iconURL: pageURL.flatMap { faviconURL(for: $0) }
        )
        guard origin.isSecureForWalletBridge else {
            return .failure(DAppRequestError(
                code: 4100,
                message: "Aperture only connects to HTTPS dApps"
            ))
        }
        switch channel {
        case "eth":
            return await handleEVM(method: method, params: params, origin: origin)
        case "sol":
            return await handleSolana(method: method, params: params, origin: origin)
        default:
            return .failure(.unsupportedMethod)
        }
    }

    /// Hook for `BrowserWebView`'s `wc:` URI interception. Hands the
    /// URI off to `WalletConnectClient.shared.pair(uri:)`.
    func handleWalletConnectURI(_ uri: String) async {
        do {
            try await WalletConnectClient.shared.pair(uri: uri)
        } catch {
            log.error("WalletConnect pair failed for \(uri, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - EVM

    private func handleEVM(method: String, params: [Any], origin: DAppOrigin) async -> DAppRequestResult {
        switch method {
        case "eth_requestAccounts":
            return await requestEVMConnect(origin: origin)
        case "eth_accounts":
            return .success(isConnected(origin) ? [activeAddress()].compactMap { $0 } : [])
        case "eth_chainId":
            return .success(activeChainIdHex())
        case "net_version":
            return .success(String(activeChainIdInt()))
        case "wallet_switchEthereumChain":
            // EIP-3326. Auto-accept switches to chains Aperture
            // supports; reject anything else with 4902 so the dApp
            // falls back to `wallet_addEthereumChain` / its own error
            // path instead of believing a switch happened. On success
            // we return the CONFIRMED chain id hex — the JS bridge
            // emits `chainChanged` with it and resolves null to the
            // dApp per spec. The page never gets to dictate our chain
            // state from its own request params.
            guard let first = params.first as? [String: Any],
                  let requestedHex = first["chainId"] as? String,
                  let requestedId = Self.chainIdInt(fromHex: requestedHex) else {
                return .failure(.invalidParams)
            }
            guard let chain = Self.supportedEVMChain(forChainId: requestedId) else {
                return .failure(DAppRequestError(
                    code: 4902,
                    message: String(format: String(localized: "Unrecognized chain ID %@ — Aperture doesn't support this chain"), requestedHex)
                ))
            }
            guard activeAddress(on: chain) != nil else {
                return .failure(DAppRequestError(
                    code: 4100,
                    message: String(format: String(localized: "This wallet has no %@ account"), chain.displayName)
                ))
            }
            selectedEVMChain = chain
            return .success(activeChainIdHex())
        case "wallet_addEthereumChain":
            guard let first = params.first as? [String: Any],
                  let requestedHex = first["chainId"] as? String,
                  let requestedId = Self.chainIdInt(fromHex: requestedHex) else {
                return .failure(.invalidParams)
            }
            guard let chain = Self.supportedEVMChain(forChainId: requestedId) else {
                return .failure(DAppRequestError(
                    code: 4902,
                    message: String(format: String(localized: "Unrecognized chain ID %@ — Aperture doesn't support this chain"), requestedHex)
                ))
            }
            guard activeAddress(on: chain) != nil else {
                return .failure(DAppRequestError(
                    code: 4100,
                    message: String(format: String(localized: "This wallet has no %@ account"), chain.displayName)
                ))
            }
            selectedEVMChain = chain
            return .success(NSNull())
        case "personal_sign", "eth_sign":
            guard isConnected(origin) else { return .failure(.unauthorized) }
            return await requestEVMSignMessage(params: params, origin: origin, method: method)
        case "eth_signTypedData_v4", "eth_signTypedData":
            guard isConnected(origin) else { return .failure(.unauthorized) }
            return await requestEVMSignTypedData(params: params, origin: origin)
        case "eth_sendTransaction":
            guard isConnected(origin) else { return .failure(.unauthorized) }
            return await requestEVMSendTransaction(params: params, origin: origin)
        case "eth_estimateGas", "eth_gasPrice", "eth_blockNumber", "eth_getBalance",
             "eth_call", "eth_getTransactionByHash", "eth_getTransactionReceipt",
             "eth_getBlockByNumber", "eth_getBlockByHash":
            // Read-only proxy through our RPC client. The dApp's RPC
            // requests flow through Aperture's endpoint rotation so we
            // share rate limits.
            return await passThroughEVMRPC(method: method, params: params)
        default:
            return .failure(.unsupportedMethod)
        }
    }

    private func requestEVMConnect(origin: DAppOrigin) async -> DAppRequestResult {
        // Already connected → return cached address immediately.
        if isConnected(origin),
           let addr = activeAddress() {
            return .success([addr])
        }
        // Otherwise present `DAppConnectSheet` and await the user's
        // choice via the pending queue.
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.connect(.init(
                id: UUID(),
                origin: origin,
                permissions: [.readAddress, .signMessages, .signTransactions],
                chain: activeChain()
            )), continuation: cont)
        }
    }

    private func requestEVMSignMessage(
        params: [Any],
        origin: DAppOrigin,
        method: String
    ) async -> DAppRequestResult {
        // personal_sign:  [message, address]
        // eth_sign:        [address, message]
        let messageHex: String
        let requestedAddress: String
        if method == "personal_sign" {
            guard params.count >= 2,
                  let first = params[0] as? String,
                  let second = params[1] as? String else { return .failure(.invalidParams) }
            if Self.isHexAddress(first) {
                requestedAddress = first
                messageHex = second
            } else {
                messageHex = first
                requestedAddress = second
            }
        } else {
            guard params.count >= 2,
                  let address = params[0] as? String,
                  let msg = params[1] as? String else { return .failure(.invalidParams) }
            requestedAddress = address
            messageHex = msg
        }
        let chain = activeChain()
        guard Self.isHexAddress(requestedAddress),
              activeAddress(on: chain)?.caseInsensitiveCompare(requestedAddress) == .orderedSame else {
            return .failure(DAppRequestError(code: 4100, message: "Requested signing address does not match the active wallet"))
        }
        let preview = Self.decodeMessage(hex: messageHex)
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.signMessage(.init(
                id: UUID(),
                origin: origin,
                messagePreview: preview,
                rawHex: messageHex,
                from: requestedAddress,
                chain: chain
            )), continuation: cont)
        }
    }

    private func requestEVMSignTypedData(params: [Any], origin: DAppOrigin) async -> DAppRequestResult {
        // eth_signTypedData_v4: [address, jsonOrObject]
        guard params.count >= 2,
              let requestedAddress = params[0] as? String else { return .failure(.invalidParams) }
        let chain = activeChain()
        guard Self.isHexAddress(requestedAddress),
              activeAddress(on: chain)?.caseInsensitiveCompare(requestedAddress) == .orderedSame else {
            return .failure(DAppRequestError(code: 4100, message: "Requested signing address does not match the active wallet"))
        }
        let payload: String
        if let s = params[1] as? String {
            payload = s
        } else if let obj = params[1] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: obj),
                  let s = String(data: data, encoding: .utf8) {
            payload = s
        } else {
            return .failure(.invalidParams)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.signTypedData(.init(
                id: UUID(),
                origin: origin,
                rawJSON: payload,
                from: requestedAddress,
                chain: chain
            )), continuation: cont)
        }
    }

    private func requestEVMSendTransaction(params: [Any], origin: DAppOrigin) async -> DAppRequestResult {
        guard let tx = params.first as? [String: Any] else { return .failure(.invalidParams) }
        // Validate the untrusted dApp params at the boundary. BOTH `from` and
        // `to` must be well-formed 0x addresses (0x + 40 hex) — this browser
        // does not support contract-creation (empty `to`), so reject a
        // missing/blank/malformed address with a clear error instead of
        // signing something the user can't review (or showing them a malformed
        // address in the confirmation sheet that fails late at signing).
        guard let from = (tx["from"] as? String)?.trimmingCharacters(in: .whitespaces),
              from.hasPrefix("0x"), from.count == 42,
              from.dropFirst(2).allSatisfy(\.isHexDigit) else {
            return .failure(.invalidParams)
        }
        guard let to = (tx["to"] as? String)?.trimmingCharacters(in: .whitespaces),
              to.hasPrefix("0x"), to.count == 42,
              to.dropFirst(2).allSatisfy(\.isHexDigit) else {
            return .failure(.invalidParams)
        }
        let valueHex = (tx["value"] as? String) ?? "0x0"
        let dataHex = (tx["data"] as? String) ?? "0x"
        let gasHex = tx["gas"] as? String
        let chain = activeChain()
        guard activeAddress(on: chain)?.caseInsensitiveCompare(from) == .orderedSame else {
            return .failure(DAppRequestError(code: 4100, message: "Transaction sender does not match the active wallet"))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.sendTransaction(.init(
                id: UUID(),
                origin: origin,
                from: from,
                to: to,
                valueHex: valueHex,
                dataHex: dataHex,
                gasHex: gasHex,
                chain: chain
            )), continuation: cont)
        }
    }

    private func passThroughEVMRPC(method: String, params: [Any]) async -> DAppRequestResult {
        // Sendable bridge — the dApp's params arrive as `[Any]` from
        // the JS bridge. RPCClient expects `[Sendable]`. We coerce
        // the leaf JSON types (String, Int, Double, Bool, Array, Dict)
        // since they're all known-Sendable. Anything we can't coerce
        // gets dropped — the dApp may not get a useful response but
        // we don't crash.
        let chain = activeChain()
        let client = RPCClient.shared
        let coerced: [Sendable] = params.compactMap { Self.coerce($0) }
        do {
            let data = try await client.callJSONResultData(
                chain: chain,
                method: method,
                params: coerced
            )
            if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                return .success(Self.coerce(obj) ?? NSNull())
            }
            return .failure(.failed("passThrough decode failed"))
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }

    private static func coerce(_ value: Any) -> (any Sendable)? {
        if let s = value as? String { return s }
        if let n = value as? Int { return n }
        if let n = value as? Double { return n }
        if let b = value as? Bool { return b }
        if let arr = value as? [Any] {
            return arr.compactMap { coerce($0) } as [any Sendable]
        }
        if let dict = value as? [String: Any] {
            var out: [String: any Sendable] = [:]
            for (k, v) in dict {
                if let c = coerce(v) { out[k] = c }
            }
            return out
        }
        if value is NSNull { return NSNull() }
        return nil
    }

    // MARK: - Solana

    private func handleSolana(method: String, params: [Any], origin: DAppOrigin) async -> DAppRequestResult {
        switch method {
        case "connect":
            return await requestSolanaConnect(origin: origin)
        case "disconnect":
            connectedOriginKeys.remove(origin.securityKey)
            removeConnection(host: origin.host)
            return .success(NSNull())
        case "signMessage":
            guard isConnected(origin) else { return .failure(.unauthorized) }
            return await requestSolanaSignMessage(params: params, origin: origin)
        case "signTransaction", "signAndSendTransaction", "signAllTransactions":
            guard isConnected(origin) else { return .failure(.unauthorized) }
            return await requestSolanaSignTransaction(params: params, origin: origin, method: method)
        default:
            return .failure(.unsupportedMethod)
        }
    }

    private func requestSolanaConnect(origin: DAppOrigin) async -> DAppRequestResult {
        // No derived Solana address (e.g. an EVM-only / Bitcoin / XRP wallet)
        // → refuse honestly instead of later handing the dApp {publicKey:""},
        // a truthy-but-invalid value it would accept and then fail to sign
        // with. Mirrors how EVM eth_accounts returns [] when there's no address.
        guard solanaAddress() != nil else {
            return .failure(DAppRequestError(code: 4100, message: String(localized: "This wallet has no Solana account")))
        }
        if isConnected(origin),
           let pubkey = solanaAddress() {
            return .success(["publicKey": pubkey])
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.connect(.init(
                id: UUID(),
                origin: origin,
                permissions: [.readAddress, .signMessages, .signTransactions],
                chain: .solana,
                channel: .solana
            )), continuation: cont)
        }
    }

    private func requestSolanaSignMessage(params: [Any], origin: DAppOrigin) async -> DAppRequestResult {
        guard let first = params.first as? [String: Any],
              let hex = first["message"] as? String else {
            return .failure(.invalidParams)
        }
        let preview = Self.decodeMessage(hex: hex)
        guard let from = solanaAddress() else {
            return .failure(DAppRequestError(code: 4100, message: String(localized: "This wallet has no Solana account")))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.signMessage(.init(
                id: UUID(),
                origin: origin,
                messagePreview: preview,
                rawHex: hex,
                from: from,
                chain: .solana
            )), continuation: cont)
        }
    }

    private func requestSolanaSignTransaction(
        params: [Any],
        origin: DAppOrigin,
        method: String
    ) async -> DAppRequestResult {
        // Same honesty as connect: with no derived Solana address there's
        // nothing to sign from — refuse rather than enqueuing a request with
        // an empty `from`.
        guard let from = solanaAddress() else {
            return .failure(DAppRequestError(code: 4100, message: String(localized: "This wallet has no Solana account")))
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.sendTransaction(.init(
                id: UUID(),
                origin: origin,
                from: from,
                to: "",
                valueHex: "0x0",
                dataHex: "0x",
                gasHex: nil,
                chain: .solana
            )), continuation: cont)
        }
    }

    // MARK: - User-side responses (called by confirmation sheets)

    /// Approve a pending `.connect` request. Adds the origin host to
    /// the allowed set, persists a `ConnectedDAppRecord` so the
    /// connection survives app launches and surfaces in Browser
    /// settings → "Connected dApps", then returns the address (EVM
    /// channel) or `{publicKey:...}` (Solana channel) via the
    /// continuation.
    func approveConnect(origin: DAppOrigin, channel: ConnectChannel) {
        // Resolve the address to reveal BEFORE recording the connection, so a
        // Solana approve with no derived address fails honestly — never
        // handing the dApp an empty publicKey and never leaving a
        // half-recorded connection behind. (requestSolanaConnect already
        // prevents the sheet from appearing without an address; this is
        // belt-and-braces.)
        let addr: any Sendable
        switch channel {
        case .evm:
            guard let evmAddress = activeAddress(on: activeChain()) else {
                resume(.failure(DAppRequestError(code: 4100, message: String(localized: "This wallet has no account for the selected network"))))
                return
            }
            addr = [evmAddress] as [String]
        case .solana:
            guard let pubkey = solanaAddress() else {
                resume(.failure(DAppRequestError(code: 4100, message: String(localized: "This wallet has no Solana account"))))
                return
            }
            addr = ["publicKey": pubkey]
        }

        connectedOriginKeys.insert(origin.securityKey)

        // Persist the connection. The full origin (name / url / icon)
        // lives on the currently-presented `.connect` request — read it
        // back so the persisted row carries the dApp's human-readable
        // identity, not just its host.
        if case .connect(let request)? = pendingRequest, request.origin.securityKey == origin.securityKey {
            persistConnection(origin: request.origin, channel: channel)
        } else {
            // Defensive: approve was called without a matching presented
            // request (shouldn't happen via the sheet). Still record a
            // minimal row so the connection is honestly reflected.
            persistConnection(origin: origin, channel: channel)
        }

        resume(.success(addr))
    }

    func rejectPending() {
        resume(.failure(.userRejected))
    }

    /// Resolve the presented request with a failure produced by the
    /// signing pipeline (key unavailable, watch-only wallet,
    /// unsupported payload). Honest errors — never fake successes.
    func failPending(_ error: DAppRequestError) {
        resume(.failure(error))
    }

    /// Called by the `.sheet(item:)` bindings when the confirmation
    /// sheet goes away. If the presented request is still unresolved
    /// (the user swiped the sheet down), reject it; if it already
    /// resolved (approve / reject / fail ran first), this is a no-op
    /// for that request. Either way, present the next queued request.
    func handleSheetDismissed() {
        if let presented = pendingRequest,
           let index = pendingQueue.firstIndex(where: { $0.request.id == presented.id }) {
            let entry = pendingQueue.remove(at: index)
            pendingRequest = nil
            entry.continuation.resume(returning: .failure(.userRejected))
        }
        scheduleNextPresentation()
    }

    /// Approve a sign-message request and return the signed hex.
    /// `signedHex` is supplied by the signer pipeline that the
    /// confirmation sheet calls into.
    func approveSign(signedHex: String) {
        resume(.success(signedHex))
    }

    /// Approve a send-transaction request and return the broadcast
    /// hash. The confirmation sheet runs the signer + broadcast and
    /// hands the hash back.
    func approveSend(txHash: String) {
        resume(.success(txHash))
    }

    // MARK: - Queue plumbing

    /// Append a request to the FIFO queue and suspend the caller on
    /// its continuation. Presents immediately when the router is idle;
    /// otherwise the request waits for the ones ahead of it.
    private func enqueue(
        _ request: PendingRequest,
        continuation: CheckedContinuation<DAppRequestResult, Never>
    ) {
        let wasIdle = pendingQueue.isEmpty && pendingRequest == nil
        pendingQueue.append((request: request, continuation: continuation))
        if wasIdle {
            pendingRequest = request
        }
    }

    /// Resolve the CURRENTLY PRESENTED request. Idempotent per
    /// request: the entry leaves the queue before its continuation
    /// fires, so a racing second call (Cancel tap + sheet-dismiss
    /// binding write) finds nothing to resume and returns.
    private func resume(_ result: DAppRequestResult) {
        guard let presented = pendingRequest,
              let index = pendingQueue.firstIndex(where: { $0.request.id == presented.id }) else {
            return
        }
        let entry = pendingQueue.remove(at: index)
        pendingRequest = nil
        entry.continuation.resume(returning: result)
        scheduleNextPresentation()
    }

    /// Present the queue head once the just-dismissed sheet has
    /// finished animating away — presenting a new `.sheet(item:)`
    /// value mid-dismissal gets dropped by SwiftUI.
    private func scheduleNextPresentation() {
        guard !pendingQueue.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            guard pendingRequest == nil, let next = pendingQueue.first else { return }
            pendingRequest = next.request
        }
    }

    // MARK: - Connection persistence

    /// Inject the SwiftData context the router persists connections
    /// into. Called once from `BrowserSessionView`'s `.task` with its
    /// `@Environment(\.modelContext)`. Idempotent — re-setting it to the
    /// same container's context is harmless. Keeping the wiring here
    /// (rather than threading a context parameter through every approve
    /// path) is the least invasive shape: the sheet only passes the approved
    /// origin and channel back to the router.
    func setModelContext(_ context: ModelContext) {
        modelContext = context
        restorePersistedConnections(from: context)
    }

    /// Rehydrate live authorizations from persisted injected connections.
    /// The persisted row keeps the original URL, so origin grants remain
    /// scheme/host/port scoped; malformed or non-HTTPS legacy rows are ignored.
    private func restorePersistedConnections(from context: ModelContext) {
        let descriptor = FetchDescriptor<ConnectedDAppRecord>()
        do {
            for record in try context.fetch(descriptor) where record.transport == "injected" {
                let origin = DAppOrigin(
                    host: record.host,
                    url: record.url,
                    title: record.name.isEmpty ? record.host : record.name,
                    iconURL: record.iconURL
                )
                guard origin.isSecureForWalletBridge else { continue }
                connectedOriginKeys.insert(origin.securityKey)
            }
        } catch {
            log.error("Failed to restore persisted dApp connections: \(String(describing: error), privacy: .public)")
        }
    }

    /// Upsert a `ConnectedDAppRecord` for an approved connection,
    /// deduped by host: refresh the existing row's `connectedAt` /
    /// `name` / `iconURL` / `chainLabel` if the host already has one,
    /// else insert. Best-effort — a persistence failure must never turn
    /// a successful connection into a user-visible error, so it's logged
    /// and swallowed (the in-memory origin allow-set already made
    /// the connection live for this session).
    private func persistConnection(origin: DAppOrigin, channel: ConnectChannel) {
        guard let context = modelContext else { return }
        let host = origin.host
        let chainLabel: String
        switch channel {
        case .evm:    chainLabel = activeChain().displayName
        case .solana: chainLabel = SupportedChain.solana.displayName
        }
        let descriptor = FetchDescriptor<ConnectedDAppRecord>(
            predicate: #Predicate { $0.host == host }
        )
        do {
            if let existing = try context.fetch(descriptor).first {
                existing.name = origin.title
                existing.url = origin.url
                existing.iconURL = origin.iconURL
                existing.connectedAt = Date()
                existing.chainLabel = chainLabel
            } else {
                let record = ConnectedDAppRecord(
                    host: host,
                    name: origin.title,
                    url: origin.url,
                    iconURL: origin.iconURL,
                    connectedAt: Date(),
                    chainLabel: chainLabel,
                    transport: "injected"
                )
                context.insert(record)
            }
            try context.save()
        } catch {
            log.error("Failed to persist dApp connection for \(host, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Delete the `ConnectedDAppRecord` for a host on disconnect. Used
    /// by the Solana `disconnect` RPC path and by `disconnect(host:)`
    /// (the settings swipe action). Best-effort; logged on failure.
    private func removeConnection(host: String) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<ConnectedDAppRecord>(
            predicate: #Predicate { $0.host == host }
        )
        do {
            for record in try context.fetch(descriptor) {
                context.delete(record)
            }
            if context.hasChanges {
                try context.save()
            }
        } catch {
            log.error("Failed to remove dApp connection for \(host, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Disconnect an in-app-browser dApp by host — drops it from the
    /// live allow-set AND deletes its persisted row. Called from the
    /// "Connected dApps" swipe-to-disconnect in `BrowserSettingsView`
    /// so the user can revoke a connection from settings, not only from
    /// inside the dApp's own UI. After this, `eth_accounts` returns
    /// `[]` for the host until the user re-connects.
    func disconnect(host: String) {
        connectedOriginKeys = connectedOriginKeys.filter { DAppOrigin.host(fromSecurityKey: $0) != host }
        removeConnection(host: host)
    }

    // MARK: - Active wallet helpers

    private func activeAddress() -> String? {
        activeAddress(on: activeChain())
    }

    private func activeAddress(on chain: SupportedChain) -> String? {
        ActiveWalletReader.shared.currentEVMAddress(chain: chain)
    }

    private func solanaAddress() -> String? {
        ActiveWalletReader.shared.currentSolanaAddress()
    }

    private func activeChain() -> SupportedChain {
        selectedEVMChain ?? ActiveWalletReader.shared.currentEVMChain() ?? .ethereum
    }

    /// EVM chain ids for every supported EVM chain. Single source for
    /// both directions — `eth_chainId` reads forward, the
    /// `wallet_switchEthereumChain` validation reads in reverse.
    private static let evmChainIds: [SupportedChain: Int] = [
        .ethereum: 1,
        .optimism: 10,
        .bnbChain: 56,
        .opBNB: 204,
        .polygon: 137,
        .base: 8453,
        .arbitrum: 42161,
        .avalanche: 43114,
        .scroll: 534352,
        .zkSync: 324,
        .celo: 42220,
    ]

    private func activeChainIdInt() -> Int {
        Self.evmChainIds[activeChain()] ?? 1
    }

    private func activeChainIdHex() -> String {
        "0x" + String(activeChainIdInt(), radix: 16)
    }

    private func isConnected(_ origin: DAppOrigin) -> Bool {
        connectedOriginKeys.contains(origin.securityKey)
    }

    /// Parse an EIP-3326 `chainId` hex string ("0x1", "0xa4b1", …).
    private static func chainIdInt(fromHex hex: String) -> Int? {
        guard hex.hasPrefix("0x") || hex.hasPrefix("0X") else { return nil }
        return Int(hex.dropFirst(2), radix: 16)
    }

    /// Reverse lookup: numeric chain id → supported chain, or `nil`
    /// when Aperture doesn't support the chain (→ JSON-RPC 4902).
    private static func supportedEVMChain(forChainId id: Int) -> SupportedChain? {
        evmChainIds.first(where: { $0.value == id })?.key
    }

    private static func isHexAddress(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("0x")
            && trimmed.count == 42
            && trimmed.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    // MARK: - Utilities

    private func faviconURL(for url: URL) -> String? {
        guard let host = url.host else { return nil }
        // Fetch the site's own favicon directly — never a third-party
        // favicon service that would learn every host the user visits.
        // `BrowserFaviconView` falls back to the monogram placeholder
        // when the fetch fails.
        return "https://\(host)/favicon.ico"
    }

    private static func decodeMessage(hex: String) -> String {
        var stripped = hex
        if stripped.hasPrefix("0x") || stripped.hasPrefix("0X") {
            stripped.removeFirst(2)
        }
        // Try UTF-8 decode.
        var bytes: [UInt8] = []
        var i = stripped.startIndex
        while i < stripped.endIndex {
            let next = stripped.index(i, offsetBy: 2, limitedBy: stripped.endIndex) ?? stripped.endIndex
            if let b = UInt8(stripped[i..<next], radix: 16) {
                bytes.append(b)
            }
            i = next
        }
        if let s = String(data: Data(bytes), encoding: .utf8),
           s.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0.value == 0x0a || $0.value == 0x09 }) {
            return s
        }
        return "0x" + stripped
    }
}

// MARK: - Pending request envelope

extension DAppRequestRouter {

    enum PendingRequest: Identifiable {
        case connect(ConnectRequest)
        case signMessage(SignMessageRequest)
        case signTypedData(SignTypedDataRequest)
        case sendTransaction(SendTransactionRequest)

        var id: UUID {
            switch self {
            case .connect(let r):         return r.id
            case .signMessage(let r):     return r.id
            case .signTypedData(let r):   return r.id
            case .sendTransaction(let r): return r.id
            }
        }
    }

    struct ConnectRequest: Identifiable, Sendable {
        let id: UUID
        let origin: DAppOrigin
        let permissions: [Permission]
        let chain: SupportedChain
        /// Which channel the dApp is asking to connect through.
        /// Added 2026-06-10 so the confirmation sheet
        /// (`DAppConnectSheet`) knows whether to surface the EVM
        /// address (`currentEVMAddress(chain:)`) or the Solana address
        /// (`currentSolanaAddress`) AND knows which `ConnectChannel`
        /// to pass to `router.approveConnect(origin:channel:)`.
        /// Defaults to `.evm` so any pre-existing caller that
        /// hasn't set the field still compiles and surfaces an EVM
        /// connect.
        let channel: ConnectChannel

        init(
            id: UUID,
            origin: DAppOrigin,
            permissions: [Permission],
            chain: SupportedChain = .ethereum,
            channel: ConnectChannel = .evm
        ) {
            self.id = id
            self.origin = origin
            self.permissions = permissions
            self.chain = chain
            self.channel = channel
        }

        enum Permission: String, Sendable {
            case readAddress
            case signMessages
            case signTransactions
        }
    }

    struct SignMessageRequest: Identifiable, Sendable {
        let id: UUID
        let origin: DAppOrigin
        let messagePreview: String
        let rawHex: String
        let from: String
        let chain: SupportedChain
    }

    struct SignTypedDataRequest: Identifiable, Sendable {
        let id: UUID
        let origin: DAppOrigin
        let rawJSON: String
        let from: String
        let chain: SupportedChain
    }

    struct SendTransactionRequest: Identifiable, Sendable {
        let id: UUID
        let origin: DAppOrigin
        let from: String
        let to: String
        let valueHex: String
        let dataHex: String
        let gasHex: String?
        let chain: SupportedChain
    }

    enum ConnectChannel: Sendable {
        case evm
        case solana
    }
}

/// What we know about the page that originated a request.
struct DAppOrigin: Hashable, Sendable {
    let host: String
    let url: String
    let title: String
    let iconURL: String?

    var isSecureForWalletBridge: Bool {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty else { return false }
        return true
    }

    var securityKey: String {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return "invalid://\(self.host.lowercased())"
        }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    static func host(fromSecurityKey key: String) -> String? {
        URLComponents(string: key)?.host
    }
}
