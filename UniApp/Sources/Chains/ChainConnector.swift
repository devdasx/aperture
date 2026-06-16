import Foundation

/// **The per-chain connector contract.**
///
/// Aperture's fleet design (user direction): every chain gets its OWN
/// independent module — its own connector file, its own
/// balance/token/history fetching code, its own test. Even though EVM
/// chains share a JSON-RPC interface, each EVM chain gets its OWN
/// connector file (the duplication is intentional and accepted): one
/// chain's endpoint quirk, decimals fix, or parsing tweak never leaks
/// into a sibling.
///
/// **What a connector IS.** A small `Sendable` value type bound to one
/// `SupportedChain`, owning that chain's request shapes + parsing. It
/// resolves its endpoints from `RPCRegistry.endpoints(for: chain)` and
/// dispatches through the shared `RPCClient` actor — which already does
/// endpoint rotation, per-endpoint rate limiting, circuit breaking, and
/// the `ConcurrencyGate`. A connector MUST NOT bypass `RPCClient` with a
/// raw `URLSession`; doing so defeats every reliability mechanism the
/// dispatcher provides (see `RPCClient`'s `shared` doc-comment).
///
/// **Return types are the EXISTING app types, verbatim.** A connector
/// never invents a new return shape:
/// - `fetchNativeBalance` → `ChainAccountSummary`
///   (`nativeBalance: Decimal`, `isUsed: Bool` — defined in
///   `LongTailAdapters.swift`). The `Decimal` is already divided by the
///   chain's native decimals (ETH not wei, BTC not sats).
/// - `fetchTokenBalances` → `[TokenBalance]` (defined in
///   `TokenBalance.swift`). Raw on-chain amounts are fine; `fiatBalance`
///   may be `nil` — pricing stays in the coordinator, NOT in the
///   connector. Each `amount` is already decoded to canonical units
///   (1000 USDC, not 1_000_000_000).
/// - `fetchHistory` → `[TransactionEvent]` (defined in
///   `TransactionScanner.swift`). Each `amount` / `fee` is already
///   divided by the token's decimals.
///
/// **Error contract.**
/// - `fetchNativeBalance` uses typed throws (`throws(RPCError)`) — the
///   same surface the existing per-chain adapters use, so the caller
///   can pattern-match `.cancelled` / `.rateLimited` / `.isHTTPNotFound`
///   exactly as before. A `404` for an unfunded account (Stellar
///   Horizon, Tron) is the normal zero-balance state, not a failure:
///   connectors map `RPCError.isHTTPNotFound(error)` to an empty/zero
///   summary rather than propagating it.
/// - `fetchTokenBalances` is non-throwing (`async -> [TokenBalance]`):
///   a token-discovery failure degrades to "no token rows" rather than
///   blanking the whole refresh. It returns only positive-balance rows
///   (zero balances are omitted — Rule #2 §A.7 honesty: the wallet home
///   shows tokens the user actually holds).
/// - `fetchHistory` uses untyped throws (`async throws`) — matching the
///   existing transaction adapters, which compose `eth_getLogs`,
///   indexer GETs, and REST pagination whose errors are heterogeneous.
///   Cancellation still propagates as `RPCError.cancelled`.
///
/// **Concurrency.** Conformers are `Sendable` structs (a `let chain`
/// plus a `let client: RPCClient`). All shared mutable state lives
/// inside the `RPCClient` actor, so a connector value carries none.
protocol ChainConnector: Sendable {
    /// The single chain this connector serves. Drives endpoint
    /// selection (`RPCRegistry.endpoints(for: chain)`) and stamps every
    /// row it returns (`ChainBalance.chain`, `TokenBalance.chain`,
    /// `TransactionEvent.chain`).
    var chain: SupportedChain { get }

    /// Native-coin balance + used-address flag for `address`.
    ///
    /// The returned `nativeBalance` is already divided by the chain's
    /// native decimals (ETH, BTC, SOL units — not wei/sats/lamports).
    /// `isUsed` is the connector's honest "has this address ever been
    /// active" heuristic (balance > 0, or a non-zero nonce / tx-count
    /// where the chain exposes one).
    ///
    /// Typed throws: `RPCError.cancelled` on task cancellation,
    /// `.allEndpointsFailed` / `.network` / `.rateLimited` on a genuine
    /// outage. An HTTP 404 for an unfunded account must be mapped to a
    /// zero summary, never thrown.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary

    /// Fungible-token balances held by `address` — the chain's curated
    /// registry tokens plus any `customContracts` the user added.
    ///
    /// Returns only POSITIVE-balance rows. Each `TokenBalance.amount` is
    /// already decoded to canonical units; `fiatBalance` is `nil` (the
    /// coordinator prices rows downstream). Non-throwing: a discovery
    /// failure degrades to `[]` (no rows), preserving the user's
    /// persisted balances instead of fabricating zeros.
    ///
    /// - Parameter customContracts: user-added token contracts / mints
    ///   for this chain. Empty for chains/states without custom tokens.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance]

    /// On-chain transaction history for `address`, newest first, capped
    /// at `limit` events.
    ///
    /// Each `TransactionEvent` is real on-chain data, normalized to the
    /// uniform direction + amount + counterparty triple (per-chain
    /// quirks — Bitcoin vin/vout, EVM from/to/value, XRPL account_tx —
    /// collapse here). Amounts/fees are already divided by decimals.
    ///
    /// Untyped throws (matching the existing transaction adapters whose
    /// composed errors are heterogeneous); `RPCError.cancelled` still
    /// propagates on cancellation.
    ///
    /// - Parameter customContracts: user-added token contracts gating
    ///   the token-transfer rows (spam from un-tracked contracts is
    ///   dropped); native history is unaffected.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent]
}
