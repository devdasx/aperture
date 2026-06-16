import Foundation

/// **Copy-pasteable performance log for diagnosing refresh latency**
/// (user direction 2026-06-17: "log all actions that happen on the main
/// screen when I pull-to-refresh, with how long each takes, so we can fix
/// any latency").
///
/// A process-wide singleton recording a timeline of timestamped events,
/// each with an optional span duration (ms). The refresh pipeline is
/// heavily concurrent (per-chain balance + history fan-out, per-RPC
/// network calls, per-chain DB commits), so this is a plain lock-guarded
/// class — `event(...)` is **synchronous and `await`-free**, cheap enough
/// to call from every task and every RPC without perturbing the timings
/// it measures. Monotonic `DispatchTime` is used so wall-clock changes
/// never corrupt a duration.
///
/// `beginRun` resets the buffer and stamps the start; every later event
/// records its elapsed-since-start, so the rendered log reads as a
/// timeline. Settings → Advanced → Refresh diagnostics renders + copies
/// `snapshotText()`.
final class RefreshPerfLog: @unchecked Sendable {
    static let shared = RefreshPerfLog()

    struct Entry: Sendable {
        let elapsedMs: Double      // since the current run began
        let category: String       // "refresh" / "balance" / "history" / "rpc" / "db" / "price" / "utxo" / "key"
        let message: String
        let durationMs: Double?     // present for completed spans
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var runStartNanos: UInt64?
    private var runLabel = ""
    private var runStartedAtText = ""
    /// Ring-buffer cap — a pathological wallet (many tokens × many RPC
    /// retries) could log thousands of lines; keep the newest.
    private let maxEntries = 8000

    private init() {}

    private func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    // MARK: - Run lifecycle

    /// Start a fresh run: clear the buffer, stamp the start, and record a
    /// `begin` marker. Called at the top of a refresh pipeline with the
    /// trigger label ("pull-to-refresh", "background refresh", …).
    func beginRun(_ label: String) {
        let start = nowNanos()
        let stamp = Self.timeFormatter.string(from: Date())
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        runStartNanos = start
        runLabel = label
        runStartedAtText = stamp
        appendLocked(category: "refresh", message: "begin · \(label)", durationMs: nil, atNanos: start)
    }

    /// Record the run total and a closing marker.
    func endRun() {
        let at = nowNanos()
        lock.lock(); defer { lock.unlock() }
        let base = runStartNanos ?? at
        let totalMs = Double(at &- base) / 1_000_000
        appendLocked(category: "refresh", message: "end · total", durationMs: totalMs, atNanos: at)
    }

    // MARK: - Events + spans

    /// Log a discrete event, optionally carrying a measured span duration.
    func event(_ category: String, _ message: String, durationMs: Double? = nil) {
        let at = nowNanos()
        lock.lock(); defer { lock.unlock() }
        appendLocked(category: category, message: message, durationMs: durationMs, atNanos: at)
    }

    /// Open a manual span — returns a monotonic token to pass to `end`.
    func start() -> UInt64 { nowNanos() }

    /// Close a manual span opened with `start()`, logging its duration.
    func end(_ category: String, _ message: String, since token: UInt64) {
        let at = nowNanos()
        let ms = Double(at &- token) / 1_000_000
        lock.lock(); defer { lock.unlock() }
        appendLocked(category: category, message: message, durationMs: ms, atNanos: at)
    }

    /// Measure an async block and log its duration.
    @discardableResult
    func measure<T>(_ category: String, _ message: String, _ body: () async -> T) async -> T {
        let token = start()
        let result = await body()
        end(category, message, since: token)
        return result
    }

    // MARK: - Render / clear

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        runStartNanos = nil
        runLabel = ""
        runStartedAtText = ""
    }

    /// The whole run rendered as plain text for copy/paste, including a
    /// "slowest actions" summary to surface latency at a glance.
    func snapshotText() -> String {
        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else {
            return "No refresh has been logged yet.\n\nPull to refresh on the wallet screen, then return here and tap Refresh."
        }
        var lines: [String] = []
        lines.append("=== Aperture Refresh Diagnostics ===")
        lines.append("Run: \(runLabel)  ·  started \(runStartedAtText)")
        lines.append("Events: \(entries.count)")
        lines.append("")
        for e in entries {
            let elapsed = String(format: "%9.1f", e.elapsedMs)
            let dur = e.durationMs.map { String(format: "  (%.1f ms)", $0) } ?? ""
            lines.append("[\(elapsed) ms]  \(e.category)  ·  \(e.message)\(dur)")
        }
        let slowest = entries
            .compactMap { e in e.durationMs.map { ($0, "\(e.category) · \(e.message)") } }
            .sorted { $0.0 > $1.0 }
            .prefix(15)
        if !slowest.isEmpty {
            lines.append("")
            lines.append("--- Slowest 15 actions ---")
            for (ms, label) in slowest {
                lines.append(String(format: "%9.1f ms  %@", ms, label))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internal

    /// Append under the lock, computing elapsed-since-run-start.
    private func appendLocked(category: String, message: String, durationMs: Double?, atNanos: UInt64) {
        let base = runStartNanos ?? atNanos
        let elapsed = Double(atNanos &- base) / 1_000_000
        entries.append(Entry(elapsedMs: elapsed, category: category, message: message, durationMs: durationMs))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
