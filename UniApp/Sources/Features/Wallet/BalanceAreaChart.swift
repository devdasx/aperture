import Charts
import SwiftUI

/// Native Swift Charts area chart shared by the balance card and balance-history
/// detail surfaces. It owns the data projection and scrub cursor, while the
/// caller owns the responsive frame, so the chart can center and expand naturally
/// on iPhone and iPad without negative insets or hand-positioned paths.
///
/// Time always flows left to right because the x-axis represents historical data,
/// not interface direction; surrounding chrome can still mirror for RTL locales.
struct BalanceAreaChart: View {
    /// One value per sample, oldest → newest (the caller sorts).
    let values: [Double]
    /// Per-point horizontal position in `[0, 1]` from each sample's timestamp
    /// — parallel to `values`. A one-hour gap and a one-year gap occupy
    /// proportional width. Empty / wrong-length falls back to equal-index
    /// spacing (a flat baseline looks the same).
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

    /// Y-axis padding band (10% top + bottom) so the curve breathes.
    private let padding: CGFloat = 0.1

    var body: some View {
        Chart {
            ForEach(chartSamples, id: \.index) { sample in
                AreaMark(
                    x: .value("Time", sample.x),
                    yStart: .value("Baseline", yDomain.lowerBound),
                    yEnd: .value("Balance", sample.y)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [
                            fillColor.opacity(UniColors.BalanceCard.chartFillTopOpacity(sign)),
                            fillColor.opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", sample.x),
                    y: .value("Balance", sample.y)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(strokeColor)
            }

            if let last = chartSamples.last {
                PointMark(
                    x: .value("Time", last.x),
                    y: .value("Balance", last.y)
                )
                .symbolSize(64)
                .foregroundStyle(strokeColor)
            }

            if let selected = selectedSample {
                RuleMark(x: .value("Selected time", selected.x))
                    .foregroundStyle(strokeColor.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                PointMark(
                    x: .value("Selected time", selected.x),
                    y: .value("Selected balance", selected.y)
                )
                .symbolSize(72)
                .foregroundStyle(strokeColor)
            }
        }
        .chartXScale(domain: 0...1)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shadow(
            color: UniColors.BalanceCard.chartGlow(sign, colorScheme) ? strokeColor.opacity(0.55) : Color.clear,
            radius: UniColors.BalanceCard.chartGlow(sign, colorScheme) ? 4 : 0
        )
        .chartOverlay { _ in
            GeometryReader { proxy in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if scrubIndex == nil { onScrubBegin() }
                                let index = indexForX(value.location.x, in: proxy.size)
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
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var strokeColor: Color {
        UniColors.BalanceCard.chartStroke(sign, colorScheme)
    }

    private var fillColor: Color {
        UniColors.BalanceCard.chartFillHue(sign, colorScheme)
    }

    private var chartSamples: [(index: Int, x: Double, y: Double)] {
        guard !values.isEmpty else {
            return [
                (0, 0, 0.5),
                (1, 1, 0.5)
            ]
        }

        if values.count == 1 {
            let y = yValue(at: 0)
            return [
                (0, 0, y),
                (1, 1, y)
            ]
        }

        return values.indices.map { index in
            (index, xValue(at: index), yValue(at: index))
        }
    }

    private var selectedSample: (index: Int, x: Double, y: Double)? {
        guard let scrubIndex,
              scrubIndex >= 0,
              scrubIndex < values.count else { return nil }
        return (scrubIndex, xValue(at: scrubIndex), yValue(at: scrubIndex))
    }

    private var yDomain: ClosedRange<Double> {
        guard !values.isEmpty else {
            return 0...1
        }
        guard minValue.isFinite, maxValue.isFinite else {
            return 0...1
        }
        if minValue == maxValue {
            let valuePadding = max(abs(minValue) * 0.01, 1)
            return (minValue - valuePadding)...(maxValue + valuePadding)
        }
        let domainPadding = (maxValue - minValue) * Double(padding) / max(1 - 2 * Double(padding), 0.01)
        return (minValue - domainPadding)...(maxValue + domainPadding)
    }

    private func xValue(at index: Int) -> Double {
        if xFractions.count == values.count {
            return min(max(xFractions[index], 0), 1)
        }
        return values.count > 1 ? Double(index) / Double(values.count - 1) : 0
    }

    private func yValue(at index: Int) -> Double {
        values[index]
    }

    // MARK: - Cursor math (O(1) per tick)

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
                if d < bestDist {
                    bestDist = d
                    best = i
                }
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
