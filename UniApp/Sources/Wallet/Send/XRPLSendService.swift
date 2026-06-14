import Foundation
import SwiftData
import WalletCore

/// Real XRP Ledger send — native XRP only (Payment transaction). Issued
/// currencies (trust-line IOUs) are out of scope: a non-native send throws
/// `.unsupportedChain`.
///
/// Pipeline (per `/tmp/recipe-xrpl.md`):
///   1. `account_info` → the account `Sequence` (nonce equivalent) and the
///      current ledger index (`ledger_current_index`) for `lastLedgerSequence`.
///   2. `signingMaterial` → the on-device secp256k1 key + sender `r…` address.
///   3. Build a `RippleSigningInput` exactly as the proven Stabro signer
///      (`TransactionSigner.signRippleTransaction`, lines 917–960): fee in
///      drops (`Int64`), `sequence` (`UInt32`), `account`, `privateKey`, an
///      `opPayment` carrying `destination` + `amount = Int64(drops)` +
///      optional `destinationTag` (from `memo` when it parses as `UInt32`),
///      and `lastLedgerSequence` (current + buffer).
///   4. `AnySigner.sign(.xrp)` → `output.encoded` (the raw signed bytes).
///   5. Broadcast JSON-RPC `submit` with `tx_blob: output.encoded.hexString`;
///      accept `engine_result` == "tesSUCCESS" (or "terQUEUED"); any other
///      code surfaces its real `engine_result_message`.
///   6. tx hash = `Hash.sha512_256(output.encoded).hexString.uppercased()`.
///   7. `tx` polls validation status.
///
/// **Fee model (no gas, no tiers).** XRPL uses a flat per-transaction base
/// fee (~12 drops). `loadFees` returns a single `.normal` option using the
/// server's load-adjusted `base_fee` when reachable, falling back to 12
/// drops — it never throws on an estimate failure (Rule #16 / Rule #26).
///
/// **XRPL JSON-RPC shape.** rippled's HTTP API takes `params` as a
/// SINGLE-ELEMENT ARRAY of one object and never echoes the JSON-RPC `id`,
/// so every call passes `validatesIDEcho: false` (mirrors the proven
/// `XRPLTransactionAdapter`). The payload lives under the `result` key.
///
/// **Off-main (Rule #28).** Every RPC + the seed-stretch + signing run off
/// the main actor; only the small `Sendable` result crosses back. Nothing
/// key-, mnemonic-, or signature-shaped is ever logged.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device — the
/// crypto is wallet-core's; this wiring is exercised by that first send.
enum XRPLSendService {

    // MARK: - Constants (per recipe)

    /// XRPL standard minimum / fallback transaction fee, in drops.
    private static let baseFeeDrops: Int64 = 12
    /// Drops per XRP (1 XRP = 1,000,000 drops).
    private static let dropsPerXRP: Decimal = {
        var result = Decimal(1)
        for _ in 0..<6 { result *= 10 }
        return result
    }()
    /// `lastLedgerSequence` buffer above the current ledger — gives the
    /// transaction a validity window (recipe gotcha #5). 20 ledgers at
    /// ~4 s/ledger ≈ 80 s, comfortably covering broadcast + a few retries.
    private static let lastLedgerBuffer: UInt32 = 20

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    /// Estimate the XRPL fee in XRP. There are no speed tiers — returns a
    /// single `.normal` option. Never throws on an estimate failure; uses
    /// the 12-drop base fee so the Send flow always has a number.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        guard isNative else { throw .unsupportedChain(chain) }

        let feeDrops = await fetchBaseFeeDrops()
        let feeXRP = Decimal(feeDrops) / dropsPerXRP
        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeXRP,
                estimatedSeconds: 5,   // a ledger closes every ~3–4 s
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        ]
    }

    /// Full send: fetch the account sequence + current ledger, derive the
    /// key, build + sign the `RippleSigningInput` exactly as Stabro,
    /// broadcast via `submit`, and return the locally-derived tx hash.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard isNative else { throw .unsupportedChain(chain) }

        // `rawAmount` is already in drops; it must be a positive Int64.
        guard let amountDrops = Int64(rawAmount), amountDrops > 0 else {
            throw .signingFailed("Invalid XRP amount.")
        }

        // 1. Sender address (off-main; the key is dropped within the call).
        let from = try ChainKeyProvider.senderAddress(for: chain, container: container)

        // 2. Account context — sequence (nonce) + the current ledger index
        //    for lastLedgerSequence. Fetched immediately before signing so
        //    the sequence hasn't gone stale (recipe gotcha #4/#5).
        let context = try await fetchAccountContext(address: from)

        // 3. Fee in drops — the server's load-adjusted base fee, else 12.
        let feeDrops = await fetchBaseFeeDrops()

        // 4. Signing material (mnemonic → key + sender address), off-main.
        let (key, fromAddress) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // 5. Build the RippleSigningInput — mirrors Stabro
        //    `signRippleTransaction` (TransactionSigner.swift:917–960).
        let operation = RippleOperationPayment.with {
            $0.destination = toAddress
            // rawAmount is in drops (the smallest XRP unit); proto amount is Int64.
            $0.amount = amountDrops
            // Destination tag (required for exchange deposits) — only when
            // `memo` is a valid UInt32. XRPL uses DestinationTag, NOT the
            // Memo array, for exchange routing (recipe gotcha #1/#10).
            if let memo, let tag = UInt32(memo) {
                $0.destinationTag = tag
            }
        }

        let input = RippleSigningInput.with {
            $0.fee = feeDrops                               // fee in drops (Int64)
            $0.sequence = context.sequence                  // account sequence from account_info
            $0.account = fromAddress
            $0.privateKey = key.data
            $0.opPayment = operation
            $0.lastLedgerSequence = context.lastLedgerSequence  // expiration guard
        }

        // 6. Sign.
        let output: RippleSigningOutput = AnySigner.sign(input: input, coin: .xrp)
        guard !output.encoded.isEmpty else {
            throw .signingFailed("XRP signing returned an empty transaction.")
        }
        let txBlobHex = output.encoded.hexString
        // tx hash = SHA-512-256 of the signed blob, hex, upper-cased — the
        // canonical XRPL transaction id (Stabro line 953).
        let txHash = Hash.sha512_256(data: output.encoded).hexString.uppercased()

        // 7. Broadcast via `submit`.
        try await submit(txBlobHex: txBlobHex)

        return ChainSignedTransaction(broadcastPayload: txBlobHex, txHash: txHash)
    }

    /// Poll the transaction by hash via `tx`. `validated == true` with
    /// `meta.TransactionResult == "tesSUCCESS"` is confirmed; validated with
    /// any other code is failed; otherwise still pending.
    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        let params: [String: Sendable] = ["transaction": txHash, "binary": false]
        let data: Data
        do {
            data = try await RPCClient.shared.callJSONResultData(
                chain: .ripple, method: "tx", params: [params], validatesIDEcho: false
            )
        } catch let error as RPCError {
            // A not-yet-validated tx returns a `txnNotFound` JSON-RPC error
            // (or a `null` result) — treat any of those as still pending
            // rather than a hard failure (recipe statusCheck #1).
            if case .cancelled = error { return .pending }
            if case .rpcError(_, let message) = error,
               message.lowercased().contains("not found") || message.lowercased().contains("txnnotfound") {
                return .pending
            }
            if case .decodingFailed = error { return .pending }
            throw mapRPC(error)
        }

        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .pending
        }

        let validated = (result["validated"] as? Bool) ?? false
        let meta = result["meta"] as? [String: Any] ?? [:]
        let txResult = meta["TransactionResult"] as? String
        let ledgerIndex = int64(result["ledger_index"]).map { UInt64(clamping: $0) }

        guard validated else { return .pending }
        if txResult == "tesSUCCESS" {
            return .confirmed(blockNumber: ledgerIndex)
        }
        // Validated but a tec*/tef* code — the fee was burned, funds not
        // delivered. Surface the real result code (recipe statusCheck #2).
        return .failed(reason: txResult ?? "The transaction failed on-ledger.")
    }

    // MARK: - Account context (sequence + current ledger)

    /// Sequence + the ledger index to base `lastLedgerSequence` on.
    private struct AccountContext: Sendable {
        let sequence: UInt32
        let lastLedgerSequence: UInt32
    }

    /// `account_info` (ledger_index: "current") → `account_data.Sequence`
    /// plus the response's `ledger_current_index`. The current-index field
    /// lets us set `lastLedgerSequence` without a second `ledger` round-trip.
    private nonisolated static func fetchAccountContext(address: String) async throws(ChainSendError) -> AccountContext {
        let params: [String: Sendable] = ["account": address, "ledger_index": "current"]
        let data: Data
        do {
            data = try await RPCClient.shared.callJSONResultData(
                chain: .ripple, method: "account_info", params: [params], validatesIDEcho: false
            )
        } catch let error as RPCError {
            throw mapRPC(error)
        }

        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .missingContext("account_info")
        }

        // An unfunded account has no on-ledger entry; rippled returns
        // `actNotFound`. A send from such an account can't succeed (it
        // hasn't met the reserve), so surface it honestly.
        if let status = result["status"] as? String, status == "error",
           let errorCode = result["error"] as? String {
            throw .broadcastRejected(humanAccountError(errorCode))
        }

        guard let accountData = result["account_data"] as? [String: Any],
              let sequence = uint32(accountData["Sequence"]) else {
            throw .missingContext("account_info")
        }

        // `ledger_current_index` is present on a `ledger_index: "current"`
        // query; fall back to `ledger_index` if a server omits it.
        let currentLedger = uint32(result["ledger_current_index"])
            ?? uint32(result["ledger_index"])
            ?? 0
        let lastLedger = currentLedger > 0 ? currentLedger &+ lastLedgerBuffer : 0

        return AccountContext(sequence: sequence, lastLedgerSequence: lastLedger)
    }

    // MARK: - Fee

    /// `fee` (no params) → `result.drops.base_fee`, as Int64 drops. Never
    /// throws: any failure falls back to the 12-drop standard minimum.
    private nonisolated static func fetchBaseFeeDrops() async -> Int64 {
        let data: Data
        do {
            // The `fee` method takes no arguments; rippled still expects a
            // single empty-object param element.
            data = try await RPCClient.shared.callJSONResultData(
                chain: .ripple, method: "fee", params: [[String: Sendable]()], validatesIDEcho: false
            )
        } catch {
            return baseFeeDrops
        }
        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let drops = result["drops"] as? [String: Any],
              let baseString = drops["base_fee"] as? String,
              let parsed = Int64(baseString), parsed > 0 else {
            return baseFeeDrops
        }
        return parsed
    }

    // MARK: - Broadcast

    /// `submit` with `tx_blob` (hex). Accepts `tesSUCCESS` and `terQUEUED`;
    /// any other engine result surfaces its real `engine_result_message`.
    private nonisolated static func submit(txBlobHex: String) async throws(ChainSendError) {
        let params: [String: Sendable] = ["tx_blob": txBlobHex]
        let data: Data
        do {
            data = try await RPCClient.shared.callJSONResultData(
                chain: .ripple, method: "submit", params: [params], validatesIDEcho: false
            )
        } catch let error as RPCError {
            throw .broadcastRejected(broadcastMessage(for: error))
        }

        guard let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let engineResult = result["engine_result"] as? String else {
            throw .broadcastRejected("The network returned an unexpected response. Try again.")
        }

        // `tesSUCCESS` = queued for inclusion; `terQUEUED` = accepted into
        // the local queue. Both mean the node took the transaction.
        guard engineResult == "tesSUCCESS" || engineResult == "terQUEUED" else {
            let message = (result["engine_result_message"] as? String) ?? engineResult
            throw .broadcastRejected(message)
        }
    }

    // MARK: - JSON number coercion

    /// JSONSerialization vends JSON numbers as `NSNumber`; XRPL fields like
    /// `Sequence` / `ledger_current_index` may also arrive as strings on
    /// some servers. Coerce both forms.
    private nonisolated static func uint32(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        if let string = value as? String { return UInt32(string) }
        return nil
    }

    private nonisolated static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    // MARK: - Error mapping

    private nonisolated static func mapRPC(_ error: RPCError) -> ChainSendError {
        switch error {
        case .noEndpoint, .allEndpointsFailed, .network, .cancelled:
            return .rpcUnavailable
        case .rateLimited:
            return .rpcUnavailable
        case .invalidResponse(let m), .decodingFailed(let m):
            return .missingContext(m)
        case .rpcError(_, let message):
            return .broadcastRejected(message)
        }
    }

    /// An honest, user-facing line for a `submit` transport failure (the
    /// engine-result path above already carries the node's own message).
    private nonisolated static func broadcastMessage(for error: RPCError) -> String {
        switch error {
        case .rpcError(_, let message):
            return message
        case .rateLimited:
            return "The network is busy right now. Try again in a moment."
        case .network, .noEndpoint, .allEndpointsFailed, .cancelled:
            return "The network is unreachable right now. Try again."
        case .invalidResponse, .decodingFailed:
            return "The network returned an unexpected response. Try again."
        }
    }

    /// Map the common `account_info` error codes to an honest line.
    private nonisolated static func humanAccountError(_ code: String) -> String {
        switch code {
        case "actNotFound":
            return "This account isn't activated yet — it needs a minimum 10 XRP reserve before it can send."
        default:
            return "Couldn't read the account from the network. Try again."
        }
    }
}
