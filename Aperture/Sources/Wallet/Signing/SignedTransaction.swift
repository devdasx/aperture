import Foundation

/// The output of a successful sign: the raw signed transaction in the
/// three shapes the per-chain broadcast methods consume, plus the
/// transaction hash/id when the signer can compute it locally.
///
/// **Shape (adapted from Stabro's `SignedTransaction`,
/// `StabroWallet/Services/KeyManagement/TransactionSigner.swift`).**
/// - `rawData` — the canonical signed bytes (RLP for EVM, the full
///   serialized tx for Bitcoin-family). The source of truth.
/// - `rawHex` — the broadcast-wire form: `0x`-prefixed hex for EVM
///   (`eth_sendRawTransaction`), bare lowercase hex for the Bitcoin
///   family (Esplora `POST /tx`, BlockCypher `txs/push`, Blockchair).
/// - `txHash` — the chain's canonical id when the signer knows it
///   locally: EVM = `keccak256(rawData)` (`0x`-prefixed); Bitcoin =
///   wallet-core's `transactionID` (the txid). Empty string only for
///   chains whose hash is assigned by the node at broadcast (none in
///   PASS 1 — EVM and Bitcoin both compute it locally).
///
/// `Sendable` so it crosses the off-main signing boundary back to the
/// `SendExecutor` cleanly. Carries no key material.
struct SignedTransaction: Sendable, Hashable {
    /// Canonical signed bytes — the source of truth.
    let rawData: Data
    /// Broadcast-wire hex. EVM: `0x`-prefixed. Bitcoin family: bare
    /// lowercase hex (no `0x`).
    let rawHex: String
    /// Chain-canonical transaction id when known locally; `""` when the
    /// node assigns it at broadcast.
    let txHash: String
}
