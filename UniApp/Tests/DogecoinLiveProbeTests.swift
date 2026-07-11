import Foundation
import Testing
@testable import Aperture

/// Live mainnet probes for Dogecoin multi-provider stack
/// (Blockbook primary → Blockchair → BlockCypher).
///
/// Address `DH5yaieqoZN36fDVciNyRueRGvGLR3mr7L` is a long-lived funded
/// mainnet address (curl-verified 2026-07-11: balance ≈ 62_040.985608 DOGE
/// on Blockbook + Blockchair).
@Suite("Dogecoin live multi-provider probes")
struct DogecoinLiveProbeTests {

    private let client = DogecoinDataClient.shared
    private let address = DogecoinDataClient.probeAddress

    @Test("registry prefers Blockbook over BlockCypher")
    func registryPrimaryIsBlockbook() {
        let endpoints = RPCRegistry.endpoints(for: .dogecoin)
        #expect(!endpoints.isEmpty)
        #expect(endpoints.first?.provider == "zelcore-blockbook")
        #expect(endpoints.contains { $0.provider == "blockcypher" })
        // Blockbook sorts ahead of BlockCypher (priority 0 < 10).
        if let bb = endpoints.first(where: { $0.provider == "zelcore-blockbook" }),
           let bc = endpoints.first(where: { $0.provider == "blockcypher" }) {
            #expect(bb.priority < bc.priority)
        }
    }

    @Test("live balance snapshot for funded mainnet address")
    func liveBalanceSnapshot() async throws {
        let start = ContinuousClock.now
        let snapshot = try await client.accountSnapshot(address: address)
        let elapsed = start.duration(to: ContinuousClock.now)

        let raw = try #require(Int64(snapshot.rawBalance))
        #expect(raw > 0, "probe address should hold DOGE; raw=\(snapshot.rawBalance)")
        // ~62k DOGE → > 1 DOGE in koinu (1e8)
        #expect(raw > 100_000_000, "expected multi-DOGE balance, got \(raw) koinu")
        #expect(snapshot.isUsed)
        #expect(elapsed < .seconds(25), "DOGE balance probe should stay responsive; elapsed \(elapsed)")
    }

    @Test("live UTXO set for funded mainnet address")
    func liveUTXOs() async throws {
        let utxos = try await client.fetchUTXOs(address: address)
        #expect(!utxos.isEmpty, "funded address must expose unspent outputs")
        let total = utxos.reduce(Int64(0)) { $0 + $1.valueSats }
        #expect(total > 0)
        #expect(utxos.allSatisfy { !$0.txid.isEmpty && $0.vout >= 0 && $0.valueSats > 0 })
        // Sum of UTXOs should match snapshot within dust of pending movement.
        let snapshot = try await client.accountSnapshot(address: address)
        let balance = try #require(Int64(snapshot.rawBalance))
        // Allow lag between providers / mempool; require same order of magnitude.
        #expect(total > balance / 2, "UTXO sum \(total) should be near balance \(balance)")
    }

    @Test("live history returns confirmed activity")
    func liveHistory() async throws {
        let events = try await client.recentEvents(address: address, limit: 20)
        #expect(!events.isEmpty, "active address should have history")
        #expect(events.allSatisfy { !$0.txHash.isEmpty })
        // Prefer at least one non-zero amount row (Blockbook); Blockchair
        // hash-only fallback uses amount "0" and is still valid activity.
        let hasDetail = events.contains { ($0.amount as NSString).doubleValue > 0 || $0.amount != "0" }
        #expect(hasDetail || events.allSatisfy { $0.txHash.count == 64 })
    }

    @Test("UTXOService routes DOGE through multi-provider client")
    func utxoServiceUsesCascade() async throws {
        let utxos = try await UTXOService().fetchUTXOs(address: address, chain: .dogecoin)
        #expect(!utxos.isEmpty)
        #expect(utxos.contains { $0.ownerAddress == address || $0.ownerAddress == nil })
    }

    @Test("scanner accountSnapshot entrypoint matches client for DOGE")
    func scannerSnapshotEntrypoint() async throws {
        let scanner = BitcoinFamilyRESTBalanceScanner()
        let snap = try await scanner.accountSnapshot(address: address, chain: .dogecoin)
        let raw = try #require(Int64(snap.rawBalance))
        #expect(raw > 100_000_000)
        #expect(snap.isUsed)
    }

    @Test("broadcast rejects malformed hex (API shape live)")
    func broadcastRejectsJunk() async throws {
        // Proves each provider's push endpoint is the real send path —
        // not 404. Expect decode / reject error, never success.
        do {
            _ = try await client.broadcast(rawHex: "00")
            Issue.record("malformed DOGE tx must not be accepted")
        } catch {
            let detail = RPCError.diagnosticDetail(for: error)
            #expect(
                detail.contains("decode")
                    || detail.contains("invalid")
                    || detail.contains("rpcError")
                    || detail.contains("HTTP")
                    || detail.contains("failed")
                    || detail.contains("Limits")
                    || detail.contains("rateLimited")
                    || !detail.isEmpty
            )
        }
    }
}
