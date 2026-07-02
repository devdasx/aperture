import Charts
import SwiftUI

struct BalanceChartScrubSelection: Equatable, Sendable {
    let xFraction: Double
    let lowerIndex: Int
    let upperIndex: Int
    let progress: Double
    let fiat: Double
    let timestamp: Date?

    var nearestIndex: Int {
        progress < 0.5 ? lowerIndex : upperIndex
    }

    var fiatDecimal: Decimal {
        Decimal(fiat)
    }
}

struct BalanceChartSample: Hashable, Sendable {
    let id: Int
    let sourceIndex: Int?
    let x: Double
    let y: Double
}

enum BalanceChartScrubResolver {
    private static let duplicateXEpsilon = 0.000_000_1

    static func selection(
        touchX: CGFloat,
        plotArea: CGRect,
        values: [Double],
        xFractions: [Double] = [],
        timestamps: [Date] = []
    ) -> BalanceChartScrubSelection? {
        guard !values.isEmpty, plotArea.width > 0 else { return nil }
        let clamped = max(plotArea.minX, min(plotArea.maxX, touchX))
        let xFraction = Double((clamped - plotArea.minX) / plotArea.width)
        let fractions = resolvedFractions(count: values.count, xFractions: xFractions)
        guard !fractions.isEmpty else { return nil }
        let firstIndex = lastDuplicateIndex(startingAt: 0, in: fractions)
        guard values.count > 1 else {
            return BalanceChartScrubSelection(
                xFraction: xFraction,
                lowerIndex: firstIndex,
                upperIndex: firstIndex,
                progress: 0,
                fiat: values[firstIndex],
                timestamp: timestamp(at: firstIndex, timestamps: timestamps)
            )
        }

        if xFraction <= fractions[firstIndex] {
            return BalanceChartScrubSelection(
                xFraction: xFraction,
                lowerIndex: firstIndex,
                upperIndex: firstIndex,
                progress: 0,
                fiat: values[firstIndex],
                timestamp: timestamp(at: firstIndex, timestamps: timestamps)
            )
        }

        let lastIndex = values.count - 1
        if xFraction >= fractions[lastIndex] {
            return BalanceChartScrubSelection(
                xFraction: xFraction,
                lowerIndex: lastIndex,
                upperIndex: lastIndex,
                progress: 0,
                fiat: values[lastIndex],
                timestamp: timestamp(at: lastIndex, timestamps: timestamps)
            )
        }

        var upperIndex = lowerBound(for: xFraction, in: fractions)
        upperIndex = lastDuplicateIndex(startingAt: upperIndex, in: fractions)
        let lowerIndex = previousDistinctIndex(before: upperIndex, in: fractions) ?? firstIndex
        let lowerX = fractions[lowerIndex]
        let upperX = fractions[upperIndex]
        let span = upperX - lowerX
        let progress = span > duplicateXEpsilon ? (xFraction - lowerX) / span : 1
        let clampedProgress = max(0, min(1, progress))
        let lowerValue = values[lowerIndex]
        let upperValue = values[upperIndex]
        let fiat = lowerValue + (upperValue - lowerValue) * clampedProgress
        return BalanceChartScrubSelection(
            xFraction: xFraction,
            lowerIndex: lowerIndex,
            upperIndex: upperIndex,
            progress: clampedProgress,
            fiat: fiat,
            timestamp: interpolatedTimestamp(
                lower: lowerIndex,
                upper: upperIndex,
                progress: clampedProgress,
                timestamps: timestamps
            )
        )
    }

    static func chartSamples(values: [Double], xFractions: [Double] = []) -> [BalanceChartSample] {
        guard !values.isEmpty else {
            return [
                BalanceChartSample(id: 0, sourceIndex: nil, x: 0, y: 0.5),
                BalanceChartSample(id: 1, sourceIndex: nil, x: 1, y: 0.5)
            ]
        }

        if values.count == 1 {
            let value = values[0]
            return [
                BalanceChartSample(id: 0, sourceIndex: 0, x: 0, y: value),
                BalanceChartSample(id: 1, sourceIndex: 0, x: 1, y: value)
            ]
        }

        return sourceSamples(values: values, xFractions: xFractions).map {
            BalanceChartSample(id: $0.index, sourceIndex: $0.index, x: $0.x, y: $0.value)
        }
    }

    private struct SourceSample: Sendable {
        let index: Int
        let x: Double
        let value: Double
    }

    private static func sourceSamples(values: [Double], xFractions: [Double]) -> [SourceSample] {
        let fractions = resolvedFractions(count: values.count, xFractions: xFractions)
        var samples: [SourceSample] = []
        samples.reserveCapacity(values.count)
        for index in values.indices {
            let next = SourceSample(index: index, x: fractions[index], value: values[index])
            if let last = samples.last, abs(last.x - next.x) <= duplicateXEpsilon {
                samples[samples.count - 1] = next
            } else {
                samples.append(next)
            }
        }
        return samples
    }

    private static func resolvedFractions(count: Int, xFractions: [Double]) -> [Double] {
        guard count > 1 else { return Array(repeating: 0, count: count) }
        guard xFractions.count == count else {
            return equalFractions(count: count)
        }
        let clamped = xFractions.map { value in
            guard value.isFinite else { return Double.nan }
            return min(max(value, 0), 1)
        }
        guard clamped.allSatisfy(\.isFinite) else {
            return equalFractions(count: count)
        }
        var hasForwardMovement = false
        for index in 1..<clamped.count {
            if clamped[index] < clamped[index - 1] {
                return equalFractions(count: count)
            }
            if clamped[index] > clamped[index - 1] {
                hasForwardMovement = true
            }
        }
        return hasForwardMovement ? clamped : equalFractions(count: count)
    }

    private static func equalFractions(count: Int) -> [Double] {
        guard count > 1 else { return Array(repeating: 0, count: count) }
        return (0..<count).map { Double($0) / Double(count - 1) }
    }

    private static func lowerBound(for xFraction: Double, in fractions: [Double]) -> Int {
        var low = 0
        var high = fractions.count - 1
        while low < high {
            let mid = (low + high) / 2
            if fractions[mid] < xFraction {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func lastDuplicateIndex(startingAt index: Int, in fractions: [Double]) -> Int {
        guard !fractions.isEmpty else { return index }
        var result = max(0, min(index, fractions.count - 1))
        while result < fractions.count - 1,
              abs(fractions[result + 1] - fractions[result]) <= duplicateXEpsilon {
            result += 1
        }
        return result
    }

    private static func previousDistinctIndex(before index: Int, in fractions: [Double]) -> Int? {
        guard !fractions.isEmpty, index > 0 else { return nil }
        let reference = fractions[max(0, min(index, fractions.count - 1))]
        var candidate = index - 1
        while candidate >= 0 {
            if abs(fractions[candidate] - reference) > duplicateXEpsilon {
                return candidate
            }
            if candidate == 0 { break }
            candidate -= 1
        }
        return nil
    }

    private static func timestamp(at index: Int, timestamps: [Date]) -> Date? {
        guard index >= 0, index < timestamps.count else { return nil }
        return timestamps[index]
    }

    private static func interpolatedTimestamp(
        lower: Int,
        upper: Int,
        progress: Double,
        timestamps: [Date]
    ) -> Date? {
        guard let lowerDate = timestamp(at: lower, timestamps: timestamps),
              let upperDate = timestamp(at: upper, timestamps: timestamps) else {
            return nil
        }
        let clampedProgress = max(0, min(1, progress))
        return lowerDate.addingTimeInterval(upperDate.timeIntervalSince(lowerDate) * clampedProgress)
    }
}

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
    /// Per-point timestamps parallel to `values`; when supplied, scrub publishes
    /// a continuous timestamp along with the touched fiat value.
    var timestamps: [Date] = []
    /// The chart's sign — drives stroke / fill / glow color together.
    let sign: UniColors.BalanceCard.Sign
    /// Published while scrubbing (and `nil` on release).
    var onScrub: (BalanceChartScrubSelection?) -> Void = { _ in }
    /// Fired once when a scrub drag begins (the card plays `impactLight`).
    var onScrubBegin: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var scrubSelection: BalanceChartScrubSelection?
    @State private var isScrubbing = false
    @State private var rejectedCurrentDrag = false
    @State private var lastHapticIndex: Int?

    /// Y-axis padding band (10% top + bottom) so the curve breathes.
    private let padding: CGFloat = 0.1

    var body: some View {
        let samples = BalanceChartScrubResolver.chartSamples(values: values, xFractions: xFractions)
        let domain = yDomain
        Chart {
            ForEach(samples, id: \.id) { sample in
                AreaMark(
                    x: .value("Time", sample.x),
                    yStart: .value("Baseline", domain.lowerBound),
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

            if scrubSelection == nil, let last = samples.last {
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
        .chartYScale(domain: domain)
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
        .chartOverlay { chartProxy in
            GeometryReader { proxy in
                let plotArea = chartProxy.plotFrame.map { proxy[$0] } ?? .zero
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                handleScrubChanged(value, plotArea: plotArea)
                            }
                            .onEnded { _ in
                                handleScrubEnded()
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

    private var selectedSample: (x: Double, y: Double)? {
        guard let scrubSelection else { return nil }
        return (scrubSelection.xFraction, scrubSelection.fiat)
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

    // MARK: - Cursor math (O(log n) per tick)

    private func handleScrubChanged(_ value: DragGesture.Value, plotArea: CGRect) {
        if rejectedCurrentDrag { return }

        if !isScrubbing {
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            if dy > dx {
                rejectedCurrentDrag = true
                return
            }
            isScrubbing = true
            onScrubBegin()
        }

        guard let selection = BalanceChartScrubResolver.selection(
            touchX: value.location.x,
            plotArea: plotArea,
            values: values,
            xFractions: xFractions,
            timestamps: timestamps
        ) else {
            return
        }

        guard selection != scrubSelection else { return }
        scrubSelection = selection
        onScrub(selection)

        let hapticIndex = selection.nearestIndex
        if hapticIndex != lastHapticIndex {
            lastHapticIndex = hapticIndex
            UniHapticEngine.shared.playScrubTick(intensity: hapticIntensity(at: hapticIndex))
        }
    }

    private func handleScrubEnded() {
        if isScrubbing {
            onScrub(nil)
            UniHapticEngine.shared.playScrubRelease()
        }
        scrubSelection = nil
        isScrubbing = false
        rejectedCurrentDrag = false
        lastHapticIndex = nil
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
