import Foundation
import SwiftData
import WalletCore

/// Real Solana send (native SOL + SPL token). One implementation; the
/// `isNative` flag selects the wallet-core transaction shape.
///
/// Pipeline (per `/tmp/recipe-solana.md`): estimate fee tiers from base
/// 5000 lamports + recent priority fee → derive ATAs (deterministic, no
/// RPC) for SPL → fetch the recent blockhash LAST (it expires in ~5 min)
/// → sign with wallet-core `AnySigner` (`SolanaSigningInput`) → broadcast
/// via `sendTransaction` (base64) → poll `getSignatureStatuses`. All off
/// the main actor (Rule #28); the base fee always shows even if the
/// priority-fee RPC fails (Rule #16 — honest, never blank), and a node
/// rejection surfaces its real reason (Rule #16 / Rule #26).
///
/// Mirrors Stabro's proven `TransactionSigner.signSolanaTransaction`
/// (lines 485–587) field-for-field for the wallet-core input, and
/// Stabro's `SolanaService` for the RPC method/param shapes — but every
/// RPC call routes through OUR `RPCClient.shared`.
///
/// ⚠️ UNVERIFIED until a real tiny-amount mainnet test send on-device.
/// The crypto is wallet-core's; the wiring is exercised by that first
/// real send.
enum SolanaSendService {

    // MARK: - Constants

    /// Protocol-fixed base fee per signature — never negotiable.
    private static let baseLamportsPerSignature: UInt64 = 5000

    /// lamports → SOL (9 decimals).
    private static func lamportsToSOL(_ lamports: UInt64) -> Decimal {
        Decimal(lamports) / pow(Decimal(10), 9)
    }

    // MARK: - Off-main orchestration (called from the @MainActor view-model)

    /// Three fee tiers from base 5000 lamports + the recent priority fee.
    /// On any RPC failure the priority component is dropped and only the
    /// base fee is used — a fee always shows (never throws here).
    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        let priorityLamports = await recentPriorityLamports(chain: chain)
        // (priority multiplier ×100, rough ETA seconds) per tier.
        let tiers: [(ChainFeeOption.Speed, UInt64, Int)] = [
            (.slow,   75, 30),
            (.normal, 100, 15),
            (.fast,   150, 8),
        ]
        return tiers.map { (speed, priorityMul, secs) in
            let scaledPriority = priorityLamports * priorityMul / 100
            let totalLamports = baseLamportsPerSignature + scaledPriority
            return ChainFeeOption(
                speed: speed,
                feeNative: lamportsToSOL(totalLamports),
                estimatedSeconds: secs,
                gasLimit: nil,
                maxFeePerGas: nil,
                maxPriorityFeePerGas: nil,
                gasPrice: nil
            )
        }
    }

    /// Full send: build the wallet-core input, fetch the blockhash LAST,
    /// sign, and broadcast. Returns the broadcast payload + the base58
    /// signature the node assigned (the tx hash used for status polling).
    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        guard chain == .solana else { throw .unsupportedChain(chain) }

        // Custody-checked key + the sender (fee payer) address. The fee
        // payer MUST be the signer (recipe gotcha #5).
        let (key, fromAddress) = try ChainKeyProvider.signingMaterial(for: chain, container: container)

        // Fetch the recent blockhash LAST (TTL ~5 min) — immediately
        // before signing, so it's still valid at broadcast (gotcha #1).
        let recentBlockhash = try await fetchLatestBlockhash(chain: chain)

        var input = SolanaSigningInput()
        input.privateKey = key.data
        input.sender = fromAddress
        input.txEncoding = .base64
        input.recentBlockhash = recentBlockhash

        if isNative {
            // Native SOL transfer.
            guard let transferAmount = UInt64(rawAmount) else {
                throw .signingFailed("Amount exceeds the maximum transferable value.")
            }
            var transfer = SolanaTransfer()
            transfer.recipient = toAddress
            transfer.value = transferAmount
            input.transferTransaction = transfer
        } else {
            // SPL token transfer.
            guard let mint = contract, !mint.isEmpty else {
                throw .signingFailed("Missing token mint address for SPL transfer.")
            }
            guard let senderAddr = SolanaAddress(string: fromAddress) else {
                throw .signingFailed("Invalid Solana sender address.")
            }
            guard let recipientAddr = SolanaAddress(string: toAddress) else {
                throw .signingFailed("Invalid Solana recipient address.")
            }
            // Token-2022 mints (AUSD / DUSD / PYUSD / USDG) live under the
            // Token-2022 program, so their ATA is a DIFFERENT PDA than the
            // legacy SPL Token derivation AND the transfer must name the
            // Token-2022 program — otherwise the signed tx references an
            // empty/legacy sender account and the node rejects it (or the
            // create path strands a recipient account under the wrong
            // program). Resolve the standard from the registry and branch
            // both the ATA derivation and the program id (recipe preSign #3;
            // mirrors Stabro signSolanaTransaction Token-2022 path).
            let isToken2022 = SolanaTokenRegistry.mints[mint]?.standard == .splToken2022
            let senderATA = (isToken2022
                ? senderAddr.token2022Address(tokenMintAddress: mint)
                : senderAddr.defaultTokenAddress(tokenMintAddress: mint)) ?? ""
            let recipientATA = (isToken2022
                ? recipientAddr.token2022Address(tokenMintAddress: mint)
                : recipientAddr.defaultTokenAddress(tokenMintAddress: mint)) ?? ""
            guard !senderATA.isEmpty, !recipientATA.isEmpty else {
                throw .signingFailed("Could not derive the token account address.")
            }
            guard let transferAmount = UInt64(rawAmount) else {
                throw .signingFailed("Amount exceeds the maximum transferable value.")
            }
            let tokenDecimals = UInt32(max(0, decimals))

            if fromAddress.lowercased() == toAddress.lowercased() {
                // Self-transfer: both ATAs exist — simple token transfer.
                var tokenTransfer = SolanaTokenTransfer()
                tokenTransfer.tokenMintAddress = mint
                tokenTransfer.senderTokenAddress = senderATA
                tokenTransfer.recipientTokenAddress = recipientATA
                tokenTransfer.amount = transferAmount
                tokenTransfer.decimals = tokenDecimals
                tokenTransfer.tokenProgramID = isToken2022 ? .token2022Program : .tokenProgram
                input.tokenTransferTransaction = tokenTransfer
            } else {
                // Transfer to another wallet: create the recipient ATA if
                // it doesn't exist (idempotent create-and-transfer).
                var createTransfer = SolanaCreateAndTransferToken()
                createTransfer.recipientMainAddress = toAddress
                createTransfer.tokenMintAddress = mint
                createTransfer.recipientTokenAddress = recipientATA
                createTransfer.senderTokenAddress = senderATA
                createTransfer.amount = transferAmount
                createTransfer.decimals = tokenDecimals
                createTransfer.tokenProgramID = isToken2022 ? .token2022Program : .tokenProgram
                input.createAndTransferTokenTransaction = createTransfer
            }
        }

        let output: SolanaSigningOutput = AnySigner.sign(input: input, coin: .solana)
        guard !output.encoded.isEmpty else {
            throw .signingFailed("Signer returned an empty transaction.")
        }
        let encoded = output.encoded   // base64-serialized signed transaction

        // Broadcast — `sendTransaction` returns the base58 signature.
        do {
            let sendOptions: [String: Sendable] = [
                "encoding": "base64",
                "skipPreflight": true,
                "preflightCommitment": "confirmed",
                "maxRetries": 3,
            ]
            let signature = try await RPCClient.shared.callJSONString(
                chain: chain, method: "sendTransaction",
                params: [encoded, sendOptions]
            )
            guard !signature.isEmpty else {
                throw ChainSendError.broadcastRejected("The network didn't return a transaction signature.")
            }
            return ChainSignedTransaction(broadcastPayload: encoded, txHash: signature)
        } catch let e as ChainSendError {
            throw e
        } catch let e as RPCError {
            throw .broadcastRejected(broadcastMessage(for: e))
        } catch {
            throw .broadcastRejected("The network rejected the transaction. Try again.")
        }
    }

    // MARK: - Status

    /// `getSignatureStatuses` → value[0]: err != null → failed;
    /// confirmationStatus == "finalized" → confirmed(slot); null or any
    /// non-finalized state → pending.
    static func status(chain: SupportedChain, txHash: String) async throws(ChainSendError) -> ChainSendStatus {
        do {
            let statusOptions: [String: Sendable] = ["searchTransactionHistory": true]
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "getSignatureStatuses",
                params: [[txHash], statusOptions]
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = obj["value"] as? [Any] else {
                return .pending
            }
            // A null first entry (NSNull) → not yet seen → pending.
            guard let first = value.first, let entry = first as? [String: Any] else {
                return .pending
            }
            // On-chain failure: `err` is a non-null error object.
            if let err = entry["err"], !(err is NSNull) {
                return .failed(reason: "The transaction failed on-chain.")
            }
            let slot = (entry["slot"] as? NSNumber)?.uint64Value
            if let confirmationStatus = entry["confirmationStatus"] as? String,
               confirmationStatus == "finalized" {
                return .confirmed(blockNumber: slot)
            }
            // processed / confirmed / null-but-seen → still pending.
            return .pending
        } catch let e as ChainSendError {
            throw e
        } catch {
            // A null `value[0]` surfaces as `.decodingFailed` only when the
            // whole result is null; the value-array path above handles the
            // common case. Any other RPC failure is a transient outage.
            if case .decodingFailed = error { return .pending }
            throw .rpcUnavailable
        }
    }

    // MARK: - Pre-sign fetches

    /// `getLatestBlockhash` → value.blockhash. Fetched LAST (gotcha #1).
    private static func fetchLatestBlockhash(chain: SupportedChain) async throws(ChainSendError) -> String {
        do {
            let commitment: [String: Sendable] = ["commitment": "finalized"]
            let data = try await RPCClient.shared.callJSONResultData(
                chain: chain, method: "getLatestBlockhash",
                params: [commitment]
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = obj["value"] as? [String: Any],
                  let blockhash = value["blockhash"] as? String,
                  !blockhash.isEmpty else {
                throw ChainSendError.missingContext("getLatestBlockhash")
            }
            return blockhash
        } catch let e as ChainSendError {
            throw e
        } catch {
            throw ChainSendError.missingContext("getLatestBlockhash")
        }
    }

    /// Average of the recent non-zero priority fees (lamports). Returns 0
    /// on empty / error — base fee alone still shows (recipe gotcha #6).
    private static func recentPriorityLamports(chain: SupportedChain) async -> UInt64 {
        guard let data = try? await RPCClient.shared.callJSONResultData(
            chain: chain, method: "getRecentPrioritizationFees", params: []
        ) else {
            return 0
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return 0
        }
        let fees: [UInt64] = arr.compactMap { ($0["prioritizationFee"] as? NSNumber)?.uint64Value }
            .filter { $0 > 0 }
        guard !fees.isEmpty else { return 0 }
        let sum = fees.reduce(UInt64(0)) { $0 &+ $1 }
        return sum / UInt64(fees.count)
    }

    // MARK: - Error mapping

    private static func broadcastMessage(for error: RPCError) -> String {
        let raw = "\(error)".lowercased()
        if raw.contains("blockhash") { return "The transaction expired before it landed. Try again." }
        if raw.contains("insufficient") || raw.contains("lamports") {
            return "Balance is less than the amount plus the network fee."
        }
        if raw.contains("signature") { return "The transaction signature was rejected." }
        return "The network rejected the transaction. Try again."
    }
}
