import Foundation

/// **Main-thread responsiveness watchdog** (user direction 2026-06-18 — find
/// out *why* the app is laggy).
///
/// A background timer pings the main thread on a fixed cadence and measures
/// how long that ping waits before the main run-loop actually runs it. The
/// wait time IS the main thread's busy-ness: if the ping waits far longer than
/// the cadence, the main thread was blocked that whole time — a long `body`
/// re-evaluation, a synchronous DB read on main, an image decode on main, a
/// heavy layout pass — i.e. exactly the dropped-frames hitch the user feels.
///
/// Every stall past `thresholdMs` is written to `DebugLog` (category `hang`),
/// so the copied log shows precisely WHEN the UI froze and for HOW LONG,
/// lined up against whatever background work (`refresh`, `db`, `ui`) was
/// happening at that timestamp. That correlation is what turns "it feels
/// laggy" into "at 15:14:32 the price batch committed → the home re-rendered
/// ×8 → the main thread stalled 180 ms".
///
/// The watchdog itself is nearly free: one `DispatchQueue.main.async` every
/// `cadence`, and it logs nothing unless a real stall is observed.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "com.thuglife.aperture.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var started = false

    /// Ping cadence — frequent enough to catch hitches, infrequent enough to
    /// be invisible load.
    private let cadence: DispatchTimeInterval = .milliseconds(500)

    /// Only stalls beyond this are logged. A frame is 16.7 ms; > 120 ms is a
    /// clearly-visible multi-frame hitch worth reporting (smaller jitter is
    /// normal and would only add noise).
    private let thresholdMs: Double = 120

    private init() {}

    /// Start the watchdog once. Safe to call again (no-op after the first).
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + cadence, repeating: cadence)
            let threshold = thresholdMs
            t.setEventHandler {
                let sentNanos = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    let waitedMs = Double(DispatchTime.now().uptimeNanoseconds &- sentNanos) / 1_000_000
                    if waitedMs > threshold {
                        DebugLog.shared.log(
                            "hang",
                            String(format: "main thread blocked ~%.0f ms (UI couldn't draw)", waitedMs)
                        )
                    }
                }
            }
            t.resume()
            timer = t
        }
    }
}
