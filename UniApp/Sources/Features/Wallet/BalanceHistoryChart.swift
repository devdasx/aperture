import SwiftUI

/// Custom-drawn sparkline balance-over-time chart for the wallet home.
///
/// **Design intent (one sentence per Rule #2 §D.1):** show the user
/// the shape of their balance changing through time — calm,
/// monochrome, undeniable, with the same silky scrub-feedback
/// character the Stabro reference encodes — so they can read "what
/// happened to my money?" in one glance and feel it under their
/// finger when they explore.
///
/// **2026-06-09 redesign.** Replaces the original SwiftUI `Charts`
/// LineMark surface with a hand-drawn Catmull-Rom-spline sparkline,
/// a translucent gradient fill under the curve, a custom 6-pill
/// period selector, a `DragGesture(minimumDistance: 0)` scrub layer
/// with a thin guide line + filled point + outer ring, and slope-
/// driven Core Haptics scrub feedback via `UniHapticEngine`'s new
/// `playScrubTick(intensity:)` / `playScrubRelease()` entry points.
/// The shape this draws now is the wallet's, the feel is Apple's.
///
/// **2026-06-09 follow-on tuning.** The original ship used quadratic
/// midpoint smoothing ported from the Stabro reference. That algorithm
/// reads silky on Stabro's dense intraday price data; on Aperture's
/// sparse balance-history data (3–5 transactions over the visible
/// range) it produced a series of visibly-joined arcs at each
/// inflection. Switched to **Catmull-Rom-to-cubic-Bézier**
/// interpolation: the curve still passes through every data point
/// exactly (no smoothing-away of the actual transactions — Rule #2
/// §A.7 honesty), but adjacent segments now share C¹-continuous
/// tangents so the line reads as one flowing shape rather than as
/// joined arcs. Endpoints clamp to zero tangent so the curve enters
/// and exits horizontally rather than overshooting at the boundaries.
///
/// **Range persistence (2026-06-09).** The selected period now
/// persists across launches via `@AppStorage` with the storage key
/// `"walletHomeBalanceHistoryRange"`. Default on first launch is
/// `.all` (show the user the whole shape of their wallet's history,
/// not just this week).
///
/// **Layer (Rule #2 §B.3):** content. No `.glassEffect()`. The
/// chart is data, not chrome — the two glass layers already in the
/// home (toolbar pill + action triplet) preserve the §B.3 two-layer
/// maximum unchanged.
///
/// **Visual register.**
/// - Single graphite stroke (`UniColors.Text.primary`) — Aperture is
///   monochrome (Rule #16 §B). Direction shows in the delta caption
///   only; the line never goes green or red.
/// - A 25%→0% gradient fill in the same color closes the curve at the
///   baseline so the area reads as glow, not as a hard fill.
/// - No axis chrome, no grid, no tick labels. The hero number above
///   the row already reports the absolute value; the chart's job is
///   the SHAPE.
/// - A pill-style period selector (1D / 1W / 1M / 1Y / All) — capsule
///   highlight on the active item, `UniColors.Background.tertiary`
///   fill, `.snappy(0.2)` animation on switch.
/// - One honest caveat line under the selector: "Valued at today's
///   prices." Rule #2 §A.7. Restrained — a footnote, not a banner.
///
/// **Scrub interaction.** Drag anywhere on the chart to pull a 1pt
/// vertical guide line + a 10pt filled `Circle` + an 18pt 2pt outer
/// ring at the nearest sample point. `UniHapticEngine.shared
/// .playScrubTick(intensity:)` fires per index change with intensity
/// = function of the local slope (steeper → stronger). Releasing
/// triggers `playScrubRelease()` — the soft "you stopped" thud — and
/// the caption returns from the scrubbed-point readout to the
/// resting signed delta.
///
/// **Time always flows left to right.** Both the sparkline canvas
/// and the period pill row override `\.layoutDirection` to
/// `.leftToRight`. Aperture's outer layout direction still flips
/// for Arabic / Hebrew / Persian / Urdu via the app-root binding
/// (Rule #11) — the chart is the explicit Rule #11 §C carve-out for
/// "display-only English content with a strict ordinal reading
/// order." Time order is data, not language.
///
/// **Empty state (Rule #2 §A.2).** A wallet with zero in-range
/// transactions doesn't get a fake flat line. It gets a calm
/// one-line caption explaining what will appear here — the same
/// register as the empty Holdings and empty Activity surfaces.
struct BalanceHistoryChart: View {
    let transactions: [TransactionRecord]
    let currentBalances: [TokenBalanceRecord]
    let currencyCode: String

    /// Persisted range selection. Default `.all` so a first-launch
    /// user sees the full shape of their wallet's history; on
    /// subsequent launches we honor whatever they last picked. The
    /// storage key is namespaced under `walletHome*` so future chart
    /// surfaces (asset detail, swap preview) can have their own
    /// independent persistence without collision.
    @AppStorage("walletHomeBalanceHistoryRange")
    private var selectedRangeRaw: String = BalanceHistoryRange.all.rawValue

    /// Computed binding over the raw `@AppStorage` string. Falls back
    /// to `.all` if the persisted raw value can't be decoded — covers
    /// the forward-compat case where we ever rename or remove a case.
    private var selectedRange: Binding<BalanceHistoryRange> {
        Binding(
            get: { BalanceHistoryRange(rawValue: selectedRangeRaw) ?? .all },
            set: { selectedRangeRaw = $0.rawValue }
        )
    }

    /// Convenience read for the call sites that only need the value
    /// (reconstructor input, accessibility readout, range-suffix
    /// caption). The picker itself takes the `Binding` above.
    private var currentRange: BalanceHistoryRange {
        BalanceHistoryRange(rawValue: selectedRangeRaw) ?? .all
    }

    @State private var scrubIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            // Reconstruct on body — pure function, cheap enough to
            // run per body evaluation. SwiftData @Query already
            // throttles wallet-home re-renders to actual data
            // changes; we don't memoize further.
            let points = BalanceHistoryReconstructor.reconstruct(
                transactions: transactions,
                currentBalances: currentBalances,
                range: currentRange
            )

            if points.count < 2 {
                emptyState
            } else {
                deltaCaption(points: points)
                // Negative horizontal padding so ONLY the sparkline
                // bleeds out beyond the card's normal inset
                // (`UniSpacing.l`) to land at 5pt from the card
                // edge. Computed as `-(UniSpacing.l - 5)` so the
                // visible curve has exactly 5pt of edge gap. Delta
                // caption above and period pill below stay at the
                // normal padding so they align with everything else
                // inside the card. Per 2026-06-09 user direction:
                // "the padding 5 pixels should be only for chart,
                // for other layouts in inside the card should be
                // same as before."
                SparklineChart(
                    points: points.map { fiatAsDouble($0.fiat) },
                    scrubIndex: $scrubIndex
                )
                .frame(height: 140)
                .padding(.horizontal, -(UniSpacing.l - 5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Balance history chart"))
                .accessibilityValue(chartAccessibilityValue(points: points))
                ChartPeriodPill(selection: selectedRange)
            }
        }
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - Delta caption

    /// Caption above the curve. When scrubbing — shows the
    /// scrubbed-point's fiat value + its relative timestamp. When
    /// at rest — shows the range's signed delta from leading-edge
    /// to trailing-edge with a directional color hint on the delta
    /// only (the line itself stays monochrome). Rule #16 §B.
    @ViewBuilder
    private func deltaCaption(points: [BalancePoint]) -> some View {
        if let index = scrubIndex,
           index >= 0,
           index < points.count
        {
            // Scrubbing mode — historical readout at the
            // selected timestamp.
            let nearest = points[index]
            HStack(spacing: UniSpacing.s) {
                Text(WalletFormatting.fiat(nearest.fiat, currencyCode: currencyCode))
                    .font(UniTypography.headline)
                    .foregroundStyle(UniColors.Text.primary)
                    .monospacedDigit()
                Text(WalletFormatting.relativeTime(nearest.timestamp))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                Spacer(minLength: 0)
            }
        } else if let first = points.first, let last = points.last {
            // Resting mode — signed delta centered under the hero
            // amount per 2026-06-09 user direction. Arrow glyph and
            // range-suffix ("today" / "this week" / etc.) removed —
            // the period pill below already names the active range,
            // and the colored sign on the delta already conveys
            // direction. One number, calm.
            let delta = last.fiat - first.fiat
            let isUp = delta > 0
            let isDown = delta < 0
            Text(deltaText(delta: delta))
                .font(UniTypography.footnote.weight(.semibold))
                .foregroundStyle(deltaColor(isUp: isUp, isDown: isDown))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func deltaText(delta: Decimal) -> String {
        let sign: String
        if delta > 0 { sign = "+" } else if delta < 0 { sign = "−" } else { sign = "" }
        let magnitude = abs(delta)
        return sign + WalletFormatting.fiat(magnitude, currencyCode: currencyCode)
    }

    private func deltaColor(isUp: Bool, isDown: Bool) -> Color {
        if isUp { return UniColors.Status.successForeground }
        if isDown { return UniColors.Status.errorForeground }
        return UniColors.Text.tertiary
    }

    /// Localized "this week" / "this month" / "this year" / "all
    /// time" / "today" suffix on the resting delta caption.
    private var rangeLabel: LocalizedStringKey {
        switch currentRange {
        case .day:   return "today"
        case .week:  return "this week"
        case .month: return "this month"
        case .year:  return "this year"
        case .all:   return "all time"
        }
    }

    // MARK: - Empty state

    // Note: the "Valued at today's prices." caveat row was removed
    // on the user's 2026-06-09 direction. The honesty principle
    // (Rule #2 §A.7) still applies — the chart's reconstruction
    // semantics live in `BalanceHistoryReconstructor`'s doc-comment
    // for future readers, but the user prefers a clean visual
    // surface without the inline disclosure.

    /// Calm empty state — no fake flat line, no chevron-down
    /// chrome. Same register as the empty Holdings + empty Activity
    /// surfaces on this screen.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            UniHeadline(text: "Balance history")
            UniFootnote(
                text: "Your balance changes will appear here as transactions confirm on-chain.",
                alignment: .leading
            )
        }
    }

    // MARK: - Helpers

    /// VoiceOver-friendly summary. Reads the start fiat, end fiat,
    /// the signed delta, and the range — enough for a screen-reader
    /// user to understand "what shape" without seeing the curve.
    private func chartAccessibilityValue(points: [BalancePoint]) -> Text {
        guard let first = points.first, let last = points.last else {
            return Text("No data")
        }
        let start = WalletFormatting.fiat(first.fiat, currencyCode: currencyCode)
        let end = WalletFormatting.fiat(last.fiat, currencyCode: currencyCode)
        let delta = deltaText(delta: last.fiat - first.fiat)
        return Text("Range \(currentRange.shortLabel). From \(start) to \(end). Change \(delta).")
    }

    /// Bridge `Decimal` → `Double` for the canvas-space math the
    /// sparkline does. We don't need `Decimal` precision for the
    /// y-axis — the chart's y-range is normalized to its own band
    /// before drawing, so floating-point drift is invisible at this
    /// scale. The hero number above the row still uses `Decimal`
    /// for the absolute readout.
    private func fiatAsDouble(_ fiat: Decimal) -> Double {
        NSDecimalNumber(decimal: fiat).doubleValue
    }
}

// MARK: - SparklineChart

/// The custom-drawn sparkline — quadratic-Bézier curve, gradient
/// fill below, scrub gesture with guide line + point + outer ring,
/// slope-driven Core Haptics on tick changes.
///
/// Ported from the Stabro reference (`SparklineChartView.swift`)
/// with the following adaptations for Aperture's contract:
///
/// - Stroke + gradient seed use `UniColors.Text.primary` (Rule #4),
///   not a green `Color(hex:)`. Aperture's chart is monochrome.
/// - Scrub guide line uses `UniColors.Text.tertiary` at the Stabro
///   opacity 0.4. Outer ring uses `UniColors.Text.primary` at the
///   Stabro opacity 0.3.
/// - Haptics route through `UniHapticEngine.shared.playScrubTick`
///   / `playScrubRelease` (Rule #10 §D — Core Haptics imports only
///   in `UniHapticEngine.swift`).
/// - `.environment(\.layoutDirection, .leftToRight)` per Rule #11
///   §C — time-ordered display content stays L→R in every locale.
private struct SparklineChart: View {

    /// One value per sample point, in the order the curve should
    /// read left-to-right. The caller is responsible for sorting
    /// (the `BalanceHistoryReconstructor` already returns oldest-
    /// to-newest). At least two points required for a meaningful
    /// curve; fewer renders a flat line.
    let points: [Double]

    /// Index of the currently-scrubbed sample, or `nil` at rest.
    /// Bound to the parent so it can swap the delta caption while
    /// the user explores.
    @Binding var scrubIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let canvasPoints = normalizedPoints(in: size)

            ZStack {
                // Gradient fill — the same quadratic path, closed
                // at the baseline, filled with a top-to-bottom
                // fade from 25% to 0% of the stroke color. This is
                // what makes the area read as glow rather than as
                // a hard fill.
                gradientFill(points: canvasPoints, in: size)

                // The sparkline stroke itself. 2pt, rounded line
                // caps + joins — same weight as the Stabro pattern
                // so the curve reads as silky regardless of how
                // jagged the source data is.
                sparklinePath(points: canvasPoints)
                    .stroke(
                        UniColors.Text.primary,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                // Scrub cursor — surfaces only while the user is
                // actively dragging. Three layers (guide line +
                // filled dot + outer ring) compose the affordance.
                if let index = scrubIndex,
                   index >= 0,
                   index < canvasPoints.count
                {
                    let pt = canvasPoints[index]
                    // Vertical guide line — 1pt, full canvas
                    // height, tertiary text color at 0.4 opacity.
                    // Subtle enough to suggest "selected x", not
                    // to compete with the curve.
                    Rectangle()
                        .fill(UniColors.Text.tertiary.opacity(0.4))
                        .frame(width: 1)
                        .position(x: pt.x, y: size.height / 2)
                    // Outer ring — 18pt circle, 2pt stroke, primary
                    // text color at 0.3 opacity. The "you are here"
                    // halo around the filled dot.
                    Circle()
                        .stroke(UniColors.Text.primary.opacity(0.3), lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .position(pt)
                    // Filled dot — 10pt circle in the primary text
                    // color. The discrete selection mark on the
                    // curve.
                    Circle()
                        .fill(UniColors.Text.primary)
                        .frame(width: 10, height: 10)
                        .position(pt)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = indexForX(value.location.x, in: size)
                        guard index != scrubIndex else { return }
                        scrubIndex = index
                        let intensity = hapticIntensity(at: index)
                        UniHapticEngine.shared.playScrubTick(intensity: intensity)
                    }
                    .onEnded { _ in
                        scrubIndex = nil
                        UniHapticEngine.shared.playScrubRelease()
                    }
            )
        }
        // Time order is data, not language — pin the canvas to L→R
        // in every locale (Rule #11 §C carve-out).
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Scrub math

    /// Maps a canvas-space x position to the nearest sample index.
    /// The drag gesture's `value.location.x` arrives in canvas
    /// space because the chart is wrapped in `GeometryReader`.
    private func indexForX(_ x: CGFloat, in size: CGSize) -> Int {
        guard points.count > 1 else { return 0 }
        let fraction = x / size.width
        let clamped = max(0, min(1, fraction))
        return Int(round(clamped * CGFloat(points.count - 1)))
    }

    /// Computes the haptic intensity for the tick at `index` from
    /// the local slope between the previous sample and this one.
    /// Steeper change → stronger tick. The mapping comes from the
    /// Stabro reference: `intensity = min(0.8, 0.15 + slope*2.2)`
    /// where `slope = |curr - prev|`. The chart's y-domain has
    /// already been normalized to its own [min, max] band so the
    /// slope is unit-free.
    private func hapticIntensity(at index: Int) -> Float {
        guard points.count > 1 else { return 0.3 }
        let safeIndex = max(0, min(points.count - 1, index))
        let prev = safeIndex > 0 ? points[safeIndex - 1] : points[safeIndex]
        let curr = points[safeIndex]
        // Slope is computed in the y-domain's own units; we
        // normalize to its overall range so the intensity is
        // comparable across days vs. years vs. flat wallets.
        let minVal = points.min() ?? 0
        let maxVal = points.max() ?? 1
        let range = max(maxVal - minVal, 0.0001)
        let normalizedSlope = abs(curr - prev) / range
        return Float(min(0.8, 0.15 + normalizedSlope * 2.2))
    }

    // MARK: - Path math

    /// Project the data series into canvas space with a 10% top
    /// and bottom padding band so the curve never grazes the edges
    /// of the chart frame. Empty input returns an empty array; the
    /// caller renders nothing in that case.
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard points.count > 1 else { return [] }
        let minVal = points.min() ?? 0
        let maxVal = points.max() ?? 1
        let range = maxVal - minVal
        // 10% top + 10% bottom padding — the Stabro `padding: 0.1`
        // constant ported verbatim. Wallet balance histories sit in
        // a band; the padding makes the curve breathe.
        let padding: CGFloat = 0.1
        return points.enumerated().map { index, value in
            let x = CGFloat(index) / CGFloat(points.count - 1) * size.width
            let normalized = range > 0 ? (CGFloat(value - minVal) / CGFloat(range)) : 0.5
            // Canvas y is top-down. We map normalized 0 → bottom of
            // the padded band; normalized 1 → top of the padded
            // band.
            let y = size.height - (normalized * size.height * (1 - 2 * padding) + size.height * padding)
            return CGPoint(x: x, y: y)
        }
    }

    /// Smooth interpolating spline through every sample point, drawn
    /// as a sequence of cubic-Bézier segments derived from a uniform
    /// Catmull-Rom spline.
    ///
    /// **Why Catmull-Rom and not quadratic-midpoint.** The original
    /// ship used the quadratic-midpoint trick (route each pair via
    /// its shared midpoint as a control vertex). That algorithm is
    /// fast and reads silky on dense data — but on sparse data (a
    /// handful of transactions over the visible range) each adjacent
    /// pair produces its own arc that bends visibly at the data
    /// vertex, so the line reads as a series of joined arcs rather
    /// than as one flowing shape.
    ///
    /// Catmull-Rom passes through every data point exactly (no
    /// smoothing-away of the actual transactions — Rule #2 §A.7
    /// honesty) AND gives every interior point a tangent derived
    /// from its neighbors `(p[i+1] − p[i−1]) / 6`, so adjacent
    /// segments share C¹-continuous tangents. The result reads as
    /// one continuous curve in the user's hand.
    ///
    /// **Endpoint clamp.** At the boundaries we don't have a
    /// `p[i−1]` (or `p[i+2]`) to compute the tangent from. The clean
    /// clamp is to substitute the endpoint itself — i.e.
    /// `p[−1] := p[0]` and `p[n] := p[n−1]` — which yields a zero
    /// tangent at each end. The curve enters and exits the canvas
    /// horizontally instead of overshooting; for a balance history
    /// that reads as "settled at the start, settled at the end."
    private func sparklinePath(points canvasPoints: [CGPoint]) -> Path {
        Path { path in
            guard let first = canvasPoints.first else { return }
            path.move(to: first)
            appendCatmullRomSegments(to: &path, points: canvasPoints)
        }
    }

    /// Gradient fill — same Catmull-Rom curve as the stroke (so the
    /// fill sits flush under it), then closed down to the baseline
    /// at both ends with straight vertical drops so the area between
    /// the curve and the bottom of the canvas can be filled with a
    /// vertical fade. The closing drops stay straight on purpose —
    /// smoothing them would round the bottom corners of the fill and
    /// break the "this is the area under the curve, baseline is
    /// flat" reading.
    private func gradientFill(points canvasPoints: [CGPoint], in size: CGSize) -> some View {
        Path { path in
            guard let first = canvasPoints.first, let last = canvasPoints.last else { return }
            path.move(to: first)
            appendCatmullRomSegments(to: &path, points: canvasPoints)
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        .fill(
            LinearGradient(
                colors: [
                    UniColors.Text.primary.opacity(0.25),
                    UniColors.Text.primary.opacity(0.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    /// Shared Catmull-Rom-to-cubic-Bézier emitter. The path must
    /// already be `move(to:)` the first point; this appends one
    /// `addCurve` segment per consecutive pair.
    ///
    /// The conversion from Catmull-Rom to cubic Bézier:
    /// ```
    /// For each segment from p[i] to p[i+1] (with p[i−1] and p[i+2]
    /// as neighbors):
    ///   tangentAtI  = (p[i+1] − p[i−1]) / 6
    ///   tangentAtI1 = (p[i+2] − p[i  ]) / 6
    ///   cp1 = p[i  ] + tangentAtI
    ///   cp2 = p[i+1] − tangentAtI1
    ///   path.addCurve(to: p[i+1], control1: cp1, control2: cp2)
    /// ```
    /// At the boundaries `p[−1]` and `p[n]` are clamped to `p[0]`
    /// and `p[n−1]` respectively, producing a zero tangent at each
    /// end.
    private func appendCatmullRomSegments(to path: inout Path, points canvasPoints: [CGPoint]) {
        let count = canvasPoints.count
        guard count > 1 else { return }
        for i in 0..<(count - 1) {
            let previous = i == 0 ? canvasPoints[i] : canvasPoints[i - 1]
            let current = canvasPoints[i]
            let next = canvasPoints[i + 1]
            let afterNext = i + 2 < count ? canvasPoints[i + 2] : next

            let oneSixth: CGFloat = 1.0 / 6.0
            let tangentAtCurrent = CGPoint(
                x: (next.x - previous.x) * oneSixth,
                y: (next.y - previous.y) * oneSixth
            )
            let tangentAtNext = CGPoint(
                x: (afterNext.x - current.x) * oneSixth,
                y: (afterNext.y - current.y) * oneSixth
            )
            let controlOne = CGPoint(
                x: current.x + tangentAtCurrent.x,
                y: current.y + tangentAtCurrent.y
            )
            let controlTwo = CGPoint(
                x: next.x - tangentAtNext.x,
                y: next.y - tangentAtNext.y
            )
            path.addCurve(to: next, control1: controlOne, control2: controlTwo)
        }
    }
}

// MARK: - ChartPeriodPill

/// The pill-style period selector. An `HStack` of `Button` rows
/// per `BalanceHistoryRange.allCases`. The active range gets a
/// capsule background in `UniColors.Background.tertiary`; the
/// others render as plain text in `UniColors.Text.tertiary`.
///
/// Ported from the Stabro reference (`ChartPeriodSelector.swift`)
/// with Aperture's token + haptic contract.
///
/// Rule #19 §C carve-out applies: these are **selection chips
/// inside a picker**, not CTAs that commit the user to a flow.
/// Plain `Button` + `.buttonStyle(.plain)` is the right primitive
/// here; forcing them through `UniButton` would attach the glass
/// material treatment to what should be flat selection chrome.
private struct ChartPeriodPill: View {
    @Binding var selection: BalanceHistoryRange

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BalanceHistoryRange.allCases, id: \.self) { period in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selection = period
                    }
                } label: {
                    Text(period.shortLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            selection == period
                                ? UniColors.Text.primary
                                : UniColors.Text.tertiary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selection == period {
                                Capsule()
                                    .fill(UniColors.Background.tertiary)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(period.shortLabel))
                .accessibilityAddTraits(selection == period ? [.isSelected] : [])
            }
        }
        // Period order is always 1H→All — never mirror under RTL.
        .environment(\.layoutDirection, .leftToRight)
        // Picker-class state change — Rule #10 §A.
        .uniHaptic(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Balance history range"))
    }
}
