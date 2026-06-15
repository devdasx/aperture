import Foundation
import WalletCore

/// Builds + signs TON transactions (native TON transfer + jetton (token)
/// transfer, with a text comment/memo + bounceable resolution + send
/// mode) from `SendDraft` + just-in-time data, adapted from Stabro's
/// proven `signTonTransaction` onto Aperture's contracts.
///
/// **wallet-core SigningInput (TheOpenNetwork.proto, WalletCore 4.6.13 —
/// field names verified against the pinned `arm64.swiftinterface` + the
/// upstream `TheOpenNetworkTests.swift` fixture):**
/// `privateKey`, `walletVersion` (enum), `sequenceNumber` (seqno, JIT),
/// `expireAt` (now+N), `messages:[TheOpenNetworkTransfer]` (≤4). Each
/// `Transfer{dest, amount (nanoton), mode, comment, bounceable,
/// jettonTransfer?}`. For a jetton send, `dest` is the SENDER's jetton
/// wallet (JIT), `amount` carries ~0.05 TON of gas, and
/// `jettonTransfer = JettonTransfer{jettonAmount, toOwner, responseAddress,
/// forwardAmount}` rides inside.
///
/// **Fee model (matrix §G7, doc-grounded — fees):** deterministic
/// phase-based fee (no user gas price). The signer sets the send mode and
/// the attached amount; mode 3 (pay-fees-separately | ignore-action-phase
/// -errors) is the standard wallet transfer, mode 128 is send-all.
///
/// **Comment/memo (matrix §G7):** TON's destination-tag equivalent —
/// exchanges require it. wallet-core wraps the text as the
/// 0x00000000-prefixed comment cell via `transfer.comment`.
///
/// **Bounceable (matrix §G7):** default `false` for user-to-user sends so
/// funds aren't lost to an uninitialized recipient; `draft.tonBounceable`
/// overrides when the compose layer resolved it (jetton-wallet
/// destinations are bounceable=true, as in the reference).
///
/// Output: `output.encoded` is the base64 signed external-message BoC for
/// `sendBocReturnHash`; `output.hash` is the cell/tx hash.
enum TONTransactionSigner {

    /// TON amount attached to a jetton transfer message for gas
    /// (TON Foundation recommendation ~0.05 TON; matrix §G7).
    private static let jettonGasAttachNanoton: UInt64 = 100_000_000 // 0.1 TON (reference value)
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
        guard let recipient = draft.recipients.first else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard let seqno = jit.tonSeqno else {
            throw SigningError.justInTimeRefreshFailed("TON seqno not refreshed")
        }

        let comment = tonComment(from: draft.memo)
        let standardMode = UInt32(
            TheOpenNetworkSendMode.payFeesSeparately.rawValue |
            TheOpenNetworkSendMode.ignoreActionPhaseErrors.rawValue
        )

        var transfer = TheOpenNetworkTransfer()

        if draft.isTokenSend {
            guard let senderJettonWallet = jit.tonSenderJettonWallet, !senderJettonWallet.isEmpty else {
                throw SigningError.justInTimeRefreshFailed("TON sender jetton wallet not resolved")
            }
            guard let jettonAmount = SigningAmount.uint64(display: recipient.amount, decimals: draft.effectiveDecimals) else {
                throw SigningError.malformedDraft("invalid jetton amount")
            }
            var jetton = TheOpenNetworkJettonTransfer()
            jetton.jettonAmount = jettonAmount
            jetton.toOwner = recipient.address
            jetton.responseAddress = draft.fromAddress // excesses return to sender
            jetton.forwardAmount = jettonForwardNanoton
            // The message goes to the SENDER's jetton wallet, carrying TON
            // for gas; jetton transfers are bounceable.
            transfer.dest = senderJettonWallet
            transfer.amount = jettonGasAttachNanoton
            transfer.mode = standardMode
            transfer.bounceable = true
            transfer.jettonTransfer = jetton
        } else {
            guard let nanoton = SigningAmount.uint64(display: recipient.amount, decimals: draft.chain.nativeDecimals) else {
                throw SigningError.malformedDraft("invalid TON amount")
            }
            transfer.dest = recipient.address
            transfer.amount = nanoton
            // Send-all uses mode 128 (attach all contract balance).
            transfer.mode = draft.isMaxSend
                ? UInt32(TheOpenNetworkSendMode.attachAllContractBalance.rawValue)
                : standardMode
            // Default non-bounceable for user wallets (matrix §G7) so funds
            // aren't lost to an uninitialized recipient; honor the compose
            // resolution when present.
            transfer.bounceable = draft.tonBounceable ?? false
            if !comment.isEmpty { transfer.comment = comment }
        }

        var input = TheOpenNetworkSigningInput()
        input.privateKey = privateKey.data
        input.walletVersion = .walletV4R2
        input.sequenceNumber = seqno
        input.expireAt = UInt32(Date().timeIntervalSince1970) + expirySeconds
        input.messages = [transfer]

        let output: TheOpenNetworkSigningOutput = AnySigner.sign(input: input, coin: .ton)
        guard output.error == .ok, !output.encoded.isEmpty else {
            throw SigningError.signingFailed(output.errorMessage.isEmpty ? "TON: empty AnySigner output" : output.errorMessage)
        }

        // `output.encoded` is a base64 BoC; decode to binary for rawData,
        // keep the base64 as the broadcast wire form (sendBocReturnHash).
        let rawData = Data(base64Encoded: output.encoded) ?? Data(output.encoded.utf8)
        return SignedTransaction(
            rawData: rawData,
            rawHex: output.encoded,        // base64 BoC for sendBocReturnHash
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
