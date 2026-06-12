import SwiftUI

/// Aperture's launch splash — the brand's first breath.
///
/// **2026-06-07 (take 6) — shared-element handoff.** Composition
/// rebuilt against `/Users/thuglifex/Downloads/design_handoff_splash_to_onboarding/`.
/// The logo is no longer the hand-driven 6-blade iris from the
/// prior `design_handoff_splash_screen/` redesign; it is now the
/// new **circle logo** — a dark vertical gradient disc containing
/// the white iris — shared with the onboarding welcome slide via
/// SwiftUI's `matchedGeometryEffect`. The logo blooms in on splash
/// entrance via a native scale + opacity keyframe driven by the
/// same `TimelineView` elapsed-time state as the rest of the
/// chrome, and on splash → onboarding the same logo view flies to
/// its onboarding position over 0.82s
/// (`cubic-bezier(0.52, 0, 0.12, 1)`), with a single medium-impact
/// haptic firing at landing.
///
/// **What's preserved from the prior splash design:**
/// - The glow halo behind the logo.
/// - The "Aperture" wordmark with its wipe-up reveal.
/// - The "Your keys. Your crypto." tagline fade.
/// - The determinate loader bar at the bottom.
/// - The radial-gradient monochrome background.
///
/// **What changed:**
/// - The mark itself: from `Brand/Mark.imageset` (bare iris) to
///   `Brand/LogoCircle.imageset` (dark-circle + iris).
/// - The mark bloom: a single restrained scale + opacity bloom
///   computed in `SplashChromeState` from the elapsed time — the
///   same cubic-bezier family the glow uses, one shot, no loops.
/// - The logo view carries `.matchedGeometryEffect` so the
///   onboarding welcome slide can claim it on transition.
///
/// **Why the bloom is hand-driven again (2026-06-10).** The take-6
/// composition played the bloom from a Lottie JSON via the
/// third-party Lottie SPM package — a Rule #3 (native-only)
/// violation in the UI layer. The bloom is now computed natively
/// from the existing `TimelineView` clock; its final frame is the
/// still `Image("LogoCircle")` itself, so the splash → onboarding
/// shared-element transition stays pixel-aligned (both screens
/// render the same `Image`).
struct SplashView: View {
    /// Logo namespace shared with the onboarding welcome slide via
    /// `AppRoot`. Both views attach `matchedGeometryEffect` to
    /// their logo container with `id: "logo"` so the system can
    /// resolve the shared-element animation.
    let logoNamespace: Namespace.ID

    /// App-wide phase from `AppRoot`. When `.splash`, this view
    /// owns the logo (isSource: true on the matchedGeometryEffect).
    /// When `.transitioning`, onboarding becomes the source and
    /// this view's logo follows along. When `.onboarding`,
    /// `AppRoot` unmounts this view entirely.
    let phase: AppPhase

    /// Fired when the splash's `splashDuration` timer elapses —
    /// i.e. the splash has held long enough that the user has
    /// read the brand mark and any initialization the splash was
    /// masking has completed. `AppRoot` consumes this to start
    /// the matchedGeometryEffect transition.
    let onSplashComplete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startDate: Date = .init()
    @State private var hasFiredComplete: Bool = false
    /// Single-shot completion timer. Stored so `.onDisappear` can
    /// cancel it — the prior `DispatchQueue.main.asyncAfter` shape
    /// could double-fire across view re-mounts because the queued
    /// closure outlived the view instance that scheduled it.
    @State private var completionTask: Task<Void, Never>?
    /// Flips true once every chrome keyframe has reached its final
    /// value. Drives the `TimelineView`'s `paused:` so the 60fps
    /// clock stops instead of ticking forever on a settled screen.
    @State private var isChromeSettled: Bool = false

    /// Total wall time the splash holds before calling
    /// `onSplashComplete`. Matches the prior splash spec's
    /// "~2.35s entrance + brief hold" — a small buffer so the
    /// logo bloom completes and the user reads the brand
    /// mark before the transition starts.
    private static let splashDuration: TimeInterval = 2.6

    /// The instant the last chrome keyframe lands. The loader is the
    /// final mover (delay 0.35s + duration 2.00s); past this point
    /// every `SplashChromeState` value is constant, so the timeline
    /// can pause.
    private static let chromeSettleDuration: TimeInterval = 2.35
    /// Reduce-motion collapses every keyframe to a single 0.30s ramp.
    private static let reducedMotionSettleDuration: TimeInterval = 0.30

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isChromeSettled)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let settleDuration = reduceMotion
                ? Self.reducedMotionSettleDuration
                : Self.chromeSettleDuration
            let chrome = SplashChromeState(elapsed: elapsed, reduceMotion: reduceMotion)
            ZStack {
                background
                GeometryReader { proxy in
                    let centerX = proxy.size.width / 2
                    let centerY = proxy.size.height / 2

                    glow(chrome: chrome)
                        .position(x: centerX, y: centerY - 26)

                    // The logo container — native scale + opacity
                    // bloom on splash entrance, then carried into
                    // onboarding via matchedGeometryEffect. Per the
                    // handoff: 80pt diameter at splash, center Y
                    // ~45% of screen. matchedGeometryEffect handles
                    // the size + position interpolation to the
                    // onboarding frame automatically — no manual
                    // frame math. `.scaleEffect` doesn't alter the
                    // layout frame, so the matched-geometry handoff
                    // still tracks the settled 80pt frame.
                    logo
                        .frame(width: 80, height: 80)
                        .scaleEffect(chrome.logoScale)
                        .opacity(chrome.logoOpacity)
                        .matchedGeometryEffect(
                            id: "logo",
                            in: logoNamespace,
                            properties: .frame,
                            isSource: phase == .splash
                        )
                        .position(x: centerX, y: centerY - 22)

                    // Wordmark sits 30pt below the 80pt logo
                    // center. Anchored to logo position so it
                    // tracks geometry consistently with the
                    // prior splash composition.
                    wordmark(chrome: chrome)
                        .position(x: centerX, y: centerY - 22 + 80 / 2 + 30 + 20)

                    tagline(chrome: chrome)
                        .position(x: centerX, y: proxy.size.height - 104)

                    loader(chrome: chrome)
                        .position(x: centerX, y: proxy.size.height - 64)
                }
            }
            .ignoresSafeArea()
            // Pause the 60fps timeline once every chrome keyframe
            // has landed. The expression flips false → true exactly
            // once per run-through; past that point every frame
            // would recompute identical values, so the clock stops.
            .onChange(of: elapsed >= settleDuration) { _, settled in
                if settled { isChromeSettled = true }
            }
        }
        .accessibilityLabel(Text("Aperture"))
        .onAppear {
            startDate = Date()
            isChromeSettled = false
            // Single-shot completion timer as a cancellable Task.
            // Created once (guarded on nil) so re-mounts can't queue
            // a second timer; cancelled in `.onDisappear` so a torn-
            // down splash never fires into a stale closure. The
            // `hasFiredComplete` guard stays as the last line of
            // defense against any double fire.
            guard completionTask == nil else { return }
            completionTask = Task {
                try? await Task.sleep(for: .seconds(Self.splashDuration))
                guard !Task.isCancelled, !hasFiredComplete else { return }
                hasFiredComplete = true
                onSplashComplete()
            }
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
        }
        // Splash chrome (background, glow, wordmark, tagline,
        // loader) fades out when the shared-element transition
        // starts. The logo itself does NOT fade — it flies via
        // matchedGeometryEffect. The 0.35s fade matches the
        // handoff's "wordmark + tagline fade opacity 1 → 0 over
        // ~0.35s starting at t=0 of the move."
        .opacity(phase == .splash ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: phase)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            UniColors.Splash.base
                .ignoresSafeArea()
            EllipticalGradient(
                stops: [
                    .init(color: UniColors.Splash.lift, location: 0),
                    .init(color: UniColors.Splash.base, location: 1)
                ],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadiusFraction: 0,
                endRadiusFraction: 0.64
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Glow

    private func glow(chrome: SplashChromeState) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: UniColors.Splash.glow, location: 0),
                        .init(color: UniColors.Splash.glow.opacity(0), location: 0.7),
                        .init(color: .clear, location: 1.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 170
                )
            )
            .frame(width: 340, height: 340)
            .blur(radius: 48)
            .opacity(chrome.glowOpacity)
            .scaleEffect(chrome.glowScale)
    }

    // MARK: - Logo

    /// The new circle logo — dark gradient disc + white iris.
    /// On splash entrance, the bloom is a native one-shot scale +
    /// opacity keyframe (`SplashChromeState.logoScale` /
    /// `.logoOpacity`) applied at the call site in `body`. Because
    /// the bloom's final frame IS this still `Image`, the
    /// matchedGeometryEffect handoff to onboarding is a single
    /// contiguous Image transition — no asset swap, no seam.
    private var logo: some View {
        Image("LogoCircle")
            .resizable()
            .scaledToFit()
    }

    // MARK: - Wordmark

    private func wordmark(chrome: SplashChromeState) -> some View {
        let wordHeight: CGFloat = 50
        return ZStack(alignment: .bottom) {
            Color.clear.frame(height: wordHeight)
            Text("Aperture")
                .font(.system(size: 42, weight: .semibold, design: .default))
                .kerning(-1.47)
                .foregroundStyle(UniColors.Splash.mark)
                .offset(y: wordHeight * chrome.wordmarkOffsetFraction)
        }
        .frame(height: wordHeight)
        .clipped()
    }

    // MARK: - Tagline

    private func tagline(chrome: SplashChromeState) -> some View {
        Text("Your keys. Your crypto.")
            .font(.system(size: 13.5, weight: .medium))
            .kerning(0.27)
            .foregroundStyle(UniColors.Splash.tagline)
            .opacity(chrome.taglineOpacity)
            .offset(y: chrome.taglineOffsetY)
    }

    // MARK: - Loader

    private func loader(chrome: SplashChromeState) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(UniColors.Splash.loaderTrack)
                .frame(width: 120, height: 3)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(UniColors.Splash.mark)
                .frame(width: 120 * chrome.loaderProgress, height: 3)
        }
        .frame(width: 120, height: 3)
    }
}

// MARK: - Splash chrome state

/// Per-frame state for the splash elements — logo bloom, glow,
/// wordmark, tagline, loader. The logo's *transition to onboarding*
/// is owned by `matchedGeometryEffect` (driven by the
/// `AppRoot.phase` change); only its entrance bloom is computed
/// here.
///
/// The chrome animation curves match the original splash spec from
/// `design_handoff_splash_screen/` — those elements weren't
/// touched by the new handoff so their motion is preserved. The
/// logo bloom is the first beat: it completes just before the
/// wordmark's 0.92s wipe-up begins, using the same cubic-bezier
/// family as the glow. One bloom, no loops (Rule #2 restraint).
private struct SplashChromeState {
    let logoOpacity: Double
    let logoScale: Double
    let glowOpacity: Double
    let glowScale: Double
    let wordmarkOffsetFraction: Double
    let taglineOpacity: Double
    let taglineOffsetY: Double
    let loaderProgress: Double

    init(elapsed: TimeInterval, reduceMotion: Bool) {
        if reduceMotion {
            let p = max(0, min(1, elapsed / 0.30))
            self.logoOpacity = p
            self.logoScale = 1
            self.glowOpacity = 0.6 * p
            self.glowScale = 1
            self.wordmarkOffsetFraction = 0
            self.taglineOpacity = p
            self.taglineOffsetY = 0
            self.loaderProgress = p
            return
        }

        // Logo bloom — delay 0s, duration 0.90s, (.2, .7, .2, 1).
        // Scale 0.60 → 1.00 across the full bloom; opacity 0 → 1
        // over the first 60% so the disc is fully present while it
        // settles into its final size. Done before the wordmark's
        // 0.92s entrance — the logo leads, everything else follows.
        let logoT = clampUnit(elapsed / 0.90)
        let logoE = SplashEase.cubicBezier(logoT, 0.2, 0.7, 0.2, 1.0)
        self.logoScale = 0.60 + 0.40 * logoE
        let logoFadeT = clampUnit(logoT / 0.60)
        self.logoOpacity = SplashEase.cubicBezier(logoFadeT, 0.2, 0.7, 0.2, 1.0)

        // Glow — delay 0.10s, duration 1.50s, (.2, .7, .2, 1)
        let glowT = clampUnit((elapsed - 0.10) / 1.50)
        let glowE = SplashEase.cubicBezier(glowT, 0.2, 0.7, 0.2, 1.0)
        if glowT <= 0 {
            self.glowOpacity = 0
        } else if glowT < 0.55 {
            let local = glowT / 0.55
            let localE = SplashEase.cubicBezier(local, 0.2, 0.7, 0.2, 1.0)
            self.glowOpacity = 0.95 * localE
        } else {
            let local = (glowT - 0.55) / 0.45
            let localE = SplashEase.cubicBezier(local, 0.2, 0.7, 0.2, 1.0)
            self.glowOpacity = 0.95 + (0.6 - 0.95) * localE
        }
        self.glowScale = 0.5 + 0.5 * glowE

        // Wordmark — delay 0.92s, duration 0.80s, (.2, .8, .2, 1)
        let wordT = clampUnit((elapsed - 0.92) / 0.80)
        let wordE = SplashEase.cubicBezier(wordT, 0.2, 0.8, 0.2, 1.0)
        self.wordmarkOffsetFraction = 1.10 * (1.0 - wordE)

        // Tagline — delay 1.50s, duration 0.70s, ease (.25, .1, .25, 1)
        let tagT = clampUnit((elapsed - 1.50) / 0.70)
        let tagE = SplashEase.cubicBezier(tagT, 0.25, 0.1, 0.25, 1.0)
        self.taglineOpacity = tagE
        self.taglineOffsetY = 8.0 * (1.0 - tagE)

        // Loader — delay 0.35s, duration 2.00s, (.4, 0, .2, 1)
        let loadT = clampUnit((elapsed - 0.35) / 2.00)
        if loadT < 0.70 {
            let local = loadT / 0.70
            let e = SplashEase.cubicBezier(local, 0.4, 0.0, 0.2, 1.0)
            self.loaderProgress = 0.82 * e
        } else {
            let local = (loadT - 0.70) / 0.30
            let e = SplashEase.cubicBezier(local, 0.4, 0.0, 0.2, 1.0)
            self.loaderProgress = 0.82 + (1.0 - 0.82) * e
        }
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
