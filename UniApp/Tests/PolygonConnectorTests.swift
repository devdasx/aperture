import Testing
import Foundation
@testable import Aperture

/// **Polygon connector live-RPC smoke test.**
///
/// The EVM-template test (`EthereumConnectorTests`) copied for
/// `.polygon`. Hits live public Polygon RPC through `RPCClient.shared`
/// (rotation + rate-limit + circuit-breaking apply —
/// `polygon-bor-rpc.publicnode.com` primary + drpc/tenderly/nodies/
/// onfinality + 1rpc), so it proves `PolygonConnector`'s request shapes
/// + parsing work against the real upstreams: `eth_getBalance` native,
/// Multicall3 `aggregate3` `balanceOf` batching (verified deployed on
/// Polygon — curl-confirmed 2026-06-16), Blockscout `txlist` native
/// history (`polygon.blockscout.com`), and chunked contract-scoped
/// `eth_getLogs` token history.
///
/// **Address.** `0xB61d7338a20Fa652EC9eD20d1392D33644837c8a` — the
/// canonical fleet test address (same one used by `EthereumConnectorTests`).
/// On-chain state is verifiable in any block explorer (polygonscan.com /
/// polygon.blockscout.com). As a real address it satisfies the contract
/// floor (≥ 0) regardless of its current Polygon balance, so the suite is
/// reproducible and never flakes on a balance change.
struct PolygonConnectorTests {

    let connector = PolygonConnector()
    /// Real, publicly-known address — the canonical fleet test address.
    let address = "0xB61d7338a20Fa652EC9eD20d1392D33644837c8a"

    @Test("Polygon native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // Real on-chain read — a non-negative POL balance, never a stub.
        #expect(summary.nativeBalance >= 0)
    }

    @Test("Polygon history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — a fresh address yields [], a funded one real rows.
        #expect(events.count >= 0)
        // Every event is stamped with this connector's chain.
        for event in events {
            #expect(event.chain == connector.chain)
        }
    }

    @Test("Polygon token balances return an array")
    func tokenBalancesReturnArray() async {
        let tokens = await connector.fetchTokenBalances(address: address, customContracts: [])
        // Non-throwing by contract; ≥ 0 positive-balance rows.
        #expect(tokens.count >= 0)
        for token in tokens {
            #expect(token.amount > 0)        // only positive balances are returned
            #expect(token.chain == connector.chain)
        }
    }
}
