import Foundation

/// **EVM data fetching is disabled app-wide** (2026-06-21 user direction:
/// zero balance / token / transaction-history fetching for every EVM chain).
///
/// EVM addresses stay derivable so the user can still RECEIVE, and Send /
/// Swap / dApp keep working — those sign + broadcast through their own RPC
/// path (`RPCClient` + `BroadcastService` + the EVM signers), never through
/// this connector. The wallet-home / holdings / activity surfaces, which DO
/// read through the connector via the scanners, get nothing for EVM.
///
/// Every EVM chain routes here from `ChainConnectorRegistry` instead of a live
/// connector, so the fleet dispatcher's exhaustive switch stays valid and any
/// stray balance/history read returns empty WITHOUT a network call. (The
/// scanners also skip EVM up front, so in practice these methods are never
/// even reached — this is the belt to that suspenders.)
struct DisabledEVMConnector: ChainConnector {
    let chain: SupportedChain

    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        ChainAccountSummary(nativeBalance: 0, isUsed: false)
    }

    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        []
    }
}
