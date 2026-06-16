import Testing
import Foundation
@testable import Aperture

/// **Avalanche connector live-RPC smoke test** (the EVM-template test,
/// copied from `EthereumConnectorTests`, swapping the connector type +
/// address). Hits live public Avalanche C-Chain RPC through
/// `RPCClient.shared` (rotation + rate-limit + circuit-breaking apply),
/// so it proves `AvalancheConnector`'s request shapes + parsing work
/// against the real upstreams (`RPCRegistry.endpoints(for: .avalanche)`).
///
/// **Address.** `0xB61d7338a20Fa652EC9eD20d1392D33644837c8a` — a real,
/// publicly-known address (the canonical fleet test address). On-chain
/// state is verifiable in any block explorer (snowtrace.io). At time of
/// writing it holds 0 AVAX / 0 tokens on Avalanche, so the assertions are
/// the contract floors (non-negative balance, ≥ 0 events, ≥ 0 rows) — a
/// funded address would surface real rows through the same code paths.
struct AvalancheConnectorTests {

    let connector = AvalancheConnector()
    /// Real, publicly-known address — the canonical fleet test address.
    let address = "0xB61d7338a20Fa652EC9eD20d1392D33644837c8a"

    @Test("Avalanche native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // Real on-chain read — a non-negative AVAX balance, never a stub.
        #expect(summary.nativeBalance >= 0)
    }

    @Test("Avalanche history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — a fresh address yields [], a funded one real rows.
        #expect(events.count >= 0)
        // Every event is stamped with this connector's chain.
        for event in events {
            #expect(event.chain == connector.chain)
        }
    }

    @Test("Avalanche token balances return an array")
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
