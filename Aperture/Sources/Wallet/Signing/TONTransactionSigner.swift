import Foundation
import WalletCore

/// Builds + signs TON transactions (native TON transfer + jetton (token)
/// transfer, with a text comment/memo + bounceable resolution + send
/// mode) from `SendDraft` + just-in-time data.
///
/// **Multi-recipient (BUG-001):** wallet v4r2 carries up to 4 outgoing
/// messages per signed op. Every draft recipient becomes one
/// `TheOpenNetworkTransfer` in `messages[]` — never only the first.
///
/// **Jetton comments (BUG-006):** WalletCore attaches a text comment on a
/// jetton send by setting `Transfer.comment` **alongside**
/// `Transfer.jettonTransfer` (see `TheOpenNetworkTests.testJettonTransferSign`).
/// The outer `comment` becomes the jetton transfer’s forward payload so
/// exchanges that require a memo still credit the deposit. Silently
/// dropping the memo is never acceptable.
enum TONTransactionSigner {

    /// TON amount attached to **each** jetton transfer message for gas.
    /// Jetton transfer flow sends an internal message to the sender's
    /// jetton wallet; the attached TON funds that message path and excess
    /// is returned. TonAPI's current cookbook uses 0.05 TON.
    ///
    /// **P1-004:** multi-recipient jetton sends attach this amount once per
    /// message (up to 4). Compose fee must reserve `× recipientCount`.
    static let jettonGasAttachNanoton: UInt64 = 50_000_000
    static let jettonGasAttachTON: Decimal = ComposeDecimal.toDisplay(
        Decimal(jettonGasAttachNanoton),
        decimals: SupportedChain.ton.nativeDecimals
    )
    /// 1 nanoton forward to trigger the transfer notification (and to carry
    /// the comment cell as forward payload when a memo is set).
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
        // P2-022: do not set ignoreActionPhaseErrors on standard transfers.
        // That flag can report external-message success while action-phase
        // fails (confirm UX risk). Pay fees separately only.
        let standardMode = UInt32(
            TheOpenNetworkSendMode.payFeesSeparately.rawValue
        )

        var messages: [TheOpenNetworkTransfer] = []
        messages.reserveCapacity(recipients.count)

        if draft.isTokenSend {
            guard let senderJettonWallet = jit.tonSenderJettonWallet, !senderJettonWallet.isEmpty else {
                throw SigningError.justInTimeRefreshFailed("TON sender jetton wallet not resolved")
            }
            for (index, r) in recipients.enumerated() {
                guard let jettonAmount = SigningAmount.uint64(display: r.amount, decimals: draft.effectiveDecimals) else {
                    throw SigningError.malformedDraft("invalid jetton amount")
                }
                var jetton = TheOpenNetworkJettonTransfer()
                jetton.jettonAmount = jettonAmount
                jetton.toOwner = r.address
                jetton.responseAddress = draft.fromAddress
                // forwardAmount ≥ 1 nanoton so a comment cell can ride as
                // the internal notification payload (WalletCore jetton path).
                jetton.forwardAmount = jettonForwardNanoton

                var transfer = TheOpenNetworkTransfer()
                transfer.dest = senderJettonWallet
                transfer.amount = jettonGasAttachNanoton
                transfer.mode = standardMode
                transfer.bounceable = true
                transfer.jettonTransfer = jetton
                // BUG-006: same field native TON uses. WalletCore encodes it
                // into the jetton transfer forward payload (not ignored when
                // jettonTransfer is set — verified against WC fixture).
                // First message only for multi-recipient tag semantics.
                if index == 0, !comment.isEmpty {
                    transfer.comment = comment
                }
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

    /// Extract a TON text comment from the draft memo (empty if none).
    static func tonComment(from memo: SendMemoValue) -> String {
        switch memo {
        case .tonComment(let s): return s
        case .text(let s):       return s
        default:                 return ""
        }
    }
}
