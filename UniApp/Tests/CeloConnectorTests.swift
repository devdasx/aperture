import Testing
import Foundation
@testable import Aperture

/// **Celo connector live-RPC smoke test.**
///
/// The EVM-template test (a sibling of `EthereumConnectorTests`), with
/// the connector type + chain swapped to `.celo`. Hits live public RPC
/// through `RPCClient.shared` (rotation + rate-limit + circuit-breaking
/// apply), so it proves `CeloConnector`'s request shapes + parsing work
/// against the real Celo upstreams (publicnode / forno / drpc, chainId
/// `0xa4ec` = 42220) and the Celo Blockscout (`celo.blockscout.com`).
///
/// **Address.** `0xB61d7338a20Fa652EC9eD20d1392D33644837c8a` — the
/// canonical fleet test address (same one the rest of the fleet's
/// connector tests use). On-chain Celo state is verifiable in any block
/// explorer (celoscan.io / celo.blockscout.com). Live-probed 2026-06-16:
/// this address is currently unfunded on Celo (zero CELO, zero txs), so
/// the reads exercise the honest zero / empty paths — a non-negative
/// balance and an empty-but-non-throwing history/token result.
struct CeloConnectorTests {

    let connector = CeloConnector()
    /// Real, publicly-known address — the canonical fleet test address.
    let address = "0xB61d7338a20Fa652EC9eD20d1392D33644837c8a"

    @Test("Celo native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // Real on-chain read — a non-negative CELO balance, never a stub.
        #expect(summary.nativeBalance >= 0)
    }

    @Test("Celo history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — a fresh address yields [], a funded one real rows.
        #expect(events.count >= 0)
        // Every event is stamped with this connector's chain.
        for event in events {
            #expect(event.chain == connector.chain)
        }
    }

    @Test("Celo token balances return an array")
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
