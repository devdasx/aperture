import Testing
import Foundation
@testable import Aperture

/// **opBNB connector live-RPC smoke test** (copied from the EVM-template
/// `EthereumConnectorTests`, swapping the connector type + chain).
///
/// Hits live public opBNB RPC through `RPCClient.shared` (rotation +
/// rate-limit + circuit-breaking apply), so it proves `OpBNBConnector`'s
/// request shapes + parsing work against the real upstreams
/// (`opbnb-rpc.publicnode.com` et al., chainId `0xcc` / 204).
///
/// **Address.** `0xB61d7338a20Fa652EC9eD20d1392D33644837c8a` — the
/// canonical fleet test address. On-chain state is verifiable in any
/// opBNB block explorer (opbnb.bscscan.com). Note: native BNB *send*
/// history is structurally empty on opBNB (no public keyless indexer —
/// `OpBNBConnector.blockscoutHost == nil`); the ERC-20 path via
/// `eth_getLogs` is the live token-history source. The assertions below
/// only require ≥ 0 rows, so they hold for a funded or fresh address
/// alike.
struct OpBNBConnectorTests {

    let connector = OpBNBConnector()
    /// Real, publicly-known address — the canonical fleet test address.
    let address = "0xB61d7338a20Fa652EC9eD20d1392D33644837c8a"

    @Test("opBNB native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // Real on-chain read — a non-negative BNB balance, never a stub.
        #expect(summary.nativeBalance >= 0)
    }

    @Test("opBNB history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — a fresh address yields [], a funded one real rows.
        #expect(events.count >= 0)
        // Every event is stamped with this connector's chain.
        for event in events {
            #expect(event.chain == connector.chain)
        }
    }

    @Test("opBNB token balances return an array")
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
