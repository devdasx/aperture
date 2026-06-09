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
/// LineMark surface with a hand-drawn quadratic-Bézier sparkline,
/// a translucent gradient fill under the curve, a custom 6-pill
/// period selector, a `DragGesture(minimumDistance: 0)` scrub layer
/// with a thin guide line + filled point + outer ring, and slope-
/// driven Core Haptics scrub feedback via `UniHapticEngine`'s new
/// `playScrubTick(intensity:)` / `playScrubRelease()` entry points.
/// The shape this draws now is the wallet's, the feel is Apple's.
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

    @State private var selectedRange: BalanceHistoryRange = .week
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
                range: selectedRange
            )

            if points.count < 2 {
                emptyState
            } else {
                deltaCaption(points: points)
                SparklineChart(
                    points: points.map { fiatAsDouble($0.fiat) },
                    scrubIndex: $scrubIndex
                )
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Balance history chart"))
                .accessibilityValue(chartAccessibilityValue(points: points))
                ChartPeriodPill(selection: $selectedRange)
                caveatLine
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
            // Resting mode — signed delta across the range. Color
            // hints the direction; magnitude is the magnitude.
            let delta = last.fiat - first.fiat
            let isUp = delta > 0
            let isDown = delta < 0
            HStack(spacing: UniSpacing.xs) {
                if isUp {
                    Image(systemName: "arrow.up.right")
                        .font(UniTypography.footnote.weight(.semibold))
                        .foregroundStyle(UniColors.Status.successForeground)
                        .accessibilityHidden(true)
                } else if isDown {
                    Image(systemName: "arrow.down.right")
                        .font(UniTypography.footnote.weight(.semibold))
                        .foregroundStyle(UniColors.Status.errorForeground)
                        .accessibilityHidden(true)
                }
                Text(deltaText(delta: delta))
                    .font(UniTypography.footnote.weight(.semibold))
                    .foregroundStyle(deltaColor(isUp: isUp, isDown: isDown))
                    .monospacedDigit()
                Text(rangeLabel)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                Spacer(minLength: 0)
            }
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
        switch selectedRange {
        case .day:   return "today"
        case .week:  return "this week"
        case .month: return "this month"
        case .year:  return "this year"
        case .all:   return "all time"
        }
    }

    // MARK: - Caveat / empty state

    /// One calm line under the picker. Rule #2 §A.7. The chart's
    /// values are derived from today's prices applied to historical
    /// quantities — the user can read the shape as a record of
    /// activity, not as a real-time dollar valuation of past states.
    private var caveatLine: some View {
        UniFootnote(
            text: "Valued at today's prices.",
            alignment: .leading,
            color: UniColors.Text.tertiary
        )
    }

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
        return Text("Range \(selectedRange.shortLabel). From \(start) to \(end). Change \(delta).")
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

    /// Smooth quadratic-Bézier path through the sample points.
    /// Between every adjacent pair we route the curve via the
    /// midpoint as a control vertex — the addQuadCurve(addQuad
    /// Curve(mid)) pattern from the Stabro reference. This yields
    /// silky rounded transitions without the over-correction a
    /// Catmull-Rom spline would introduce.
    private func sparklinePath(points canvasPoints: [CGPoint]) -> Path {
        Path { path in
            guard let first = canvasPoints.first else { return }
            path.move(to: first)
            for i in 1..<canvasPoints.count {
                let mid = CGPoint(
                    x: (canvasPoints[i - 1].x + canvasPoints[i].x) / 2,
                    y: (canvasPoints[i - 1].y + canvasPoints[i].y) / 2
                )
                path.addQuadCurve(to: mid, control: canvasPoints[i - 1])
                path.addQuadCurve(to: canvasPoints[i], control: mid)
            }
        }
    }

    /// Gradient fill — same quadratic curve, then closed down to
    /// the baseline at both ends so the area between the curve
    /// and the bottom of the canvas can be filled with a vertical
    /// fade.
    private func gradientFill(points canvasPoints: [CGPoint], in size: CGSize) -> some View {
        Path { path in
            guard let first = canvasPoints.first, let last = canvasPoints.last else { return }
            path.move(to: first)
            for i in 1..<canvasPoints.count {
                let mid = CGPoint(
                    x: (canvasPoints[i - 1].x + canvasPoints[i].x) / 2,
                    y: (canvasPoints[i - 1].y + canvasPoints[i].y) / 2
                )
                path.addQuadCurve(to: mid, control: canvasPoints[i - 1])
                path.addQuadCurve(to: canvasPoints[i], control: mid)
            }
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
