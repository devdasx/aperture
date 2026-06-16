import Testing
import Foundation
@testable import Aperture

/// **Optimism connector live-RPC smoke test.**
///
/// The EVM-template test (copied from `EthereumConnectorTests`, swapping
/// the connector type). Hits live public RPC through `RPCClient.shared`
/// (rotation + rate-limit + circuit-breaking apply), so it proves
/// `OptimismConnector`'s request shapes + parsing work against the real
/// Optimism upstreams.
///
/// **Address.** `0xB61d7338a20Fa652EC9eD20d1392D33644837c8a` — a real,
/// publicly-known address (the canonical fleet test address). On-chain
/// state is verifiable in any block explorer
/// (optimistic.etherscan.io / explorer.optimism.io). At the time of
/// authoring it holds 0 native ETH on Optimism — a real zero, not a
/// stub — which is exactly the `>= 0` non-negative contract the
/// native-balance check asserts.
struct OptimismConnectorTests {

    let connector = OptimismConnector()
    /// Real, publicly-known address — the canonical fleet test address.
    let address = "0xB61d7338a20Fa652EC9eD20d1392D33644837c8a"

    @Test("Optimism native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // Real on-chain read — a non-negative ETH balance, never a stub.
        #expect(summary.nativeBalance >= 0)
    }

    @Test("Optimism history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — a fresh address yields [], a funded one real rows.
        #expect(events.count >= 0)
        // Every event is stamped with this connector's chain.
        for event in events {
            #expect(event.chain == connector.chain)
        }
    }

    @Test("Optimism token balances return an array")
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
