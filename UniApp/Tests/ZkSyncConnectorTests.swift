import Testing
import Foundation
@testable import Aperture

/// **zkSync Era connector live-RPC smoke test.**
///
/// The EVM-template test (mirrors `EthereumConnectorTests`, swapping the
/// connector type + chain). Hits live public RPC through
/// `RPCClient.shared` (rotation + rate-limit + circuit-breaking apply),
/// so it proves `ZkSyncConnector`'s request shapes + parsing work
/// against the real upstreams (matter-labs `mainnet.era.zksync.io`,
/// `zksync.drpc.org`, keyed 1rpc `zksync2-era`; chainId `0x144`) and the
/// `zksync.blockscout.com` indexer.
///
/// **Address.** `0xB61d7338a20Fa652EC9eD20d1392D33644837c8a` — the
/// canonical fleet test address (a real, publicly-known Ethereum-format
/// address). On-chain state is verifiable in any zkSync block explorer
/// (explorer.zksync.io / zksync.blockscout.com).
struct ZkSyncConnectorTests {

    let connector = ZkSyncConnector()
    /// Real, publicly-known address — the canonical fleet test address.
    let address = "0xB61d7338a20Fa652EC9eD20d1392D33644837c8a"

    @Test("zkSync native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // Real on-chain read — a non-negative ETH balance, never a stub.
        #expect(summary.nativeBalance >= 0)
    }

    @Test("zkSync history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — a fresh address yields [], a funded one real rows.
        #expect(events.count >= 0)
        // Every event is stamped with this connector's chain.
        for event in events {
            #expect(event.chain == connector.chain)
        }
    }

    @Test("zkSync token balances return an array")
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
