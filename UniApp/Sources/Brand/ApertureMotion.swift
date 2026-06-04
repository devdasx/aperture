import CoreGraphics
import Foundation

/// Aperture iris motion behaviors, ported verbatim from the canonical
/// `animated-logo.html` brand spec authored by the app owner.
///
/// Only ``splash(at:)`` is implemented today — that's the one moment the
/// app currently has a surface for (the launch splash and the Welcome
/// onboarding slide hero). The four remaining canonical behaviors
/// (`loading`, `refresh`, `send`, `receive`) belong to surfaces that don't
/// exist yet (the loading indicator, pull-to-refresh, the Send-confirm and
/// Receive-arrival flows). They will be added here when those surfaces
/// land — porting them prematurely would violate Rule #2 "strip one thing"
/// (YAGNI).
enum ApertureMotion {

    /// One frame of iris state for a given motion behavior.
    ///
    /// Drives ``ApertureIrisView``'s `rc` / `rot` directly, plus the
    /// containing view's `opacity` and `scale`.
    struct Frame: Equatable {
        let rc: CGFloat
        let rot: CGFloat
        let opacity: Double
        let scale: CGFloat
    }

    // MARK: - Easing functions (port of animated-logo.html lines 77–79)

    /// Cubic ease-out — fast start, gentle settle.
    /// `eOut(t) = 1 - (1-t)^3`
    @inline(__always)
    static func easeOut(_ t: CGFloat) -> CGFloat {
        let inv = 1 - t
        return 1 - inv * inv * inv
    }

    /// Cubic ease-in-out — symmetric S-curve.
    /// `eInOut(t) = t<.5 ? 4t³ : 1 - ((-2t+2)³)/2`
    @inline(__always)
    static func easeInOut(_ t: CGFloat) -> CGFloat {
        if t < 0.5 {
            return 4 * t * t * t
        } else {
            let v = -2 * t + 2
            return 1 - (v * v * v) / 2
        }
    }

    /// Ease-out with overshoot — the iris blooms slightly past `open` then
    /// settles back. `c1 = 1.70158`, `c3 = c1 + 1`.
    @inline(__always)
    static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158
        let c3 = c1 + 1
        let tm1 = t - 1
        return 1 + c3 * tm1 * tm1 * tm1 + c1 * tm1 * tm1
    }

    /// Clamps a value into [0, 1].
    @inline(__always)
    static func clamp01(_ x: CGFloat) -> CGFloat {
        return min(max(x, 0), 1)
    }

    @inline(__always)
    static func clamp01(_ x: Double) -> Double {
        return min(max(x, 0), 1)
    }

    // MARK: - Splash

    /// Total duration of the splash behavior, in seconds. Outside this
    /// window the iris is fully faded out — callers gate presentation on
    /// this value.
    static let splashDuration: TimeInterval = 3.6

    /// Splash behavior: the iris blooms open with overshoot, holds, then
    /// fades. Port of `beh.splash(tt)` in `animated-logo.html`.
    ///
    /// Phases (`tt` is seconds since the animation started):
    ///   * `0.00 – 0.15` — closed, fading in, pre-rotated to -0.55 rad
    ///   * `0.15 – 1.40` — opens from shut → open with `easeOutBack`
    ///     overshoot; rotation eases back to 0; opacity reaches 1
    ///   * `1.40 – 2.85` — hold fully open at unit opacity and scale
    ///   * `2.85 – 3.60` — fade out with `easeInOut`, scale grows +6%
    ///   * `> 3.60` — invisible (opacity 0, scale 1.06)
    static func splash(at time: TimeInterval) -> Frame {
        let tt = CGFloat(time)
        let t0: CGFloat = 0.15
        let dur: CGFloat = 1.25

        // Default to the held-open / faded-out tail values.
        var rc: CGFloat = ApertureIrisView.openValue
        var rot: CGFloat = 0
        var opacity: Double = 1
        var scale: CGFloat = 1

        if tt < t0 {
            // Phase 1 — closed, fading in, pre-rotated.
            rc = ApertureIrisView.shutValue
            opacity = Double(clamp01(tt / 0.3))
            scale = 0.9
            rot = -0.55
        } else if tt < t0 + dur {
            // Phase 2 — bloom open with overshoot.
            let u = clamp01((tt - t0) / dur)
            rc = ApertureIrisView.shutValue
                + (ApertureIrisView.openValue - ApertureIrisView.shutValue) * easeOutBack(u)
            rot = -0.55 * (1 - easeOut(u))
            opacity = Double(clamp01(tt / 0.4))
            scale = 0.9 + 0.1 * easeOut(u)
        } else if tt < 2.85 {
            // Phase 3 — hold fully open.
            rc = ApertureIrisView.openValue
            rot = 0
            opacity = 1
            scale = 1
        } else {
            // Phase 4 — fade out with subtle scale grow.
            let u = clamp01((tt - 2.85) / 0.75)
            rc = ApertureIrisView.openValue
            rot = 0
            opacity = Double(1 - easeInOut(u))
            scale = 1 + 0.06 * u
        }

        return Frame(rc: rc, rot: rot, opacity: opacity, scale: scale)
    }
}
