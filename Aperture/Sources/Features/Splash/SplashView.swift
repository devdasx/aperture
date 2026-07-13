import SwiftUI

/// Aperture's launch splash — logo only, then hands off to main or passcode.
///
/// The mark fades in (opacity bloom). Product name is not shown. When
/// the short settle finishes, `onSplashComplete` flips `AppRoot` off
/// splash so `RootGate` or the lock overlay can open with the system-
/// style scale + opacity transition.
struct SplashView: View {
    /// Kept for API compatibility with `AppRoot` / onboarding; matched
    /// geometry handoff is no longer used on this surface.
    let logoNamespace: Namespace.ID

    /// App-wide phase from `AppRoot`. While `.splash`, this view is
    /// fully opaque; otherwise it fades out as content takes over.
    let phase: AppPhase

    /// Fired once the logo bloom settles. `AppRoot` unmounts splash
    /// and reveals main content or the passcode overlay.
    let onSplashComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startDate: Date = .init()
    @State private var hasFiredComplete: Bool = false
    /// Single-shot completion timer. Cancelled on disappear so a
    /// torn-down splash never fires into a stale closure.
    @State private var completionTask: Task<Void, Never>?
    /// Flips true once the logo keyframe has settled so the timeline
    /// can pause instead of ticking forever.
    @State private var isChromeSettled: Bool = false

    /// Total wall time before handoff — logo fade plus a short hold.
    private static let splashDuration: TimeInterval = 0.90

    private static let chromeSettleDuration: TimeInterval = 0.65
    private static let reducedMotionSettleDuration: TimeInterval = 0.28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isChromeSettled)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let settleDuration = reduceMotion
                ? Self.reducedMotionSettleDuration
                : Self.chromeSettleDuration
            let chrome = SplashChromeState(elapsed: elapsed, reduceMotion: reduceMotion)
            ZStack {
                background
                logo
                    .frame(width: 80, height: 80)
                    .scaleEffect(chrome.logoScale)
                    .opacity(chrome.logoOpacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
            .onChange(of: elapsed >= settleDuration) { _, settled in
                if settled { isChromeSettled = true }
            }
        }
        .accessibilityLabel(Text(verbatim: "Aperture"))
        .onAppear {
            startDate = Date()
            isChromeSettled = false
            guard completionTask == nil else { return }
            let duration = reduceMotion ? Self.reducedMotionSettleDuration : Self.splashDuration
            completionTask = Task {
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled, !hasFiredComplete else { return }
                hasFiredComplete = true
                onSplashComplete()
            }
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
        }
        .opacity(phase == .splash ? 1 : 0)
        .animation(.easeOut(duration: 0.28), value: phase)
    }

    // MARK: - Background

    private var background: some View {
        UniColors.Background.primary
            .ignoresSafeArea()
    }

    // MARK: - Logo

    private var logo: some View {
        ApertureIrisView(ringColor: UniColors.Brand.mark)
    }
}

// MARK: - Splash chrome state

/// Per-frame logo fade (and a subtle scale) for splash entrance.
private struct SplashChromeState {
    let logoOpacity: Double
    let logoScale: Double

    init(elapsed: TimeInterval, reduceMotion: Bool) {
        if reduceMotion {
            let p = max(0, min(1, elapsed / 0.28))
            self.logoOpacity = p
            self.logoScale = 1
            return
        }

        // Fade + slight scale — logo only, no wordmark.
        let logoT = clampUnit(elapsed / 0.65)
        let logoE = SplashEase.cubicBezier(logoT, 0.25, 0.1, 0.25, 1.0)
        self.logoScale = 0.92 + 0.08 * logoE
        self.logoOpacity = SplashEase.cubicBezier(logoT, 0.25, 0.1, 0.25, 1.0)
    }
}

@inline(__always)
private func clampUnit(_ x: Double) -> Double {
    max(0, min(1, x))
}

// MARK: - Cubic-Bezier solver

private enum SplashEase {
    static func cubicBezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var u = t
        for _ in 0..<10 {
            let oneMinusU = 1 - u
            let x = 3 * oneMinusU * oneMinusU * u * x1
                  + 3 * oneMinusU * u * u * x2
                  + u * u * u
            let dx = 3 * oneMinusU * oneMinusU * x1
                   + 6 * oneMinusU * u * (x2 - x1)
                   + 3 * u * u * (1 - x2)
            if abs(dx) < 1e-6 { break }
            let delta = (x - t) / dx
            u -= delta
            if u < 0 { u = 0 }
            if u > 1 { u = 1 }
            if abs(delta) < 1e-6 { break }
        }
        let oneMinusU = 1 - u
        return 3 * oneMinusU * oneMinusU * u * y1
             + 3 * oneMinusU * u * u * y2
             + u * u * u
    }
}
