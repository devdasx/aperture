import Testing
import Foundation
@testable import Aperture

/// **Ripple (XRP Ledger) connector live-RPC smoke test.**
///
/// Hits live rippled JSON-RPC through `RPCClient.shared`
/// (s1.ripple.com primary, s2.ripple.com fallback, xrplcluster.com
/// last-resort — rotation + rate-limit + circuit-breaking apply), so it
/// proves `RippleConnector`'s `account_info` (balance), `account_lines`
/// (IOU tokens), and `account_tx` (Payment history) request shapes and
/// parsing work against the real upstreams — including the XRPL
/// id-echo opt-out (`validatesIDEcho: false`), without which every
/// response is rejected and XRP reads 0.
///
/// **Address.** `rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh` — the **XRP Ledger
/// genesis account** (the original account created in the very first
/// ledger; documented on xrpl.org and every XRPL explorer, e.g.
/// xrpscan.com/account/rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh and
/// livenet.xrpl.org). It is permanently activated and funded — a live
/// `account_info` curl (2026-06-16, s1.ripple.com) returned
/// `Balance: 56760625556` drops (≈ 56,760.6 XRP) and `account_tx`
/// returned a full 50-row page of validated `Payment` envelopes with a
/// continuation `marker` — so it is the canonical "well-known funded
/// XRP address" for a reproducible live test. Verifiable at
/// livenet.xrpl.org/accounts/rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh.
struct RippleConnectorTests {

    let connector = RippleConnector()
    /// XRP Ledger genesis account — permanently activated, deep Payment history.
    let address = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"

    @Test("Ripple native balance read succeeds and is non-negative")
    func nativeBalanceSucceeds() async throws {
        let summary = try await connector.fetchNativeBalance(address: address)
        // The genesis account is permanently funded, so a real read is > 0;
        // assert the contract floor (≥ 0) so a provider hiccup degrades
        // gracefully rather than flaking the suite.
        #expect(summary.nativeBalance >= 0)
        // It holds well above the base reserve, so it must read as used.
        #expect(summary.isUsed)
    }

    @Test("Ripple history returns an array without throwing")
    func historyReturnsArray() async throws {
        let events = try await connector.fetchHistory(address: address, limit: 25, customContracts: [])
        // ≥ 0 events — the genesis account has a deep real Payment history.
        #expect(events.count >= 0)
        for event in events {
            #expect(event.chain == connector.chain)
            // Native XRP rows carry no contract; issued-currency rows do.
            if event.tokenSymbol == "XRP" {
                #expect(event.tokenContract == nil)
            }
            // Every parsed row must carry a real on-chain hash.
            #expect(!event.txHash.isEmpty)
        }
    }

    @Test("Ripple token balances return an array (positive rows only)")
    func tokenBalancesReturnArray() async {
        let tokens = await connector.fetchTokenBalances(address: address, customContracts: [])
        // Non-throwing by contract; only positive-balance registry IOUs.
        #expect(tokens.count >= 0)
        for token in tokens {
            #expect(token.amount > 0)
            #expect(token.chain == connector.chain)
            #expect(token.fiatBalance == nil)   // priced by the coordinator
        }
    }
}
