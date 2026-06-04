import SwiftUI

/// Native SwiftUI port of the Aperture iris/diaphragm — the canonical brand
/// mark, rendered live from geometry rather than from a static image.
///
/// The mark is a 7-blade aperture diaphragm: an outer disc of radius 40 on a
/// 100-unit grid centered at (50, 50), with a 7-vertex rounded polygon (the
/// "opening") subtracted via even-odd fill. Seven hairline seams radiate from
/// each polygon vertex along its edge direction to the outer circle — these
/// are what give the blade illusion. When drawn in the negative-space color
/// (i.e., the background behind the iris), the seams read as transparent
/// gaps that visually carve the ring into seven blades.
///
/// Geometry mirrors `animated-logo.html`'s `geom(rc, rot)` JS function
/// verbatim — same vertex math, same `bow` curvature, same seam endpoint
/// computation. This is a native port of the canonical brand spec authored
/// by the app owner; per Rule #7 it ships the *real* mark, not an
/// approximation built from SwiftUI primitives. Rendering happens through
/// `Canvas` (system primitive) so animation is GPU-accelerated and the
/// shape is resolution-independent.
///
/// ## Usage
///
/// ```swift
/// // Static (e.g. as a slide hero) — held at fully-open with no rotation.
/// ApertureIrisView(rc: ApertureIrisView.openValue, rot: 0)
///     .frame(width: 112, height: 112)
///
/// // Animated (e.g. splash) — drive `rc` and `rot` from a `TimelineView`.
/// TimelineView(.animation) { context in
///     let frame = ApertureMotion.splash(at: context.date.timeIntervalSince(start))
///     ApertureIrisView(rc: frame.rc, rot: frame.rot)
///         .opacity(frame.opacity)
///         .scaleEffect(frame.scale)
/// }
/// ```
struct ApertureIrisView: View {
    /// Opening radius on the 100-unit grid. Animate between
    /// ``shutValue`` (closed iris, ≈ 2.4) and ``openValue`` (fully open, 17).
    let rc: CGFloat

    /// Rotation of the inner polygon, in radians.
    let rot: CGFloat

    /// Fill color of the iris ring. Defaults to the brand accent
    /// (`UniColors.Tint.accent`) so the mark adapts to light/dark and to
    /// the user's chosen accent for free.
    let ringColor: Color

    /// Color of the negative space (the carved opening and the seam gaps).
    /// Must match the surface the iris is drawn on so the seams read as
    /// transparent. Defaults to `UniColors.Background.primary`.
    let negativeColor: Color

    init(
        rc: CGFloat = ApertureIrisView.openValue,
        rot: CGFloat = 0,
        ringColor: Color = UniColors.Brand.mark,
        negativeColor: Color = UniColors.Background.primary
    ) {
        self.rc = rc
        self.rot = rot
        self.ringColor = ringColor
        self.negativeColor = negativeColor
    }

    // MARK: - Geometry constants (verbatim from animated-logo.html)

    /// Fully-open opening radius on the 100-unit grid.
    static let openValue: CGFloat = 17

    /// Fully-shut opening radius on the 100-unit grid (the iris never closes
    /// to a point — the closed state is a small dot, mirroring a real
    /// camera shutter).
    static let shutValue: CGFloat = 2.4

    /// Outer disc radius on the 100-unit grid.
    private static let outerRadius: CGFloat = 40

    /// Number of aperture blades.
    private static let bladeCount: Int = 7

    /// Hairline width for the seam strokes, in 100-unit-grid units. At the
    /// canonical brand-spec stroke width of 1.35 the seams read as
    /// blade-defining hairlines at every render size.
    private static let seamStroke: CGFloat = 1.35

    // MARK: - Body

    var body: some View {
        Canvas { context, size in
            // Scale the 100-unit design grid to fit the view, preserving
            // aspect (the design is square so we take the smaller dimension).
            let side = min(size.width, size.height)
            let scale = side / 100.0
            let originX = (size.width - side) / 2.0
            let originY = (size.height - side) / 2.0

            // Push the design-grid transform so the rest of the drawing
            // uses canonical 100-unit coordinates.
            context.translateBy(x: originX, y: originY)
            context.scaleBy(x: scale, y: scale)

            let geometry = Self.geom(rc: rc, rot: rot)

            // Ring: disc minus inner polygon, filled with the brand color.
            // Even-odd fill rule does the subtraction.
            context.fill(geometry.ringPath, with: .color(ringColor), style: FillStyle(eoFill: true))

            // Seams: drawn in the negative-space color so they carve the
            // ring into seven blades. Round caps would compound at the
            // vertices and look chunky; butt caps match the canonical SVG.
            let seamStyle = StrokeStyle(
                lineWidth: Self.seamStroke,
                lineCap: .butt,
                lineJoin: .miter
            )
            for seam in geometry.seams {
                var seamPath = Path()
                seamPath.move(to: seam.0)
                seamPath.addLine(to: seam.1)
                context.stroke(seamPath, with: .color(negativeColor), style: seamStyle)
            }
        }
        .drawingGroup() // Composite off-screen so seams blend cleanly with the ring.
        .accessibilityHidden(true) // Decorative — the surrounding view labels.
    }

    // MARK: - Geometry (port of `geom(rc, rot)` in animated-logo.html)

    /// Cached per-render geometry: the ring path and seven seam segments.
    private struct Geometry {
        let ringPath: Path
        let seams: [(CGPoint, CGPoint)] // (start at vertex, end on outer circle)
    }

    /// Computes the iris geometry for a given opening radius + rotation.
    ///
    /// Port of `geom(rc, rot)` in `animated-logo.html`. Returns the combined
    /// even-odd ring path (outer disc minus rounded inner polygon) and the
    /// seven seam line segments.
    private static func geom(rc: CGFloat, rot: CGFloat) -> Geometry {
        let effectiveRc = max(1.8, rc) // matches JS: never collapses past a dot
        let phase = -CGFloat.pi / 2 + rot
        let step = (2 * CGFloat.pi) / CGFloat(bladeCount)

        // Vertices of the inner polygon.
        var vertices: [CGPoint] = []
        vertices.reserveCapacity(bladeCount)
        for k in 0..<bladeCount {
            let angle = phase + CGFloat(k) * step
            vertices.append(CGPoint(
                x: 50 + effectiveRc * cos(angle),
                y: 50 + effectiveRc * sin(angle)
            ))
        }

        // Outward bow on each edge — fades as the iris closes so a closed
        // iris reads as a tight dot, not a bulging puff.
        let bow: CGFloat = 0.7 * min(max(rc / 17, 0), 1.1)

        // Combined path: outer disc + rounded inner polygon. The Canvas
        // fills with even-odd so the inner polygon punches through.
        var path = Path()

        // Outer disc.
        path.addEllipse(in: CGRect(
            x: 50 - outerRadius,
            y: 50 - outerRadius,
            width: 2 * outerRadius,
            height: 2 * outerRadius
        ))

        // Rounded inner polygon — port of `roundedPoly(V, bow)`.
        for k in 0..<bladeCount {
            let a = vertices[k]
            let b = vertices[(k + 1) % bladeCount]
            if k == 0 {
                path.move(to: a)
            }
            // Midpoint of edge a→b, outward normal from center (50, 50).
            let mx = (a.x + b.x) / 2
            let my = (a.y + b.y) / 2
            let nx = mx - 50
            let ny = my - 50
            let nl = max(hypot(nx, ny), 1e-6)
            let cx = mx + (nx / nl) * bow
            let cy = my + (ny / nl) * bow
            path.addQuadCurve(to: b, control: CGPoint(x: cx, y: cy))
        }
        path.closeSubpath()

        // Seam segments — port of `seamEnd(V0, V1, R)`. The seam starts at
        // V[(k+1)%N] (each blade's anchor) and extends along the edge
        // direction (from V[k] to V[k+1]) outward to where it meets the
        // outer circle of radius R.
        var seams: [(CGPoint, CGPoint)] = []
        seams.reserveCapacity(bladeCount)
        for k in 0..<bladeCount {
            let v0 = vertices[k]
            let v1 = vertices[(k + 1) % bladeCount]
            let end = seamEnd(from: v0, through: v1, radius: outerRadius)
            seams.append((v1, end))
        }

        return Geometry(ringPath: path, seams: seams)
    }

    /// Extends the ray from `from` through `through` until it meets the
    /// outer circle of `radius` centered at (50, 50). Port of `seamEnd` in
    /// the canonical JS.
    private static func seamEnd(from v0: CGPoint, through v1: CGPoint, radius: CGFloat) -> CGPoint {
        let dx = v1.x - v0.x
        let dy = v1.y - v0.y
        let l = max(hypot(dx, dy), 1e-6)
        let ux = dx / l
        let uy = dy / l
        // Solve |v1 + t·u - (50,50)|^2 = radius^2 for t > 0.
        let ax = v1.x - 50
        let ay = v1.y - 50
        let b = ax * ux + ay * uy
        let c = ax * ax + ay * ay - radius * radius
        let disc = max(0, b * b - c)
        let t = -b + sqrt(disc)
        return CGPoint(x: v1.x + t * ux, y: v1.y + t * uy)
    }
}

// MARK: - Previews

#Preview("Open") {
    ApertureIrisView(rc: ApertureIrisView.openValue, rot: 0)
        .frame(width: 200, height: 200)
        .padding()
}

#Preview("Shut") {
    ApertureIrisView(rc: ApertureIrisView.shutValue, rot: -0.55)
        .frame(width: 200, height: 200)
        .padding()
}

#Preview("Mid") {
    ApertureIrisView(rc: 10, rot: 0.4)
        .frame(width: 200, height: 200)
        .padding()
}
