import Foundation

/// Run `operation` and return its result, or `nil` if it doesn't finish
/// within `seconds` (2026-06-17 — refresh-latency fix).
///
/// A pull-to-refresh fans out across every chain in parallel; a single
/// chain whose endpoints rotate through timeouts (NEAR / Tron / a degraded
/// provider) used to take tens of seconds and hold the WHOLE refresh — and
/// the spinner — hostage, because the balance stream only finishes once
/// every chain's task does. Wrapping each chain's fetch in this bound means
/// a slow chain is abandoned at the deadline (its last-known DB value is
/// kept) instead of stalling everything.
///
/// On timeout the operation task is cancelled; because every RPC read
/// honors cancellation (URLSession cancels, the scanners check
/// `Task.isCancelled`), it unwinds promptly rather than leaking.
func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
