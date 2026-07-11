import Foundation

/// Polls a chain for the live confirmation status of a just-broadcast
/// transaction, so a "Submitted" surface flips to "Confirmed"/"Failed" the
/// moment the chain reports the receipt (Rule #25 — live, not a one-shot
/// snapshot the user has to refresh by hand).
///
/// It reuses `TransactionDetailService.detail`, which ALREADY resolves a real
/// `TransactionStatus` for every supported family — EVM receipts, Bitcoin
/// confirmations, Solana signature status, and the XRPL / Stellar / TON /
/// TRON / NEAR / Aptos / Polkadot / Sui lookups. One primitive, all
/// 24 chains: no new per-chain network code and no new crypto (Rule #3 —
/// compose the proven path).
///
/// Honest by construction (Rule #16): a tx the provider hasn't indexed yet,
/// or one still sitting in the mempool, reads as `.pending` — never a
/// fabricated success. `awaitResolution` returns the terminal verdict the
/// instant it lands, `.pending` if the poll budget runs out (the screen keeps
/// honestly showing "Submitted"), and `.pending` immediately on cancellation
/// (the user left the screen — stop the network work).
enum TransactionConfirmation {

    /// Terminal-or-pending verdict for a status read.
    enum Outcome: Sendable, Equatable {
        /// The chain reported the tx mined / validated successfully.
        case confirmed
        /// The chain reported the tx reverted / errored on-chain. Funds
        /// didn't move (the surface must say so honestly — Rule #16).
        case failed
        /// Not yet resolvable — still in the mempool, or no receipt indexed.
        case pending
    }

    /// A single status read. A `nil` detail (provider can't see the tx yet)
    /// or a `.pending` status both read as `.pending` — never a failure
    /// (Rule #16).
    static func probe(
        txHash: String,
        chain: SupportedChain,
        address: String? = nil,
        tokenContract: String? = nil,
        counterparty: String? = nil,
        client: RPCClient = .shared
    ) async -> Outcome {
        let detail = await TransactionDetailService.detail(
            chain: chain,
            txHash: txHash,
            tokenContract: tokenContract,
            address: address,
            counterparty: counterparty,
            client: client
        )
        switch detail?.status {
        case .confirmed:      return .confirmed
        case .failed:         return .failed
        case .pending, .none: return .pending
        }
    }

    /// Loop probing `txHash` until it resolves (`.confirmed` / `.failed`) or
    /// the poll budget is exhausted / the surrounding task is cancelled.
    ///
    /// Backs off gently: a short wait before the first probe (a just-broadcast
    /// tx has no receipt yet, so an immediate read only wastes a round-trip),
    /// then a steady interval. The default budget (~4 minutes) comfortably
    /// covers EVM / Solana / fast L1s while the user watches the result
    /// screen; slower chains (a Bitcoin block ~10 min) honestly stay
    /// "Submitted" and reconcile on the next history scan.
    static func awaitResolution(
        txHash: String,
        chain: SupportedChain,
        address: String? = nil,
        tokenContract: String? = nil,
        counterparty: String? = nil,
        firstDelay: Duration = .seconds(4),
        interval: Duration = .seconds(6),
        maxAttempts: Int = 40,
        client: RPCClient = .shared
    ) async -> Outcome {
        let hash = txHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return .pending }

        var attempt = 0
        while attempt < maxAttempts {
            if Task.isCancelled { return .pending }
            try? await Task.sleep(for: attempt == 0 ? firstDelay : interval)
            if Task.isCancelled { return .pending }

            let outcome = await probe(
                txHash: hash,
                chain: chain,
                address: address,
                tokenContract: tokenContract,
                counterparty: counterparty,
                client: client
            )
            if outcome != .pending { return outcome }
            attempt += 1
        }
        return .pending
    }
}
