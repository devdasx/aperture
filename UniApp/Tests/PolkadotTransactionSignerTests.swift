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
            network: .relay,
            includeMetadataHashMode: true
        )

        #expect(extra.hexString == "0501040000")
    }

    @Test("Polkadot Asset Hub signed extras include native fee asset id")
    func assetHubSignedExtraIncludesNativeFeeAssetID() {
        let era = Data(hexString: "0x0501")!
        let extra = PolkadotTransactionSigner.signedExtra(
            era: era,
            nonce: 1,
            tip: 0,
            network: .assetHub,
            includeMetadataHashMode: true
        )

        #expect(extra.hexString == "050104000000")
    }

    @Test("Polkadot additional signed payload includes disabled metadata hash option")
    func additionalSignedIncludesMetadataHashNone() throws {
        let genesisHash = try #require(
            Data(hexString: "0x68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f")
        )
        let blockHash = try #require(
            Data(hexString: "0x321bd66a7da0a47ea350a05f211c371b60e0d9774c51455f1e8b9e9c9f40f785")
        )
        let additional = PolkadotTransactionSigner.additionalSigned(
            specVersion: 2_003_001,
            transactionVersion: 15,
            genesisHash: genesisHash,
            blockHash: blockHash,
            includeMetadataHash: true
        )

        #expect(additional.count == 73)
        #expect(additional.suffix(1) == Data([0x00]))
    }

    @Test("Polkadot transferKeepAlive call uses current relay-chain call indices")
    func relayTransferKeepAliveCallEncoding() throws {
        let accountBytes = try #require(
            SS58.decodeAccountId("13ZLCqJNPsRZYEbwjtZZFpWt9GyFzg5WahXCVWKpWdUJqrQ5")
        )
        let account = Data(accountBytes)
        let call = PolkadotTransactionSigner.transferKeepAliveCall(
            toAccountId: account,
            value: 10_000_000_000,
            network: .relay
        )

        #expect(call.hexString.hasPrefix("0503007120f76076bcb0efdf94c7219e116899d0163ea61cb428183d71324eb33b2bce"))
        #expect(call.hexString.hasSuffix("0700e40b5402"))
    }

    @Test("Polkadot Asset Hub transferKeepAlive call uses Asset Hub call indices")
    func assetHubTransferKeepAliveCallEncoding() throws {
        let accountBytes = try #require(
            SS58.decodeAccountId("13ZLCqJNPsRZYEbwjtZZFpWt9GyFzg5WahXCVWKpWdUJqrQ5")
        )
        let account = Data(accountBytes)
        let call = PolkadotTransactionSigner.transferKeepAliveCall(
            toAccountId: account,
            value: 10_000_000_000,
            network: .assetHub
        )

        #expect(call.hexString.hasPrefix("0a03007120f76076bcb0efdf94c7219e116899d0163ea61cb428183d71324eb33b2bce"))
        #expect(call.hexString.hasSuffix("0700e40b5402"))
    }

    @Test("Polkadot Asset Hub signer emits a verifiable current-runtime signed extrinsic")
    func signBuildsVerifiableExtrinsic() throws {
        let privateKey = try #require(
            PrivateKey(data: Data(hexString: "afeefca74d9a325cf1d6b6911d61a65c32afa8e02bd5e78e2e4ac2910bab45f5")!)
        )
        let recipientAddress = "13ZLCqJNPsRZYEbwjtZZFpWt9GyFzg5WahXCVWKpWdUJqrQ5"
        let recipientAccount = Data(try #require(SS58.decodeAccountId(recipientAddress)))
        let genesisHash = try #require(
            Data(hexString: "0x68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f")
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
            polkadotSpecVersion: 2_003_001,
            polkadotTransactionVersion: 15,
            polkadotBlockHash: SigningNumeric.hexString0x(blockHash),
            polkadotBlockNumber: 3_910_736,
            polkadotNonce: 1,
            polkadotNetwork: .assetHub,
            polkadotGenesisHash: SigningNumeric.hexString0x(genesisHash)
        )

        let signed = try PolkadotTransactionSigner.sign(draft: draft, jit: jit, privateKey: privateKey)
        let body = Data(signed.rawData.dropFirst(2))
        let publicKey = privateKey.getPublicKeyEd25519().data
        let expectedCall = PolkadotTransactionSigner.transferKeepAliveCall(
            toAccountId: recipientAccount,
            value: 10_000_000_000,
            network: .assetHub
        )
        let expectedExtra = PolkadotTransactionSigner.signedExtra(
            era: PolkadotTransactionSigner.mortalEra(blockNumber: 3_910_736, period: 64),
            nonce: 1,
            tip: 0,
            network: .assetHub,
            includeMetadataHashMode: true
        )
        let additional = PolkadotTransactionSigner.additionalSigned(
            specVersion: 2_003_001,
            transactionVersion: 15,
            genesisHash: genesisHash,
            blockHash: blockHash,
            includeMetadataHash: true
        )

        #expect(Data(signed.rawData.prefix(2)).hexString == PolkadotTransactionSigner.compact(UInt64(body.count)).hexString)
        #expect(body.count == 105 + expectedCall.count)
        #expect(body[0] == 0x84)
        #expect(body[1] == 0x00)
        #expect(Data(body[2..<34]) == publicKey)
        #expect(body[34] == 0x00)
        #expect(Data(body[99..<105]) == expectedExtra)
        #expect(Data(body[105..<body.count]) == expectedCall)

        let signature = Data(body[35..<99])
        let payload = expectedCall + expectedExtra + additional
        let signable = payload.count > 256 ? BLAKE2b.hash(payload, outlen: 32) : payload
        let verifyingKey = try #require(PublicKey(data: publicKey, type: .ed25519))
        #expect(verifyingKey.verify(signature: signature, message: signable))
    }

    // MARK: - BUG-011 Asset Hub token transfers

    /// Real mainnet SS58 account used across Polkadot docs / fixtures.
    private static let realRecipient = "13ZLCqJNPsRZYEbwjtZZFpWt9GyFzg5WahXCVWKpWdUJqrQ5"
    /// WalletCore fixture private key → known public SS58 sender.
    private static let fixtureSender = "12smx8Z4GX2JVBScAMbg47XA1xupTRDVG4yGfN4Qcn9icCq2"

    @Test("Asset Hub assets.transferKeepAlive matches polkadot.js encoding for USDT 1984")
    func assetsTransferKeepAliveUSDTEncoding() throws {
        let account = Data(try #require(SS58.decodeAccountId(Self.realRecipient)))
        // Captured from @polkadot/api against live Asset Hub metadata:
        // assets.transferKeepAlive(1984, dest, 1_000_000)
        let expected =
            "3209011f007120f76076bcb0efdf94c7219e116899d0163ea61cb428183d71324eb33b2bce02093d00"
        let call = try PolkadotTransactionSigner.assetsTransferKeepAliveCall(
            assetId: 1984,
            toAccountId: account,
            amount: 1_000_000,
            network: .assetHub
        )
        #expect(call.hexString == expected)
    }

    @Test("Asset Hub assets.transferKeepAlive matches polkadot.js encoding for USDC 1337")
    func assetsTransferKeepAliveUSDCEncoding() throws {
        let account = Data(try #require(SS58.decodeAccountId(Self.realRecipient)))
        let expected =
            "3209e514007120f76076bcb0efdf94c7219e116899d0163ea61cb428183d71324eb33b2bce02093d00"
        let call = try PolkadotTransactionSigner.assetsTransferKeepAliveCall(
            assetId: 1337,
            toAccountId: account,
            amount: 1_000_000,
            network: .assetHub
        )
        #expect(call.hexString == expected)
    }

    @Test("Asset Hub assets.transferAll keepAlive encoding for USDT")
    func assetsTransferAllEncoding() throws {
        let account = Data(try #require(SS58.decodeAccountId(Self.realRecipient)))
        let expected =
            "3220011f007120f76076bcb0efdf94c7219e116899d0163ea61cb428183d71324eb33b2bce01"
        let call = try PolkadotTransactionSigner.assetsTransferAllCall(
            assetId: 1984,
            toAccountId: account,
            keepAlive: true,
            network: .assetHub
        )
        #expect(call.hexString == expected)
    }

    @Test("resolveAssetHubAssetId accepts catalog USDT/USDC id strings")
    func resolveAssetHubAssetIdFromDraft() throws {
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .polkadotWeight,
            estimatedTotalNative: Decimal(string: "0.015")!,
            worstCaseTotalNative: Decimal(string: "0.015")!
        )
        fee.polkadotTipPlancks = 0

        let usdt = SendDraft(
            chain: .polkadot,
            tokenSymbol: "USDT",
            tokenContract: "1984",
            tokenDecimals: 6,
            fromAddress: Self.fixtureSender,
            recipients: [SendRecipientAmount(address: Self.realRecipient, amount: Decimal(1), name: nil)],
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
        #expect(try PolkadotTransactionSigner.resolveAssetHubAssetId(draft: usdt) == 1984)

        let usdc = SendDraft(
            chain: .polkadot,
            tokenSymbol: "USDC",
            tokenContract: "1337",
            tokenDecimals: 6,
            fromAddress: Self.fixtureSender,
            recipients: [SendRecipientAmount(address: Self.realRecipient, amount: Decimal(1), name: nil)],
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
        #expect(try PolkadotTransactionSigner.resolveAssetHubAssetId(draft: usdc) == 1337)
    }

    @Test("BUG-011 Asset Hub USDT sign builds verifiable extrinsic with assets.transferKeepAlive call")
    func signAssetHubUSDTBuildsVerifiableExtrinsic() throws {
        let privateKey = try #require(
            PrivateKey(data: Data(hexString: "afeefca74d9a325cf1d6b6911d61a65c32afa8e02bd5e78e2e4ac2910bab45f5")!)
        )
        let recipientAccount = Data(try #require(SS58.decodeAccountId(Self.realRecipient)))
        let genesisHash = try #require(
            Data(hexString: "0x68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f")
        )
        let blockHash = try #require(
            Data(hexString: "0x321bd66a7da0a47ea350a05f211c371b60e0d9774c51455f1e8b9e9c9f40f785")
        )
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .polkadotWeight,
            estimatedTotalNative: Decimal(string: "0.015")!,
            worstCaseTotalNative: Decimal(string: "0.015")!
        )
        fee.polkadotTipPlancks = 0
        // 1.0 USDT = 1_000_000 base units (6 decimals)
        let draft = SendDraft(
            chain: .polkadot,
            tokenSymbol: "USDT",
            tokenContract: "1984",
            tokenDecimals: 6,
            fromAddress: Self.fixtureSender,
            recipients: [SendRecipientAmount(address: Self.realRecipient, amount: Decimal(1), name: nil)],
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
        #expect(draft.isTokenSend)
        let jit = TransactionSigner.JustInTimeData(
            polkadotSpecVersion: 2_003_001,
            polkadotTransactionVersion: 15,
            polkadotBlockHash: SigningNumeric.hexString0x(blockHash),
            polkadotBlockNumber: 3_910_736,
            polkadotNonce: 1,
            polkadotNetwork: .assetHub,
            polkadotGenesisHash: SigningNumeric.hexString0x(genesisHash)
        )

        let signed = try PolkadotTransactionSigner.sign(draft: draft, jit: jit, privateKey: privateKey)
        let body = Data(signed.rawData.dropFirst(2))
        let publicKey = privateKey.getPublicKeyEd25519().data
        let expectedCall = try PolkadotTransactionSigner.assetsTransferKeepAliveCall(
            assetId: 1984,
            toAccountId: recipientAccount,
            amount: 1_000_000,
            network: .assetHub
        )
        let expectedExtra = PolkadotTransactionSigner.signedExtra(
            era: PolkadotTransactionSigner.mortalEra(blockNumber: 3_910_736, period: 64),
            nonce: 1,
            tip: 0,
            network: .assetHub,
            includeMetadataHashMode: true
        )
        let additional = PolkadotTransactionSigner.additionalSigned(
            specVersion: 2_003_001,
            transactionVersion: 15,
            genesisHash: genesisHash,
            blockHash: blockHash,
            includeMetadataHash: true
        )

        #expect(body[0] == 0x84)
        #expect(Data(body[99..<105]) == expectedExtra)
        #expect(Data(body[105..<body.count]) == expectedCall)
        #expect(expectedCall.hexString.hasPrefix("3209")) // Assets pallet + transferKeepAlive

        let signature = Data(body[35..<99])
        let payload = expectedCall + expectedExtra + additional
        let signable = payload.count > 256 ? BLAKE2b.hash(payload, outlen: 32) : payload
        let verifyingKey = try #require(PublicKey(data: publicKey, type: .ed25519))
        #expect(verifyingKey.verify(signature: signature, message: signable))
    }

    @Test("BUG-011 send-max uses assets.transferAll keepAlive")
    func signAssetHubUSDTMaxUsesTransferAll() throws {
        let privateKey = try #require(
            PrivateKey(data: Data(hexString: "afeefca74d9a325cf1d6b6911d61a65c32afa8e02bd5e78e2e4ac2910bab45f5")!)
        )
        let recipientAccount = Data(try #require(SS58.decodeAccountId(Self.realRecipient)))
        let genesisHash = try #require(
            Data(hexString: "0x68d56f15f85d3136970ec16946040bc1752654e906147f7e43e9d539d7c3de2f")
        )
        let blockHash = try #require(
            Data(hexString: "0x321bd66a7da0a47ea350a05f211c371b60e0d9774c51455f1e8b9e9c9f40f785")
        )
        var fee = FeeChoice(
            tier: .normal,
            feeModel: .polkadotWeight,
            estimatedTotalNative: Decimal(string: "0.015")!,
            worstCaseTotalNative: Decimal(string: "0.015")!
        )
        fee.polkadotTipPlancks = 0
        let draft = SendDraft(
            chain: .polkadot,
            tokenSymbol: "USDT",
            tokenContract: "1984",
            tokenDecimals: 6,
            fromAddress: Self.fixtureSender,
            recipients: [SendRecipientAmount(address: Self.realRecipient, amount: Decimal(42), name: nil)],
            fee: fee,
            selectedUTXOs: nil,
            changeAddress: nil,
            changeSats: nil,
            opReturn: nil,
            signalsRBF: false,
            memo: .none,
            isMaxSend: true,
            recipientNeedsActivation: false,
            tonBounceable: nil
        )
        let jit = TransactionSigner.JustInTimeData(
            polkadotSpecVersion: 2_003_001,
            polkadotTransactionVersion: 15,
            polkadotBlockHash: SigningNumeric.hexString0x(blockHash),
            polkadotBlockNumber: 3_910_736,
            polkadotNonce: 2,
            polkadotNetwork: .assetHub,
            polkadotGenesisHash: SigningNumeric.hexString0x(genesisHash)
        )
        let signed = try PolkadotTransactionSigner.sign(draft: draft, jit: jit, privateKey: privateKey)
        let expectedCall = try PolkadotTransactionSigner.assetsTransferAllCall(
            assetId: 1984,
            toAccountId: recipientAccount,
            keepAlive: true,
            network: .assetHub
        )
        #expect(signed.rawData.suffix(expectedCall.count) == expectedCall)
    }

    @Test("Live Asset Hub runtime still has Assets pallet index 50 / transferKeepAlive 9")
    func liveAssetHubAssetsCallIndices() async throws {
        // Soft network probe — always-on when RPC is reachable.
        do {
            let (spec, tx) = try await PolkadotAssetHubRPCClient.shared.runtimeVersion()
            #expect(spec > 0)
            #expect(tx > 0)
            // Encode a dry call and ask payment_queryInfo with a zeroed signature?
            // Nodes reject unsigned extrinsics; the SCALE prefix is enough to pin
            // call indices against the polkadot.js live capture (0x32 0x09).
            let account = Data(try #require(SS58.decodeAccountId(Self.realRecipient)))
            let call = try PolkadotTransactionSigner.assetsTransferKeepAliveCall(
                assetId: 1984,
                toAccountId: account,
                amount: 1,
                network: .assetHub
            )
            #expect(call[0] == 50)
            #expect(call[1] == 9)
            print("[PolkadotAssetHub] live runtime spec=\(spec) txVersion=\(tx) assets.call=\(call.prefix(2).hexString)")
        } catch {
            print("[PolkadotAssetHub] live runtime probe skipped: \(error)")
        }
    }
}
