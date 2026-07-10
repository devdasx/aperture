import Foundation
import WalletCore

/// Builds + signs TON transactions (native TON transfer + jetton (token)
/// transfer, with a text comment/memo + bounceable resolution + send
/// mode) from `SendDraft` + just-in-time data.
///
/// **Multi-recipient (BUG-001):** wallet v4r2 carries up to 4 outgoing
/// messages per signed op. Every draft recipient becomes one
/// `TheOpenNetworkTransfer` in `messages[]` — never only the first.
enum TONTransactionSigner {

    /// TON amount attached to a jetton transfer message for gas. TON's
    /// Jetton transfer flow sends an internal message to the sender's
    /// jetton wallet; the attached TON funds that message path and excess
    /// is returned. TonAPI's current cookbook uses 0.05 TON.
    static let jettonGasAttachNanoton: UInt64 = 50_000_000
    static let jettonGasAttachTON: Decimal = ComposeDecimal.toDisplay(
        Decimal(jettonGasAttachNanoton),
        decimals: SupportedChain.ton.nativeDecimals
    )
    /// 1 nanoton forward to trigger the transfer notification.
    private static let jettonForwardNanoton: UInt64 = 1
    /// External-message expiry window (now + 60s).
    private static let expirySeconds: UInt32 = 60

    static func sign(
        draft: SendDraft,
        jit: TransactionSigner.JustInTimeData,
        privateKey: PrivateKey
    ) throws -> SignedTransaction {
        guard draft.chain == .ton else {
            throw SigningError.malformedDraft("TON signer used for \(draft.chain.rawValue)")
        }
        let recipients = try SendRecipientSigning.requireRecipients(draft)
        guard let seqno = jit.tonSeqno else {
            throw SigningError.justInTimeRefreshFailed("TON seqno not refreshed")
        }

        let comment = tonComment(from: draft.memo)
        let standardMode = UInt32(
            TheOpenNetworkSendMode.payFeesSeparately.rawValue |
            TheOpenNetworkSendMode.ignoreActionPhaseErrors.rawValue
        )

        var messages: [TheOpenNetworkTransfer] = []
        messages.reserveCapacity(recipients.count)

        if draft.isTokenSend {
            guard let senderJettonWallet = jit.tonSenderJettonWallet, !senderJettonWallet.isEmpty else {
                throw SigningError.justInTimeRefreshFailed("TON sender jetton wallet not resolved")
            }
            for r in recipients {
                guard let jettonAmount = SigningAmount.uint64(display: r.amount, decimals: draft.effectiveDecimals) else {
                    throw SigningError.malformedDraft("invalid jetton amount")
                }
                var jetton = TheOpenNetworkJettonTransfer()
                jetton.jettonAmount = jettonAmount
                jetton.toOwner = r.address
                jetton.responseAddress = draft.fromAddress
                jetton.forwardAmount = jettonForwardNanoton

                var transfer = TheOpenNetworkTransfer()
                transfer.dest = senderJettonWallet
                transfer.amount = jettonGasAttachNanoton
                transfer.mode = standardMode
                transfer.bounceable = true
                transfer.jettonTransfer = jetton
                messages.append(transfer)
            }
        } else {
            for (index, r) in recipients.enumerated() {
                guard let nanoton = SigningAmount.uint64(display: r.amount, decimals: draft.chain.nativeDecimals) else {
                    throw SigningError.malformedDraft("invalid TON amount")
                }
                var transfer = TheOpenNetworkTransfer()
                transfer.dest = r.address
                transfer.amount = nanoton
                // Send-all is single-recipient only (validated by requireRecipients).
                transfer.mode = draft.isMaxSend
                    ? UInt32(TheOpenNetworkSendMode.attachAllContractBalance.rawValue)
                    : standardMode
                transfer.bounceable = draft.tonBounceable ?? false
                // Tag semantics: attach comment to the first message only.
                if index == 0, !comment.isEmpty {
                    transfer.comment = comment
                }
                messages.append(transfer)
            }
        }

        var input = TheOpenNetworkSigningInput()
        input.privateKey = privateKey.data
        input.walletVersion = .walletV4R2
        input.sequenceNumber = seqno
        input.expireAt = UInt32(Date().timeIntervalSince1970) + expirySeconds
        input.messages = messages

        let output: TheOpenNetworkSigningOutput = AnySigner.sign(input: input, coin: .ton)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "TON: empty AnySigner output" : output.errorMessage)
        }

        let rawData = Data(base64Encoded: output.encoded) ?? Data(output.encoded.utf8)
        return SignedTransaction(
            rawData: rawData,
            rawHex: output.encoded,
            txHash: output.hash.hexString
        )
    }

    // MARK: - Helpers

    private static func tonComment(from memo: SendMemoValue) -> String {
        switch memo {
        case .tonComment(let s): return s
        case .text(let s):       return s
        default:                 return ""
        }
    }
}
