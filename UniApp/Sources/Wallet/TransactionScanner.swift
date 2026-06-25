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
    /// (so 0.001 BTC, not 100_000 sats). Serialize with
    /// `NSDecimalNumber(decimal:).stringValue` when writing to
    /// SwiftData's `amountRaw` — `String(describing:)` can emit
    /// scientific notation that `Decimal(string:)` mis-parses on
    /// read-back.
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
