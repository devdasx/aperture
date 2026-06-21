import Foundation

/// **Data fetching is disabled for some chains** (2026-06-21 user direction):
/// every EVM chain, the whole Bitcoin family (BTC / BCH / LTC / DOGE), and
/// Tron. The authoritative predicate is `SupportedChain.fetchingDisabled`.
///
/// Those chains' addresses stay derivable so the user can still RECEIVE, and
/// Send still works — it fetches UTXOs (`UTXOService`) and signs + broadcasts
/// (`BroadcastService` + the per-chain signers) through its OWN path, never
/// through this connector. The wallet-home / holdings / activity surfaces,
/// which read through the connector via the scanners, get nothing.
///
/// Every disabled chain routes here from `ChainConnectorRegistry` instead of a
/// live connector, so the fleet dispatcher's exhaustive switch stays valid and
/// any stray balance/history read returns empty WITHOUT a network call. (The
/// scanners also skip these chains up front, so in practice these methods are
/// never even reached — this is the belt to that suspenders.)
struct DisabledChainConnector: ChainConnector {
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
