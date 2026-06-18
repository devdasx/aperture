import CoreGraphics

// MARK: - MonotoneCubic (Fritsch–Carlson, overshoot-free)

/// Builds smooth, overshoot-free cubic-Bézier segments through points with
/// **strictly increasing x** — the Fritsch–Carlson monotone cubic (PCHIP).
///
/// This is the balance chart's curve renderer (2026-06-19). It replaces the
/// linear path: Mode C samples a dense, strictly-x-increasing grid, so a smooth
/// spline is well-defined, and a *monotone* cubic is curvy AND provably cannot
/// overshoot — it never introduces a peak or dip absent from the data (no loops
/// / V's, unlike a uniform Catmull-Rom). A transaction renders as a smooth steep
/// S-ramp into its new level instead of a hard corner; flat data (constant
/// value) yields zero tangents → a straight line.
///
/// Pure `CoreGraphics` value math (no SwiftUI) so it's independently
/// unit-testable; the path is built once per data change (inside the
/// `.equatable()` curve view), never per scrub frame.
enum MonotoneCubic {
    /// One cubic segment: the Bézier `to` end + its two control points. The
    /// caller must `move(to:)` the first point, then `addCurve` each segment.
    static func bezierSegments(_ pts: [CGPoint]) -> [(to: CGPoint, c1: CGPoint, c2: CGPoint)] {
        let n = pts.count
        guard n >= 2 else { return [] }

        // Degenerate cubic for a 2-point series (a straight line).
        func straight(_ a: CGPoint, _ b: CGPoint) -> (to: CGPoint, c1: CGPoint, c2: CGPoint) {
            let dx = b.x - a.x, dy = b.y - a.y
            return (b, CGPoint(x: a.x + dx / 3, y: a.y + dy / 3), CGPoint(x: b.x - dx / 3, y: b.y - dy / 3))
        }
        if n == 2 { return [straight(pts[0], pts[1])] }

        // 1) Secant slopes.
        var delta = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            delta[i] = dx != 0 ? (pts[i + 1].y - pts[i].y) / dx : 0
        }
        // 2) Tangents (one-sided at the ends, averaged in the interior). **At a
        // local extremum — where the two neighboring secants have opposite
        // signs (a gain-then-loss peak or loss-then-gain trough) — zero the
        // tangent.** This is the canonical PCHIP step the bare magnitude limiter
        // below omits; without it the curve would still bulge past a peak. With
        // it, the interpolant provably cannot overshoot.
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for i in 1..<(n - 1) {
            if delta[i - 1] * delta[i] <= 0 {
                m[i] = 0
            } else {
                m[i] = (delta[i - 1] + delta[i]) / 2
            }
        }
        // 3) Fritsch–Carlson magnitude limiter — caps each tangent so the cubic
        // stays monotone within every segment.
        for i in 0..<(n - 1) {
            if delta[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
            } else {
                let a = m[i] / delta[i]
                let b = m[i + 1] / delta[i]
                let s = a * a + b * b
                if s > 9 {
                    let t = 3 / s.squareRoot()
                    m[i] = t * a * delta[i]
                    m[i + 1] = t * b * delta[i]
                }
            }
        }
        // 4) Hermite → cubic Bézier per segment.
        var segments: [(to: CGPoint, c1: CGPoint, c2: CGPoint)] = []
        segments.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            let c1 = CGPoint(x: pts[i].x + dx / 3, y: pts[i].y + m[i] * dx / 3)
            let c2 = CGPoint(x: pts[i + 1].x - dx / 3, y: pts[i + 1].y - m[i + 1] * dx / 3)
            segments.append((pts[i + 1], c1, c2))
        }
        return segments
    }
}
