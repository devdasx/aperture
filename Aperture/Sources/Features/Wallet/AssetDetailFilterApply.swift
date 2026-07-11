import Foundation

/// **Pure-function filter + sort applier** for the asset-detail
/// screen's transaction list and network breakdown. Mirrors
/// `WalletHomeFilterApply` in shape — keeping the filter logic out of
/// the SwiftUI view body for testability, reusability, and one
/// auditable code path.
///
/// **Honesty (Rule #2 §A.7).** `apply(transactions:with:)` returns
/// the filtered set; the view derives the "Showing N of M" preview
/// from the pre- and post-filter counts. The pre-filter count is the
/// total asset-scoped transactions (not the wallet's total) so the
/// preview doesn't conflate "all transactions" with "all transactions
/// for this asset."
///
/// **Pipeline (each step shrinks the set).**
///
///     1. Symbol scope         — drop tx whose tokenSymbol doesn't
///                              match the asset identity. ALWAYS
///                              applied first.
///     2. Network selection    — drop if the tx's chain is not in
///                              selectedNetworks (when non-empty).
///     3. Direction            — drop if direction doesn't match.
///     4. Time range           — drop if occurredAt < cutoff.
///     5. Sort                 — per the chosen comparator.
enum AssetDetailFilterApply {

    /// Symbol-scope filter. Drops every transaction whose token
    /// symbol doesn't match the asset identity. The match is
    /// case-insensitive — Trust Wallet's `USDC` vs a registry's
    /// `usdc` both match an identity of `USDC`.
    ///
    /// This is the entry point for every asset-detail transaction
    /// consumer; the wallet's full transaction history is the input,
    /// the asset-scoped slice is the output.
    static func scope(
        transactions: [TransactionRecord],
        to identity: AssetIdentity
    ) -> [TransactionRecord] {
        let target = identity.symbol.uppercased()
        switch identity.kind {
        case .nativeCoin(let chain):
            // Native coin identity scopes by symbol AND chain — ETH
            // on Ethereum is distinct from ETH on Arbitrum, and
            // sending USDC isn't the same asset as sending ETH on
            // the Ethereum tab.
            let rawChain = chain.rawValue
            return transactions.filter { tx in
                let symbolMatch = tx.tokenSymbol.uppercased() == target
                guard symbolMatch else { return false }
                // Must be a native transaction (contract nil OR
                // symbol matches the chain's ticker — the legacy
                // shape some adapters wrote).
                guard tx.tokenContract == nil
                      || tx.tokenContract?.isEmpty == true
                else { return false }
                // The tx belongs to this chain if its parent
                // address's chainRaw matches.
                guard let addressChain = tx.address?.chainRaw,
                      addressChain == rawChain
                else { return false }
                return true
            }
        case .token:
            // Token identity scopes by symbol only — USDC on every
            // network the user holds aggregates here. Drop natives
            // (any tx whose symbol matches a chain ticker we serve).
            return transactions.filter { tx in
                let symbolMatch = tx.tokenSymbol.uppercased() == target
                guard symbolMatch else { return false }
                // Tokens have a non-empty tokenContract.
                guard let contract = tx.tokenContract, !contract.isEmpty
                else { return false }
                return true
            }
        }
    }

    /// Apply the network + direction + time-range filter + sort
    /// pipeline to a pre-scoped transaction list. The scoping by
    /// asset identity is done by `scope(transactions:to:)` above
    /// because every consumer needs that step first.
    static func apply(
        transactions: [TransactionRecord],
        with inputs: AssetDetailFilterInputs,
        now: Date = Date()
    ) -> [TransactionRecord] {
        var rows = transactions

        // 2. Network selection — drop rows whose parent address's
        //    chain isn't in the selected set (empty sentinel = all).
        if !inputs.selectedNetworks.isEmpty {
            rows = rows.filter { tx in
                guard let chainRaw = tx.address?.chainRaw else { return false }
                return inputs.selectedNetworks.contains(chainRaw)
            }
        }

        // 3. Direction — both / incoming / outgoing.
        switch inputs.direction {
        case .both:
            break
        case .incoming:
            rows = rows.filter { $0.directionRaw == TransactionDirection.incoming.rawValue }
        case .outgoing:
            rows = rows.filter { $0.directionRaw == TransactionDirection.outgoing.rawValue }
        }

        // 4. Time range — keep tx whose occurredAt ≥ cutoff.
        let cutoff = inputs.timeRange.cutoff(from: now)
        if cutoff != .distantPast {
            rows = rows.filter { $0.occurredAt >= cutoff }
        }

        // 5. Sort.
        rows.sort(by: comparator(inputs.sortKey))

        return rows
    }

    private static func comparator(
        _ key: AssetDetailFilterPreferences.SortKey
    ) -> (TransactionRecord, TransactionRecord) -> Bool {
        switch key {
        case .newest:
            return { $0.occurredAt > $1.occurredAt }
        case .largest:
            return { a, b in
                let aAmount = Decimal(string: a.amountRaw) ?? .zero
                let bAmount = Decimal(string: b.amountRaw) ?? .zero
                if aAmount == bAmount {
                    return a.occurredAt > b.occurredAt
                }
                return aAmount > bAmount
            }
        case .network:
            return { a, b in
                let aChain = a.address?.chainRaw ?? ""
                let bChain = b.address?.chainRaw ?? ""
                if aChain == bChain {
                    return a.occurredAt > b.occurredAt
                }
                // Plain ordinal comparison — `chainRaw` is a
                // programmatic identifier, not human text, so the
                // locale-aware comparator buys nothing and costs a
                // collation pass per comparison.
                return aChain < bChain
            }
        }
    }

    // MARK: - Network rows filter

    /// Apply the network-level visibility filter to the
    /// `AssetResolution.networks` array — drops rows whose chain is
    /// not in `inputs.selectedNetworks` (when non-empty) AND drops
    /// rows whose `amount == 0` when `inputs.hideZeroNetworks` is
    /// true. Pinned/heads-up rows aren't a thing here — every
    /// network the asset exists on is equal in priority.
    static func apply(
        networks: [AssetNetworkRow],
        with inputs: AssetDetailFilterInputs
    ) -> [AssetNetworkRow] {
        var rows = networks
        if !inputs.selectedNetworks.isEmpty {
            rows = rows.filter { inputs.selectedNetworks.contains($0.chain.rawValue) }
        }
        if inputs.hideZeroNetworks {
            rows = rows.filter { $0.isHeld }
        }
        return rows
    }
}
