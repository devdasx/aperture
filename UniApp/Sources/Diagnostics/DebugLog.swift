import Foundation

/// **Session-wide rolling debug log** (user direction 2026-06-18: "add logs
/// for all actions running in the background … I should be able to copy them
/// from Settings and send them, so we can understand what's happening").
///
/// Unlike `RefreshPerfLog` — which keeps only the MOST RECENT refresh run and
/// resets its buffer on every `beginRun` — this accumulates EVERY logged
/// action across the whole session into one ring buffer with absolute
/// wall-clock timestamps. So the timeline that led up to a hitch is still
/// there when the user opens Settings → Advanced → Debug logs to copy it.
///
/// What flows in:
/// - the full refresh pipeline (forwarded automatically from `RefreshPerfLog`
///   — every chain scan, RPC round-trip, price batch, DB commit, with ms),
/// - the 30 s background auto-refresh loop (`loop` — tick / gate-closed),
/// - main-thread `body` re-renders with their cause (`ui` — the work that
///   competes with scrolling), and
/// - main-thread stalls detected by `MainThreadWatchdog` (`hang` — the direct
///   "the UI froze for N ms" signal).
///
/// Thread-safe via a single `NSLock`; `log(...)` is synchronous and
/// `await`-free so it's cheap to call from any task, any thread — including
/// the main thread inside a SwiftUI `body`. Every line records whether it ran
/// on the main thread, so the copied log shows at a glance what is competing
/// with the UI.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    struct Line: Sendable {
        let at: Date
        let onMain: Bool
        let category: String
        let message: String
        let durationMs: Double?
    }

    private let lock = NSLock()
    private var lines: [Line] = []
    /// Ring-buffer cap — a few minutes of heavy activity. Newest kept.
    private let maxLines = 6000
    private let sessionStart = Date()

    // Per-view render accounting for the throttled `renderTick`.
    private struct RenderStat { var total = 0; var emitted = 0; var lastEmitNanos: UInt64 = 0 }
    private var renderStats: [String: RenderStat] = [:]

    private init() {}

    // MARK: - Logging

    /// Append one line. Cheap, lock-guarded, await-free; safe from any thread.
    func log(_ category: String, _ message: String, durationMs: Double? = nil) {
        let line = Line(
            at: Date(),
            onMain: Thread.isMainThread,
            category: category,
            message: message,
            durationMs: durationMs
        )
        lock.lock()
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    /// Time a synchronous main-thread block and log it only when it's slow
    /// enough to matter (> 2 ms) — so the log surfaces the expensive
    /// main-thread rebuilds that compete with scrolling, without noise.
    @discardableResult
    func measureMain<T>(_ message: String, _ body: () -> T) -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
        if ms > 2 { log("ui", message, durationMs: ms) }
        return result
    }

    /// Count a SwiftUI `body` re-evaluation for `view`, emitting a throttled
    /// summary (at most one line per ~300 ms window) so a render storm shows
    /// as "×N in window" instead of flooding the log at 60 fps. `detail` is
    /// an `@autoclosure` so the cause string (the live `@Query` counts) is
    /// only built when a line is actually emitted.
    func renderTick(_ view: String, detail: @autoclosure () -> String) {
        let now = DispatchTime.now().uptimeNanoseconds
        var emitLine: String?
        lock.lock()
        var st = renderStats[view] ?? RenderStat()
        st.total &+= 1
        let elapsed = st.lastEmitNanos == 0 ? UInt64.max : (now &- st.lastEmitNanos)
        if elapsed > 300_000_000 {
            let delta = st.total - st.emitted
            if delta > 0 {
                emitLine = "\(view) body re-rendered ×\(delta) · \(detail()) · total \(st.total)"
            }
            st.emitted = st.total
            st.lastEmitNanos = now
        }
        renderStats[view] = st
        lock.unlock()
        if let emitLine { log("ui", emitLine) }
    }

    // MARK: - Render / clear

    func clear() {
        lock.lock()
        lines.removeAll(keepingCapacity: false)
        renderStats.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// The whole session rendered as plain text for copy/paste — a timeline
    /// with absolute timestamps + thread tags, a main-thread-stall summary, a
    /// "slowest actions" summary, and per-category counts. Called on the main
    /// thread from `DiagnosticsLogView`.
    func snapshotText() -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()

        guard !snapshot.isEmpty else {
            return """
            No activity logged yet.

            Use the app for a bit — open the wallet, scroll, let it auto-refresh \
            (or pull to refresh) — then come back here and tap Refresh. Copy the \
            log and send it over so we can see exactly what's happening.
            """
        }

        var out: [String] = []
        out.append("=== Aperture Debug Log ===")
        out.append("Device: \(Self.deviceLine)")
        out.append("App: \(Self.appVersionLine)")
        out.append("Session start: \(Self.stampFull.string(from: sessionStart))")
        out.append("Copied: \(Self.stampFull.string(from: Date()))  ·  \(snapshot.count) events")
        out.append("Format: [time] (thread) category · message (duration)")
        out.append("")

        for l in snapshot {
            let t = Self.stampTime.string(from: l.at)
            let thread = l.onMain ? "main" : "bg  "
            let dur = l.durationMs.map { String(format: "  (%.0f ms)", $0) } ?? ""
            out.append("[\(t)] (\(thread)) \(l.category) · \(l.message)\(dur)")
        }

        // Main-thread stalls — the direct "UI froze" signal.
        let hangs = snapshot.filter { $0.category == "hang" }
        if !hangs.isEmpty {
            out.append("")
            out.append("--- Main-thread stalls: \(hangs.count) ---")
            for h in hangs.suffix(25) {
                out.append("[\(Self.stampTime.string(from: h.at))] \(h.message)")
            }
        }

        // Slowest measured spans (background or main).
        let slowest = snapshot
            .compactMap { l in l.durationMs.map { ($0, "\(l.onMain ? "main" : "bg") · \(l.category) · \(l.message)") } }
            .sorted { $0.0 > $1.0 }
            .prefix(15)
        if !slowest.isEmpty {
            out.append("")
            out.append("--- Slowest 15 actions ---")
            for (ms, label) in slowest {
                out.append(String(format: "%8.0f ms  %@", ms, label))
            }
        }

        // Per-category counts — a quick shape of where the work is.
        var counts: [String: Int] = [:]
        for l in snapshot { counts[l.category, default: 0] += 1 }
        out.append("")
        out.append("--- Event counts by category ---")
        for (cat, n) in counts.sorted(by: { $0.value > $1.value }) {
            out.append(String(format: "%6d  %@", n, cat))
        }

        return out.joined(separator: "\n")
    }

    // MARK: - Header helpers (computed on the main thread in snapshotText)

    private static var deviceLine: String {
        // `ProcessInfo` (not `UIDevice`) so this stays nonisolated — `UIDevice`
        // is @MainActor under Swift 6 and `snapshotText()` runs off any actor.
        // `operatingSystemVersionString` → e.g. "Version 18.5 (Build 22F76)".
        "iOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(deviceModelIdentifier)"
    }

    private static var deviceModelIdentifier: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(value))))
        }
        return id.isEmpty ? "unknown" : id
    }

    private static var appVersionLine: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static let stampTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let stampFull: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
