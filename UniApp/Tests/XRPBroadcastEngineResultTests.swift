import Foundation
import Testing
@testable import Aperture

/// P0-007: XRPL submit must only treat `tes*` as applied success.
/// `ter*` means not applied — never false “Sent” / optimistic debit.
@Suite("XRP broadcast engine_result (P0-007)")
struct XRPBroadcastEngineResultTests {

    // MARK: - Outcome classifier

    @Test("tesSUCCESS is applied success")
    func tesSuccess() {
        #expect(BroadcastService.xrpSubmitOutcome("tesSUCCESS") == .appliedSuccess)
        #expect(BroadcastService.xrpSubmitOutcome("tesSUCCESS ") == .appliedSuccess)
    }

    @Test("ter* including terQUEUED is notAppliedRetryable")
    func terFamily() {
        for code in [
            "terQUEUED",
            "terRETRY",
            "terNO_ACCOUNT",
            "terNO_AUTH",
            "terNO_LINE",
            "terNO_RIPPLE",
            "terFUNDS_SPENT",
            "terLAST",
            "terPRE_SEQ",
        ] {
            #expect(
                BroadcastService.xrpSubmitOutcome(code) == .notAppliedRetryable,
                "\(code) must not be success"
            )
        }
    }

    @Test("tec/tef/tem/tel are rejected")
    func hardRejectFamilies() {
        for code in [
            "tecUNFUNDED_PAYMENT",
            "tecPATH_DRY",
            "tecNO_DST",
            "tefPAST_SEQ",
            "tefMAX_LEDGER",
            "temMALFORMED",
            "temBAD_AMOUNT",
            "telFAILED",
            "telINSUF_FEE_P",
        ] {
            #expect(
                BroadcastService.xrpSubmitOutcome(code) == .rejected,
                "\(code) must be rejected"
            )
        }
    }

    @Test("empty / unknown codes")
    func emptyUnknown() {
        #expect(BroadcastService.xrpSubmitOutcome("") == .unknown)
        #expect(BroadcastService.xrpSubmitOutcome("WTF") == .unknown)
    }

    // MARK: - parseXRPSubmitResponse

    @Test("tesSUCCESS returns hash from tx_json")
    func parseTesHash() throws {
        let data = json([
            "engine_result": "tesSUCCESS",
            "engine_result_message": "The transaction was applied.",
            "tx_json": ["hash": "ABCD1234"],
        ])
        #expect(try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "LOCAL") == "ABCD1234")
    }

    @Test("tesSUCCESS nested under result envelope")
    func parseNestedResult() throws {
        let data = json([
            "result": [
                "engine_result": "tesSUCCESS",
                "tx_json": ["hash": "NESTEDHASH"],
            ] as [String: Any],
        ])
        #expect(try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "") == "NESTEDHASH")
    }

    @Test("BUG regression: terQUEUED must not return hash as success")
    func terQueuedNotSuccess() {
        let data = json([
            "engine_result": "terQUEUED",
            "engine_result_message": "Held until escalated fee drops.",
            "tx_json": ["hash": "QUEUEDHASH"],
            "accepted": true,
            "applied": false,
        ] as [String: Any])
        do {
            let hash = try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "LOCAL")
            Issue.record("terQUEUED must not succeed with hash \(hash)")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous(let msg) = error else {
                Issue.record("expected broadcastAmbiguous, got \(error)")
                return
            }
            #expect(msg.localizedCaseInsensitiveContains("not yet applied")
                    || msg.localizedCaseInsensitiveContains("queued")
                    || msg.localizedCaseInsensitiveContains("escalated"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("terNO_ACCOUNT is ambiguous not success")
    func terNoAccount() {
        let data = json([
            "engine_result": "terNO_ACCOUNT",
            "engine_result_message": "The source account does not exist.",
            "tx_json": ["hash": "H"],
        ])
        do {
            _ = try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "L")
            Issue.record("must not succeed")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected ambiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("tecUNFUNDED_PAYMENT is broadcastFailed")
    func tecUnfunded() {
        let data = json([
            "engine_result": "tecUNFUNDED_PAYMENT",
            "engine_result_message": "Insufficient XRP balance.",
        ])
        do {
            _ = try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "L")
            Issue.record("must fail")
        } catch let error as SigningError {
            guard case .broadcastFailed(let msg) = error else {
                Issue.record("expected failed, got \(error)")
                return
            }
            #expect(msg.localizedCaseInsensitiveContains("Insufficient")
                    || msg.localizedCaseInsensitiveContains("UNFUNDED"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Only tes* may use local tx hash fallback")
    func localHashOnlyOnTes() throws {
        let tes = json(["engine_result": "tesSUCCESS"])
        #expect(try BroadcastService.parseXRPSubmitResponse(tes, localTxHash: "LOCALONLY") == "LOCALONLY")

        let ter = json(["engine_result": "terQUEUED", "tx_json": ["hash": "H"]])
        do {
            _ = try BroadcastService.parseXRPSubmitResponse(ter, localTxHash: "LOCALONLY")
            Issue.record("ter must not use local hash as success")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected ambiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Helpers

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}
