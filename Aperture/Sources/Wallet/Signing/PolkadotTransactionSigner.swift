import Foundation
import WalletCore

enum PolkadotSigningNetwork: String, Sendable, Hashable {
    case relay
    case assetHub

    var genesisHashHex: String {
        switch self {
        case .relay:
            return "91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb49219da7a70ce90c3"
        case .assetHub:
            return "68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f"
        }
    }

    var balancesPalletIndex: UInt8 {
        switch self {
        case .relay: return 0x05
        case .assetHub: return 0x0a
        }
    }

    var transferKeepAliveCallIndex: UInt8 { 0x03 }

    /// Asset Hub `pallet_assets` index (live metadata `spec_name=statemint`).
    var assetsPalletIndex: UInt8? {
        switch self {
        case .relay: return nil
        case .assetHub: return 50 // 0x32
        }
    }

    /// `assets.transfer_keep_alive` call index.
    var assetsTransferKeepAliveCallIndex: UInt8 { 0x09 }

    /// `assets.transfer_all` call index (send-max path).
    var assetsTransferAllCallIndex: UInt8 { 0x20 }

    /// `frame_utility` pallet index (Polkadot relay vs Asset Hub metadata).
    var utilityPalletIndex: UInt8 {
        switch self {
        case .relay: return 26
        case .assetHub: return 40
        }
    }

    /// `utility.batch_all` call index (atomic multi-call; fails all on error).
    var batchAllCallIndex: UInt8 { 0x02 }

    /// Asset Hub's `ChargeAssetTxPayment` signed extension encodes
    /// `{ tip, asset_id }`; `asset_id = None` means fees are paid in native DOT.
    var signedExtraIncludesFeeAssetID: Bool {
        self == .assetHub
    }
}

/// Builds + signs Polkadot Asset Hub transactions from `SendDraft` + JIT data:
/// - native DOT → `balances.transferKeepAlive`
/// - Asset Hub tokens (USDT 1984, USDC 1337, …) → `assets.transferKeepAlive`
///   / `assets.transferAll` (send-max)
///
/// This intentionally does not use WalletCore's Polkadot extrinsic builder.
/// Polkadot mainnet now includes the `CheckMetadataHash` signed extension,
/// which adds a mode byte to signed extras. WalletCore 4.6.x's Polkadot proto
/// has no field for that extension, so its otherwise-valid signature is over
/// the wrong payload and current nodes reject it as `Invalid Transaction`.
/// We still use WalletCore's private-key/public-key/signature primitives, then
/// encode the current SCALE extrinsic directly.
///
/// **Fee model (matrix §G11, doc-grounded — fees):** weight-based
/// inclusion fee computed by the runtime; the only sender lever is the
/// optional `tip` (`FeeChoice.polkadotTipPlancks`). Fees remain in native DOT
/// (`ChargeAssetTxPayment.asset_id = None`) even when moving USDT/USDC.
///
/// Aperture shows Polkadot balances from Asset Hub, so production sends
/// target Asset Hub too. Tests still exercise relay-chain constants to keep
/// the SCALE helpers honest across both Substrate runtimes.
///
/// Output: `output.encoded` is the SCALE-encoded signed extrinsic for
/// `author_submitExtrinsic` (0x-hex); the node assigns the hash.
enum PolkadotTransactionSigner {

    /// Mortal-era period (~6.4 min at 64 blocks) so a stuck tx expires.
    private static let mortalEraPeriod: UInt64 = 64
    private static let signedExtrinsicVersion: UInt8 = 0x84
    private static let ed25519SignatureKind: UInt8 = 0x00
    private static let multiAddressAccountIdKind: UInt8 = 0x00
    private static let checkMetadataHashDisabledMode: UInt8 = 0x00
    private static let optionNone: UInt8 = 0x00

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .polkadot else {
            throw SigningError.malformedDraft("Polkadot signer used for \(draft.chain.rawValue)")
        }
        // BUG-001: every recipient is encoded into the call (single transfer
        // or utility.batch_all of transferKeepAlive / assets.transfer* calls).
        let recipients = try SendRecipientSigning.requireRecipients(draft)
        guard let specVersion = jit.polkadotSpecVersion,
              let txVersion = jit.polkadotTransactionVersion else {
            throw SigningError.justInTimeRefreshFailed("Polkadot runtime version not refreshed")
        }
        guard let blockHashHex = jit.polkadotBlockHash,
              let blockHash = SigningNumeric.hexToData(blockHashHex.hasPrefix("0x") ? String(blockHashHex.dropFirst(2)) : blockHashHex) else {
            throw SigningError.justInTimeRefreshFailed("Polkadot block hash not refreshed")
        }
        guard let blockNumber = jit.polkadotBlockNumber, blockNumber > 0 else {
            throw SigningError.justInTimeRefreshFailed("Polkadot block number not refreshed")
        }
        guard let nonce = jit.polkadotNonce else {
            throw SigningError.justInTimeRefreshFailed("Polkadot nonce not refreshed")
        }
        // Asset Hub tokens always target Asset Hub (not the relay). Native DOT
        // sends also use Asset Hub in production; tests may still pass `.relay`.
        let network: PolkadotSigningNetwork = draft.isTokenSend
            ? .assetHub
            : (jit.polkadotNetwork ?? .assetHub)
        let genesisHashHex = jit.polkadotGenesisHash ?? network.genesisHashHex
        guard let genesisHash = SigningNumeric.hexToData(stripped0x(genesisHashHex)) else {
            throw SigningError.signingFailed("Polkadot genesis hash invalid")
        }

        let assetId: UInt32?
        if draft.isTokenSend {
            assetId = try resolveAssetHubAssetId(draft: draft)
        } else {
            assetId = nil
        }

        var transferCalls: [Data] = []
        transferCalls.reserveCapacity(recipients.count)
        for (index, r) in recipients.enumerated() {
            guard let accountId = SS58.decodeAccountId(r.address) else {
                throw SigningError.malformedDraft("invalid Polkadot recipient address")
            }
            let dest = Data(accountId)
            if let assetId {
                // BUG-011: Asset Hub `pallet_assets` transfers (USDT/USDC/…).
                if draft.isMaxSend, recipients.count == 1, index == 0 {
                    transferCalls.append(
                        try assetsTransferAllCall(
                            assetId: assetId,
                            toAccountId: dest,
                            keepAlive: true,
                            network: network
                        )
                    )
                } else {
                    guard let value = SigningAmount.uint64(
                        display: r.amount,
                        decimals: draft.effectiveDecimals
                    ) else {
                        throw SigningError.malformedDraft("invalid Asset Hub token amount")
                    }
                    transferCalls.append(
                        try assetsTransferKeepAliveCall(
                            assetId: assetId,
                            toAccountId: dest,
                            amount: value,
                            network: network
                        )
                    )
                }
            } else {
                guard let value = SigningAmount.uint64(
                    display: r.amount,
                    decimals: draft.chain.nativeDecimals
                ) else {
                    throw SigningError.malformedDraft("invalid DOT amount")
                }
                transferCalls.append(
                    transferKeepAliveCall(toAccountId: dest, value: value, network: network)
                )
            }
        }
        let tip = draft.fee.polkadotTipPlancks.flatMap(SigningAmount.uint64) ?? 0

        let publicKey = privateKey.getPublicKeyEd25519().data
        let era = mortalEra(blockNumber: blockNumber, period: mortalEraPeriod)
        let call: Data
        if transferCalls.count == 1, let only = transferCalls.first {
            call = only
        } else {
            call = batchAllCall(innerCalls: transferCalls, network: network)
        }
        let signedExtra = signedExtra(
            era: era,
            nonce: nonce,
            tip: tip,
            network: network,
            includeMetadataHashMode: true
        )
        let additional = additionalSigned(
            specVersion: specVersion,
            transactionVersion: txVersion,
            genesisHash: genesisHash,
            blockHash: blockHash,
            includeMetadataHash: true
        )
        let payload = call + signedExtra + additional
        let signable = payload.count > 256 ? BLAKE2b.hash(payload, outlen: 32) : payload
        guard let signature = privateKey.sign(digest: signable, curve: .ed25519), signature.count == 64 else {
            throw SigningError.signingFailed("Polkadot signature failed")
        }

        let rawData = signedExtrinsic(
            publicKey: publicKey,
            signature: signature,
            signedExtra: signedExtra,
            call: call
        )
        guard !rawData.isEmpty else { throw SigningError.signingFailed("Polkadot: empty signer output") }

        return SignedTransaction(
            rawData: rawData,
            rawHex: SigningNumeric.hexString0x(rawData), // 0x-hex for author_submitExtrinsic
            txHash: ""                                   // node assigns the hash
        )
    }

    // MARK: - SCALE encoding

    static func transferKeepAliveCall(toAccountId: Data, value: UInt64, network: PolkadotSigningNetwork) -> Data {
        var out = Data([network.balancesPalletIndex, network.transferKeepAliveCallIndex])
        out.append(multiAddress(accountId: toAccountId))
        out.append(compact(value))
        return out
    }

    /// Asset Hub `assets.transfer_keep_alive(id, target, amount)`.
    /// SCALE (live metadata): pallet=50 | call=9 | Compact<u32> id |
    /// MultiAddress | Compact<u128> amount.
    static func assetsTransferKeepAliveCall(
        assetId: UInt32,
        toAccountId: Data,
        amount: UInt64,
        network: PolkadotSigningNetwork
    ) throws -> Data {
        guard let pallet = network.assetsPalletIndex else {
            throw SigningError.signingFailed("Assets pallet is only available on Asset Hub")
        }
        var out = Data([pallet, network.assetsTransferKeepAliveCallIndex])
        out.append(compact(UInt64(assetId)))
        out.append(multiAddress(accountId: toAccountId))
        out.append(compact(amount))
        return out
    }

    /// Asset Hub `assets.transfer_all(id, dest, keep_alive)`.
    static func assetsTransferAllCall(
        assetId: UInt32,
        toAccountId: Data,
        keepAlive: Bool,
        network: PolkadotSigningNetwork
    ) throws -> Data {
        guard let pallet = network.assetsPalletIndex else {
            throw SigningError.signingFailed("Assets pallet is only available on Asset Hub")
        }
        var out = Data([pallet, network.assetsTransferAllCallIndex])
        out.append(compact(UInt64(assetId)))
        out.append(multiAddress(accountId: toAccountId))
        out.append(keepAlive ? 0x01 : 0x00)
        return out
    }

    /// `utility.batch_all(calls)` — atomic multi-transfer (BUG-001).
    /// SCALE: pallet | call_index | Compact<u32> len | Call… (raw call bytes).
    static func batchAllCall(innerCalls: [Data], network: PolkadotSigningNetwork) -> Data {
        var out = Data([network.utilityPalletIndex, network.batchAllCallIndex])
        out.append(compact(UInt64(innerCalls.count)))
        for call in innerCalls {
            out.append(call)
        }
        return out
    }

    /// Resolve Asset Hub asset id from `SendDraft.tokenContract`
    /// (catalog stores `"1337"` / `"1984"`).
    static func resolveAssetHubAssetId(draft: SendDraft) throws -> UInt32 {
        guard let raw = draft.tokenContract?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw SigningError.malformedDraft("Asset Hub token id missing")
        }
        // Prefer registry match (symbol/id), then plain numeric contract.
        if let entry = PolkadotAssetRegistry.entry(assetIdString: raw)
            ?? PolkadotAssetRegistry.entry(symbol: draft.tokenSymbol ?? "") {
            return entry.assetId
        }
        guard let assetId = UInt32(raw) else {
            throw SigningError.malformedDraft("invalid Asset Hub asset id: \(raw)")
        }
        return assetId
    }

    static func signedExtra(
        era: Data,
        nonce: UInt64,
        tip: UInt64,
        network: PolkadotSigningNetwork,
        includeMetadataHashMode: Bool
    ) -> Data {
        var out = Data()
        out.append(era)
        out.append(compact(nonce))
        out.append(compact(tip))
        if network.signedExtraIncludesFeeAssetID {
            out.append(optionNone)
        }
        if includeMetadataHashMode {
            out.append(checkMetadataHashDisabledMode)
        }
        return out
    }

    static func additionalSigned(
        specVersion: UInt32,
        transactionVersion: UInt32,
        genesisHash: Data,
        blockHash: Data,
        includeMetadataHash: Bool
    ) -> Data {
        var out = Data()
        out.append(littleEndian(specVersion))
        out.append(littleEndian(transactionVersion))
        out.append(genesisHash)
        out.append(blockHash)
        if includeMetadataHash {
            out.append(optionNone)
        }
        return out
    }

    static func signedExtrinsic(
        publicKey: Data,
        signature: Data,
        signedExtra: Data,
        call: Data
    ) -> Data {
        var body = Data([signedExtrinsicVersion])
        body.append(multiAddress(accountId: publicKey))
        body.append(ed25519SignatureKind)
        body.append(signature)
        body.append(signedExtra)
        body.append(call)

        var out = compact(UInt64(body.count))
        out.append(body)
        return out
    }

    static func mortalEra(blockNumber: UInt64, period requestedPeriod: UInt64) -> Data {
        let period = min(max(nextPowerOfTwo(requestedPeriod), 4), 1 << 16)
        let phase = blockNumber % period
        let quantizeFactor = max(period >> 12, 1)
        let quantizedPhase = (phase / quantizeFactor) * quantizeFactor
        let trailing = UInt64(period.trailingZeroBitCount)
        let encoded = min(15, max(1, trailing - 1)) | ((quantizedPhase / quantizeFactor) << 4)
        return Data([UInt8(encoded & 0xff), UInt8((encoded >> 8) & 0xff)])
    }

    static func compact(_ value: UInt64) -> Data {
        if value < 1 << 6 {
            return Data([UInt8(value << 2)])
        }
        if value < 1 << 14 {
            let encoded = UInt16(value << 2) | 0x01
            return Data([UInt8(encoded & 0xff), UInt8((encoded >> 8) & 0xff)])
        }
        if value < 1 << 30 {
            let encoded = UInt32(value << 2) | 0x02
            return Data([
                UInt8(encoded & 0xff),
                UInt8((encoded >> 8) & 0xff),
                UInt8((encoded >> 16) & 0xff),
                UInt8((encoded >> 24) & 0xff)
            ])
        }

        var bytes: [UInt8] = []
        var n = value
        while n > 0 {
            bytes.append(UInt8(n & 0xff))
            n >>= 8
        }
        let prefix = UInt8(((bytes.count - 4) << 2) | 0x03)
        return Data([prefix] + bytes)
    }

    private static func multiAddress(accountId: Data) -> Data {
        var out = Data([multiAddressAccountIdKind])
        out.append(accountId)
        return out
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }

    private static func stripped0x(_ hex: String) -> String {
        (hex.hasPrefix("0x") || hex.hasPrefix("0X")) ? String(hex.dropFirst(2)) : hex
    }

    private static func nextPowerOfTwo(_ value: UInt64) -> UInt64 {
        guard value > 1 else { return 1 }
        var n: UInt64 = 1
        while n < value { n <<= 1 }
        return n
    }
}

actor PolkadotAssetHubRPCClient {
    static let shared = PolkadotAssetHubRPCClient()

    private let endpoints = [
        URL(string: "https://polkadot-asset-hub-rpc.polkadot.io")!,
        URL(string: "https://statemint.api.onfinality.io/public")!,
        URL(string: "https://asset-hub-polkadot-rpc.n.dwellir.com")!,
    ]
    private let session: URLSession
    private var requestID = 0

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: configuration)
        }
    }

    func runtimeVersion() async throws -> (specVersion: UInt32, transactionVersion: UInt32) {
        let result = try await callJSON(method: "state_getRuntimeVersion", params: [])
        guard let rv = result as? [String: Any],
              let specVersion = (rv["specVersion"] as? NSNumber)?.uint32Value,
              let transactionVersion = (rv["transactionVersion"] as? NSNumber)?.uint32Value else {
            throw RPCError.invalidResponse("Polkadot Asset Hub runtime version unavailable")
        }
        return (specVersion, transactionVersion)
    }

    func finalizedHead() async throws -> String {
        try await callJSONString(method: "chain_getFinalizedHead", params: [])
    }

    func genesisHash() async throws -> String {
        try await callJSONString(method: "chain_getBlockHash", params: [0])
    }

    func headerNumber(hash: String) async throws -> UInt64 {
        let result = try await callJSON(method: "chain_getHeader", params: [hash])
        guard let header = result as? [String: Any],
              let numberHex = header["number"] as? String,
              let number = UInt64(Self.stripped0x(numberHex), radix: 16) else {
            throw RPCError.invalidResponse("Polkadot Asset Hub header unavailable")
        }
        return number
    }

    func accountNextIndex(address: String) async throws -> UInt64 {
        try await callJSONUInt64(method: "system_accountNextIndex", params: [address])
    }

    func submitExtrinsic(_ rawHex: String) async throws -> String {
        try await callJSONString(method: "author_submitExtrinsic", params: [rawHex])
    }

    private func callJSONString(method: String, params: [Any]) async throws -> String {
        let result = try await callJSON(method: method, params: params)
        guard let string = result as? String else {
            throw RPCError.invalidResponse("\(method) result was not a string")
        }
        return string
    }

    private func callJSONUInt64(method: String, params: [Any]) async throws -> UInt64 {
        let result = try await callJSON(method: method, params: params)
        if let number = result as? NSNumber { return number.uint64Value }
        if let string = result as? String, let number = UInt64(string) { return number }
        throw RPCError.invalidResponse("\(method) result was not a number")
    }

    private func callJSON(method: String, params: [Any]) async throws -> Any {
        var lastError: RPCError = .allEndpointsFailed(.polkadot)
        for endpoint in endpoints {
            do {
                requestID += 1
                let id = requestID
                let body: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": method,
                    "params": params,
                ]
                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    throw RPCError.invalidResponse("Failed to encode Polkadot Asset Hub JSON-RPC envelope")
                }

                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
                request.httpBody = bodyData

                let responseData: Data
                let response: URLResponse
                do {
                    (responseData, response) = try await session.apertureData(
                        for: request,
                        family: "rpc-json",
                        operation: "Polkadot Asset Hub \(method)",
                        metadata: [
                            "chain": "polkadot",
                            "source": "PolkadotAssetHubRPCClient",
                            "endpoint": endpoint.host ?? endpoint.absoluteString
                        ]
                    )
                } catch let urlError as URLError {
                    if urlError.code == .cancelled { throw RPCError.cancelled }
                    throw RPCError.network(urlError.localizedDescription)
                } catch is CancellationError {
                    throw RPCError.cancelled
                } catch {
                    throw RPCError.network(error.localizedDescription)
                }

                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 {
                        throw RPCError.rateLimited(retryAfter: Self.retryAfterDate(from: http))
                    }
                    if !(200..<300).contains(http.statusCode) {
                        if [408, 502, 503, 504].contains(http.statusCode)
                            || (520...527).contains(http.statusCode) {
                            throw RPCError.network("HTTP \(http.statusCode) from \(endpoint.host ?? endpoint.absoluteString)")
                        }
                        throw RPCError.invalidResponse("HTTP \(http.statusCode) from \(endpoint.host ?? endpoint.absoluteString)")
                    }
                }

                guard let decoded = try? JSONSerialization.jsonObject(with: responseData),
                      let envelope = decoded as? [String: Any] else {
                    throw RPCError.decodingFailed("Polkadot Asset Hub response did not parse as JSON")
                }
                if let errorDict = envelope["error"] as? [String: Any] {
                    let code = (errorDict["code"] as? NSNumber)?.intValue ?? -1
                    let message = errorDict["message"] as? String ?? "unknown"
                    throw RPCError.rpcError(code: code, message: message)
                }
                guard Self.responseID(in: envelope, matches: id) else {
                    throw RPCError.invalidResponse("JSON-RPC response id does not match request id \(id)")
                }
                guard let result = envelope["result"] else {
                    throw RPCError.invalidResponse("JSON-RPC response missing `result`")
                }
                return result
            } catch let rpc as RPCError {
                if case .cancelled = rpc { throw rpc }
                if case .rpcError = rpc { throw rpc }
                lastError = rpc
                continue
            } catch {
                lastError = .network(error.localizedDescription)
                continue
            }
        }
        throw lastError
    }

    private static func responseID(in envelope: [String: Any], matches requestID: Int) -> Bool {
        if let number = envelope["id"] as? NSNumber {
            return number.intValue == requestID
        }
        if let string = envelope["id"] as? String {
            return Int(string) == requestID
        }
        return false
    }

    private static func retryAfterDate(from response: HTTPURLResponse) -> Date {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header) {
            return Date().addingTimeInterval(seconds)
        }
        return Date().addingTimeInterval(60)
    }

    private static func stripped0x(_ hex: String) -> String {
        (hex.hasPrefix("0x") || hex.hasPrefix("0X")) ? String(hex.dropFirst(2)) : hex
    }
}
