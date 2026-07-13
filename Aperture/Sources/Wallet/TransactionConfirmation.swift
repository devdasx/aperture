import Foundation

/// Polls a chain for the live confirmation status of a just-broadcast
/// transaction, so a "Confirming" surface flips to "Sent"/"Failed" the
/// moment the chain reports the receipt (Rule #25 — live, not a one-shot
/// snapshot the user has to refresh by hand).
///
/// Most chains reuse `TransactionDetailService.detail` (EVM receipts,
/// Bitcoin confirmations, XRPL / Stellar / TON / …). **Solana** is special:
/// `getTransaction` often lags behind the signature landing on the leader
/// (indexing lag), so probes use `getSignatureStatuses` first (P1 #12).
///
/// Honest by construction (Rule #16): a tx the provider hasn't seen yet
/// reads as `.pending` — never a fabricated success.
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
        let hash = txHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return .pending }

        // Solana: signature status is available before getTransaction indexes.
        if chain == .solana {
            return await probeSolana(signature: hash, client: client)
        }

        let detail = await TransactionDetailService.detail(
            chain: chain,
            txHash: hash,
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

    /// Solana confirmation (P1 #12).
    ///
    /// 1. `getSignatureStatuses` + `searchTransactionHistory` — works during
    ///    the window where `getTransaction` still returns null.
    /// 2. Fall back to `getTransaction` (detail service) for full err/meta.
    ///
    /// `confirmationStatus`:
    /// - `processed` → still pending for the UI (can be rolled back)
    /// - `confirmed` / `finalized` + no err → confirmed
    /// - any non-null `err` → failed
    private static func probeSolana(
        signature: String,
        client: RPCClient
    ) async -> Outcome {
        if let fromStatuses = await solanaSignatureStatus(signature: signature, client: client) {
            return fromStatuses
        }
        // Indexed full tx (or still null → pending).
        let detail = await TransactionDetailService.detail(
            chain: .solana,
            txHash: signature,
            client: client
        )
        switch detail?.status {
        case .confirmed:      return .confirmed
        case .failed:         return .failed
        case .pending, .none: return .pending
        }
    }

    /// `getSignatureStatuses` probe. `nil` when the RPC has no row yet.
    private static func solanaSignatureStatus(
        signature: String,
        client: RPCClient
    ) async -> Outcome? {
        let config: [String: Sendable] = ["searchTransactionHistory": true]
        guard let data = try? await client.callJSONResultData(
            chain: .solana,
            method: "getSignatureStatuses",
            params: [[signature], config]
        ),
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }

        // Shape: { "value": [ { err, confirmationStatus, ... } | null ] }
        let value = root["value"] as? [Any] ?? []
        guard let first = value.first else { return nil }
        if first is NSNull { return nil }
        guard let status = first as? [String: Any] else { return nil }

        let err = status["err"]
        let hasErr = err != nil && !(err is NSNull)
        if hasErr { return .failed }

        let confirmation = (status["confirmationStatus"] as? String)?.lowercased()
        switch confirmation {
        case "confirmed", "finalized":
            return .confirmed
        case "processed":
            // Optimistic only — keep Confirming until confirmed/finalized.
            return .pending
        default:
            // Older nodes may omit confirmationStatus but set confirmations.
            if let conf = status["confirmations"] as? NSNumber, conf.intValue >= 0, !hasErr {
                // null confirmations often means finalized on modern RPCs.
                return .pending
            }
            if status["confirmations"] is NSNull, !hasErr {
                // Finalized: confirmations is null per Solana RPC docs.
                return .confirmed
            }
            return .pending
        }
    }

    /// Loop probing `txHash` until it resolves (`.confirmed` / `.failed`) or
    /// the poll budget is exhausted / the surrounding task is cancelled.
    ///
    /// Solana uses a shorter first delay + interval (signatures land fast;
    /// getSignatureStatuses survives indexing lag). Other chains keep a
    /// gentler cadence. Slower L1s (Bitcoin ~10 min) honestly stay
    /// "Confirming" past the budget and reconcile on the next history scan.
    static func awaitResolution(
        txHash: String,
        chain: SupportedChain,
        address: String? = nil,
        tokenContract: String? = nil,
        counterparty: String? = nil,
        firstDelay: Duration? = nil,
        interval: Duration? = nil,
        maxAttempts: Int? = nil,
        client: RPCClient = .shared
    ) async -> Outcome {
        let hash = txHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return .pending }

        let resolvedFirst: Duration
        let resolvedInterval: Duration
        let resolvedMax: Int
        if chain == .solana {
            resolvedFirst = firstDelay ?? .milliseconds(800)
            resolvedInterval = interval ?? .seconds(1.5)
            resolvedMax = maxAttempts ?? 80 // ~2 min with short interval
        } else {
            resolvedFirst = firstDelay ?? .seconds(4)
            resolvedInterval = interval ?? .seconds(6)
            resolvedMax = maxAttempts ?? 40
        }

        var attempt = 0
        while attempt < resolvedMax {
            if Task.isCancelled { return .pending }
            try? await Task.sleep(for: attempt == 0 ? resolvedFirst : resolvedInterval)
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
