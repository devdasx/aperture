import Foundation

/// P1-001 / BUG-004: pure policy for balance-scanner RPC failures.
///
/// Contrast TON/TRON: token probe failure → keep last-good rows (do not invent zeros).
/// Native probe failure → skip balance/UTXO writes and mark the chain failed.
///
/// Scanners must never upsert invented `"0"` balances or empty UTXO sets after a
/// transport failure; that overwrites good portfolio data and can empty compose caches.
enum BalanceProbeKeepLastGood {
    /// Upsert balance rows only when the probe succeeded with real data.
    static func shouldUpsertBalance(probeSucceeded: Bool) -> Bool {
        probeSucceeded
    }

    /// Replace the UTXO cache only when every address UTXO fetch succeeded.
    /// A failed fetch must not wipe last-good UTXOs with `[]`.
    static func shouldReplaceUTXOs(probeSucceeded: Bool) -> Bool {
        probeSucceeded
    }

    /// Mark the chain failed when any required probe failed so UI does not
    /// present a false "synced at $0" state.
    static func failedChains(
        chain: SupportedChain,
        nativeProbeSucceeded: Bool,
        tokenProbeSucceeded: Bool = true
    ) -> Set<SupportedChain> {
        if nativeProbeSucceeded && tokenProbeSucceeded {
            return []
        }
        return [chain]
    }

    /// Keep only successful per-token/per-mint probe results. Failed probes
    /// are omitted so callers never invent `rawBalance: "0"`.
    static func compactSuccessfulProbes<T>(_ results: [T?]) -> (rows: [T], anyFailed: Bool) {
        var rows: [T] = []
        var anyFailed = false
        rows.reserveCapacity(results.count)
        for result in results {
            if let result {
                rows.append(result)
            } else {
                anyFailed = true
            }
        }
        return (rows, anyFailed)
    }
}
