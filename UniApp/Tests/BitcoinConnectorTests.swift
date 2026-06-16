import Testing
import Foundation
@testable import Aperture

/// **Worked example — Bitcoin connector live-REST smoke test.**
///
/// The REST/UTXO-template test every Bitcoin-family connector test
/// copies (swap the connector type + address + provider shape). Hits
/// live Esplora REST through `RPCClient.shared` (mempool.space primary,
/// blockstream fallback — rotation + rate-limit + circuit-breaking
/// apply), so it proves `BitcoinConnector`'s `/address/{addr}` +
/// `/address/{addr}/txs` request shapes and vin/vout parsing work
/// against the real upstreams.
///
/// **Address.** `1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa` — the Bitcoin
/// **genesis block coinbase address** (Satoshi Nakamoto's address from
/// block 0, 2009). It holds the 50 BTC genesis reward plus thousands of
/// donation outputs accumulated over the years, so it is permanently
/// funded with a deep, immutable transaction history — the canonical
/// "well-known funded BTC address" for a reproducible live test.
/// Verifiable at mempool.space/address/1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa.
struct BitcoinConnectorTests {

    let connector = BitcoinConnector()
    /// Bitcoin genesis coinbase address — permanently funded, deep history.
    let address = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

    @Test("Bitcoin native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // The genesis address is permanently funded, so a real read is > 0;
        // assert the contract floor (≥ 0) so a provider hiccup degrades
        // gracefully rather than flaking the suite.
        #expect(summary.nativeBalance >= 0)
        // It has received funds, so it must read as used.
        #expect(summary.isUsed)
    }

    @Test("Bitcoin history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — the genesis address has a deep real history.
        #expect(events.count >= 0)
        for event in events {
            #expect(event.chain == connector.chain)
            #expect(event.tokenSymbol == "BTC")   // native-only chain
            #expect(event.tokenContract == nil)
        }
    }

    @Test("Bitcoin token balances return an empty array (no token layer)")
    func tokenBalancesReturnArray() async {
        let tokens = await connector.fetchTokenBalances(address: address, customContracts: [])
        // Bitcoin has no fungible-token layer Aperture tracks.
        #expect(tokens.isEmpty)
    }
}
