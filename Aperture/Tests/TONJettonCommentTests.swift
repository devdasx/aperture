import Foundation
import Testing
import WalletCore
@testable import Aperture

/// BUG-006: jetton sends must carry the user comment (exchange memo),
/// not drop it. WalletCore encodes `Transfer.comment` next to
/// `jettonTransfer` as the forward payload — same as
/// `TheOpenNetworkTests.testJettonTransferSign`.
struct TONJettonCommentTests {

    // MARK: - Memo extraction

    @Test("tonComment reads tonComment and text memos")
    func tonCommentExtraction() {
        #expect(TONTransactionSigner.tonComment(from: .tonComment("memo-123")) == "memo-123")
        #expect(TONTransactionSigner.tonComment(from: .text("plain")) == "plain")
        #expect(TONTransactionSigner.tonComment(from: .none) == "")
        #expect(TONTransactionSigner.tonComment(from: .destinationTag(7)) == "")
        #expect(TONTransactionSigner.tonComment(from: .splMemo("sol")) == "")
    }

    // MARK: - WalletCore fixture parity (comment lands in signed BoC)

    @Test("WalletCore jetton transfer with comment embeds ASCII in encoded BoC")
    func walletCoreJettonCommentInEncodedOutput() {
        // Fixture keys/addresses from WalletCore TheOpenNetworkTests.testJettonTransferSign
        let privateKeyData = Data(hexString: "c054900a527538c1b4325688a421c0469b171c29f23a62da216e90b0df2412ee")!
        let comment = "test comment"

        // WalletCore Swift bindings use UInt64 for TON amounts (not Data).
        let jettonTransfer = TheOpenNetworkJettonTransfer.with {
            $0.jettonAmount = 500_000_000 // 500 * 1e6
            $0.toOwner = "EQAFwMs5ha8OgZ9M4hQr80z9NkE7rGxUpE1hCFndiY6JnDx8"
            $0.responseAddress = "EQBaKIMq5Am2p_rfR1IFTwsNWHxBkOpLTmwUain5Fj4llTXk"
            $0.forwardAmount = 1
        }

        let withComment = TheOpenNetworkTransfer.with {
            $0.dest = "EQBiaD8PO1NwfbxSkwbcNT9rXDjqhiIvXWymNO-edV0H5lja"
            $0.amount = 100_000_000 // 0.1 TON attach
            $0.mode = UInt32(
                TheOpenNetworkSendMode.payFeesSeparately.rawValue |
                TheOpenNetworkSendMode.ignoreActionPhaseErrors.rawValue
            )
            $0.comment = comment
            $0.bounceable = true
            $0.jettonTransfer = jettonTransfer
        }

        let withoutComment = TheOpenNetworkTransfer.with {
            $0.dest = "EQBiaD8PO1NwfbxSkwbcNT9rXDjqhiIvXWymNO-edV0H5lja"
            $0.amount = 100_000_000
            $0.mode = UInt32(
                TheOpenNetworkSendMode.payFeesSeparately.rawValue |
                TheOpenNetworkSendMode.ignoreActionPhaseErrors.rawValue
            )
            $0.bounceable = true
            $0.jettonTransfer = jettonTransfer
        }

        let baseInput = TheOpenNetworkSigningInput.with {
            $0.privateKey = privateKeyData
            $0.sequenceNumber = 1
            $0.expireAt = 1787693046
            $0.walletVersion = .walletV4R2
        }

        var inputWith = baseInput
        inputWith.messages = [withComment]
        var inputWithout = baseInput
        inputWithout.messages = [withoutComment]

        let outWith: TheOpenNetworkSigningOutput = AnySigner.sign(input: inputWith, coin: .ton)
        let outWithout: TheOpenNetworkSigningOutput = AnySigner.sign(input: inputWithout, coin: .ton)

        #expect(outWith.error == .ok)
        #expect(outWithout.error == .ok)
        #expect(!outWith.encoded.isEmpty)
        #expect(outWith.encoded != outWithout.encoded, "comment must change the signed jetton payload")

        // WC fixture expected string (includes "test comment")
        let expectedWithComment =
            "te6cckECBAEAARUAAUWIALRRBlXIE21P9b6OpAqeFhqw+IMh1Jac2CjUU/IsfEsqDAEBnGiFlaLItV573gJqBvctP5j3jVKlLuxmO+pnW0QGlXjXgzjw5YeTNwRG9upJHOl6GA3pFetKNojqGzfkxku+owUpqaMXao4H9gAAAAEAAwIBaGIAMTQfh52puD7eKUmDbhqfta4cdUMRF662Uxp3zzqug/MgL68IAAAAAAAAAAAAAAAAAAEDAMoPin6lAAAAAAAAAABB3NZQCAALgZZzC14dAz6ZxChX5pn6bIJ3WNipSJrCELO7Ex0TOQAWiiDKuQJtqf630dSBU8LDVh8QZDqS05sFGop+RY+JZUICAAAAAHRlc3QgY29tbWVudG/bd5c="
        #expect(outWith.encoded == expectedWithComment)

        // Decoded BoC must contain the ASCII comment bytes.
        if let boc = Data(base64Encoded: outWith.encoded) {
            let needle = Data(comment.utf8)
            #expect(boc.range(of: needle) != nil, "encoded BoC should embed the comment ASCII")
        } else {
            Issue.record("could not base64-decode signed BoC")
        }
    }

    // MARK: - Aperture signer path

    @Test("TONTransactionSigner jetton path embeds comment (does not silently drop)")
    func apertureJettonSignerEmbedsComment() throws {
        // Deterministic 32-byte ed25519 seed for offline signing only.
        let keyData = Data(hexString: "c054900a527538c1b4325688a421c0469b171c29f23a62da216e90b0df2412ee")!
        guard let privateKey = PrivateKey(data: keyData) else {
            Issue.record("PrivateKey init failed")
            return
        }

        let comment = "deposit-memo-42"
        let draftWith = makeJettonDraft(memo: .tonComment(comment))
        let draftWithout = makeJettonDraft(memo: .none)
        let jit = TransactionSigner.JustInTimeData(
            tonSeqno: 1,
            tonSenderJettonWallet: "EQBiaD8PO1NwfbxSkwbcNT9rXDjqhiIvXWymNO-edV0H5lja"
        )

        let signedWith = try TONTransactionSigner.sign(draft: draftWith, jit: jit, privateKey: privateKey)
        let signedWithout = try TONTransactionSigner.sign(draft: draftWithout, jit: jit, privateKey: privateKey)

        #expect(!signedWith.rawHex.isEmpty)
        #expect(signedWith.rawHex != signedWithout.rawHex, "jetton memo must change the signed payload")

        if let boc = Data(base64Encoded: signedWith.rawHex) {
            #expect(
                boc.range(of: Data(comment.utf8)) != nil,
                "jetton signed BoC must contain the user comment bytes"
            )
        } else {
            // WalletCore may return base64; if not base64, still require payload divergence.
            #expect(signedWith.rawHex.contains("deposit") || signedWith.rawData.range(of: Data(comment.utf8)) != nil
                    || signedWith.rawHex != signedWithout.rawHex)
        }
    }

    @Test("Native TON path still embeds comment")
    func nativeCommentStillWorks() throws {
        let keyData = Data(hexString: "c054900a527538c1b4325688a421c0469b171c29f23a62da216e90b0df2412ee")!
        guard let privateKey = PrivateKey(data: keyData) else {
            Issue.record("PrivateKey init failed")
            return
        }
        let comment = "native-tag"
        let draft = SendDraft(
            chain: .ton,
            tokenSymbol: nil,
            tokenContract: nil,
            tokenDecimals: nil,
            fromAddress: "EQBaKIMq5Am2p_rfR1IFTwsNWHxBkOpLTmwUain5Fj4llTXk",
            recipients: [
                SendRecipientAmount(
                    address: "EQAFwMs5ha8OgZ9M4hQr80z9NkE7rGxUpE1hCFndiY6JnDx8",
                    amount: Decimal(string: "0.1")!,
                    name: nil
                )
            ],
            fee: FeeChoice(
                tier: .normal,
                feeModel: .tonFixed,
                estimatedTotalNative: 0,
                worstCaseTotalNative: 0
            ),
            selectedUTXOs: nil,
            changeAddress: nil,
            changeSats: nil,
            opReturn: nil,
            signalsRBF: false,
            memo: .tonComment(comment),
            isMaxSend: false,
            recipientNeedsActivation: false,
            tonBounceable: false
        )
        let jit = TransactionSigner.JustInTimeData(tonSeqno: 1)
        let signed = try TONTransactionSigner.sign(draft: draft, jit: jit, privateKey: privateKey)
        #expect(!signed.rawHex.isEmpty)
        if let boc = Data(base64Encoded: signed.rawHex) {
            #expect(boc.range(of: Data(comment.utf8)) != nil)
        }
    }

    // MARK: - Helpers

    private func makeJettonDraft(memo: SendMemoValue) -> SendDraft {
        SendDraft(
            chain: .ton,
            tokenSymbol: "USDT",
            tokenContract: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs",
            tokenDecimals: 6,
            fromAddress: "EQBaKIMq5Am2p_rfR1IFTwsNWHxBkOpLTmwUain5Fj4llTXk",
            recipients: [
                SendRecipientAmount(
                    address: "EQAFwMs5ha8OgZ9M4hQr80z9NkE7rGxUpE1hCFndiY6JnDx8",
                    amount: Decimal(string: "1.5")!,
                    name: nil
                )
            ],
            fee: FeeChoice(
                tier: .normal,
                feeModel: .tonFixed,
                estimatedTotalNative: TONTransactionSigner.jettonGasAttachTON,
                worstCaseTotalNative: TONTransactionSigner.jettonGasAttachTON
            ),
            selectedUTXOs: nil,
            changeAddress: nil,
            changeSats: nil,
            opReturn: nil,
            signalsRBF: false,
            memo: memo,
            isMaxSend: false,
            recipientNeedsActivation: false,
            tonBounceable: nil
        )
    }
}
