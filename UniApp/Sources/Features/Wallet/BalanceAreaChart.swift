import SwiftUI

/// The flagship balance-card area chart, transcribed from the design
/// handoff (`design_handoff_balance_card 2/README.md` §Chart spec and
/// the inline `chart()` JS in `Aperture Balance Card.html`).
///
/// **Design intent (Rule #2 §D.1):** draw the *shape* of the user's
/// balance through time as one calm, flowing, semantically-colored curve
/// — green when the range gained, red when it lost, a dead-straight
/// neutral line when it didn't move — so the user reads "what happened to
/// my money" in a glance and can pull a live readout under their finger.
///
/// **Faithful to the handoff, line for line.**
/// - **Smoothing:** Catmull-Rom → cubic Bézier through every point
///   (`(p[i+1]−p[i−1])/6` tangents), the exact algorithm the reference
///   `chart()` emits. Passes through every data vertex (no transaction
///   smoothed away — Rule #2 §A.7 honesty).
/// - **Stroke:** `2.6` non-scaling width, round caps + joins.
/// - **Area fill:** a vertical gradient in the stroke hue, top opacity
///   `0.20` (gain) / `0.18` (loss) / `0.06` (flat), fading to `0` at the
///   baseline.
/// - **End-point marker:** a solid `4.5`pt dot + a `9`pt halo at `18%`
///   opacity, both in the stroke color.
/// - **Dark-mode glow:** a gaussian-blur merge (σ≈3) under the stroke —
///   ON for gain/loss in dark, OFF for flat and OFF in light (handoff:
///   "Dark chart has the glow; light chart does not"). Expressed with the
///   native `.blur(radius:)` + composite, which is the SwiftUI form of
///   the SVG `feGaussianBlur` merge (NOT a Rule #3 glass substitute — this
///   is a data-viz glow on a `Shape`, the §C structural carve-out).
/// - **Flat state:** a perfectly straight horizontal line centered in the
///   chart area — no waves, no glow — per the handoff (`FLAT` series at a
///   constant mid value).
/// - **Full-bleed:** the chart bleeds to the card's edges (the card pads
///   it with negative insets); height ≈ 120pt.
///
/// **Color (Rule #4):** every stroke / fill / cursor color resolves
/// through `UniColors.BalanceCard.*(sign, scheme)`. The chart reads the
/// app's `\.colorScheme` so the card adapts (dark chart in dark mode,
/// light chart in light) exactly like the handoff's two-column reference.
///
/// **Scrub (handoff §Interactions):** dragging publishes the touched
/// point's index through `onScrub` (the card maps it to the value the
/// hero renders with the native `.contentTransition(.numericText())`).
/// A vertical hairline + a dot at the touch point track the finger, both
/// in the chart color. The number snaps **per data point** (not per
/// pixel), matching the Stocks/Wallet feel; a `tap` haptic fires as the
/// hairline crosses each point, `impactLight` on scrub-begin (fired by
/// the card via the `onScrubBegin` callback).
///
/// **Time always flows left → right** — the canvas and any cursor pin
/// `\.layoutDirection` to `.leftToRight` (Rule #11 §C: time order is data,
/// not language; the chrome around the chart still flips for RTL locales).
struct BalanceAreaChart: View {
    /// One value per sample, oldest → newest (the caller sorts).
    let values: [Double]
    /// Per-point horizontal position in `[0, 1]` from each sample's
    /// TIMESTAMP (Mode B real-time x-axis) — parallel to `values`. A one-hour
    /// gap and a one-year gap occupy proportional width. Empty / wrong-length
    /// falls back to equal-index spacing (a flat baseline looks the same).
    var xFractions: [Double] = []
    /// Precomputed min / max so the per-drag normalization never rescans.
    let minValue: Double
    let maxValue: Double
    /// The chart's sign — drives stroke / fill / glow color together.
    let sign: UniColors.BalanceCard.Sign
    /// Published per scrub-index change (and `nil` on release).
    var onScrub: (Int?) -> Void = { _ in }
    /// Fired once when a scrub drag begins (the card plays `impactLight`).
    var onScrubBegin: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    /// The scrubbed index — LOCAL `@State` so a tick invalidates only
    /// this view, never the card (the 2026-06-13 long-scrub-freeze fix).
    @State private var scrubIndex: Int?

    /// Canvas y-padding band (10% top + bottom) so the curve breathes.
    private let padding: CGFloat = 0.1

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let stroke = UniColors.BalanceCard.chartStroke(sign, colorScheme)
            let glow = UniColors.BalanceCard.chartGlow(sign, colorScheme)
            ZStack {
                // The static curve — invariant during a scrub. Extracted
                // to an `Equatable` subview + `.drawingGroup()` so a drag
                // tick (which moves only the cursor) never recomputes the
                // two O(N) Bézier paths or re-rasterizes them, and so
                // list scrolling composites a flat texture rather than
                // re-stroking up to ~2,000 points per frame.
                BalanceAreaCurve(
                    values: values,
                    xFractions: xFractions,
                    minValue: minValue,
                    maxValue: maxValue,
                    sign: sign,
                    scheme: colorScheme,
                    padding: padding
                )
                .equatable()
                .drawingGroup()

                // Scrub cursor — the only live-vector element per tick.
                if let index = scrubIndex,
                   values.count > 1,
                   index >= 0,
                   index < values.count {
                    let pt = cursorPoint(index: index, in: size)
                    Rectangle()
                        .fill(stroke.opacity(0.5))
                        .frame(width: 1.5)
                        .position(x: pt.x, y: size.height / 2)
                    Circle()
                        .fill(stroke.opacity(0.18))
                        .frame(width: 18, height: 18)
                        .position(pt)
                    Circle()
                        .fill(stroke)
                        .frame(width: 9, height: 9)
                        .position(pt)
                }
            }
            // The dark-mode glow halo: a blurred copy of the stroke under
            // the crisp one. SwiftUI form of the SVG feGaussianBlur merge.
            .compositingGroup()
            .shadow(
                color: glow ? stroke.opacity(0.55) : Color.clear,
                radius: glow ? 4 : 0
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if scrubIndex == nil { onScrubBegin() }
                        let index = indexForX(value.location.x, in: size)
                        guard index != scrubIndex else { return }
                        scrubIndex = index
                        onScrub(index)
                        UniHapticEngine.shared.playScrubTick(intensity: hapticIntensity(at: index))
                    }
                    .onEnded { _ in
                        scrubIndex = nil
                        onScrub(nil)
                        UniHapticEngine.shared.playScrubRelease()
                    }
            )
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Cursor math (O(1) per tick)

    private func cursorPoint(index: Int, in size: CGSize) -> CGPoint {
        let count = values.count
        let useTime = xFractions.count == count
        let x: CGFloat = {
            if useTime { return CGFloat(xFractions[index]) * size.width }
            return count > 1 ? CGFloat(index) / CGFloat(count - 1) * size.width : 0
        }()
        let range = maxValue - minValue
        let normalized = range > 0 ? (CGFloat(values[index] - minValue) / CGFloat(range)) : 0.5
        let y = size.height - (normalized * size.height * (1 - 2 * padding) + size.height * padding)
        return CGPoint(x: x, y: y)
    }

    private func indexForX(_ x: CGFloat, in size: CGSize) -> Int {
        guard values.count > 1 else { return 0 }
        let clamped = Double(max(0, min(1, x / max(size.width, 1))))
        // Time-spaced hit-test: pick the sample whose TIME fraction is nearest
        // the touch, so an unevenly-spaced curve maps the finger correctly.
        // Falls back to index spacing when no fractions were supplied.
        if xFractions.count == values.count {
            var best = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (i, f) in xFractions.enumerated() {
                let d = abs(f - clamped)
                if d < bestDist { bestDist = d; best = i }
            }
            return best
        }
        return Int(round(clamped * Double(values.count - 1)))
    }

    /// Slope-driven scrub-tick intensity (steeper change → stronger
    /// tick), normalized to the chart's own band so it's comparable
    /// across ranges. Ported from the original Stabro mapping.
    private func hapticIntensity(at index: Int) -> Float {
        guard values.count > 1 else { return 0.3 }
        let safeIndex = max(0, min(values.count - 1, index))
        let prev = safeIndex > 0 ? values[safeIndex - 1] : values[safeIndex]
        let curr = values[safeIndex]
        let range = max(maxValue - minValue, 0.0001)
        let normalizedSlope = abs(curr - prev) / range
        return Float(min(0.8, 0.15 + normalizedSlope * 2.2))
    }
}

// MARK: - BalanceAreaCurve (static, equatable)

/// The invariant gradient-fill + Catmull-Rom stroke + end-point marker.
/// Split out + `.equatable()` so a scrub tick skips its body, and so
/// `.drawingGroup()` rasterizes it once (only re-rasterizing when the
/// data actually changes). Conforms to the exact handoff geometry.
private struct BalanceAreaCurve: View, Equatable {
    let values: [Double]
    /// Per-point horizontal position in `[0, 1]` from each sample's TIMESTAMP
    /// (real-time x-axis). Empty / wrong-length falls back to index spacing.
    let xFractions: [Double]
    let minValue: Double
    let maxValue: Double
    let sign: UniColors.BalanceCard.Sign
    let scheme: ColorScheme
    let padding: CGFloat

    nonisolated static func == (lhs: BalanceAreaCurve, rhs: BalanceAreaCurve) -> Bool {
        lhs.minValue == rhs.minValue
            && lhs.maxValue == rhs.maxValue
            && lhs.sign == rhs.sign
            && lhs.scheme == rhs.scheme
            && lhs.values == rhs.values
            && lhs.xFractions == rhs.xFractions
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let canvasPoints = normalizedPoints(in: size)
            let stroke = UniColors.BalanceCard.chartStroke(sign, scheme)
            let fillHue = UniColors.BalanceCard.chartFillHue(sign, scheme)
            let fillTop = UniColors.BalanceCard.chartFillTopOpacity(sign)
            ZStack {
                // Gradient area fill — curve closed at the baseline.
                areaPath(points: canvasPoints, in: size)
                    .fill(
                        LinearGradient(
                            colors: [fillHue.opacity(fillTop), fillHue.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                // The stroke — 2.6pt, round caps/joins.
                strokePath(points: canvasPoints)
                    .stroke(
                        stroke,
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                    )
                // End-point marker — 4.5pt dot + 9pt halo @18%.
                if let end = canvasPoints.last {
                    Circle()
                        .fill(stroke.opacity(0.18))
                        .frame(width: 18, height: 18)
                        .position(end)
                    Circle()
                        .fill(stroke)
                        .frame(width: 9, height: 9)
                        .position(end)
                }
            }
        }
    }

    // MARK: - Path math

    /// Project the series into canvas space with the 10% top/bottom band.
    /// **Flat sign** ignores the (noisy) series and pins every point to
    /// the vertical center — the handoff's "perfectly straight horizontal
    /// line centered" flat state.
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else {
            // One value (or none) → a centered flat segment edge to edge.
            return [
                CGPoint(x: 0, y: size.height / 2),
                CGPoint(x: size.width, y: size.height / 2)
            ]
        }
        let useTime = xFractions.count == values.count
        func xPosition(_ index: Int) -> CGFloat {
            (useTime ? CGFloat(xFractions[index]) : CGFloat(index) / CGFloat(values.count - 1)) * size.width
        }
        if sign == .flat {
            let y = size.height / 2
            return values.indices.map { index in
                CGPoint(x: xPosition(index), y: y)
            }
        }
        let range = maxValue - minValue
        return values.enumerated().map { index, value in
            let x = xPosition(index)
            let normalized = range > 0 ? (CGFloat(value - minValue) / CGFloat(range)) : 0.5
            let y = size.height - (normalized * size.height * (1 - 2 * padding) + size.height * padding)
            return CGPoint(x: x, y: y)
        }
    }

    private func strokePath(points canvasPoints: [CGPoint]) -> Path {
        Path { path in
            guard let first = canvasPoints.first else { return }
            path.move(to: first)
            appendLinearSegments(to: &path, points: canvasPoints)
        }
    }

    private func areaPath(points canvasPoints: [CGPoint], in size: CGSize) -> Path {
        Path { path in
            guard let first = canvasPoints.first, let last = canvasPoints.last else { return }
            path.move(to: first)
            appendLinearSegments(to: &path, points: canvasPoints)
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
    }

    /// **Linear step rendering (2026-06-19 Bug 1 fix).** The balance is a
    /// step function — constant between transactions, a jump at each — so the
    /// reconstructor emits a near-vertical before/after pair per transaction.
    /// A smoothing spline (the old uniform Catmull-Rom) overshoots a
    /// near-vertical pair (control points shoot past the data → the loop at a
    /// step top) AND assumes equal x spacing, which the time-proportional
    /// `xFractions` violate (→ waviness). Straight segments draw the step
    /// EXACTLY: clean horizontal runs, clean vertical risers, zero overshoot.
    /// The 2.6 pt round caps + joins still soften the corners so it reads
    /// premium. (A monotone/PCHIP spline is NOT an option — the vertical
    /// risers share an x, which strictly-increasing-x splines can't represent.)
    private func appendLinearSegments(to path: inout Path, points canvasPoints: [CGPoint]) {
        for point in canvasPoints.dropFirst() {
            path.addLine(to: point)
        }
    }
}
