import Foundation
import OSLog
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

    /// Connection state per page host. Once a dApp's host is in the
    /// allowed set, `eth_accounts` returns the active wallet's address
    /// without prompting again.
    private var connectedHosts: Set<String> = []

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
            title: (pageTitle?.isEmpty == false) ? pageTitle! : (pageURL?.host ?? "dApp"),
            iconURL: pageURL.flatMap { faviconURL(for: $0) }
        )
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
            return .success(connectedHosts.contains(origin.host) ? [activeAddress()].compactMap { $0 } : [])
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
                    message: "Unrecognized chain ID \(requestedHex) — Aperture doesn't support this chain"
                ))
            }
            selectedEVMChain = chain
            return .success(activeChainIdHex())
        case "wallet_addEthereumChain":
            // We support every registered chain natively; no-op.
            return .success(NSNull())
        case "personal_sign", "eth_sign":
            guard connectedHosts.contains(origin.host) else { return .failure(.unauthorized) }
            return await requestEVMSignMessage(params: params, origin: origin, method: method)
        case "eth_signTypedData_v4", "eth_signTypedData":
            guard connectedHosts.contains(origin.host) else { return .failure(.unauthorized) }
            return await requestEVMSignTypedData(params: params, origin: origin)
        case "eth_sendTransaction":
            guard connectedHosts.contains(origin.host) else { return .failure(.unauthorized) }
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
        if connectedHosts.contains(origin.host),
           let addr = activeAddress() {
            return .success([addr])
        }
        // Otherwise present `DAppConnectSheet` and await the user's
        // choice via the pending queue.
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.connect(.init(
                id: UUID(),
                origin: origin,
                permissions: [.readAddress, .signMessages, .signTransactions]
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
        if method == "personal_sign" {
            guard let msg = params.first as? String else { return .failure(.invalidParams) }
            messageHex = msg
        } else {
            guard params.count >= 2, let msg = params[1] as? String else { return .failure(.invalidParams) }
            messageHex = msg
        }
        let preview = Self.decodeMessage(hex: messageHex)
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.signMessage(.init(
                id: UUID(),
                origin: origin,
                messagePreview: preview,
                rawHex: messageHex,
                chain: activeChain()
            )), continuation: cont)
        }
    }

    private func requestEVMSignTypedData(params: [Any], origin: DAppOrigin) async -> DAppRequestResult {
        // eth_signTypedData_v4: [address, jsonOrObject]
        guard params.count >= 2 else { return .failure(.invalidParams) }
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
                chain: activeChain()
            )), continuation: cont)
        }
    }

    private func requestEVMSendTransaction(params: [Any], origin: DAppOrigin) async -> DAppRequestResult {
        guard let tx = params.first as? [String: Any] else { return .failure(.invalidParams) }
        let from = (tx["from"] as? String) ?? ""
        let to = (tx["to"] as? String) ?? ""
        let valueHex = (tx["value"] as? String) ?? "0x0"
        let dataHex = (tx["data"] as? String) ?? "0x"
        let gasHex = tx["gas"] as? String
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.sendTransaction(.init(
                id: UUID(),
                origin: origin,
                from: from,
                to: to,
                valueHex: valueHex,
                dataHex: dataHex,
                gasHex: gasHex,
                chain: activeChain()
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
            connectedHosts.remove(origin.host)
            return .success(NSNull())
        case "signMessage":
            guard connectedHosts.contains(origin.host) else { return .failure(.unauthorized) }
            return await requestSolanaSignMessage(params: params, origin: origin)
        case "signTransaction", "signAndSendTransaction", "signAllTransactions":
            guard connectedHosts.contains(origin.host) else { return .failure(.unauthorized) }
            return await requestSolanaSignTransaction(params: params, origin: origin, method: method)
        default:
            return .failure(.unsupportedMethod)
        }
    }

    private func requestSolanaConnect(origin: DAppOrigin) async -> DAppRequestResult {
        if connectedHosts.contains(origin.host),
           let pubkey = solanaAddress() {
            return .success(["publicKey": pubkey])
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.connect(.init(
                id: UUID(),
                origin: origin,
                permissions: [.readAddress, .signMessages, .signTransactions],
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
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.signMessage(.init(
                id: UUID(),
                origin: origin,
                messagePreview: preview,
                rawHex: hex,
                chain: .solana
            )), continuation: cont)
        }
    }

    private func requestSolanaSignTransaction(
        params: [Any],
        origin: DAppOrigin,
        method: String
    ) async -> DAppRequestResult {
        return await withCheckedContinuation { (cont: CheckedContinuation<DAppRequestResult, Never>) in
            enqueue(.sendTransaction(.init(
                id: UUID(),
                origin: origin,
                from: solanaAddress() ?? "",
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
    /// the allowed set; returns the address (EVM channel) or
    /// `{publicKey:...}` (Solana channel) via the continuation.
    func approveConnect(host: String, channel: ConnectChannel) {
        connectedHosts.insert(host)
        let addr: any Sendable
        switch channel {
        case .evm:
            addr = [activeAddress()].compactMap { $0 } as [String]
        case .solana:
            addr = ["publicKey": solanaAddress() ?? ""]
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

    // MARK: - Active wallet helpers

    private func activeAddress() -> String? {
        ActiveWalletReader.shared.currentEVMAddress()
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
        .kavaEvm: 2222
    ]

    private func activeChainIdInt() -> Int {
        Self.evmChainIds[activeChain()] ?? 1
    }

    private func activeChainIdHex() -> String {
        "0x" + String(activeChainIdInt(), radix: 16)
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
        /// Which channel the dApp is asking to connect through.
        /// Added 2026-06-10 so the confirmation sheet
        /// (`DAppConnectSheet`) knows whether to surface the EVM
        /// address (`currentEVMAddress`) or the Solana address
        /// (`currentSolanaAddress`) AND knows which `ConnectChannel`
        /// to pass to `router.approveConnect(host:channel:)`.
        /// Defaults to `.evm` so any pre-existing caller that
        /// hasn't set the field still compiles and surfaces an EVM
        /// connect.
        let channel: ConnectChannel

        init(
            id: UUID,
            origin: DAppOrigin,
            permissions: [Permission],
            channel: ConnectChannel = .evm
        ) {
            self.id = id
            self.origin = origin
            self.permissions = permissions
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
        let chain: SupportedChain
    }

    struct SignTypedDataRequest: Identifiable, Sendable {
        let id: UUID
        let origin: DAppOrigin
        let rawJSON: String
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
}
