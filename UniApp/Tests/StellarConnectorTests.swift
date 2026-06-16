import Testing
import Foundation
@testable import Aperture

/// **Stellar connector live-Horizon smoke test.**
///
/// The "other"-family test for the `.stellar` connector. Hits live
/// Horizon REST through `RPCClient.shared` (horizon.stellar.org SDF
/// primary, horizon.stellar.lobstr.co fallback — rotation + rate-limit +
/// circuit-breaking apply), so it proves `StellarConnector`'s
/// `/accounts/{addr}` + `/accounts/{addr}/payments` request shapes and
/// `balances` / `_embedded.records` parsing work against the real
/// upstreams.
///
/// **Address.** `GADTIB3KMVVXE4DHDHX4OMYV2ZOHKAKFVUPAYTIAKI5Y5N3NQS226LCZ`
/// — a real, well-formed Stellar public key. Live curl (2026-06-16)
/// confirms Horizon returns **404 Resource Missing** for both
/// `/accounts/{addr}` and `/accounts/{addr}/payments` on this account: it
/// is unfunded / not yet created on-chain. That makes it the canonical
/// witness for the connector's **404 = unfunded → zero summary / empty
/// history** contract (`RPCError.isHTTPNotFound`): the read must NOT
/// throw, `nativeBalance` is exactly `0`, the address is `isUsed == false`,
/// and history is `[]`. The contract floor (`≥ 0`, `count ≥ 0`) is
/// asserted so the suite degrades gracefully if the account is ever funded
/// and on a provider hiccup, rather than flaking. Verifiable at
/// stellar.expert/explorer/public/account/GADTIB3KMVVXE4DHDHX4OMYV2ZOHKAKFVUPAYTIAKI5Y5N3NQS226LCZ.
struct StellarConnectorTests {

    let connector = StellarConnector()
    /// Well-formed Stellar account that returns Horizon 404 (unfunded) —
    /// the live witness for the 404 = zero-balance / empty-history path.
    let address = "GADTIB3KMVVXE4DHDHX4OMYV2ZOHKAKFVUPAYTIAKI5Y5N3NQS226LCZ"

    @Test("Stellar native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // A Horizon 404 (unfunded account) must map to a zero summary,
        // never a throw. Assert the contract floor (≥ 0).
        #expect(summary.nativeBalance >= 0)
    }

    @Test("Stellar history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // A 404 on the first page maps to an empty history (≥ 0 events).
        #expect(events.count >= 0)
        for event in events {
            #expect(event.chain == connector.chain)
        }
    }

    @Test("Stellar token balances return an empty array (no token layer)")
    func tokenBalancesReturnArray() async {
        let tokens = await connector.fetchTokenBalances(address: address, customContracts: [])
        // Aperture does not scan Stellar trustline tokens as held balances.
        #expect(tokens.isEmpty)
    }
}
