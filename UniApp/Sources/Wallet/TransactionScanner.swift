import Foundation

/// One on-chain transaction observed at one of the wallet's addresses.
/// Per-chain quirks (Bitcoin's vin/vout vs. EVM's from/to/value vs.
/// XRPL's account_tx envelope) collapse to a uniform direction +
/// amount + counterparty triple so the UI renders every chain the
/// same way.
///
/// **Why a value type and not the SwiftData `TransactionRecord`.** The
/// scanner is a pure read pipeline — it must work the same in test
/// mode (no SwiftData write) as in real-wallet mode (write through
/// `TransactionRepository`). The value type is the boundary; both
/// modes share the same fetch + parse stages and diverge only at the
/// sink.
///
/// **Honesty (Rule #16 §A.5).** A `TransactionEvent` is the truth of
/// what the upstream RPC reported, normalized but never fabricated.
/// If a chain doesn't expose a counterparty (XRPL `Payment` to a
/// destination tag, Aptos resource events), the field is the empty
/// string and the UI reads "—" — not "unknown" or a placeholder
/// hash.
struct TransactionEvent: Hashable, Sendable {
    let chain: SupportedChain
    /// The address this event belongs to (the wallet's, not the
    /// counterparty's). Lets the consumer write the row into the
    /// right `WalletAddressRecord` via `TransactionRepository`.
    let address: String
    /// On-chain transaction hash / signature / ledger sequence-id.
    /// Format differs per chain (hex for EVM/BTC, base58 for Solana,
    /// integer-string for XRPL ledger sequence).
    let txHash: String
    /// `.incoming` (the wallet received funds) / `.outgoing` (the
    /// wallet sent funds) / `.internal` (movement between the
    /// wallet's own addresses).
    let direction: TransactionDirection
    /// Amount as a `Decimal` already divided by the token's decimals
    /// (so 0.001 BTC, not 100_000 sats). Use `String(describing:)`
    /// when writing to SwiftData's `amountRaw`.
    let amount: Decimal
    /// `BTC` / `ETH` / `USDC` / `XRP` etc. For native sends this is
    /// the chain's native ticker; for token transfers it's the
    /// contract's symbol.
    let tokenSymbol: String
    /// Contract address for non-native transfers (`nil` for native
    /// coin). EVM: ERC-20 contract; Solana: SPL mint; XRPL: issuer +
    /// currency code; Aptos: coin module address.
    let tokenContract: String?
    /// Block height / slot / ledger sequence the transaction
    /// landed in. `nil` only for `.pending` events.
    let blockNumber: Int64?
    /// On-chain timestamp.
    let occurredAt: Date
    /// `.pending` / `.confirmed` / `.failed`. Real failed transactions
    /// are surfaced honestly — we don't filter them out.
    let status: TransactionStatus
    /// Counterparty address (sender for `.incoming`, receiver for
    /// `.outgoing`). Empty for events without a single counterparty
    /// (multi-input BTC, contract calls).
    let counterparty: String
    /// Fee in chain native units (`Decimal`, already divided by
    /// decimals). `nil` for incoming transactions where the wallet
    /// didn't pay the fee.
    let fee: Decimal?
}

// MARK: - Protocol

/// Reads on-chain transaction history for one or more addresses.
/// Phase-1 ships with `StubTransactionScanner` (empty); the production
/// `RealRPCTransactionScanner` reads from public RPC / REST endpoints
/// per chain (Rule #3 — no third-party SDK).
///
/// The protocol has two modes:
///
/// 1. **`scan(addresses:limit:)`** — bulk fetch; returns a list of
///    events across every supplied address-chain pair. Used by
///    `WalletHomeView.runRefresh()` to populate the real wallet's
///    SwiftData store.
///
/// 2. **`streamScan(addresses:limit:)`** — async sequence; emits
///    each event as soon as its chain's adapter resolves. Used by
///    test mode so the UI shows rows landing in real time, never
///    blocking the slowest chain.
///
/// Both modes share the same per-chain fan-out and adapter set.
protocol TransactionScanner: Sendable {
    /// Bulk fetch — returns all events for `addresses`, up to `limit`
    /// per address. May reorder events arbitrarily; callers sort
    /// by `occurredAt` for display.
    func scan(
        addresses: [SupportedChain: String],
        limit: Int
    ) async -> [TransactionEvent]

    /// Streaming variant — yields events as their per-chain adapters
    /// complete. Caller must consume the stream until it terminates;
    /// dropping early cancels the per-chain tasks via the
    /// `onTermination` handler.
    func streamScan(
        addresses: [SupportedChain: String],
        limit: Int
    ) -> AsyncStream<TransactionEvent>
}

// MARK: - Stub

/// Empty scanner. Used in unit tests, in previews, and as a
/// type-safe fallback when no scanner has been injected yet. Returns
/// no events so the UI's empty-state surfaces continue to render
/// honestly (Rule #16).
struct StubTransactionScanner: TransactionScanner {
    func scan(
        addresses: [SupportedChain: String],
        limit: Int
    ) async -> [TransactionEvent] { [] }

    func streamScan(
        addresses: [SupportedChain: String],
        limit: Int
    ) -> AsyncStream<TransactionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
