import Foundation
import SwiftData
import WalletCore

/// Real Cosmos-SDK send — native **KAVA** (`cosmos.bank.v1beta1.MsgSend`)
/// on Kava mainnet (`kava_2222-10`). One implementation; native KAVA only.
///
/// **Signing approach — wallet-core's Cosmos signer (preferred).** The proven
/// Stabro reference (`KavaTransactionBuilder.buildAndSign`) does NOT hand-roll
/// Amino/Protobuf — it builds a `CosmosSigningInput` (MsgSend) and delegates to
/// `AnySigner.sign(input:, coin: .kava)`. We do the same here: simpler, more
/// robust, and exactly what shipped in production. Every wallet-core field is
/// verified against the WalletCore `.swiftinterface` (see the implementation
/// notes + the `kava_2222-10` chain id).
///
/// Pipeline (per `/tmp/recipe-cosmos.md`):
/// 1. `GET cosmos/auth/v1beta1/accounts/{addr}` → account_number + sequence
///    (fetched fresh immediately before signing — sequence MUST be current,
///    recipe gotcha #1).
/// 2. Derive key + sender address via `ChainKeyProvider`.
/// 3. Build `CosmosSigningInput` (signingMode `.protobuf`, chainID
///    `kava_2222-10`, MsgSend with denom `ukava`, fixed fee) → `AnySigner.sign`.
/// 4. Extract the base64 `tx_bytes` from `output.serialized`'s JSON envelope,
///    re-encode the raw protobuf as base64, and broadcast via
///    `POST cosmos/tx/v1beta1/txs` (`BROADCAST_MODE_SYNC`).
/// 5. Status: `GET cosmos/tx/v1beta1/txs/{hash}` → `tx_response.code`.
///
/// **Fee model.** Cosmos has no EIP-1559 / gas estimation: `fee = gasLimit ×
/// gasPrice` (recipe). gasLimit `200,000`; gasPrice `0.05 ukava/gas` per the
/// brief. One `.normal` tier; EVM-only fields nil. `loadFees` never throws on
/// a fee-fetch issue — it uses the recipe default (Rule #16 / Rule #26).
///
/// **Off-main (Rule #28).** Every RPC + the seed stretch + signing run off the
/// main actor; only the small `Sendable` result crosses back.
/// **Honest (Rule #16 / Rule #26).** A node rejection surfaces its real
/// `raw_log`; nothing key-, mnemonic-, or signature-shaped is ever logged.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device — the
/// crypto is wallet-core's; this wiring is exercised by that first real send.
enum CosmosSendService {

    // MARK: - Constants (per recipe + brief)

    /// Kava mainnet chain ID for Cosmos signing (recipe gotcha #3 — NEVER
    /// derive from the RPC response; hard-code mainnet). Matches the proven
    /// Stabro `KavaTransactionBuilder.chainID`.
    private static let chainID = "kava_2222-10"

    /// Fixed gas limit for a bank/send (recipe: 200,000 is a safe upper bound;
    /// Cosmos has no gas-estimation endpoint, gotcha #2).
    private static let gasLimit: UInt64 = 200_000

    /// Gas price in ukava per gas unit (brief: ~0.05 ukava/gas).
    private static let gasPriceUkava = Decimal(string: "0.05") ?? Decimal(0.05)

    /// ukava per KAVA (1 KAVA = 1e6 ukava).
    private static let ukavaPerKava = Decimal(1_000_000)

    /// Native fee denom — ALWAYS `ukava`, never `KAVA` (recipe gotcha #4).
    private static let feeDenom = "ukava"

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    /// Cosmos has a single fixed fee (no slow/normal/fast). Returns one
    /// `.normal` option. Never throws on a fee issue — the recipe default is
    /// always available so the Send flow has a number. (It DOES throw for a
    /// non-Kava chain or a non-native send, both unsupported here.)
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        guard chain == .kava else { throw .unsupportedChain(chain) }
        // Native KAVA only — Cosmos token transfers use denoms, not contracts,
        // and the token registry isn't wired here; refuse honestly (brief).
        guard isNative else { throw .unsupportedChain(chain) }

        // feeUkava = gasLimit × gasPrice  (recipe final-fee calc).
        let feeUkava = Decimal(gasLimit) * gasPriceUkava
        let feeNative = feeUkava / ukavaPerKava   // → KAVA

        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeNative,
                estimatedSeconds: 8,   // Kava blocks ~2–3 s; confirms fast
                gasLimit: nil,         // EVM-only field
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        ]
    }

    /// Full send: fetch the account (number + sequence) fresh, derive the key,
    /// build + sign the `CosmosSigningInput` (MsgSend, ukava), broadcast the
    /// raw protobuf, and return the node-assigned txhash.
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard chain == .kava else { throw .unsupportedChain(chain) }
        guard isNative else { throw .unsupportedChain(chain) }

        // 1. Signing material (mnemonic → key + sender kava1… address), off-main.
        let (key, fromAddress) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // 2. Account number + sequence — fetched immediately before signing so
        //    the sequence is current (recipe gotcha #1; NEVER cached).
        let account = try await fetchAccountInfo(address: fromAddress)

        // 3. Build the MsgSend message (denom ukava — amount in smallest unit).
        var sendMessage = CosmosMessage.Send()
        sendMessage.fromAddress = fromAddress
        sendMessage.toAddress = toAddress
        var sendCoin = CosmosAmount()
        sendCoin.denom = feeDenom
        sendCoin.amount = rawAmount        // ALREADY ukava (1 KAVA = 1e6)
        sendMessage.amounts = [sendCoin]

        var message = CosmosMessage()
        message.sendCoinsMessage = sendMessage

        // 4. Fixed fee: amount (ukava) + gas (recipe; gotcha #14 — flat fee).
        var feeCoin = CosmosAmount()
        feeCoin.denom = feeDenom
        feeCoin.amount = feeAmountUkava()
        var fee = CosmosFee()
        fee.amounts = [feeCoin]
        fee.gas = gasLimit

        // 5. Signing input — mirrors Stabro KavaTransactionBuilder exactly.
        var input = CosmosSigningInput()
        input.signingMode = .protobuf       // the Cosmos standard (recipe)
        input.chainID = chainID             // kava_2222-10 (hard-coded mainnet)
        input.accountNumber = account.accountNumber
        input.sequence = account.sequence
        input.messages = [message]
        input.fee = fee
        input.privateKey = key.data
        if let memo, !memo.isEmpty { input.memo = memo }   // optional (gotcha #6)

        // 6. Sign with wallet-core's Cosmos signer.
        let output: CosmosSigningOutput = AnySigner.sign(input: input, coin: .kava)
        guard output.error == .ok, !output.serialized.isEmpty else {
            let reason = output.errorMessage.isEmpty ? "Signing failed." : output.errorMessage
            throw .signingFailed(reason)
        }

        // 7. Extract the base64 tx_bytes from the serialized JSON envelope
        //    `{"tx_bytes":"<base64>","mode":"…"}`. We decode → re-encode so the
        //    broadcast body carries the raw protobuf in base64 (recipe: NOT the
        //    JSON wrapper). Mirrors Stabro KavaTransactionBuilder lines 123–135.
        guard
            let envelopeData = output.serialized.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
            let txBytesB64 = envelope["tx_bytes"] as? String,
            let rawProtobuf = Data(base64Encoded: txBytesB64)
        else {
            throw .signingFailed("Could not extract transaction bytes.")
        }
        let broadcastB64 = rawProtobuf.base64EncodedString()

        // 8. Broadcast (BROADCAST_MODE_SYNC) → tx_response.{txhash, code, raw_log}.
        let txHash = try await broadcast(txBytesBase64: broadcastB64)

        return ChainSignedTransaction(broadcastPayload: broadcastB64, txHash: txHash)
    }

    /// Poll the transaction by hash. Cosmos finality is immediate — once on
    /// chain with `code == 0` it's confirmed; `code != 0` is a failure; a 404 /
    /// missing `tx_response` means not yet indexed (pending).
    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        guard chain == .kava else { throw .unsupportedChain(chain) }

        let data: Data
        do {
            data = try await RPCClient.shared.callREST(
                chain: .kava, path: "cosmos/tx/v1beta1/txs/\(txHash)"
            )
        } catch {
            // Network error / not-yet-indexed → assume in-flight (recipe).
            return .pending
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let txResponse = json["tx_response"] as? [String: Any] else {
            // Missing tx_response (404 / empty) → still pending (recipe).
            return .pending
        }

        let code = intValue(txResponse["code"]) ?? 0
        if code == 0 {
            let height = uint64Value(txResponse["height"])
            return .confirmed(blockNumber: height)
        }
        let rawLog = (txResponse["raw_log"] as? String) ?? ""
        return .failed(reason: rawLog.isEmpty ? "The transaction failed on-chain." : rawLog)
    }

    // MARK: - Account fetch (number + sequence)

    private struct AccountInfo: Sendable {
        let accountNumber: UInt64
        let sequence: UInt64
    }

    /// `GET cosmos/auth/v1beta1/accounts/{addr}` → account_number + sequence.
    /// Handles all Kava account nestings (BaseAccount / EthAccount /
    /// VestingAccount) exactly as the proven Stabro builder (lines 51–66).
    /// A brand-new (never-funded) account 404s → number/sequence default to 0
    /// (recipe gotcha #9 — the first tx initializes the account on-chain).
    private nonisolated static func fetchAccountInfo(address: String) async throws(ChainSendError) -> AccountInfo {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(
                chain: .kava, path: "cosmos/auth/v1beta1/accounts/\(address)"
            )
        } catch {
            // 404 for a never-funded account arrives as an RPC failure; a
            // brand-new account signs with number/sequence 0 (gotcha #9).
            return AccountInfo(accountNumber: 0, sequence: 0)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any] else {
            // No account body → treat as new (gotcha #9).
            return AccountInfo(accountNumber: 0, sequence: 0)
        }

        // Try every nesting path the recipe lists.
        let baseAccount: [String: Any]
        if let ba = account["base_account"] as? [String: Any] {
            // EthAccount / ModuleAccount.
            baseAccount = ba
        } else if let bva = account["base_vesting_account"] as? [String: Any],
                  let ba = bva["base_account"] as? [String: Any] {
            // VestingAccount.
            baseAccount = ba
        } else {
            // Direct BaseAccount.
            baseAccount = account
        }

        let accountNumber = UInt64(stringValue(baseAccount["account_number"]) ?? "0") ?? 0
        let sequence = UInt64(stringValue(baseAccount["sequence"]) ?? "0") ?? 0
        return AccountInfo(accountNumber: accountNumber, sequence: sequence)
    }

    // MARK: - Broadcast

    /// `POST cosmos/tx/v1beta1/txs` with `{"tx_bytes":<base64>,"mode":"BROADCAST_MODE_SYNC"}`
    /// → `tx_response.{txhash, code, raw_log}`. `code == 0` succeeds (returns
    /// txhash); `code != 0` throws `.broadcastRejected(raw_log)` with the
    /// node's real reason (Rule #16 / Rule #26).
    private nonisolated static func broadcast(txBytesBase64: String) async throws(ChainSendError) -> String {
        let body: [String: Sendable] = [
            "tx_bytes": txBytesBase64,
            "mode": "BROADCAST_MODE_SYNC",
        ]

        let data: Data
        do {
            data = try await RPCClient.shared.callRESTPost(
                chain: .kava, path: "cosmos/tx/v1beta1/txs", body: body
            )
        } catch {
            throw mapRPC(error)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let txResponse = json["tx_response"] as? [String: Any] else {
            throw .broadcastRejected("No transaction response from the network.")
        }

        let code = intValue(txResponse["code"]) ?? 0
        let txHash = (txResponse["txhash"] as? String) ?? ""

        if code == 0 {
            guard !txHash.isEmpty else {
                throw .broadcastRejected("The network accepted the transaction but returned no hash.")
            }
            return txHash
        }

        // Rejected — surface the node's honest reason.
        let rawLog = (txResponse["raw_log"] as? String) ?? ""
        throw .broadcastRejected(rawLog.isEmpty ? "The network rejected the transaction." : rawLog)
    }

    // MARK: - Fee helper

    /// feeAmount in ukava = gasLimit × gasPrice, as a raw integer string
    /// (rounded down — never overcharge). E.g. 200,000 × 0.05 = 10,000 ukava.
    private nonisolated static func feeAmountUkava() -> String {
        let raw = Decimal(gasLimit) * gasPriceUkava
        var truncated = Decimal()
        var input = raw
        NSDecimalRound(&truncated, &input, 0, .down)
        let amount = NSDecimalNumber(decimal: truncated).stringValue
        // A zero fee would be rejected by the network; floor at 1 ukava.
        return amount == "0" ? "1" : amount
    }

    // MARK: - JSON value helpers (Cosmos numbers arrive as strings or numbers)

    private nonisolated static func stringValue(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private nonisolated static func uint64Value(_ value: Any?) -> UInt64? {
        if let i = value as? Int, i >= 0 { return UInt64(i) }
        if let n = value as? NSNumber { return n.uint64Value }
        if let s = value as? String { return UInt64(s) }
        return nil
    }

    // MARK: - Error mapping

    /// Fold an `RPCError` into a `ChainSendError`, preserving an honest reason
    /// where the node supplied one. Mirrors `TronSendService.mapRPC`.
    private nonisolated static func mapRPC(_ error: RPCError) -> ChainSendError {
        switch error {
        case .noEndpoint, .allEndpointsFailed, .network, .cancelled, .rateLimited:
            return .rpcUnavailable
        case .invalidResponse(let m), .decodingFailed(let m):
            return .missingContext(m)
        case .rpcError(_, let message):
            return .broadcastRejected(message)
        }
    }
}
