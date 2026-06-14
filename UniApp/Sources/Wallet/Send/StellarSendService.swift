import Foundation
import SwiftData
import WalletCore

/// Real Stellar (XLM) send. Native XLM only — issued assets are out of
/// scope for now (a non-native send throws `.unsupportedChain`).
///
/// Pipeline (Horizon REST via OUR `RPCClient`):
///   `GET accounts/{addr}` → current sequence → sign with the NEXT
///   sequence (`+1`) → form-encoded `POST transactions` → poll
///   `GET transactions/{hash}`.
///
/// Stellar uses a flat fee (100 stroops / operation) with no estimation
/// call and no slow/normal/fast tiers, so `loadFees` returns a single
/// `.normal` option and never throws. The signing mirrors Stabro's
/// proven `signStellarTransaction` (`StellarOperationPayment` →
/// `StellarSigningInput` → `AnySigner.sign(.stellar)` →
/// `output.signature`, the base64 XDR envelope).
///
/// **Funds-safety (Rule #16 / #26).** `rawAmount` is ALREADY stroops
/// (1 XLM = 1e7 stroops); it's parsed as `Int64` with no float drift.
/// The mainnet passphrase is `StellarPassphrase.stellar.description` —
/// signing with the wrong passphrase produces valid-looking XDR that the
/// network rejects, so it's pinned. A Horizon rejection surfaces the real
/// error body via `.broadcastRejected` rather than fabricating success.
///
/// **Off-main (Rule #28).** `nonisolated`; all RPC + signing run off the
/// main actor. Nothing key- or signature-shaped is logged.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device —
/// the crypto is wallet-core's; this turn wires it faithfully to the
/// proven Stabro usage and the authoritative recipe.
enum StellarSendService {

    /// Stellar base fee: 100 stroops (0.00001 XLM) per operation.
    private static let baseFeeStroops: Int32 = 100
    /// 1 XLM = 10^7 stroops.
    private static let stroopsPerXLM: Decimal = 10_000_000

    // MARK: - Fees

    /// Flat fee — a single `.normal` tier at 100 stroops. Never throws
    /// (Stellar has no estimation RPC); EVM-only fields are nil.
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        let feeNative = Decimal(Int(baseFeeStroops)) / stroopsPerXLM
        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeNative,
                estimatedSeconds: 6,   // one ledger close (~3–10s)
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        ]
    }

    // MARK: - Send

    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        // Native XLM only — issued assets are out of scope for now.
        guard isNative else { throw .unsupportedChain(chain) }

        // rawAmount is ALREADY stroops; Stellar's payment amount is Int64.
        guard let amountStroops = Int64(rawAmount), amountStroops > 0 else {
            throw .signingFailed("Amount is out of range for Stellar.")
        }

        // Derive the sender address + signing key on-device (off-main).
        let (key, fromAddress) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // Current account sequence from Horizon. Stellar requires the tx
        // to carry the NEXT sequence, so we sign with sequence + 1 (this
        // mirrors Stabro's SendViewModel: `(UInt64(sequence) ?? 0) + 1`).
        let currentSequence = try await fetchSequence(chain: chain, address: fromAddress)
        let nextSequence = currentSequence + 1

        // Build + sign exactly as Stabro's signStellarTransaction.
        var payment = StellarOperationPayment()
        payment.destination = toAddress
        payment.amount = amountStroops

        var input = StellarSigningInput()
        input.fee = baseFeeStroops
        input.sequence = nextSequence
        input.account = fromAddress
        input.privateKey = key.data
        input.passphrase = StellarPassphrase.stellar.description
        input.opPayment = payment

        // Memo: numeric → memoID, else text (≤28 bytes), else void.
        if let memo, !memo.isEmpty {
            if let memoNumeric = UInt64(memo) {
                input.memoID = StellarMemoId.with { $0.id = Int64(bitPattern: memoNumeric) }
            } else {
                input.memoText = StellarMemoText.with { $0.text = String(memo.prefix(28)) }
            }
        } else {
            input.memoVoid = StellarMemoVoid()
        }

        let output: StellarSigningOutput = AnySigner.sign(input: input, coin: .stellar)
        guard output.error == .ok, !output.signature.isEmpty else {
            let reason = output.errorMessage.isEmpty
                ? "Signing failed."
                : output.errorMessage
            throw .signingFailed(reason)
        }

        // output.signature is the base64-encoded signed XDR envelope.
        let xdrBase64 = output.signature

        // Broadcast form-encoded: `tx=<percent-encoded XDR>`. The `+` in
        // base64 decodes as a space in form-encoded data, corrupting the
        // XDR — so percent-encode against `.alphanumerics` (escapes +, /, =).
        let encoded = xdrBase64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? xdrBase64
        guard let body = "tx=\(encoded)".data(using: .utf8) else {
            throw .signingFailed("Could not encode the transaction for broadcast.")
        }

        let responseData: Data
        do {
            responseData = try await RPCClient.shared.callRESTPostRaw(
                chain: chain,
                path: "transactions",
                body: body,
                contentType: "application/x-www-form-urlencoded"
            )
        } catch let error as RPCError {
            // callRESTPostRaw folds Horizon's non-2xx body into the error
            // (e.g. bad sequence / underfunded / malformed XDR), so the
            // user sees the real reason rather than a bare status code.
            throw .broadcastRejected(broadcastMessage(for: error))
        }

        // Horizon returns { "hash": "...", "successful": true } on accept.
        struct StellarTxResult: Decodable { let hash: String?; let successful: Bool? }
        guard let result = try? JSONDecoder().decode(StellarTxResult.self, from: responseData) else {
            // 2xx but unparseable — surface Horizon's body honestly.
            let snippet = String(decoding: responseData.prefix(240), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw .broadcastRejected(snippet.isEmpty ? "The network rejected the transaction. Try again." : snippet)
        }

        // `successful: false` means the ledger applied the envelope but the
        // operation failed (e.g. underfunded / no trustline) — honest reject.
        if result.successful == false {
            throw .broadcastRejected("The transaction was rejected by the network.")
        }

        return ChainSignedTransaction(broadcastPayload: xdrBase64, txHash: result.hash ?? "")
    }

    // MARK: - Status

    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        guard !txHash.isEmpty else { return .pending }
        do {
            let data = try await RPCClient.shared.callREST(
                chain: chain, path: "transactions/\(txHash)"
            )
            struct StellarTx: Decodable {
                let successful: Bool?
                let ledger: UInt64?
            }
            guard let tx = try? JSONDecoder().decode(StellarTx.self, from: data) else {
                // 2xx but unparseable — not yet a definitive result.
                return .pending
            }
            if tx.successful == true {
                return .confirmed(blockNumber: tx.ledger)
            }
            // Present in Horizon but not successful → failed.
            return .failed(reason: "The transaction failed on-chain.")
        } catch let error as RPCError {
            // 404 (not yet in a closed ledger) surfaces as an invalid
            // HTTP response here — treat any not-yet-visible / transient
            // result as still pending (continue polling), never a failure.
            switch error {
            case .invalidResponse, .decodingFailed, .network, .allEndpointsFailed, .rateLimited, .cancelled, .rpcError:
                return .pending
            case .noEndpoint:
                throw .rpcUnavailable
            }
        }
    }

    // MARK: - Sequence fetch (Horizon REST)

    private nonisolated static func fetchSequence(
        chain: SupportedChain, address: String
    ) async throws(ChainSendError) -> Int64 {
        let data: Data
        do {
            data = try await RPCClient.shared.callREST(chain: chain, path: "accounts/\(address)")
        } catch {
            throw .missingContext("accounts")
        }
        // Horizon returns the CURRENT sequence as a string.
        struct StellarAccount: Decodable { let sequence: String }
        guard let account = try? JSONDecoder().decode(StellarAccount.self, from: data),
              let sequence = Int64(account.sequence) else {
            throw .missingContext("sequence")
        }
        return sequence
    }

    // MARK: - Error mapping

    private static func broadcastMessage(for error: RPCError) -> String {
        let raw = "\(error)".lowercased()
        if raw.contains("tx_bad_seq") || raw.contains("bad_seq") || raw.contains("sequence") {
            return "The account sequence changed — try the send again."
        }
        if raw.contains("underfunded") || raw.contains("insufficient") {
            return "Balance is less than the amount plus the network fee."
        }
        if raw.contains("no_trust") || raw.contains("no trust") || raw.contains("trustline") {
            return "The recipient can't receive this asset."
        }
        if raw.contains("tx_insufficient_fee") || raw.contains("insufficient_fee") {
            return "The network fee is too low — try again."
        }
        if raw.contains("malformed") || raw.contains("invalid") {
            return "The transaction was malformed. Try again."
        }
        if raw.contains("offline") || raw.contains("network") {
            return "The network is unreachable right now. Try again."
        }
        return "The network rejected the transaction. Try again."
    }
}
