import Foundation
import WalletCore

/// Builds + signs Solana transactions (native SOL + SPL token transfer).
///
/// **Multi-recipient (BUG-001):**
/// - N = 1: WalletCore high-level transfer / token transfer paths.
/// - N > 1 native: `RawMessage` with N `SystemProgram.transfer` instructions.
/// - N > 1 SPL: `RawMessage` with N token transfers (all recipient ATAs must
///   already exist — creation is single-recipient only in the high-level path).
enum SolanaTransactionSigner {

    private static let systemProgramID = "11111111111111111111111111111111"
    /// SystemProgram::Transfer instruction index.
    private static let systemTransferIx: UInt32 = 2
    /// SPL Token::Transfer instruction index.
    private static let tokenTransferIx: UInt8 = 3

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .solana else {
            throw SigningError.malformedDraft("Solana signer used for \(draft.chain.rawValue)")
        }
        let recipients = try SendRecipientSigning.requireRecipients(draft)
        guard let blockhash = jit.solanaRecentBlockhash, !blockhash.isEmpty else {
            throw SigningError.justInTimeRefreshFailed("Solana recent blockhash not refreshed")
        }

        var input = SolanaSigningInput()
        input.privateKey = privateKey.data
        input.sender = draft.fromAddress
        input.recentBlockhash = blockhash
        input.txEncoding = .base64

        applyPriorityFees(&input, draft: draft, recipientCount: recipients.count)

        let memo = solanaMemo(from: draft.memo)

        if recipients.count == 1, let recipient = recipients.first {
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
        } else if draft.isTokenSend {
            try buildMultiTokenTransfer(&input, draft: draft, recipients: recipients, blockhash: blockhash, jit: jit)
        } else {
            try buildMultiNativeTransfer(&input, draft: draft, recipients: recipients, blockhash: blockhash)
        }

        let output: SolanaSigningOutput = AnySigner.sign(input: input, coin: .solana)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SigningError.signingFailed(reason(output))
        }

        let rawData = Data(output.encoded.utf8)
        return SignedTransaction(
            rawData: rawData,
            rawHex: output.encoded,
            txHash: ""
        )
    }

    // MARK: - Priority fees

    private static func applyPriorityFees(
        _ input: inout SolanaSigningInput,
        draft: SendDraft,
        recipientCount: Int
    ) {
        if let priceDec = draft.fee.computeUnitPrice,
           let price = SigningAmount.uint64(priceDec), price > 0 {
            input.priorityFeePrice = SolanaPriorityFeePrice.with { $0.price = price }
        }
        let scaledLimit: UInt64 = {
            if let limitDec = draft.fee.computeUnitLimit,
               let limit = SigningAmount.uint64(limitDec), limit > 0 {
                return limit
            }
            // Multi transfers need more CU headroom.
            let base: UInt64 = draft.isTokenSend ? 50_000 : 450
            return base &* UInt64(max(1, min(recipientCount, 15)))
        }()
        if scaledLimit > 0, scaledLimit <= UInt32.max {
            input.priorityFeeLimit = SolanaPriorityFeeLimit.with { $0.limit = UInt32(scaledLimit) }
        }
    }

    // MARK: - Single token transfer (high-level WC)

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

        let tokenProgramId = SolanaTokenRegistry.tokenProgramId(for: mint)
        let senderATA = jit.solanaSenderTokenAccount
            ?? SolanaProgramDerivedAddress.associatedTokenAddress(
                owner: draft.fromAddress,
                mint: mint,
                tokenProgramId: tokenProgramId
            )
            ?? SolanaAddress(string: draft.fromAddress)?.defaultTokenAddress(tokenMintAddress: mint)
        let recipientATA = jit.solanaRecipientTokenAccount
            ?? jit.solanaRecipientTokenAccountsByOwner?[recipient.address]
            ?? SolanaProgramDerivedAddress.associatedTokenAddress(
                owner: recipient.address,
                mint: mint,
                tokenProgramId: tokenProgramId
            )
            ?? SolanaAddress(string: recipient.address)?.defaultTokenAddress(tokenMintAddress: mint)
        guard let senderATA, !senderATA.isEmpty, let recipientATA, !recipientATA.isEmpty else {
            throw SigningError.malformedDraft("could not derive SPL token accounts")
        }
        let walletCoreTokenProgram = walletCoreTokenProgramId(for: SolanaTokenRegistry.standard(for: mint))

        let needsCreation = jit.solanaRecipientATANeedsCreationByOwner?[recipient.address]
            ?? jit.solanaRecipientATANeedsCreation
            ?? draft.recipientNeedsActivation

        if needsCreation {
            input.createAndTransferTokenTransaction = SolanaCreateAndTransferToken.with {
                $0.recipientMainAddress = recipient.address
                $0.tokenMintAddress = mint
                $0.recipientTokenAddress = recipientATA
                $0.senderTokenAddress = senderATA
                $0.amount = amount
                $0.decimals = decimals
                $0.tokenProgramID = walletCoreTokenProgram
                if !memo.isEmpty { $0.memo = memo }
            }
        } else {
            input.tokenTransferTransaction = SolanaTokenTransfer.with {
                $0.tokenMintAddress = mint
                $0.senderTokenAddress = senderATA
                $0.recipientTokenAddress = recipientATA
                $0.amount = amount
                $0.decimals = decimals
                $0.tokenProgramID = walletCoreTokenProgram
                if !memo.isEmpty { $0.memo = memo }
            }
        }
    }

    // MARK: - Multi native (RawMessage)

    private static func buildMultiNativeTransfer(
        _ input: inout SolanaSigningInput,
        draft: SendDraft,
        recipients: [SendRecipientAmount],
        blockhash: String
    ) throws {
        // account_keys: [signer, r1, r2, …, systemProgram]
        var accountKeys: [String] = [draft.fromAddress]
        var recipientIndices: [UInt32] = []
        recipientIndices.reserveCapacity(recipients.count)
        for r in recipients {
            if let existing = accountKeys.firstIndex(of: r.address) {
                recipientIndices.append(UInt32(existing))
            } else {
                recipientIndices.append(UInt32(accountKeys.count))
                accountKeys.append(r.address)
            }
        }
        let systemProgramIndex = UInt32(accountKeys.count)
        accountKeys.append(systemProgramID)

        var instructions: [SolanaRawMessage.Instruction] = []
        instructions.reserveCapacity(recipients.count)
        for (i, r) in recipients.enumerated() {
            guard let lamports = SigningAmount.uint64(display: r.amount, decimals: draft.chain.nativeDecimals) else {
                throw SigningError.malformedDraft("invalid SOL amount")
            }
            instructions.append(SolanaRawMessage.Instruction.with {
                $0.programID = systemProgramIndex
                $0.accounts = [0, recipientIndices[i]] // from (signer), to
                $0.programData = systemTransferData(lamports: lamports)
            })
        }

        let legacy = SolanaRawMessage.MessageLegacy.with {
            $0.header = SolanaRawMessage.MessageHeader.with {
                $0.numRequiredSignatures = 1
                $0.numReadonlySignedAccounts = 0
                $0.numReadonlyUnsignedAccounts = 1 // system program
            }
            $0.accountKeys = accountKeys
            $0.recentBlockhash = blockhash
            $0.instructions = instructions
        }
        input.rawMessage = SolanaRawMessage.with {
            $0.legacy = legacy
        }
    }

    // MARK: - Multi SPL (RawMessage, ATAs must exist)

    private static func buildMultiTokenTransfer(
        _ input: inout SolanaSigningInput,
        draft: SendDraft,
        recipients: [SendRecipientAmount],
        blockhash: String,
        jit: TransactionSigner.JustInTimeData
    ) throws {
        guard let mint = draft.tokenContract, !mint.isEmpty else {
            throw SigningError.malformedDraft("SPL token send missing mint")
        }
        let tokenProgramId = SolanaTokenRegistry.tokenProgramId(for: mint)
        let senderATA = jit.solanaSenderTokenAccount
            ?? SolanaProgramDerivedAddress.associatedTokenAddress(
                owner: draft.fromAddress,
                mint: mint,
                tokenProgramId: tokenProgramId
            )
            ?? SolanaAddress(string: draft.fromAddress)?.defaultTokenAddress(tokenMintAddress: mint)
        guard let senderATA, !senderATA.isEmpty else {
            throw SigningError.malformedDraft("could not derive sender SPL token account")
        }

        // Multi SPL requires every recipient ATA to already exist.
        var recipientATAs: [(owner: String, ata: String)] = []
        recipientATAs.reserveCapacity(recipients.count)
        for r in recipients {
            if jit.solanaRecipientATANeedsCreationByOwner?[r.address] == true {
                throw SigningError.signingFailed(
                    "One or more recipients need a token account created first. Send to them individually, or fund their token account, then try multi-send again."
                )
            }
            let ata = jit.solanaRecipientTokenAccountsByOwner?[r.address]
                ?? SolanaProgramDerivedAddress.associatedTokenAddress(
                    owner: r.address,
                    mint: mint,
                    tokenProgramId: tokenProgramId
                )
                ?? SolanaAddress(string: r.address)?.defaultTokenAddress(tokenMintAddress: mint)
            guard let ata, !ata.isEmpty else {
                throw SigningError.malformedDraft("could not derive recipient SPL token account")
            }
            recipientATAs.append((r.address, ata))
        }

        // account_keys: [signer, senderATA, rATA1…, tokenProgram]
        var accountKeys: [String] = [draft.fromAddress, senderATA]
        var destIndices: [UInt32] = []
        for (_, ata) in recipientATAs {
            if let existing = accountKeys.firstIndex(of: ata) {
                destIndices.append(UInt32(existing))
            } else {
                destIndices.append(UInt32(accountKeys.count))
                accountKeys.append(ata)
            }
        }
        let tokenProgramIndex = UInt32(accountKeys.count)
        accountKeys.append(tokenProgramId)

        var instructions: [SolanaRawMessage.Instruction] = []
        for (i, r) in recipients.enumerated() {
            guard let amount = SigningAmount.uint64(display: r.amount, decimals: draft.effectiveDecimals) else {
                throw SigningError.malformedDraft("invalid SPL token amount")
            }
            // Token Transfer accounts: source, dest, authority
            instructions.append(SolanaRawMessage.Instruction.with {
                $0.programID = tokenProgramIndex
                $0.accounts = [1, destIndices[i], 0]
                $0.programData = tokenTransferData(amount: amount)
            })
        }

        let legacy = SolanaRawMessage.MessageLegacy.with {
            $0.header = SolanaRawMessage.MessageHeader.with {
                $0.numRequiredSignatures = 1
                $0.numReadonlySignedAccounts = 0
                $0.numReadonlyUnsignedAccounts = 1 // token program
            }
            $0.accountKeys = accountKeys
            $0.recentBlockhash = blockhash
            $0.instructions = instructions
        }
        input.rawMessage = SolanaRawMessage.with {
            $0.legacy = legacy
        }
    }

    // MARK: - Instruction data

    private static func systemTransferData(lamports: UInt64) -> Data {
        var data = Data(count: 12)
        // u32 LE instruction index = 2 (Transfer)
        data[0] = UInt8(systemTransferIx & 0xff)
        data[1] = UInt8((systemTransferIx >> 8) & 0xff)
        data[2] = UInt8((systemTransferIx >> 16) & 0xff)
        data[3] = UInt8((systemTransferIx >> 24) & 0xff)
        var le = lamports.littleEndian
        withUnsafeBytes(of: &le) { data.replaceSubrange(4..<12, with: $0) }
        return data
    }

    private static func tokenTransferData(amount: UInt64) -> Data {
        var data = Data([tokenTransferIx])
        var le = amount.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        return data
    }

    // MARK: - Helpers

    private static func solanaMemo(from memo: SendMemoValue) -> String {
        switch memo {
        case .splMemo(let s): return s
        case .text(let s):    return s
        default:              return ""
        }
    }

    private static func walletCoreTokenProgramId(for standard: SolanaTokenStandard) -> SolanaTokenProgramId {
        switch standard {
        case .splToken:
            return .tokenProgram
        case .splToken2022:
            return .token2022Program
        }
    }

    private static func reason(_ output: SolanaSigningOutput) -> String {
        output.errorMessage.isEmpty ? "Solana: empty AnySigner output" : output.errorMessage
    }
}
