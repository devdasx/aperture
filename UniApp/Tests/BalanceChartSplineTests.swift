import Testing
import CoreGraphics
@testable import Aperture

/// Tests for `MonotoneCubic` — the Fritsch–Carlson monotone cubic that renders
/// the balance chart curve (2026-06-19). The whole reason to use it over a
/// plain Catmull-Rom is that it is **curvy but provably overshoot-free**: the
/// interpolant never rises above a segment's higher endpoint nor dips below its
/// lower one. These tests lock that property in.
struct BalanceChartSplineTests {

    /// Sample a cubic Bézier at parameter `t`.
    static func bezier(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p3.x
        let y = u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p3.y
        return CGPoint(x: x, y: y)
    }

    /// Assert no sample of any segment leaves its two endpoints' y-range.
    static func assertNoOvershoot(_ pts: [CGPoint], tol: CGFloat = 1e-6) {
        let segs = MonotoneCubic.bezierSegments(pts)
        #expect(segs.count == pts.count - 1)
        for (i, seg) in segs.enumerated() {
            let p0 = pts[i]
            let lo = min(p0.y, seg.to.y) - tol
            let hi = max(p0.y, seg.to.y) + tol
            for k in 0...20 {
                let y = bezier(p0, seg.c1, seg.c2, seg.to, CGFloat(k) / 20).y
                #expect(y >= lo && y <= hi, "overshoot in seg \(i) at t=\(CGFloat(k)/20): y=\(y) ∉ [\(lo),\(hi)]")
            }
        }
    }

    // MARK: - No overshoot (the core guarantee)

    @Test("Monotone-increasing data: no segment overshoots its endpoints")
    func increasingNoOvershoot() {
        // Includes a near-flat pair then a steep jump (the case Catmull-Rom looped).
        Self.assertNoOvershoot([
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0.1), CGPoint(x: 2, y: 5),
            CGPoint(x: 3, y: 5.05), CGPoint(x: 4, y: 12),
        ])
    }

    @Test("A peak (gain then loss) does not bulge above the peak")
    func peakNoOvershoot() {
        // Classic extremum case: rises to 10 at x=1, falls to 5 — the curve must
        // never exceed 10 (the bare magnitude limiter alone would; the extremum
        // tangent-zeroing prevents it).
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 10), CGPoint(x: 2, y: 5)]
        Self.assertNoOvershoot(pts)
        let segs = MonotoneCubic.bezierSegments(pts)
        for (i, seg) in segs.enumerated() {
            for k in 0...20 {
                let y = Self.bezier(pts[i], seg.c1, seg.c2, seg.to, CGFloat(k) / 20).y
                #expect(y <= 10 + 1e-6, "bulged above the peak: \(y)")
            }
        }
    }

    @Test("A trough (loss then gain) does not dip below the trough")
    func troughNoOvershoot() {
        let pts = [CGPoint(x: 0, y: 10), CGPoint(x: 1, y: 2), CGPoint(x: 2, y: 8)]
        Self.assertNoOvershoot(pts)
        let segs = MonotoneCubic.bezierSegments(pts)
        for (i, seg) in segs.enumerated() {
            for k in 0...20 {
                let y = Self.bezier(pts[i], seg.c1, seg.c2, seg.to, CGFloat(k) / 20).y
                #expect(y >= 2 - 1e-6, "dipped below the trough: \(y)")
            }
        }
    }

    @Test("A realistic noisy series stays within each segment's bounds")
    func noisyNoOvershoot() {
        Self.assertNoOvershoot([
            CGPoint(x: 0, y: 100), CGPoint(x: 1, y: 102), CGPoint(x: 2, y: 98),
            CGPoint(x: 3, y: 130), CGPoint(x: 4, y: 128), CGPoint(x: 5, y: 200),
            CGPoint(x: 6, y: 199), CGPoint(x: 7, y: 150),
        ])
    }

    // MARK: - Smoothness (C1 continuity)

    @Test("Consecutive segments share a tangent at each interior point (C1)")
    func c1Continuity() {
        let pts = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 3), CGPoint(x: 2, y: 2),
            CGPoint(x: 3, y: 9), CGPoint(x: 4, y: 7),
        ]
        let segs = MonotoneCubic.bezierSegments(pts)
        // At interior point i (the join of seg i-1 and seg i), the incoming
        // control arm (p[i] − c2 of seg i-1) and the outgoing arm (c1 of seg i
        // − p[i]) must have the same slope dy/dx.
        for i in 1..<(pts.count - 1) {
            let incoming = segs[i - 1]   // ends at pts[i]
            let outgoing = segs[i]       // starts at pts[i]
            let inDx = pts[i].x - incoming.c2.x
            let inDy = pts[i].y - incoming.c2.y
            let outDx = outgoing.c1.x - pts[i].x
            let outDy = outgoing.c1.y - pts[i].y
            #expect(abs(inDx) > 1e-9 && abs(outDx) > 1e-9)
            let inSlope = inDy / inDx
            let outSlope = outDy / outDx
            #expect(abs(inSlope - outSlope) < 1e-6, "C1 break at point \(i): \(inSlope) vs \(outSlope)")
        }
    }

    // MARK: - Degenerate inputs

    @Test("Two points → one straight segment; flat data → flat segments")
    func degenerate() {
        #expect(MonotoneCubic.bezierSegments([CGPoint(x: 0, y: 5)]).isEmpty)
        #expect(MonotoneCubic.bezierSegments([CGPoint(x: 0, y: 5), CGPoint(x: 1, y: 9)]).count == 1)
        // All-equal y → every control point on the flat line (no wiggle).
        let flat = [CGPoint(x: 0, y: 4), CGPoint(x: 1, y: 4), CGPoint(x: 2, y: 4)]
        for seg in MonotoneCubic.bezierSegments(flat) {
            #expect(abs(seg.c1.y - 4) < 1e-9 && abs(seg.c2.y - 4) < 1e-9 && abs(seg.to.y - 4) < 1e-9)
        }
    }
}
