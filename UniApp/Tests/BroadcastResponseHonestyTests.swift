import Foundation
import Testing
@testable import Aperture

/// BUG-021: broadcast must never report success from a local txid when the
/// provider body did not confirm a hash (false "sent" on DOGE/BCH and peers).
@Suite("Broadcast response honesty (BUG-021)")
struct BroadcastResponseHonestyTests {

    // MARK: - BlockCypher (DOGE)

    @Test("BlockCypher success returns tx.hash from body")
    func blockCypherSuccessHashFromBody() throws {
        let data = json([
            "tx": ["hash": "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"]
        ])
        let hash = try BroadcastService.parseBlockCypherPushResponse(data)
        #expect(hash == "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899")
    }

    @Test("BlockCypher error field is broadcastFailed")
    func blockCypherErrorField() {
        let data = json(["error": "Error validating transaction: Transaction already exists."])
        do {
            _ = try BroadcastService.parseBlockCypherPushResponse(data)
            Issue.record("expected throw")
        } catch let error as SigningError {
            guard case .broadcastFailed(let msg) = error else {
                Issue.record("expected broadcastFailed, got \(error)")
                return
            }
            #expect(msg.contains("already exists"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("BUG-021: BlockCypher 2xx-shaped body without hash is ambiguous (not local txid)")
    func blockCypherUnexpectedBodyAmbiguous() {
        // Old bug: returned signed.txHash here.
        let data = json(["status": "ok", "message": "accepted"])
        do {
            _ = try BroadcastService.parseBlockCypherPushResponse(data)
            Issue.record("must not succeed without confirmed hash")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected broadcastAmbiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    @Test("BlockCypher empty / non-JSON body is ambiguous")
    func blockCypherGarbageAmbiguous() {
        let data = Data("not-json".utf8)
        #expect(throws: SigningError.self) {
            _ = try BroadcastService.parseBlockCypherPushResponse(data)
        }
    }

    // MARK: - Blockchair (BCH)

    @Test("Blockchair success returns data.transaction_hash")
    func blockchairSuccessHashFromBody() throws {
        let data = json([
            "data": ["transaction_hash": "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"],
            "context": ["code": 200]
        ])
        let hash = try BroadcastService.parseBlockchairPushResponse(data, httpStatus: 200)
        #expect(hash == "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff")
    }

    @Test("Blockchair context.error is broadcastFailed")
    func blockchairContextError() {
        let data = json([
            "data": NSNull(),
            "context": ["code": 400, "error": "TX decode failed"]
        ])
        do {
            _ = try BroadcastService.parseBlockchairPushResponse(data, httpStatus: 400)
            Issue.record("expected throw")
        } catch let error as SigningError {
            guard case .broadcastFailed(let msg) = error else {
                Issue.record("expected broadcastFailed, got \(error)")
                return
            }
            #expect(msg.contains("decode"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("BUG-021: Blockchair HTTP 2xx without transaction_hash is ambiguous")
    func blockchair2xxWithoutHashAmbiguous() {
        // Old bug: returned signed.txHash on 2xx unexpected body.
        let data = json(["data": ["status": "ok"], "context": ["code": 200]])
        do {
            _ = try BroadcastService.parseBlockchairPushResponse(data, httpStatus: 200)
            Issue.record("must not succeed without transaction_hash")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected broadcastAmbiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Blockchair non-2xx without parseable error is broadcastFailed")
    func blockchairHttpError() {
        let data = Data("<html>gateway timeout</html>".utf8)
        do {
            _ = try BroadcastService.parseBlockchairPushResponse(data, httpStatus: 504)
            Issue.record("expected throw")
        } catch let error as SigningError {
            guard case .broadcastFailed = error else {
                Issue.record("expected broadcastFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - XRP / TRON (confirmed accept may use local hash)

    @Test("XRP tesSUCCESS with body hash prefers body")
    func xrpBodyHashPreferred() throws {
        let data = json([
            "engine_result": "tesSUCCESS",
            "tx_json": ["hash": "NODEHASH"]
        ])
        let hash = try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "LOCALHASH")
        #expect(hash == "NODEHASH")
    }

    @Test("XRP tesSUCCESS without body hash uses local only when non-empty")
    func xrpLocalWhenEngineAccepted() throws {
        let data = json(["engine_result": "tesSUCCESS", "tx_json": [:] as [String: Any]])
        let hash = try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "LOCALHASH")
        #expect(hash == "LOCALHASH")
    }

    @Test("XRP accepted but no body hash and empty local is ambiguous")
    func xrpAcceptedNoHashAmbiguous() {
        let data = json(["engine_result": "tesSUCCESS"])
        do {
            _ = try BroadcastService.parseXRPSubmitResponse(data, localTxHash: "")
            Issue.record("expected ambiguous")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected broadcastAmbiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("TRON result true without txid uses local; without either is ambiguous")
    func tronAcceptPaths() throws {
        let okBody = json(["result": true, "txid": "TRONTX"])
        #expect(try BroadcastService.parseTronBroadcastResponse(okBody, localTxHash: "LOCAL") == "TRONTX")

        let okNoTxid = json(["result": true])
        #expect(try BroadcastService.parseTronBroadcastResponse(okNoTxid, localTxHash: "LOCAL") == "LOCAL")

        do {
            _ = try BroadcastService.parseTronBroadcastResponse(okNoTxid, localTxHash: "")
            Issue.record("expected ambiguous when no txid")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected broadcastAmbiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - NEAR / TON (no local fallback)

    @Test("NEAR hash must be in body")
    func nearRequiresBodyHash() throws {
        let ok = json(["transaction": ["hash": "nearHash123"]])
        #expect(try BroadcastService.parseNearSendTxResponse(ok) == "nearHash123")

        do {
            _ = try BroadcastService.parseNearSendTxResponse(json(["transaction": [:] as [String: Any]]))
            Issue.record("expected ambiguous")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected broadcastAmbiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("TON hash must be in body when ok")
    func tonRequiresBodyHash() throws {
        let ok = json(["ok": true, "result": ["hash": "tonHash"]])
        #expect(try BroadcastService.parseTONSendBocResponse(ok) == "tonHash")

        do {
            _ = try BroadcastService.parseTONSendBocResponse(json(["ok": true, "result": [:] as [String: Any]]))
            Issue.record("expected ambiguous")
        } catch let error as SigningError {
            guard case .broadcastAmbiguous = error else {
                Issue.record("expected broadcastAmbiguous, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }

        do {
            _ = try BroadcastService.parseTONSendBocResponse(json(["ok": false, "error": "boc invalid"]))
            Issue.record("expected failed")
        } catch let error as SigningError {
            guard case .broadcastFailed(let msg) = error else {
                Issue.record("expected broadcastFailed, got \(error)")
                return
            }
            #expect(msg.contains("invalid"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Helpers

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}
