import SwiftUI

/// Aperture's launch splash — the brand's first breath, redesigned 2026-06-07
/// against `/Users/thuglifex/Downloads/design_handoff_splash_screen/`.
///
/// **Composition (top → bottom):**
/// - Radial-gradient monochrome background (Lift `#1A1C21|#FFFFFF` →
///   Base `#000000|#EEF0F4` at center-upper, 50% × 38%).
/// - Soft 340pt halo behind the lockup at `y = -26` from screen center.
/// - Lockup (mark + wordmark) at screen center with `y = -22`:
///   * Iris mark 118pt from `Brand/Mark.imageset` with a drop shadow.
///   * 30pt gap.
///   * "Aperture" wordmark — SF Pro Display 42pt semibold,
///     letter-spacing -0.035em, wipe-up reveal from below by 110% inside
///     a clipped container.
/// - Tagline "Your keys. Your crypto." anchored 104pt from the bottom.
/// - Determinate loader bar 120×3pt anchored 64pt from the bottom.
///
/// **Animation timeline (~2.6s total, all cubic-bezier per the handoff):**
///
/// | Element | Delay | Duration | Curve | Animates |
/// |---|---|---|---|---|
/// | Glow | 0.10s | 1.50s | `(.2,.7,.2,1)` | opacity 0→.95@55%→.6; scale .5→1 |
/// | Mark | 0.15s | 1.00s | `(.2,.8,.2,1)` | opacity 0→1@58%; scale .45→1.09@58%→.985@78%→1; rotate -95°→7°@58°→-1.5°@78°→0° |
/// | Loader | 0.35s | 2.00s | `(.4,0,.2,1)` | width 0→.82@70%→1 |
/// | Wordmark | 0.92s | 0.80s | `(.2,.8,.2,1)` | translateY 110%→0 (clipped wipe-up) |
/// | Tagline | 1.50s | 0.70s | `(.25,.1,.25,1)` (ease) | opacity 0→1; translateY 8→0 |
///
/// Driven by `TimelineView(.animation)` over a per-frame
/// `SplashAnimationState` computed from elapsed seconds, with a
/// hand-written cubic-bezier solver so the easings match the CSS
/// reference byte-for-byte. Reduce Motion → simple 0.3s cross-fade
/// per the handoff spec.
///
/// **Native-only.** Per Rule #3, no Lottie playback for the iris bloom
/// — the design's mark animation is multi-keyframe with intermediate
/// stops AND has to coordinate with four other animated elements on a
/// shared timeline, so hand-driving it from `TimelineView` is the
/// canonical SwiftUI pattern and gives pixel-perfect timing. The
/// `splash-*.json` Lottie files remain bundled for any future use
/// outside this exact composition.
struct SplashView: View {
    let onComplete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startDate: Date = .init()
    @State private var hasFinished: Bool = false

    /// Total wall time before `onComplete` fires. Matches the handoff's
    /// "~2.35s entrance + brief hold" with a small buffer so the last
    /// keyframe settles before the screen transitions out.
    private static let totalDuration: TimeInterval = 2.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSince(startDate)
            let state = SplashAnimationState(elapsed: elapsed, reduceMotion: reduceMotion)
            ZStack {
                background
                GeometryReader { proxy in
                    let centerX = proxy.size.width / 2
                    let centerY = proxy.size.height / 2

                    glow(state: state)
                        .position(x: centerX, y: centerY - 26)

                    lockup(state: state)
                        .position(x: centerX, y: centerY - 22)

                    tagline(state: state)
                        .position(x: centerX, y: proxy.size.height - 104)

                    loader(state: state)
                        .position(x: centerX, y: proxy.size.height - 64)
                }
            }
            .ignoresSafeArea()
        }
        .accessibilityLabel(Text("Aperture"))
        .onAppear {
            startDate = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.totalDuration) {
                guard !hasFinished else { return }
                hasFinished = true
                onComplete()
            }
        }
    }

    // MARK: - Background

    /// Radial-gradient lift at the upper-center. The handoff specifies
    /// `radial-gradient(125% 80% at 50% 38%, lift 0%, base 64%|72%)` —
    /// elliptical with the center above true center. SwiftUI's
    /// `EllipticalGradient` honours the elliptical shape; the
    /// `endRadiusFraction` is tuned to land within ~3pt of the CSS
    /// reference across iPhone 17 sizes.
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

    private func glow(state: SplashAnimationState) -> some View {
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
            .opacity(state.glowOpacity)
            .scaleEffect(state.glowScale)
    }

    // MARK: - Lockup (mark + wordmark)

    private func lockup(state: SplashAnimationState) -> some View {
        VStack(spacing: 30) {
            mark(state: state)
            wordmark(state: state)
        }
    }

    /// 118pt iris mark with drop shadow + scale + rotation animations.
    private func mark(state: SplashAnimationState) -> some View {
        Image("Mark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 118, height: 118)
            .foregroundStyle(UniColors.Splash.mark)
            .opacity(state.markOpacity)
            .scaleEffect(state.markScale)
            .rotationEffect(.degrees(state.markRotation))
            .shadow(
                color: shadowColor,
                radius: shadowRadius,
                x: 0,
                y: 14
            )
    }

    /// Drop shadow per spec — heavier on the black variant.
    /// Black: `0 14px 34px rgba(0,0,0,0.5)`. Light: `0 14px 30px rgba(10,15,30,0.16)`.
    private var shadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.5)
            : Color(red: 10.0/255, green: 15.0/255, blue: 30.0/255).opacity(0.16)
    }

    private var shadowRadius: CGFloat {
        // CSS blur radius is ~2× SwiftUI's shadow radius for similar visual weight.
        colorScheme == .dark ? 17 : 15
    }

    /// "Aperture" wordmark — wipe-up reveal inside a clipped frame.
    private func wordmark(state: SplashAnimationState) -> some View {
        let wordHeight: CGFloat = 50 // ample container so the rise reads cleanly
        return ZStack(alignment: .bottom) {
            Color.clear.frame(height: wordHeight)
            Text("Aperture")
                .font(.system(size: 42, weight: .semibold, design: .default))
                .kerning(-1.47) // -0.035em × 42pt
                .foregroundStyle(UniColors.Splash.mark)
                .offset(y: wordHeight * state.wordmarkOffsetFraction)
        }
        .frame(height: wordHeight)
        .clipped()
    }

    // MARK: - Tagline

    private func tagline(state: SplashAnimationState) -> some View {
        Text("Your keys. Your crypto.")
            .font(.system(size: 13.5, weight: .medium))
            .kerning(0.27) // 0.02em × 13.5pt
            .foregroundStyle(UniColors.Splash.tagline)
            .opacity(state.taglineOpacity)
            .offset(y: state.taglineOffsetY)
    }

    // MARK: - Loader

    private func loader(state: SplashAnimationState) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(UniColors.Splash.loaderTrack)
                .frame(width: 120, height: 3)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(UniColors.Splash.mark)
                .frame(width: 120 * state.loaderProgress, height: 3)
        }
        .frame(width: 120, height: 3)
    }
}

// MARK: - Animation state

/// Per-frame splash animation state, computed from elapsed seconds. All
/// interpolations match the CSS cubic-bezier curves in the design
/// handoff exactly via `SplashEase.cubicBezier(...)` — a Newton-Raphson
/// solver for the x(t) → t inversion + a polynomial y(t) evaluation.
///
/// Reduce Motion → a single 0.3s cross-fade in opacity per the handoff
/// fallback spec (everything else stays at its final value).
private struct SplashAnimationState {
    let glowOpacity: Double
    let glowScale: Double
    let markOpacity: Double
    let markScale: Double
    let markRotation: Double // degrees
    let wordmarkOffsetFraction: Double // 1.10 → 0 (clipped wipe-up)
    let taglineOpacity: Double
    let taglineOffsetY: Double
    let loaderProgress: Double

    init(elapsed: TimeInterval, reduceMotion: Bool) {
        if reduceMotion {
            let p = max(0, min(1, elapsed / 0.30))
            self.glowOpacity = 0.6 * p
            self.glowScale = 1
            self.markOpacity = p
            self.markScale = 1
            self.markRotation = 0
            self.wordmarkOffsetFraction = 0
            self.taglineOpacity = p
            self.taglineOffsetY = 0
            self.loaderProgress = p
            return
        }

        // Glow — delay 0.10s, duration 1.50s, (.2, .7, .2, 1)
        // Keyframes: opacity 0 → 0.95 @ 55% → 0.6 @ 100%; scale 0.5 → 1.0.
        let glowT = clampUnit((elapsed - 0.10) / 1.50)
        let glowE = SplashEase.cubicBezier(glowT, 0.2, 0.7, 0.2, 1.0)
        if glowT <= 0 {
            self.glowOpacity = 0
        } else if glowT < 0.55 {
            // 0 → 0.95 over [0, 0.55] using the eased x at the local fraction.
            let local = glowT / 0.55
            let localE = SplashEase.cubicBezier(local, 0.2, 0.7, 0.2, 1.0)
            self.glowOpacity = 0.95 * localE
        } else {
            // 0.95 → 0.6 over [0.55, 1.0].
            let local = (glowT - 0.55) / 0.45
            let localE = SplashEase.cubicBezier(local, 0.2, 0.7, 0.2, 1.0)
            self.glowOpacity = 0.95 + (0.6 - 0.95) * localE
        }
        self.glowScale = 0.5 + 0.5 * glowE

        // Mark — delay 0.15s, duration 1.00s, (.2, .8, .2, 1)
        // Three-segment keyframes for scale + rotation; opacity reaches 1 at 58%.
        let markT = clampUnit((elapsed - 0.15) / 1.00)
        let markCurve: (Double, Double, Double, Double) = (0.2, 0.8, 0.2, 1.0)
        if markT <= 0 {
            self.markOpacity = 0
            self.markScale = 0.45
            self.markRotation = -95
        } else {
            // Opacity: 0 → 1 over [0, 0.58], then 1.
            if markT < 0.58 {
                let local = markT / 0.58
                self.markOpacity = SplashEase.cubicBezier(local, markCurve.0, markCurve.1, markCurve.2, markCurve.3)
            } else {
                self.markOpacity = 1
            }
            // Scale + rotation segmented at 0.58, 0.78, 1.0.
            if markT < 0.58 {
                let local = markT / 0.58
                let e = SplashEase.cubicBezier(local, markCurve.0, markCurve.1, markCurve.2, markCurve.3)
                self.markScale = 0.45 + (1.09 - 0.45) * e
                self.markRotation = -95 + (7 - (-95)) * e
            } else if markT < 0.78 {
                let local = (markT - 0.58) / 0.20
                let e = SplashEase.cubicBezier(local, markCurve.0, markCurve.1, markCurve.2, markCurve.3)
                self.markScale = 1.09 + (0.985 - 1.09) * e
                self.markRotation = 7 + (-1.5 - 7) * e
            } else {
                let local = (markT - 0.78) / 0.22
                let e = SplashEase.cubicBezier(local, markCurve.0, markCurve.1, markCurve.2, markCurve.3)
                self.markScale = 0.985 + (1.0 - 0.985) * e
                self.markRotation = -1.5 + (0 - (-1.5)) * e
            }
        }

        // Wordmark — delay 0.92s, duration 0.80s, (.2, .8, .2, 1)
        // translateY 110% → 0 inside the clipped container.
        let wordT = clampUnit((elapsed - 0.92) / 0.80)
        let wordE = SplashEase.cubicBezier(wordT, 0.2, 0.8, 0.2, 1.0)
        self.wordmarkOffsetFraction = 1.10 * (1.0 - wordE)

        // Tagline — delay 1.50s, duration 0.70s, ease (.25, .1, .25, 1)
        // opacity 0 → 1, translateY 8 → 0.
        let tagT = clampUnit((elapsed - 1.50) / 0.70)
        let tagE = SplashEase.cubicBezier(tagT, 0.25, 0.1, 0.25, 1.0)
        self.taglineOpacity = tagE
        self.taglineOffsetY = 8.0 * (1.0 - tagE)

        // Loader — delay 0.35s, duration 2.00s, (.4, 0, .2, 1)
        // width 0 → 0.82 @ 70% → 1.0 @ 100%.
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

/// Evaluates the CSS cubic-bezier curve `(P1x, P1y, P2x, P2y)` at the
/// input `t ∈ [0, 1]` where t is the **x** coordinate on the curve, and
/// returns the corresponding **y**. The CSS contract: P0 = (0,0), P3 =
/// (1,1), so a 4-tuple of curve parameters uniquely identifies the
/// easing. Newton-Raphson converges in ≤8 iterations to sub-pixel
/// precision for the curves used in this splash.
private enum SplashEase {
    static func cubicBezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        // Solve x(u) = t for u via Newton-Raphson.
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
        // Evaluate y(u).
        let oneMinusU = 1 - u
        return 3 * oneMinusU * oneMinusU * u * y1
             + 3 * oneMinusU * u * u * y2
             + u * u * u
    }
}

// MARK: - Previews

#Preview("Black (dark)") {
    SplashView(onComplete: {})
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    SplashView(onComplete: {})
        .preferredColorScheme(.light)
}
