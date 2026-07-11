import Foundation

/// **Pure-function filter + sort applier** for the wallet-wide Activity
/// screen. Mirrors `AssetDetailFilterApply` and `WalletHomeFilterApply`
/// in shape — the entire filter pipeline lives here, out of the SwiftUI
/// body, so it is testable in isolation and there is exactly one
/// auditable code path for "what the user sees."
///
/// **Fiat dependency.** Amount-range filtering and largest/smallest
/// sorting need each row's value in the user's display currency. That
/// can't be derived from a `TransactionRecord` alone (it needs a price
/// map), so the caller injects a `fiatValue` resolver. Keeping it a
/// closure keeps this function pure: a test passes a deterministic stub
/// instead of standing up the pricing engine.
///
/// **Pipeline (each step shrinks the set; cheapest predicates first).**
///
///     1. Network selection — drop if chain ∉ selectedNetworks (when set)
///     2. Symbol selection  — drop if symbol ∉ selectedSymbols (when set)
///     3. Asset class       — native coins vs tokens
///     4. Direction         — drop if direction doesn't match
///     5. Status            — drop if status doesn't match
///     6. Kind              — transfer / self-transfer / bridge
///     7. Time range        — preset cutoff OR explicit custom window
///     8. Search            — drop if no field contains the query
///     9. Amount range      — drop if fiat value is outside [min, max]
///    10. Sort              — per the chosen comparator (fiat for value sorts)
enum WalletActivityFilterApply {

    /// Apply the full filter + sort pipeline.
    ///
    /// - Parameters:
    ///   - transactions: the wallet-scoped feed (already dust-gated by
    ///     the caller — dust removal is a separate, always-on rule).
    ///   - inputs: the decoded preference snapshot.
    ///   - fiatValue: resolves a row's value in the display currency, or
    ///     `nil` when no price is known. Used for amount-range filtering
    ///     and value sorts.
    ///   - now: injected clock for deterministic preset-range tests.
    static func apply(
        transactions: [TransactionRecord],
        with inputs: WalletActivityFilterInputs,
        fiatValue: (TransactionRecord) -> Decimal?,
        now: Date = Date()
    ) -> [TransactionRecord] {
        var rows = transactions

        // 1. Network selection (empty sentinel = all).
        if !inputs.selectedNetworks.isEmpty {
            rows = rows.filter { tx in
                guard let chainRaw = tx.address?.chainRaw else { return false }
                return inputs.selectedNetworks.contains(chainRaw)
            }
        }

        // 2. Symbol selection (empty sentinel = all). Compared
        //    uppercased — the stored symbol casing varies by adapter.
        if !inputs.selectedSymbols.isEmpty {
            rows = rows.filter { inputs.selectedSymbols.contains($0.tokenSymbol.uppercased()) }
        }

        // 3. Asset class. `nil` / empty contract is the native coin row.
        switch inputs.assetClass {
        case .all:
            break
        case .coins:
            rows = rows.filter { ($0.tokenContract ?? "").isEmpty }
        case .tokens:
            rows = rows.filter { !($0.tokenContract ?? "").isEmpty }
        }

        // 4. Direction.
        switch inputs.direction {
        case .all:
            break
        case .incoming:
            rows = rows.filter { $0.directionRaw == TransactionDirection.incoming.rawValue }
        case .outgoing:
            rows = rows.filter { $0.directionRaw == TransactionDirection.outgoing.rawValue }
        case .internal:
            rows = rows.filter { $0.directionRaw == TransactionDirection.internal.rawValue }
        }

        // 5. Status.
        switch inputs.status {
        case .all:
            break
        case .confirmed, .pending, .failed:
            rows = rows.filter { $0.statusRaw == inputs.status.rawValue }
        }

        // 6. Kind.
        switch inputs.kind {
        case .all:
            break
        case .transfer, .selfTransfer, .bridge:
            rows = rows.filter { $0.kind.rawValue == inputs.kind.rawValue }
        }

        // 7. Time range — preset cutoff OR explicit custom window.
        if inputs.timeRange == .custom {
            if let start = inputs.customStart {
                rows = rows.filter { $0.occurredAt >= start }
            }
            if let end = inputs.customEnd {
                // End is inclusive of the whole chosen day — the sheet
                // hands us the END of the day, so a plain ≤ is correct.
                rows = rows.filter { $0.occurredAt <= end }
            }
        } else {
            let cutoff = inputs.timeRange.cutoff(from: now)
            if cutoff != .distantPast {
                rows = rows.filter { $0.occurredAt >= cutoff }
            }
        }

        // 8. Search — case-insensitive substring over counterparty,
        //    symbol, and tx hash. `searchText` arrives lowercased.
        let query = inputs.searchText
        if !query.isEmpty {
            rows = rows.filter { tx in
                tx.counterparty.lowercased().contains(query)
                    || tx.tokenSymbol.lowercased().contains(query)
                    || tx.txHash.lowercased().contains(query)
            }
        }

        // Resolve fiat ONCE per surviving row — needed by the amount
        // filter and/or a value sort. Computing it here (not inside the
        // sort comparator) avoids O(n log n) re-resolves and sidesteps
        // escaping the non-escaping `fiatValue` parameter.
        let needsFiat = inputs.hasAmountBound
            || inputs.sortKey == .largest
            || inputs.sortKey == .smallest
        var fiatById: [UUID: Decimal] = [:]
        if needsFiat {
            for tx in rows {
                if let value = fiatValue(tx) { fiatById[tx.id] = value }
            }
        }

        // 9. Amount range (fiat, display currency). When a bound is
        //    active, a row whose fiat we can't compute is dropped — it
        //    can't be proven to satisfy "≥ $X" (honesty over a guess).
        if inputs.hasAmountBound {
            rows = rows.filter { tx in
                guard let value = fiatById[tx.id] else { return false }
                if let min = inputs.minFiat, value < min { return false }
                if let max = inputs.maxFiat, value > max { return false }
                return true
            }
        }

        // 10. Sort.
        rows.sort(by: comparator(inputs.sortKey, fiatById: fiatById))
        return rows
    }

    private static func comparator(
        _ key: WalletActivityFilterPreferences.SortKey,
        fiatById: [UUID: Decimal]
    ) -> (TransactionRecord, TransactionRecord) -> Bool {
        switch key {
        case .newest:
            return { $0.occurredAt > $1.occurredAt }
        case .oldest:
            return { $0.occurredAt < $1.occurredAt }
        case .largest:
            return { a, b in
                let av = fiatById[a.id] ?? .zero
                let bv = fiatById[b.id] ?? .zero
                if av == bv { return a.occurredAt > b.occurredAt }
                return av > bv
            }
        case .smallest:
            return { a, b in
                let av = fiatById[a.id] ?? .zero
                let bv = fiatById[b.id] ?? .zero
                if av == bv { return a.occurredAt > b.occurredAt }
                return av < bv
            }
        }
    }
}
