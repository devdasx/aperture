import Foundation
import Testing
@testable import Aperture

/// P0-006: activation / dest-tag / memo-required flags must be set from real
/// account probes (Send only — never receive).
@Suite("Send recipient account probe (P0-006)")
struct SendRecipientAccountProbeTests {

    // MARK: - XRP

    @Test("XRP actNotFound → needsActivation")
    func xrpUnfunded() {
        let data = json([
            "error": "actNotFound",
            "error_message": "Account not found.",
            "status": "error",
        ])
        let result = SendRecipientAccountProbe.parseXRPAccountInfoJSON(data)
        #expect(result.needsActivation)
        #expect(!result.requiresDestinationTag)
        #expect(!result.requiresMemo)
    }

    @Test("XRP Flags RequireDestTag → requiresDestinationTag")
    func xrpRequireDestFlag() {
        // lsfRequireDestTag = 0x00020000
        let data = json([
            "account_data": [
                "Account": "rN7n7otQDd6FczFgLdlqtyMVrn3HMfH5Qp",
                "Balance": "1000000000",
                "Flags": 131_072, // 0x20000
                "OwnerCount": 0,
            ] as [String: Any],
            "status": "success",
        ])
        let result = SendRecipientAccountProbe.parseXRPAccountInfoJSON(data)
        #expect(!result.needsActivation)
        #expect(result.requiresDestinationTag)
        #expect(!result.requiresMemo)
    }

    @Test("XRP account_flags.requireDestinationTag true")
    func xrpAccountFlagsObject() {
        let data = json([
            "account_data": [
                "Account": "rN7n7otQDd6FczFgLdlqtyMVrn3HMfH5Qp",
                "Balance": "1000000000",
                "Flags": 0,
            ] as [String: Any],
            "account_flags": [
                "requireDestinationTag": true,
            ] as [String: Any],
            "status": "success",
        ])
        let result = SendRecipientAccountProbe.parseXRPAccountInfoJSON(data)
        #expect(result.requiresDestinationTag)
        #expect(!result.needsActivation)
    }

    @Test("XRP funded without dest flag → no special gates")
    func xrpFundedPlain() {
        let data = json([
            "account_data": [
                "Account": "rN7n7otQDd6FczFgLdlqtyMVrn3HMfH5Qp",
                "Balance": "1000000000",
                "Flags": 0,
                "OwnerCount": 2,
            ] as [String: Any],
            "status": "success",
        ])
        let result = SendRecipientAccountProbe.parseXRPAccountInfoJSON(data)
        #expect(result == .none)
    }

    // MARK: - Stellar

    @Test("Stellar 404 / not_found → needsActivation (create_account)")
    func stellarUnfunded() {
        let data = json([
            "type": "https://stellar.org/horizon-errors/not_found",
            "title": "Resource Missing",
            "status": 404,
        ])
        let result = SendRecipientAccountProbe.parseStellarAccountJSON(data, httpNotFound: false)
        #expect(result.needsActivation)
        #expect(!result.requiresMemo)

        let notFound = SendRecipientAccountProbe.parseStellarAccountJSON(Data(), httpNotFound: true)
        #expect(notFound.needsActivation)
    }

    @Test("Stellar config.memo_required data → requiresMemo")
    func stellarMemoRequired() {
        // Horizon stores data values base64; "1" → "MQ=="
        let data = json([
            "id": "GABCDEFGHIJKLMNOPQRSTUVWXYZ234567",
            "sequence": "123",
            "data": [
                "config.memo_required": "MQ==",
            ] as [String: Any],
        ])
        let result = SendRecipientAccountProbe.parseStellarAccountJSON(data, httpNotFound: false)
        #expect(!result.needsActivation)
        #expect(result.requiresMemo)
        #expect(!result.requiresDestinationTag)
    }

    @Test("Stellar memo_required plain and base64 parsers")
    func stellarMemoValueParse() {
        #expect(SendRecipientAccountProbe.parseMemoRequiredValue("1"))
        #expect(SendRecipientAccountProbe.parseMemoRequiredValue("true"))
        #expect(SendRecipientAccountProbe.parseMemoRequiredValue("MQ=="))
        #expect(!SendRecipientAccountProbe.parseMemoRequiredValue("0"))
        #expect(!SendRecipientAccountProbe.parseMemoRequiredValue("MA==")) // "0"
    }

    @Test("Stellar funded without memo data → none")
    func stellarFundedPlain() {
        let data = json([
            "id": "GABCDEFGHIJKLMNOPQRSTUVWXYZ234567",
            "sequence": "123",
            "balances": [["asset_type": "native", "balance": "10.0"]],
        ])
        let result = SendRecipientAccountProbe.parseStellarAccountJSON(data, httpNotFound: false)
        #expect(result == .none)
    }

    // MARK: - TRON

    @Test("TRON empty account → needsActivation")
    func tronUnactivated() {
        let data = json([:] as [String: Any])
        let result = SendRecipientAccountProbe.parseTronGetAccountJSON(data)
        #expect(result.needsActivation)
    }

    @Test("TRON funded account → no activation")
    func tronFunded() {
        let data = json([
            "address": "TXYZabcdefghijklmnopqrstuvwxyz123456",
            "balance": 1_000_000,
            "create_time": 1_600_000_000_000,
        ] as [String: Any])
        let result = SendRecipientAccountProbe.parseTronGetAccountJSON(data)
        #expect(!result.needsActivation)
        #expect(result == .none)
    }

    // MARK: - Validator integration

    @Test("Validator blocks XRP without tag when flag set")
    func validatorDestinationTagRequired() {
        let fee = FeeChoice(
            tier: .normal,
            feeModel: .xrpFixed,
            estimatedTotalNative: Decimal(string: "0.00001")!,
            worstCaseTotalNative: Decimal(string: "0.00001")!
        )
        let inputs = SendDraftValidator.Inputs(
            chain: .ripple,
            isToken: false,
            nativeBalance: 100,
            tokenBalance: nil,
            recipients: [SendRecipientAmount(address: "rDest", amount: 10, name: nil)],
            fee: fee,
            state: .init(),
            memo: .none,
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: true,
            recipientRequiresMemo: false,
            recipientIsNew: false
        )
        let errors = SendDraftValidator().validate(inputs)
        #expect(errors.contains(.destinationTagRequired))
    }

    @Test("Validator blocks Stellar without memo when required")
    func validatorMemoRequired() {
        let fee = FeeChoice(
            tier: .normal,
            feeModel: .stellarPerOp,
            estimatedTotalNative: Decimal(string: "0.00001")!,
            worstCaseTotalNative: Decimal(string: "0.00001")!
        )
        let inputs = SendDraftValidator.Inputs(
            chain: .stellar,
            isToken: false,
            nativeBalance: 100,
            tokenBalance: nil,
            recipients: [SendRecipientAmount(address: "GDEST", amount: 5, name: nil)],
            fee: fee,
            state: .init(),
            memo: .none,
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: false,
            recipientRequiresMemo: true,
            recipientIsNew: false
        )
        let errors = SendDraftValidator().validate(inputs)
        #expect(errors.contains(.memoRequired))
    }

    @Test("Validator enforces activation minimum for new XRP account")
    func validatorActivationMinimum() {
        let fee = FeeChoice(
            tier: .normal,
            feeModel: .xrpFixed,
            estimatedTotalNative: 0,
            worstCaseTotalNative: 0
        )
        let inputs = SendDraftValidator.Inputs(
            chain: .ripple,
            isToken: false,
            nativeBalance: 100,
            tokenBalance: nil,
            recipients: [SendRecipientAmount(address: "rNew", amount: Decimal(string: "0.5")!, name: nil)],
            fee: fee,
            state: .init(),
            memo: .none,
            opReturnByteCount: nil,
            recipientRequiresDestinationTag: false,
            recipientRequiresMemo: false,
            recipientIsNew: true
        )
        let errors = SendDraftValidator().validate(inputs)
        #expect(errors.contains { if case .belowActivationMinimum = $0 { return true }; return false })
    }

    @Test("Compose model setRecipientAccountProbe assigns all three flags")
    @MainActor
    func modelSetsFlags() {
        let model = SendComposeModel(
            chain: .ripple,
            tokenSymbol: nil,
            tokenContract: nil,
            tokenDecimals: nil,
            fromAddress: "rFrom",
            recipients: [SendRecipientEntry(address: "rTo", name: nil, memo: nil)],
            currencyCode: "USD"
        )
        #expect(!model.recipientNeedsActivation)
        #expect(!model.recipientRequiresDestinationTag)
        #expect(!model.recipientRequiresMemo)

        model.setRecipientAccountProbe(SendRecipientAccountProbeResult(
            needsActivation: true,
            requiresDestinationTag: true,
            requiresMemo: false
        ))
        #expect(model.recipientNeedsActivation)
        #expect(model.recipientRequiresDestinationTag)
        #expect(!model.recipientRequiresMemo)
    }

    @Test("Unsupported chains return .none without inventing gates")
    func unsupportedNone() async {
        let result = await SendRecipientAccountProbe.probe(
            chain: .bitcoin,
            recipientAddress: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh"
        )
        #expect(result == .none)
    }

    // MARK: - Helpers

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}
