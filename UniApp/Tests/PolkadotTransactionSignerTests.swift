import Foundation
import Testing
import WalletCore
@testable import Aperture

struct PolkadotTransactionSignerTests {

    @Test("Polkadot SCALE compact encoding matches known values")
    func compactEncoding() {
        #expect(PolkadotTransactionSigner.compact(0).hexString == "00")
        #expect(PolkadotTransactionSigner.compact(1).hexString == "04")
        #expect(PolkadotTransactionSigner.compact(63).hexString == "fc")
        #expect(PolkadotTransactionSigner.compact(64).hexString == "0101")
        #expect(PolkadotTransactionSigner.compact(16_383).hexString == "fdff")
        #expect(PolkadotTransactionSigner.compact(16_384).hexString == "02000100")
        #expect(PolkadotTransactionSigner.compact(1_000_000_000).hexString == "02286bee")
        #expect(PolkadotTransactionSigner.compact(10_000_000_000).hexString == "0700e40b5402")
    }

    @Test("Polkadot mortal era matches WalletCore fixture")
    func mortalEraEncoding() {
        #expect(PolkadotTransactionSigner.mortalEra(blockNumber: 3_910_736, period: 64).hexString == "0501")
        #expect(PolkadotTransactionSigner.mortalEra(blockNumber: 3_541_050, period: 64).hexString == "a503")
    }

    @Test("Polkadot signed extras include disabled CheckMetadataHash mode before the call")
    func signedExtraIncludesMetadataHashMode() {
        let era = Data(hexString: "0x0501")!
        let extra = PolkadotTransactionSigner.signedExtra(
            era: era,
            nonce: 1,
            tip: 0,
            includeMetadataHashMode: true
        )

        #expect(extra.hexString == "0501040000")
    }

    @Test("Polkadot transferKeepAlive call uses current relay-chain call indices")
    func transferKeepAliveCallEncoding() throws {
        let accountBytes = try #require(
            SS58.decodeAccountId("13ZLCqJNPsRZYEbwjtZZFpWt9GyFzg5WahXCVWKpWdUJqrQ5")
        )
        let account = Data(accountBytes)
        let call = PolkadotTransactionSigner.transferKeepAliveCall(
            toAccountId: account,
            value: 10_000_000_000
        )

        #expect(call.hexString.hasPrefix("0503007120f76076bcb0efdf94c7219e116899d0163ea61cb428183d71324eb33b2bce"))
        #expect(call.hexString.hasSuffix("0700e40b5402"))
    }

    @Test("Polkadot signer emits a verifiable current-runtime signed extrinsic")
    func signBuildsVerifiableExtrinsic() throws {
        let privateKey = try #require(
            PrivateKey(data: Data(hexString: "afeefca74d9a325cf1d6b6911d61a65c32afa8e02bd5e78e2e4ac2910bab45f5")!)
        )
        let recipientAddress = "13ZLCqJNPsRZYEbwjtZZFpWt9GyFzg5WahXCVWKpWdUJqrQ5"
        let recipientAccount = Data(try #require(SS58.decodeAccountId(recipientAddress)))
        let genesisHash = try #require(
            Data(hexString: "0x91b171bb158e2d3848fa23a9f1c25182fb8e20313b2c1eb49219da7a70ce90c3")
        )
        let blockHash = try #require(
            Data(hexString: "0x321bd66a7da0a47ea350a05f211c371b60e0d9774c51455f1e8b9e9c9f40f785")
        )
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .polkadotWeight,
            estimatedTotalNative: Decimal(string: "0.001")!,
            worstCaseTotalNative: Decimal(string: "0.001")!
        )
        fee.polkadotTipPlancks = 0
        let draft = SendDraft(
            chain: .polkadot,
            tokenSymbol: nil,
            tokenContract: nil,
            tokenDecimals: nil,
            fromAddress: "12smx8Z4GX2JVBScAMbg47XA1xupTRDVG4yGfN4Qcn9icCq2",
            recipients: [SendRecipientAmount(address: recipientAddress, amount: Decimal(1), name: nil)],
            fee: fee,
            selectedUTXOs: nil,
            changeAddress: nil,
            changeSats: nil,
            opReturn: nil,
            signalsRBF: false,
            memo: .none,
            isMaxSend: false,
            recipientNeedsActivation: false,
            tonBounceable: nil
        )
        let jit = TransactionSigner.JustInTimeData(
            polkadotSpecVersion: 2_003_000,
            polkadotTransactionVersion: 26,
            polkadotBlockHash: SigningNumeric.hexString0x(blockHash),
            polkadotBlockNumber: 3_910_736,
            polkadotNonce: 1
        )

        let signed = try PolkadotTransactionSigner.sign(draft: draft, jit: jit, privateKey: privateKey)
        let body = Data(signed.rawData.dropFirst(2))
        let publicKey = privateKey.getPublicKeyEd25519().data
        let expectedCall = PolkadotTransactionSigner.transferKeepAliveCall(
            toAccountId: recipientAccount,
            value: 10_000_000_000
        )
        let expectedExtra = PolkadotTransactionSigner.signedExtra(
            era: PolkadotTransactionSigner.mortalEra(blockNumber: 3_910_736, period: 64),
            nonce: 1,
            tip: 0,
            includeMetadataHashMode: true
        )
        let additional = PolkadotTransactionSigner.additionalSigned(
            specVersion: 2_003_000,
            transactionVersion: 26,
            genesisHash: genesisHash,
            blockHash: blockHash
        )

        #expect(Data(signed.rawData.prefix(2)).hexString == PolkadotTransactionSigner.compact(UInt64(body.count)).hexString)
        #expect(body.count == 104 + expectedCall.count)
        #expect(body[0] == 0x84)
        #expect(body[1] == 0x00)
        #expect(Data(body[2..<34]) == publicKey)
        #expect(body[34] == 0x00)
        #expect(Data(body[99..<104]) == expectedExtra)
        #expect(Data(body[104..<body.count]) == expectedCall)

        let signature = Data(body[35..<99])
        let payload = expectedCall + expectedExtra + additional
        let signable = payload.count > 256 ? BLAKE2b.hash(payload, outlen: 32) : payload
        let verifyingKey = try #require(PublicKey(data: publicKey, type: .ed25519))
        #expect(verifyingKey.verify(signature: signature, message: signable))
    }
}
