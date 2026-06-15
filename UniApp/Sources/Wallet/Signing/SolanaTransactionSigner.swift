import Foundation
import WalletCore

/// Builds + signs Solana transactions (native SOL + SPL token transfer,
/// with idempotent ATA creation + optional SPL memo + compute-budget
/// priority fee) from `SendDraft` + just-in-time data, adapted from
/// Stabro's proven `signSolanaTransaction` onto Aperture's contracts.
///
/// **wallet-core SigningInput (Solana.proto, WalletCore 4.6.13 —
/// field names verified against the pinned `arm64.swiftinterface`):**
/// `privateKey`, `sender`, `recentBlockhash` (JIT), `txEncoding`
/// (`.base64`), `priorityFeePrice` (micro-lamports/CU), `priorityFeeLimit`
/// (compute units), and the transaction oneof:
/// - `transferTransaction` = `SolanaTransfer{recipient, value(lamports), memo}`
///   for native SOL.
/// - `tokenTransferTransaction` = `SolanaTokenTransfer{tokenMintAddress,
///   senderTokenAddress, recipientTokenAddress, amount, decimals, memo,
///   tokenProgramID}` when the recipient ATA already exists.
/// - `createAndTransferTokenTransaction` = `SolanaCreateAndTransferToken{…}`
///   (idempotent ATA create + transfer) when it does not.
///
/// **Fee model (matrix §G4, doc-grounded — solana.com/docs/core/fees):**
/// base = 5,000 lamports/signature (static); priority = ceil(price ×
/// limit / 1e6) lamports, billed on the REQUESTED limit. The draft's
/// `FeeChoice.computeUnitPrice` (micro-lamports/CU) + `.computeUnitLimit`
/// (CU) drive wallet-core's `SetComputeUnitPrice`/`SetComputeUnitLimit`
/// compute-budget instructions. A 0 price (idle network) is allowed.
///
/// **JIT:** `recentBlockhash` (getLatestBlockhash, ~60–90s validity) +
/// the resolved sender/recipient ATAs and whether the recipient ATA must
/// be created (getTokenAccountsByOwner / derived ATA). Broadcast:
/// `sendTransaction` (base64); confirm `getSignatureStatuses`.
///
/// Output: `output.encoded` is the base64 signed tx; the node assigns the
/// signature/txid at broadcast (Solana's signature is the first signature
/// of the tx — `txHash` left empty, the broadcaster returns the real id).
enum SolanaTransactionSigner {

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .solana else {
            throw SigningError.malformedDraft("Solana signer used for \(draft.chain.rawValue)")
        }
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let blockhash = jit.solanaRecentBlockhash, !blockhash.isEmpty else {
            throw SigningError.justInTimeRefreshFailed("Solana recent blockhash not refreshed")
        }

        var input = SolanaSigningInput()
        input.privateKey = privateKey.data
        input.sender = draft.fromAddress
        input.recentBlockhash = blockhash
        input.txEncoding = .base64

        // Compute-budget priority fee (matrix §G4). Price is
        // micro-lamports/CU, limit is compute units; both come from the
        // resolved FeeChoice. A 0 price is valid (idle network); set the
        // instructions only when a positive price/limit is present so a
        // bare transfer isn't burdened with a no-op compute-budget ix.
        if let priceDec = draft.fee.computeUnitPrice,
           let price = SigningAmount.uint64(priceDec), price > 0 {
            input.priorityFeePrice = SolanaPriorityFeePrice.with { $0.price = price }
        }
        if let limitDec = draft.fee.computeUnitLimit,
           let limit = SigningAmount.uint64(limitDec), limit > 0, limit <= UInt32.max {
            input.priorityFeeLimit = SolanaPriorityFeeLimit.with { $0.limit = UInt32(limit) }
        }

        let memo = solanaMemo(from: draft.memo)

        if draft.isTokenSend {
            try buildTokenTransfer(&input, draft: draft, recipient: recipient, memo: memo, jit: jit)
        } else {
            guard let lamports = SigningAmount.uint64(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
                throw SigningError.malformedDraft("invalid SOL amount")
            }
            input.transferTransaction = SolanaTransfer.with {
                $0.recipient = recipient.address
                $0.value = lamports
                if !memo.isEmpty { $0.memo = memo }
            }
        }

        let output: SolanaSigningOutput = AnySigner.sign(input: input, coin: .solana)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SigningError.signingFailed(reason(output))
        }

        let rawData = Data(output.encoded.utf8)
        return SignedTransaction(
            rawData: rawData,
            rawHex: output.encoded, // base64 wire form for sendTransaction
            txHash: ""              // node assigns the signature at broadcast
        )
    }

    // MARK: - Token transfer

    private static func buildTokenTransfer(
        _ input: inout SolanaSigningInput,
        draft: SendDraft,
        recipient: SendRecipientAmount,
        memo: String,
        jit: TransactionSigner.JustInTimeData
    ) throws {
        guard let mint = draft.tokenContract, !mint.isEmpty else {
            throw SigningError.malformedDraft("SPL token send missing mint")
        }
        guard let amount = SigningAmount.uint64(display: recipient.amount, decimals: draft.effectiveDecimals) else {
            throw SigningError.malformedDraft("invalid SPL token amount")
        }
        let decimals = UInt32(max(0, draft.effectiveDecimals))

        // The ATAs are derived by the compose/JIT layer (the recipient's
        // ATA must be checked for existence). Fall back to local
        // derivation via wallet-core's SolanaAddress so the signer never
        // hard-fails when the JIT layer didn't pre-resolve them.
        let senderATA = jit.solanaSenderTokenAccount
            ?? SolanaAddress(string: draft.fromAddress)?.defaultTokenAddress(tokenMintAddress: mint)
        let recipientATA = jit.solanaRecipientTokenAccount
            ?? SolanaAddress(string: recipient.address)?.defaultTokenAddress(tokenMintAddress: mint)
        guard let senderATA, !senderATA.isEmpty, let recipientATA, !recipientATA.isEmpty else {
            throw SigningError.malformedDraft("could not derive SPL token accounts")
        }

        // `recipientNeedsActivation` (set by compose) OR the JIT
        // existence check selects CreateAndTransfer (idempotent create +
        // transfer) vs a plain TokenTransfer when the ATA already exists.
        let needsCreation = jit.solanaRecipientATANeedsCreation ?? draft.recipientNeedsActivation

        if needsCreation {
            input.createAndTransferTokenTransaction = SolanaCreateAndTransferToken.with {
                $0.recipientMainAddress = recipient.address
                $0.tokenMintAddress = mint
                $0.recipientTokenAddress = recipientATA
                $0.senderTokenAddress = senderATA
                $0.amount = amount
                $0.decimals = decimals
                if !memo.isEmpty { $0.memo = memo }
            }
        } else {
            input.tokenTransferTransaction = SolanaTokenTransfer.with {
                $0.tokenMintAddress = mint
                $0.senderTokenAddress = senderATA
                $0.recipientTokenAddress = recipientATA
                $0.amount = amount
                $0.decimals = decimals
                if !memo.isEmpty { $0.memo = memo }
            }
        }
    }

    // MARK: - Helpers

    /// SPL memo string from the draft's typed memo (exchanges may require
    /// it — matrix §G4 "destination-tag equivalent").
    private static func solanaMemo(from memo: SendMemoValue) -> String {
        switch memo {
        case .splMemo(let s): return s
        case .text(let s):    return s
        default:              return ""
        }
    }

    private static func reason(_ output: SolanaSigningOutput) -> String {
        output.errorMessage.isEmpty ? "Solana: empty AnySigner output" : output.errorMessage
    }
}
