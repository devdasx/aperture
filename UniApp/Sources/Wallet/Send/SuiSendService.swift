import Foundation
import SwiftData
import WalletCore

/// Real native-SUI send for the Sui network. Sui signing is TWO-STEP:
/// the fullnode builds the unsigned `TransactionData` bytes (`unsafe_paySui`),
/// then wallet-core signs those exact bytes with `signDirect` and we
/// broadcast bytes + signature back to the node.
///
/// Pipeline: derive sender (off-main) → fetch owned SUI coin objects
/// (`suix_getCoins`) → pick a recipe-default gas budget → `unsafe_paySui`
/// → wallet-core `AnySigner.sign(.sui)` on the returned base64 txBytes →
/// `sui_executeTransactionBlock` → poll `sui_getTransactionBlock`. All off
/// the main actor (Rule #28); every value is fetched live (no guesses),
/// and a node rejection surfaces its real reason (Rule #16 / Rule #26).
///
/// **Native SUI only.** Sui token (non-native) sends are out of scope for
/// now — `isNative == false` throws `.unsupportedChain`. The mnemonic and
/// the derived `PrivateKey` never leave `ChainKeyProvider`'s call frame;
/// nothing key-, txBytes-, or signature-shaped is ever logged.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device.
/// The crypto is wallet-core's (`SuiSignDirect` / `SuiSigningOutput`,
/// matching Trust Wallet Core's own `SuiTests.testTransferSui`); the RPC
/// wiring is exercised by that first real send.
enum SuiSendService {

    /// Native SUI coin type — the move type used for both gas and the
    /// transfer in a native send.
    private static let suiCoinType = "0x2::sui::SUI"

    /// 1 SUI = 1e9 MIST.
    private static let mistPerSui = Decimal(1_000_000_000)

    /// A safe, recipe-default gas budget for a simple SUI transfer
    /// (~3,000,000–5,000,000 MIST). Used as the gas budget passed to
    /// `unsafe_paySui` and as the fee shown in `loadFees`. Sui refunds the
    /// unused portion automatically after execution.
    private static let defaultGasBudgetMist: UInt64 = 3_000_000

    // MARK: - Fees

    /// Sui has no fast/normal/slow market — gas is a fixed budget
    /// (`gasBudget` is the worst-case cap; unused gas is refunded). We
    /// surface a single `.normal` tier. NEVER throws on a network hiccup —
    /// the budget is the recipe default, so the Send sheet always has a
    /// fee to show. (Only `.unsupportedChain` for a wrong chain / token
    /// send, which is a programming-contract failure, not a network one.)
    nonisolated static func loadFees(
        chain: SupportedChain,
        toAddress: String,
        rawAmount: String,
        isNative: Bool,
        contract: String?,
        decimals: Int,
        container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        guard chain == .sui else { throw .unsupportedChain(chain) }
        guard isNative else { throw .unsupportedChain(chain) }

        let feeNative = Decimal(defaultGasBudgetMist) / mistPerSui

        return [
            ChainFeeOption(
                speed: .normal,
                feeNative: feeNative,
                estimatedSeconds: 5,
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        ]
    }

    // MARK: - Send

    /// Full send: select owned SUI coin objects, build the unsigned tx via
    /// `unsafe_paySui`, sign with wallet-core `signDirect`, broadcast, and
    /// return the digest. Native SUI only.
    nonisolated static func performSend(
        chain: SupportedChain,
        toAddress: String,
        rawAmount: String,
        isNative: Bool,
        contract: String?,
        decimals: Int,
        memo: String?,
        speed: ChainFeeOption.Speed,
        container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard chain == .sui else { throw .unsupportedChain(chain) }
        guard isNative else { throw .unsupportedChain(chain) }

        let signer = try ChainKeyProvider.senderAddress(for: chain, container: container)
        let gasBudget = defaultGasBudgetMist

        // `unsafe_paySui` draws BOTH the transfer amount AND the gas from
        // these coins (no separate gas coin for a native send), so the
        // selection must cover amount + gasBudget.
        let needed = try amountPlusBudget(rawAmount: rawAmount, gasBudget: gasBudget)
        let inputCoinIDs = try await selectCoinObjectIDs(
            chain: chain, owner: signer, atLeast: needed
        )

        // Step 1 — node builds the unsigned transaction bytes.
        let txBytes = try await buildTxBytes(
            chain: chain,
            signer: signer,
            inputCoinIDs: inputCoinIDs,
            recipient: toAddress,
            amount: rawAmount,
            gasBudget: gasBudget
        )

        // Step 2 — wallet-core signs the exact base64 txBytes.
        let signature = try sign(txBytes: txBytes, chain: chain, container: container)

        // Broadcast bytes + signature.
        let digest = try await broadcast(
            chain: chain, txBytes: txBytes, signature: signature
        )

        return ChainSignedTransaction(broadcastPayload: txBytes, txHash: digest)
    }

    // MARK: - Status

    nonisolated static func status(
        chain: SupportedChain,
        txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        guard chain == .sui else { throw .unsupportedChain(chain) }
        do {
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain,
                method: "sui_getTransactionBlock",
                params: [txHash, ["showEffects": true]]
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .pending
            }
            // result.effects.status.status == "success" | "failure"
            guard let effects = obj["effects"] as? [String: Any],
                  let status = effects["status"] as? [String: Any],
                  let state = status["status"] as? String else {
                return .pending
            }
            switch state {
            case "success":
                let epoch = (effects["executedEpoch"] as? String).flatMap { UInt64($0) }
                return .confirmed(blockNumber: epoch)
            case "failure":
                let reason = (status["error"] as? String) ?? "The transaction failed on-chain."
                return .failed(reason: reason)
            default:
                return .pending
            }
        } catch let e as RPCError {
            // A not-yet-finalized tx returns `null` → `.decodingFailed`
            // here; treat any not-yet-available block as still pending.
            if case .decodingFailed = e { return .pending }
            throw .rpcUnavailable
        }
    }

    // MARK: - Coin selection

    /// Fetch the owner's SUI coin objects (`suix_getCoins`) and greedily
    /// select object ids whose summed balance covers `atLeast` MIST.
    /// `unsafe_paySui` uses these for both the transfer and gas.
    private nonisolated static func selectCoinObjectIDs(
        chain: SupportedChain,
        owner: String,
        atLeast needed: Decimal
    ) async throws(ChainSendError) -> [String] {
        let data: Data
        do {
            // suix_getCoins [owner, coinType, cursor, limit]
            data = try await RPCClient.shared.callJSONResultData(
                chain: chain,
                method: "suix_getCoins",
                params: [owner, suiCoinType, NSNull(), 50]
            )
        } catch {
            throw .missingContext("suix_getCoins")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["data"] as? [[String: Any]], !entries.isEmpty else {
            throw .missingContext("No SUI coins to spend.")
        }

        // Largest-first selection minimizes the number of input coins.
        let coins: [(id: String, balance: Decimal)] = entries.compactMap { entry in
            guard let id = entry["coinObjectId"] as? String else { return nil }
            // `balance` is a MIST string in the JSON response (some nodes
            // return it as a number — handle both).
            let balStr = (entry["balance"] as? String)
                ?? (entry["balance"] as? NSNumber).map { $0.stringValue }
                ?? "0"
            return (id, Decimal(string: balStr) ?? 0)
        }.sorted { $0.balance > $1.balance }

        var selected: [String] = []
        var running = Decimal(0)
        for coin in coins {
            selected.append(coin.id)
            running += coin.balance
            if running >= needed { break }
        }

        guard !selected.isEmpty, running >= needed else {
            throw .broadcastRejected("Balance is less than the amount plus the network fee.")
        }
        return selected
    }

    // MARK: - Build (step 1: node builds the unsigned tx)

    /// `unsafe_paySui(signer, input_coins, recipients, amounts, gas_budget)`
    /// → `result.txBytes` (base64 BCS-serialized `TransactionData`). Gas is
    /// taken from `input_coins` for a native send (no separate gas object).
    private nonisolated static func buildTxBytes(
        chain: SupportedChain,
        signer: String,
        inputCoinIDs: [String],
        recipient: String,
        amount: String,
        gasBudget: UInt64
    ) async throws(ChainSendError) -> String {
        let data: Data
        do {
            data = try await RPCClient.shared.callJSONResultData(
                chain: chain,
                method: "unsafe_paySui",
                params: [
                    signer,                 // signer
                    inputCoinIDs,           // input_coins (object ids)
                    [recipient],            // recipients
                    [amount],               // amounts (decimal MIST strings)
                    String(gasBudget),      // gas_budget (decimal string)
                ]
            )
        } catch let e as RPCError {
            throw .broadcastRejected(buildMessage(for: e))
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let txBytes = obj["txBytes"] as? String, !txBytes.isEmpty else {
            throw .missingContext("unsafe_paySui returned no txBytes")
        }
        return txBytes
    }

    // MARK: - Sign (step 2: wallet-core signDirect)

    /// Mirrors Trust Wallet Core `SuiTests.testTransferSui` and Stabro's
    /// `signSuiTransaction` (TransactionSigner.swift:966–1000): feed the
    /// node's base64 txBytes into `SuiSignDirect.unsignedTxMsg`, sign with
    /// `.sui`, and return the base64 signature (scheme-prefixed by
    /// wallet-core, exactly what `sui_executeTransactionBlock` expects).
    private nonisolated static func sign(
        txBytes: String,
        chain: SupportedChain,
        container: ModelContainer
    ) throws(ChainSendError) -> String {
        let (key, _) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        var signDirect = SuiSignDirect()
        signDirect.unsignedTxMsg = txBytes

        var input = SuiSigningInput()
        input.privateKey = key.data
        input.signDirectMessage = signDirect

        let output: SuiSigningOutput = AnySigner.sign(input: input, coin: .sui)

        guard output.error == .ok, !output.signature.isEmpty else {
            let reason = output.errorMessage.isEmpty
                ? "Sui signer returned an empty signature."
                : output.errorMessage
            throw .signingFailed(reason)
        }
        // output.unsignedTx echoes the txBytes we broadcast; output.signature
        // is what pairs with it.
        return output.signature
    }

    // MARK: - Broadcast

    /// `sui_executeTransactionBlock(tx_bytes, [signature], options, request_type)`
    /// → `result.digest`.
    private nonisolated static func broadcast(
        chain: SupportedChain,
        txBytes: String,
        signature: String
    ) async throws(ChainSendError) -> String {
        let data: Data
        do {
            data = try await RPCClient.shared.callJSONResultData(
                chain: chain,
                method: "sui_executeTransactionBlock",
                params: [
                    txBytes,                        // tx_bytes (base64)
                    [signature],                    // signatures (base64)
                    ["showEffects": true],          // options
                    "WaitForLocalExecution",        // request type
                ]
            )
        } catch let e as RPCError {
            throw .broadcastRejected(buildMessage(for: e))
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .broadcastRejected("The network rejected the transaction. Try again.")
        }

        // If the node executed but reverted, surface the honest reason.
        if let effects = obj["effects"] as? [String: Any],
           let status = effects["status"] as? [String: Any],
           let state = status["status"] as? String, state == "failure" {
            let reason = (status["error"] as? String) ?? "The transaction reverted on-chain."
            throw .broadcastRejected(reason)
        }

        guard let digest = obj["digest"] as? String, !digest.isEmpty else {
            throw .broadcastRejected("The network rejected the transaction. Try again.")
        }
        return digest
    }

    // MARK: - Amount helpers

    /// amount (MIST) + gasBudget (MIST), as a Decimal, for coin selection.
    /// `rawAmount` is ALREADY MIST (1 SUI = 1e9), per the send contract.
    private nonisolated static func amountPlusBudget(
        rawAmount: String,
        gasBudget: UInt64
    ) throws(ChainSendError) -> Decimal {
        guard let amount = Decimal(string: rawAmount), amount >= 0 else {
            throw .signingFailed("Invalid send amount.")
        }
        return amount + Decimal(gasBudget)
    }

    private nonisolated static func buildMessage(for error: RPCError) -> String {
        let raw = "\(error)".lowercased()
        if raw.contains("insufficient") || raw.contains("balance") {
            return "Balance is less than the amount plus the network fee."
        }
        if raw.contains("gas") {
            return "The network fee was too low for this transfer. Try again."
        }
        if raw.contains("object") && (raw.contains("version") || raw.contains("locked") || raw.contains("not found")) {
            return "A coin used for this send changed. Try again."
        }
        return "The network rejected the transaction. Try again."
    }
}
