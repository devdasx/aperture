import Foundation
import SwiftData
import WalletCore

/// Real TON send — native TON and Jetton transfers on TON mainnet.
///
/// Pipeline: fetch the wallet's on-chain `seqno` (toncenter v2
/// `runGetMethod`) → resolve the sender's Jetton wallet contract for token
/// sends (toncenter v3 `/jetton/wallets`) → derive the signing key
/// (`ChainKeyProvider`) → build a `TheOpenNetworkSigningInput` (walletV4R2,
/// `sequenceNumber = seqno`, `expireAt = now + 600`, one
/// `TheOpenNetworkTransfer`) exactly as the proven Stabro signer →
/// `AnySigner.sign(.ton)` → broadcast the base64 BOC via toncenter v2
/// `sendBoc`. All off the main actor (Rule #28).
///
/// **Funds-safety (Rule #16 / Rule #26).** `seqno` is fetched live
/// immediately before signing (a stale seqno is rejected by the network
/// with exit-35); amounts are raw smallest-unit integers (nanoton / Jetton
/// units) — no float drift; the broadcast hash is the real
/// `output.hash` from the signed BOC; status never fabricates a confirm.
/// Nothing key-, mnemonic-, or signature-shaped is ever logged.
///
/// **wallet-core field types** are taken from the linked
/// `WalletCore.swiftinterface` (`TW_TheOpenNetwork_Proto_*`): `Transfer.amount`,
/// `JettonTransfer.jettonAmount`, and `JettonTransfer.forwardAmount` are all
/// `UInt64` in this build — the signing block mirrors Stabro's
/// `signTonTransaction` exactly. `SigningOutput.encoded` is the base64 BOC
/// string (broadcast as-is); `SigningOutput.hash` is `Data` → `.hexString`.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet send on-device. The
/// crypto is wallet-core's; the RPC wiring is exercised by that first send.
enum TonSendService {

    // MARK: - Constants

    /// Message validity window — 10 minutes, the TON-wallet standard
    /// (recipe §gotchas). Absolute unix timestamp added at sign time.
    private static let expireWindowSeconds: UInt32 = 600

    /// Native send mode: pay fees from balance (not from the user's
    /// stated amount) + don't revert the outer message on a recipient
    /// action-phase error. `0x01 | 0x02` (recipe §gotchas).
    private static var nativeSendMode: UInt32 {
        UInt32(TheOpenNetworkSendMode.payFeesSeparately.rawValue
             | TheOpenNetworkSendMode.ignoreActionPhaseErrors.rawValue)
    }

    /// TON attached to a Jetton transfer message to cover the Jetton
    /// wallet's gas — 0.1 TON in nanoton (Stabro line 858).
    private static let jettonAttachedNanoton: UInt64 = 100_000_000

    /// Nanoton forwarded to the recipient as a transfer notification —
    /// 1 nanoton is always safe and what most wallets expect
    /// (recipe §gotchas, Stabro line 855).
    private static let jettonForwardNanoton: UInt64 = 1

    /// Flat fee fallback when live estimation is unavailable —
    /// ~0.05 TON covers a Jetton transfer; native is cheaper but the
    /// estimate already dominates. Honest, never thrown (recipe §feeEstimation).
    private static let fallbackNativeFee = Decimal(string: "0.012")!
    private static let fallbackJettonFee = Decimal(string: "0.05")!

    /// A minimal valid BOC (empty cell). toncenter `estimateFee` rejects an
    /// empty `body` string with HTTP 500 (recipe §gotchas).
    private static let minimalBOC = "te6cckEBAQEAAgAAAEysuc0="

    /// nanoton / Jetton-unit scale used to convert a raw smallest-unit
    /// fee to a TON `Decimal`.
    private static let tonScale = pow(Decimal(10), 9)

    // MARK: - Fees

    /// TON has no slow/normal/fast tiers — a single flat point estimate
    /// (recipe §feeEstimation). We query toncenter `estimateFee` for the
    /// sender; on any failure we fall back to the recipe default. Never
    /// throws on estimate failure.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        guard chain == .ton else { throw .unsupportedChain(chain) }

        // The sender address is needed for the estimate body. If we can't
        // derive it (watch-only / key off-device), surface that honestly —
        // it's the same failure the send would hit.
        let from = try ChainKeyProvider.senderAddress(for: chain, container: container)

        let feeNative = await estimateFee(
            sender: from, isNative: isNative
        ) ?? (isNative ? fallbackNativeFee : fallbackJettonFee)

        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeNative,
                estimatedSeconds: 5,   // TON finalizes ~every 5s
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        ]
    }

    /// Live `estimateFee` against toncenter v2. Returns `nil` on any
    /// failure so the caller applies the recipe default (never throws).
    private nonisolated static func estimateFee(
        sender: String, isNative: Bool
    ) async -> Decimal? {
        let body: [String: Sendable] = [
            "address": sender,
            "body": minimalBOC,
            "ignore_chksig": true,
        ]
        guard let data = try? await RPCClient.shared.callRESTPost(
            chain: .ton, path: "estimateFee", body: body
        ) else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let fees = result["source_fees"] as? [String: Any] else {
            return nil
        }
        // Each fee may decode as Int64 or (rarely) a numeric string —
        // coerce both honestly.
        func nano(_ key: String) -> Int64 {
            if let i = fees[key] as? Int64 { return i }
            if let n = fees[key] as? NSNumber { return n.int64Value }
            if let s = fees[key] as? String, let i = Int64(s) { return i }
            return 0
        }
        let total = nano("in_fwd_fee") + nano("storage_fee")
                  + nano("gas_fee") + nano("fwd_fee")
        guard total > 0 else { return nil }

        var fee = Decimal(total) / tonScale
        // A Jetton transfer also forwards `jettonAttachedNanoton` of TON
        // to the Jetton wallet on top of the network fee — surface the
        // true TON cost the user pays.
        if !isNative {
            fee += Decimal(jettonAttachedNanoton) / tonScale
        }
        return fee
    }

    // MARK: - Send

    /// Build the signing input exactly as the Stabro signer, sign with
    /// wallet-core, and broadcast the base64 BOC. Runs off the main actor.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard chain == .ton else { throw .unsupportedChain(chain) }

        // Derive the sender address first (also fails fast for watch-only).
        let from = try ChainKeyProvider.senderAddress(for: chain, container: container)

        // Seqno — fetched live immediately before signing. A stale seqno
        // is rejected with exit-35 (recipe §gotchas).
        let seqno = try await fetchSeqno(address: from)

        // The raw amount is already the smallest unit (nanoton / Jetton
        // unit) per the API contract — parse to UInt64 (wallet-core's
        // field type in this build).
        guard let amountUnits = UInt64(rawAmount) else {
            throw .signingFailed("Amount exceeds the maximum transferable value.")
        }

        // For a Jetton send, resolve the SENDER's Jetton wallet contract
        // (owner + master). The transfer is addressed to that contract,
        // never the master (recipe §gotchas — wrong address loses funds).
        var jettonWalletDest: String? = nil
        if !isNative {
            guard let master = contract, !master.isEmpty else {
                throw .signingFailed("Missing Jetton master contract for token send.")
            }
            jettonWalletDest = try await fetchJettonWalletAddress(
                owner: from, master: master
            )
        }

        // Derive the signing key (custody-checked, off-main).
        let (key, _) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // ---- Build TheOpenNetworkSigningInput (mirrors Stabro §821–882) ----
        var input = TheOpenNetworkSigningInput()
        input.privateKey = key.data
        input.walletVersion = .walletV4R2
        input.sequenceNumber = UInt32(seqno)
        // NOTE: `Date()` argless init is unavailable in some isolation
        // contexts — use the timestamp form (per the API brief).
        input.expireAt = UInt32(Date().timeIntervalSince1970) + expireWindowSeconds

        var transfer = TheOpenNetworkTransfer()

        if isNative {
            // Native TON transfer — bounceable=false (native never bounces).
            transfer.dest = toAddress
            transfer.amount = amountUnits
            transfer.mode = nativeSendMode
            transfer.bounceable = false
        } else {
            // Jetton transfer — the message targets the sender's Jetton
            // wallet contract; bounceable=true so it can reject + return.
            var jetton = TheOpenNetworkJettonTransfer()
            jetton.jettonAmount = amountUnits
            jetton.toOwner = toAddress
            jetton.responseAddress = from
            jetton.forwardAmount = jettonForwardNanoton

            transfer.dest = jettonWalletDest ?? ""
            transfer.amount = jettonAttachedNanoton   // 0.1 TON for the message
            transfer.mode = nativeSendMode
            transfer.bounceable = true
            transfer.jettonTransfer = jetton
        }

        input.messages = [transfer]

        let output: TheOpenNetworkSigningOutput = AnySigner.sign(input: input, coin: .ton)

        guard output.error == .ok, !output.encoded.isEmpty else {
            // errorMessage is wallet-core's own (no secret material).
            let reason = output.errorMessage.isEmpty
                ? "TON signing returned an empty transaction."
                : output.errorMessage
            throw .signingFailed(reason)
        }

        // output.encoded is the base64 BOC string — broadcast as-is.
        // output.hash is the tx hash (Data) — the real, post-sign hash.
        let bocBase64 = output.encoded
        let txHash = output.hash.hexString

        try await broadcast(bocBase64: bocBase64)

        return ChainSignedTransaction(broadcastPayload: bocBase64, txHash: txHash)
    }

    // MARK: - Status

    /// TON exposes no reliable by-hash transaction lookup on toncenter v2,
    /// and this entry point carries no sender address to scope a
    /// `getTransactions` scan to. Rather than fabricate a confirm
    /// (forbidden — Rule #26), we honestly report `.pending`: the broadcast
    /// hash is the user-facing receipt, and TON finalizes within ~5s of
    /// `sendBoc` acceptance (recipe §statusCheck — "broadcast success IS
    /// the confirmation signal").
    ///
    /// A future enhancement (when the sender address is threaded through)
    /// can scan `getTransactions` for the sender and match `in_msg.hash` /
    /// `transaction_id.hash` against the broadcast hash — the parsing
    /// helpers below are kept ready for that.
    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        guard chain == .ton else { throw .unsupportedChain(chain) }
        return .pending
    }

    /// Best-effort confirmation scan for when a sender address is
    /// available: returns `.confirmed` iff the sender's recent
    /// transactions contain `txHash`, else `.pending`. Not wired into the
    /// container-less `status(chain:txHash:)` entry point above; provided
    /// so a caller that has the sender can verify execution honestly.
    nonisolated static func status(
        sender: String, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        let target = normalizedHashHex(txHash)
        guard !target.isEmpty else { return .pending }
        guard let hashes = try? await recentTransactionHashes(address: sender) else {
            return .pending
        }
        return hashes.contains(target) ? .confirmed(blockNumber: nil) : .pending
    }

    // MARK: - RPC: seqno

    /// Fetch the wallet's `seqno` via toncenter v2 `runGetMethod`
    /// (recipe §preSignContext). Response shape:
    /// `{ "ok": true, "result": { "stack": [[type, value], ...] } }` —
    /// `stack[0][1]` is the seqno as a (possibly hex) string.
    private nonisolated static func fetchSeqno(address: String) async throws(ChainSendError) -> UInt64 {
        let body: [String: Sendable] = [
            "address": address,
            "method": "seqno",
            "stack": [String](),   // empty stack
        ]
        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPost(
                chain: .ton, path: "runGetMethod", body: body
            )
        } catch {
            // `callRESTPost` has typed throws — `error` is `RPCError`.
            throw mapRPC(error, context: "seqno")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            throw .missingContext("seqno")
        }

        // A freshly-created wallet contract that has never sent a tx has
        // no seqno method yet — exit_code != 0. Treat as seqno 0 (the
        // first outgoing message uses seqno 0).
        if let exit = result["exit_code"] as? Int, exit != 0 {
            return 0
        }
        guard let stack = result["stack"] as? [[Any]],
              let first = stack.first, first.count >= 2 else {
            // Empty stack on a never-used wallet → seqno 0.
            return 0
        }
        return parseStackInt(first[1]) ?? 0
    }

    // MARK: - RPC: Jetton wallet address

    /// Resolve the sender's Jetton wallet contract via toncenter v3
    /// `/jetton/wallets?owner_address=&jetton_address=&limit=1`
    /// (recipe §preSignContext step 3). The transfer must target THIS
    /// address, not the master (recipe §gotchas).
    private nonisolated static func fetchJettonWalletAddress(
        owner: String, master: String
    ) async throws(ChainSendError) -> String {
        // tonapi.io / toncenter v3 live under the same `.ton` REST
        // endpoints; the v3 jetton path is served by toncenter.
        let query = [
            URLQueryItem(name: "owner_address", value: owner),
            URLQueryItem(name: "jetton_address", value: master),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(
                chain: .ton, path: "jetton/wallets", query: query
            )
        } catch {
            throw mapRPC(error, context: "jettonWallet")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wallets = json["jetton_wallets"] as? [[String: Any]],
              let first = wallets.first,
              let address = first["address"] as? String, !address.isEmpty else {
            // No Jetton wallet means the sender holds none of this token —
            // honest failure rather than a transfer into the void.
            throw .missingContext("jettonWallet")
        }
        return address
    }

    // MARK: - RPC: broadcast

    /// Broadcast the signed base64 BOC via toncenter v2 `sendBoc`
    /// (recipe §broadcast). Body `{ "boc": "<base64>" }`. A node rejection
    /// surfaces its real reason (Rule #16).
    private nonisolated static func broadcast(bocBase64: String) async throws(ChainSendError) {
        let body: [String: Sendable] = ["boc": bocBase64]
        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPost(
                chain: .ton, path: "sendBoc", body: body
            )
        } catch {
            // Typed throws — `error` is `RPCError`. Surface its real reason.
            throw .broadcastRejected(broadcastMessage(for: error))
        }

        // toncenter returns `{ "ok": true, "result": {...} }` on success;
        // on failure either `ok: false` or an `error` string. Surface the
        // honest reason instead of assuming success.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A 2xx with an unparseable body — assume accepted (toncenter
            // returns 2xx only on mempool acceptance).
            return
        }
        if let ok = json["ok"] as? Bool, ok { return }
        if let err = json["error"] as? String {
            throw .broadcastRejected(broadcastMessage(forText: err))
        }
        // No explicit ok/error but a `result` present → accepted.
        if json["result"] != nil { return }
        throw .broadcastRejected("The network rejected the transaction. Try again.")
    }

    // MARK: - RPC: recent transactions (status best-effort)

    /// Fetch the sender's recent transaction hashes (hex) via toncenter v2
    /// `getTransactions`. We compare the broadcast hash against each tx's
    /// `transaction_id.hash` and `in_msg.hash` (both base64 from the node,
    /// converted to hex).
    private nonisolated static func recentTransactionHashes(address: String) async throws(ChainSendError) -> Set<String> {
        let query = [
            URLQueryItem(name: "address", value: address),
            URLQueryItem(name: "limit", value: "20"),
        ]
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(
                chain: .ton, path: "getTransactions", query: query
            )
        } catch {
            // Typed throws — `error` is `RPCError`.
            throw mapRPC(error, context: "getTransactions")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let txs = json["result"] as? [[String: Any]] else {
            return []
        }

        var hashes = Set<String>()
        for tx in txs {
            if let txid = tx["transaction_id"] as? [String: Any],
               let h = txid["hash"] as? String {
                hashes.insert(base64HashToHex(h))
            }
            if let inMsg = tx["in_msg"] as? [String: Any],
               let h = inMsg["hash"] as? String {
                hashes.insert(base64HashToHex(h))
            }
        }
        return hashes
    }

    // MARK: - Parsing helpers

    /// Parse a TON stack value (String or Int) to UInt64. Stack numbers
    /// are commonly hex-prefixed strings ("0x5"), sometimes plain decimal
    /// strings, sometimes JSON numbers.
    private nonisolated static func parseStackInt(_ value: Any) -> UInt64? {
        if let n = value as? NSNumber { return n.uint64Value }
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16)
        }
        return UInt64(trimmed) ?? UInt64(trimmed, radix: 16)
    }

    /// Normalize a caller-supplied hash to lowercase hex without 0x.
    private nonisolated static func normalizedHashHex(_ hash: String) -> String {
        let clean = hash.hasPrefix("0x") || hash.hasPrefix("0X") ? String(hash.dropFirst(2)) : hash
        return clean.lowercased()
    }

    /// Convert a base64 (or base64url) 32-byte hash from the node to hex.
    /// Falls back to the lowercased input when it isn't valid base64.
    private nonisolated static func base64HashToHex(_ value: String) -> String {
        var s = value.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4 for Foundation's decoder.
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: s) else { return value.lowercased() }
        return data.hexString.lowercased()
    }

    // MARK: - Error mapping

    private nonisolated static func mapRPC(_ error: RPCError, context: String) -> ChainSendError {
        switch error {
        case .cancelled, .network, .allEndpointsFailed, .rateLimited:
            // The endpoints are unreachable / saturated right now — the UI
            // should say "try again", not "couldn't prepare".
            return .rpcUnavailable
        case .noEndpoint, .invalidResponse, .decodingFailed, .rpcError:
            // A real pre-sign fetch failed in a way that names the step.
            return .missingContext(context)
        }
    }

    private nonisolated static func broadcastMessage(for error: RPCError) -> String {
        broadcastMessage(forText: "\(error)")
    }

    private nonisolated static func broadcastMessage(forText text: String) -> String {
        let raw = text.lowercased()
        if raw.contains("exit") && raw.contains("35") { return "The wallet's sequence number changed. Try again." }
        if raw.contains("insufficient") || raw.contains("balance") { return "Balance is less than the amount plus the network fee." }
        if raw.contains("bag of cells") || raw.contains("boc") { return "The signed transaction was malformed. Try again." }
        if raw.contains("expire") { return "The transaction window expired. Try again." }
        return "The network rejected the transaction. Try again."
    }
}
