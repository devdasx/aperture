import Foundation
import Testing
@testable import Aperture

/// BUG-001: multi-recipient drafts must never silently pay only the first
/// recipient. These tests lock the safety contract + capability matrix +
/// Polkadot batch encoding without live network signing.
struct MultiRecipientSigningTests {

    // MARK: - Capability honesty

    @Test("Single-recipient chains advertise max 1")
    func singleRecipientCaps() {
        let singles: [SupportedChain] = [
            .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
            .polygon, .bnbChain, .opBNB, .avalanche, .celo,
            .tron, .ripple, .near, .stellar
        ]
        for chain in singles {
            #expect(
                ChainSendCapability.maxRecipients(for: chain) == 1,
                "\(chain.rawValue) must be single-recipient only"
            )
            #expect(
                ChainComposeCapability.capability(for: chain).maxRecipients == 1,
                "compose cap mismatch for \(chain.rawValue)"
            )
        }
    }

    @Test("Multi-capable chains advertise max > 1")
    func multiRecipientCaps() {
        #expect(ChainSendCapability.maxRecipients(for: .bitcoin) == 20)
        #expect(ChainSendCapability.maxRecipients(for: .ton) == 4)
        #expect(ChainSendCapability.maxRecipients(for: .sui) == 20)
        #expect(ChainSendCapability.maxRecipients(for: .solana) == 15)
        #expect(ChainSendCapability.maxRecipients(for: .polkadot) == 20)
        #expect(ChainSendCapability.maxRecipients(for: .aptos) == 20)
    }

    // MARK: - requireRecipients contract

    @Test("requireRecipients refuses multi on single-recipient chain")
    func refuseMultiOnEVM() {
        let draft = makeDraft(
            chain: .ethereum,
            recipients: [
                SendRecipientAmount(address: "0x1111111111111111111111111111111111111111", amount: 1, name: nil),
                SendRecipientAmount(address: "0x2222222222222222222222222222222222222222", amount: 1, name: nil)
            ]
        )
        #expect(throws: SigningError.self) {
            _ = try SendRecipientSigning.requireRecipients(draft)
        }
    }

    @Test("requireRecipients returns every recipient on multi-capable chain")
    func multiListPreserved() throws {
        let draft = makeDraft(
            chain: .ton,
            recipients: [
                SendRecipientAmount(address: "EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c", amount: 1, name: nil),
                SendRecipientAmount(address: "EQBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBG9c", amount: 2, name: nil)
            ]
        )
        let list = try SendRecipientSigning.requireRecipients(draft, coin: nil)
        #expect(list.count == 2)
        #expect(list[0].amount == 1)
        #expect(list[1].amount == 2)
    }

    @Test("requireRecipients refuses send-max with multiple recipients")
    func refuseMaxPlusMulti() {
        let draft = makeDraft(
            chain: .bitcoin,
            recipients: [
                SendRecipientAmount(address: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh", amount: 1, name: nil),
                SendRecipientAmount(address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq", amount: 1, name: nil)
            ],
            isMaxSend: true
        )
        #expect(throws: SigningError.self) {
            _ = try SendRecipientSigning.requireRecipients(draft, coin: nil)
        }
    }

    @Test("requireSingleRecipient rejects multi list")
    func singleHelperRejectsMulti() {
        let draft = makeDraft(
            chain: .ethereum,
            recipients: [
                SendRecipientAmount(address: "0x1111111111111111111111111111111111111111", amount: 1, name: nil),
                SendRecipientAmount(address: "0x2222222222222222222222222222222222222222", amount: 1, name: nil)
            ]
        )
        #expect(throws: SigningError.self) {
            _ = try SendRecipientSigning.requireSingleRecipient(draft, coin: nil)
        }
    }

    // MARK: - Polkadot batch encoding

    @Test("Polkadot batchAll wraps N transfer calls")
    func polkadotBatchAllEncoding() {
        let account = Data(repeating: 0x11, count: 32)
        let call1 = PolkadotTransactionSigner.transferKeepAliveCall(
            toAccountId: account, value: 100, network: .assetHub
        )
        let call2 = PolkadotTransactionSigner.transferKeepAliveCall(
            toAccountId: account, value: 200, network: .assetHub
        )
        let batch = PolkadotTransactionSigner.batchAllCall(
            innerCalls: [call1, call2], network: .assetHub
        )
        // Asset Hub utility pallet 40, batch_all call index 2.
        #expect(batch[0] == 40)
        #expect(batch[1] == 2)
        // Compact length 2 → 0x08 (value 2 << 2)
        #expect(batch[2] == 0x08)
        // Remainder is the concatenation of both calls.
        #expect(Data(batch.dropFirst(3)) == call1 + call2)
    }

    // MARK: - Helpers

    private func makeDraft(
        chain: SupportedChain,
        recipients: [SendRecipientAmount],
        isMaxSend: Bool = false
    ) -> SendDraft {
        SendDraft(
            chain: chain,
            tokenSymbol: nil,
            tokenContract: nil,
            tokenDecimals: nil,
            fromAddress: "from",
            recipients: recipients,
            fee: FeeChoice(
                tier: .normal,
                feeModel: .evm1559,
                estimatedTotalNative: 0,
                worstCaseTotalNative: 0
            ),
            selectedUTXOs: nil,
            changeAddress: nil,
            changeSats: nil,
            opReturn: nil,
            signalsRBF: false,
            memo: .none,
            isMaxSend: isMaxSend,
            recipientNeedsActivation: false,
            tonBounceable: nil
        )
    }
}
