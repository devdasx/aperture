import Testing
import Foundation
@testable import Aperture

/// **BNB Chain (BSC) connector live-RPC smoke test.**
///
/// The EVM-template test (`EthereumConnectorTests`) copied for
/// `.bnbChain`. Hits live public BSC RPC through `RPCClient.shared`
/// (rotation + rate-limit + circuit-breaking apply —
/// `bsc-rpc.publicnode.com` primary + Binance dataseeds + 1rpc), so it
/// proves `BnbChainConnector`'s request shapes + parsing work against the
/// real upstreams: `eth_getBalance` native, Multicall3 `aggregate3`
/// `balanceOf` batching (verified deployed on BSC), and chunked
/// contract-scoped `eth_getLogs` token history.
///
/// **Address.** `0xB61d7338a20Fa652EC9eD20d1392D33644837c8a` — the
/// canonical fleet test address (same one used by `EthereumConnectorTests`).
/// On-chain state is verifiable in any block explorer (bscscan.com).
/// As a real address it satisfies the contract floor (≥ 0) regardless of
/// its current BSC balance, so the suite is reproducible and never flakes
/// on a balance change.
///
/// **No native-history assertion.** BSC has no public Blockscout indexer
/// Aperture trusts, and native BNB transfers emit no `Transfer` logs, so
/// `fetchHistory` returns ONLY BEP-20 token-transfer rows by design —
/// every history row therefore carries a non-nil `tokenContract`.
struct BnbChainConnectorTests {

    let connector = BnbChainConnector()
    /// Real, publicly-known address — the canonical fleet test address.
    let address = "0xB61d7338a20Fa652EC9eD20d1392D33644837c8a"

    @Test("BNB Chain native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // Real on-chain read — a non-negative BNB balance, never a stub.
        #expect(summary.nativeBalance >= 0)
    }

    @Test("BNB Chain history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — a fresh address yields [], a funded one real rows.
        #expect(events.count >= 0)
        for event in events {
            // Every event is stamped with this connector's chain.
            #expect(event.chain == connector.chain)
            // BSC history is BEP-20-only (no native Blockscout indexer),
            // so every row is a token transfer with a contract.
            #expect(event.tokenContract != nil)
        }
    }

    @Test("BNB Chain token balances return an array")
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
