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

struct BalanceChartSample: Hashable, Identifiable, Sendable {
    let id: Int
    let sourceIndex: Int
    let date: Date
    let xFraction: Double
    let value: Double

    var x: Double { xFraction }
    var y: Double { value }
}

enum BalanceChartScrubResolver {
    private static let duplicateTimeEpsilon: TimeInterval = 0.000_001
    private static let syntheticReferenceDate = Date(timeIntervalSinceReferenceDate: 0)
    private static let syntheticTimeSpan: TimeInterval = 1_000

    static func selection(
        touchX: CGFloat,
        plotArea: CGRect,
        values: [Double],
        xFractions: [Double] = [],
        timestamps: [Date] = []
    ) -> BalanceChartScrubSelection? {
        guard !values.isEmpty, plotArea.width > 0 else { return nil }

        let clampedX = max(plotArea.minX, min(plotArea.maxX, touchX))
        let requestedFraction = Double((clampedX - plotArea.minX) / plotArea.width)

        if values.count == 1 {
            return BalanceChartScrubSelection(
                xFraction: requestedFraction,
                lowerIndex: 0,
                upperIndex: 0,
                progress: 0,
                fiat: values[0],
                timestamp: timestamp(at: 0, timestamps: timestamps)
            )
        }

        let samples = chartSamples(values: values, xFractions: xFractions, timestamps: timestamps)
        guard !samples.isEmpty else { return nil }
        guard samples.count > 1 else {
            let sample = samples[0]
            return BalanceChartScrubSelection(
                xFraction: requestedFraction,
                lowerIndex: sample.sourceIndex,
                upperIndex: sample.sourceIndex,
                progress: 0,
                fiat: sample.value,
                timestamp: sample.date
            )
        }

        let domain = dateDomain(for: samples)
        let span = max(domain.upperBound.timeIntervalSince(domain.lowerBound), 0)
        let targetDate = domain.lowerBound.addingTimeInterval(span * requestedFraction)
        guard let resolved = selection(date: targetDate, samples: samples) else { return nil }

        return BalanceChartScrubSelection(
            xFraction: requestedFraction,
            lowerIndex: resolved.lowerIndex,
            upperIndex: resolved.upperIndex,
            progress: resolved.progress,
            fiat: resolved.fiat,
            timestamp: resolved.timestamp
        )
    }

    static func selection(date: Date, samples rawSamples: [BalanceChartSample]) -> BalanceChartScrubSelection? {
        let samples = normalizedSamples(rawSamples)
        guard let first = samples.first else { return nil }

        guard samples.count > 1 else {
            return BalanceChartScrubSelection(
                xFraction: 0,
                lowerIndex: first.sourceIndex,
                upperIndex: first.sourceIndex,
                progress: 0,
                fiat: first.value,
                timestamp: first.date
            )
        }

        let domain = dateDomain(for: samples)
        let lowerDomainTime = domain.lowerBound.timeIntervalSinceReferenceDate
        let upperDomainTime = domain.upperBound.timeIntervalSinceReferenceDate
        let targetTime = min(max(date.timeIntervalSinceReferenceDate, lowerDomainTime), upperDomainTime)
        let clampedDate = Date(timeIntervalSinceReferenceDate: targetTime)

        if targetTime <= first.date.timeIntervalSinceReferenceDate {
            return exactSelection(sample: first, xFraction: 0)
        }

        guard let last = samples.last else { return nil }
        if targetTime >= last.date.timeIntervalSinceReferenceDate {
            return exactSelection(sample: last, xFraction: 1)
        }

        var upperIndex = lowerBoundIndex(for: targetTime, in: samples)
        upperIndex = lastDuplicateIndex(startingAt: upperIndex, in: samples)
        let lowerIndex = previousDistinctIndex(before: upperIndex, in: samples) ?? 0

        let lower = samples[lowerIndex]
        let upper = samples[upperIndex]
        let lowerTime = lower.date.timeIntervalSinceReferenceDate
        let upperTime = upper.date.timeIntervalSinceReferenceDate
        let span = upperTime - lowerTime
        let rawProgress = span > duplicateTimeEpsilon ? (targetTime - lowerTime) / span : 1
        let progress = min(max(rawProgress, 0), 1)
        let fiat = lower.value + (upper.value - lower.value) * progress

        return BalanceChartScrubSelection(
            xFraction: xFraction(for: clampedDate, in: domain),
            lowerIndex: lower.sourceIndex,
            upperIndex: upper.sourceIndex,
            progress: progress,
            fiat: fiat,
            timestamp: clampedDate
        )
    }

    static func chartSamples(
        values: [Double],
        xFractions: [Double] = [],
        timestamps: [Date] = []
    ) -> [BalanceChartSample] {
        guard !values.isEmpty else { return [] }

        let fractions = resolvedFractions(count: values.count, xFractions: xFractions)
        let dates = resolvedDates(count: values.count, fractions: fractions, timestamps: timestamps)

        var samples: [BalanceChartSample] = []
        samples.reserveCapacity(values.count)
        for index in values.indices {
            let value = values[index]
            guard value.isFinite else { continue }
            samples.append(
                BalanceChartSample(
                    id: index,
                    sourceIndex: index,
                    date: dates[index],
                    xFraction: fractions[index],
                    value: value
                )
            )
        }
        return normalizedSamples(samples)
    }

    static func dateDomain(for rawSamples: [BalanceChartSample]) -> ClosedRange<Date> {
        let samples = normalizedSamples(rawSamples)
        guard let first = samples.first?.date else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }

        guard let last = samples.last?.date, first < last else {
            return first.addingTimeInterval(-60)...first.addingTimeInterval(60)
        }

        return first...last
    }

    private static func exactSelection(
        sample: BalanceChartSample,
        xFraction: Double
    ) -> BalanceChartScrubSelection {
        BalanceChartScrubSelection(
            xFraction: xFraction,
            lowerIndex: sample.sourceIndex,
            upperIndex: sample.sourceIndex,
            progress: 0,
            fiat: sample.value,
            timestamp: sample.date
        )
    }

    private static func resolvedDates(
        count: Int,
        fractions: [Double],
        timestamps: [Date]
    ) -> [Date] {
        if timestamps.count == count {
            var previous = timestamps[0]
            var hasForwardMovement = false
            var valid = true

            for index in 1..<timestamps.count {
                let current = timestamps[index]
                if current < previous {
                    valid = false
                    break
                }
                if current > previous {
                    hasForwardMovement = true
                }
                previous = current
            }

            if valid, hasForwardMovement || count == 1 {
                return timestamps
            }
        }

        return fractions.map { fraction in
            syntheticReferenceDate.addingTimeInterval(fraction * syntheticTimeSpan)
        }
    }

    private static func resolvedFractions(count: Int, xFractions: [Double]) -> [Double] {
        guard count > 1 else { return Array(repeating: 0, count: count) }
        guard xFractions.count == count else { return equalFractions(count: count) }

        let clamped = xFractions.map { value -> Double in
            guard value.isFinite else { return Double.nan }
            return min(max(value, 0), 1)
        }

        guard clamped.allSatisfy(\.isFinite) else { return equalFractions(count: count) }

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

    private static func normalizedSamples(_ samples: [BalanceChartSample]) -> [BalanceChartSample] {
        let sorted = samples.sorted {
            if abs($0.date.timeIntervalSince($1.date)) > duplicateTimeEpsilon {
                return $0.date < $1.date
            }
            return $0.sourceIndex < $1.sourceIndex
        }

        var result: [BalanceChartSample] = []
        result.reserveCapacity(sorted.count)
        for sample in sorted {
            if let last = result.last,
               abs(last.date.timeIntervalSince(sample.date)) <= duplicateTimeEpsilon {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }
        return result
    }

    private static func lowerBoundIndex(
        for targetTime: TimeInterval,
        in samples: [BalanceChartSample]
    ) -> Int {
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date.timeIntervalSinceReferenceDate < targetTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func lastDuplicateIndex(
        startingAt index: Int,
        in samples: [BalanceChartSample]
    ) -> Int {
        guard !samples.isEmpty else { return index }
        var result = max(0, min(index, samples.count - 1))
        while result < samples.count - 1,
              abs(samples[result + 1].date.timeIntervalSince(samples[result].date)) <= duplicateTimeEpsilon {
            result += 1
        }
        return result
    }

    private static func previousDistinctIndex(
        before index: Int,
        in samples: [BalanceChartSample]
    ) -> Int? {
        guard !samples.isEmpty, index > 0 else { return nil }

        let safeIndex = max(0, min(index, samples.count - 1))
        let reference = samples[safeIndex].date
        var candidate = safeIndex - 1

        while candidate >= 0 {
            if abs(samples[candidate].date.timeIntervalSince(reference)) > duplicateTimeEpsilon {
                return candidate
            }
            if candidate == 0 { break }
            candidate -= 1
        }

        return nil
    }

    private static func xFraction(for date: Date, in domain: ClosedRange<Date>) -> Double {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > duplicateTimeEpsilon else { return 0 }
        return min(max(date.timeIntervalSince(domain.lowerBound) / span, 0), 1)
    }

    private static func timestamp(at index: Int, timestamps: [Date]) -> Date? {
        guard index >= 0, index < timestamps.count else { return nil }
        return timestamps[index]
    }
}

private enum BalanceChartDragIntent {
    case undecided
    case scrub
    case scroll
}

struct BalanceAreaChart: View {
    let values: [Double]
    var xFractions: [Double] = []
    let minValue: Double
    let maxValue: Double
    var timestamps: [Date] = []
    let sign: UniColors.BalanceCard.Sign
    var onScrub: (BalanceChartScrubSelection?) -> Void = { _ in }
    var onScrubBegin: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var scrubSelection: BalanceChartScrubSelection?
    @State private var dragIntent: BalanceChartDragIntent = .undecided
    @State private var lastHapticIndex: Int?

    var body: some View {
        let samples = BalanceChartScrubResolver.chartSamples(
            values: values,
            xFractions: xFractions,
            timestamps: timestamps
        )

        chart(samples: samples)
            .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private func chart(samples: [BalanceChartSample]) -> some View {
        if samples.isEmpty {
            Color.clear
        } else {
            let yDomain = yDomain
            let xDomain = BalanceChartScrubResolver.dateDomain(for: samples)

            Chart {
                ForEach(samples) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        yStart: .value("Baseline", yDomain.lowerBound),
                        yEnd: .value("Balance", sample.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(areaGradient)

                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Balance", sample.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(strokeColor)
                }

                if scrubSelection == nil, let last = samples.last {
                    PointMark(
                        x: .value("Time", last.date),
                        y: .value("Balance", last.value)
                    )
                    .symbolSize(64)
                    .foregroundStyle(strokeColor)
                }

                if let selectedSample {
                    RuleMark(x: .value("Selected time", selectedSample.date))
                        .foregroundStyle(strokeColor.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))

                    PointMark(
                        x: .value("Selected time", selectedSample.date),
                        y: .value("Selected balance", selectedSample.value)
                    )
                    .symbolSize(72)
                    .foregroundStyle(strokeColor)
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .shadow(
                color: chartHasGlow ? strokeColor.opacity(0.55) : Color.clear,
                radius: chartHasGlow ? 4 : 0
            )
            .chartOverlay { chartProxy in
                GeometryReader { proxy in
                    let plotArea = chartProxy.plotFrame.map { proxy[$0] } ?? .zero
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    handleScrubChanged(
                                        value,
                                        chartProxy: chartProxy,
                                        plotArea: plotArea,
                                        samples: samples
                                    )
                                }
                                .onEnded { _ in
                                    handleScrubEnded()
                                }
                        )
                }
            }
            .transaction { transaction in
                if scrubSelection != nil {
                    transaction.animation = nil
                }
            }
        }
    }

    private var strokeColor: Color {
        UniColors.BalanceCard.chartStroke(sign, colorScheme)
    }

    private var fillColor: Color {
        UniColors.BalanceCard.chartFillHue(sign, colorScheme)
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [
                fillColor.opacity(UniColors.BalanceCard.chartFillTopOpacity(sign)),
                fillColor.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var chartHasGlow: Bool {
        UniColors.BalanceCard.chartGlow(sign, colorScheme)
    }

    private var selectedSample: (date: Date, value: Double)? {
        guard let scrubSelection, let date = scrubSelection.timestamp else { return nil }
        return (date, scrubSelection.fiat)
    }

    private var yDomain: ClosedRange<Double> {
        guard !values.isEmpty, minValue.isFinite, maxValue.isFinite else {
            return 0...1
        }

        let low = min(minValue, maxValue)
        let high = max(minValue, maxValue)
        let spread = max(high - low, max(abs(high), 1) * 0.04)
        let padding = spread * 0.18
        return (low - padding)...(high + padding)
    }

    private func handleScrubChanged(
        _ value: DragGesture.Value,
        chartProxy: ChartProxy,
        plotArea: CGRect,
        samples: [BalanceChartSample]
    ) {
        switch dragIntent {
        case .scroll:
            return
        case .undecided:
            let dx = abs(value.translation.width)
            let dy = abs(value.translation.height)
            if dy > dx, dy > 8 {
                dragIntent = .scroll
                scrubSelection = nil
                onScrub(nil)
                return
            }
            guard dx >= 8 else { return }
            dragIntent = .scrub
            onScrubBegin()
        case .scrub:
            break
        }

        guard plotArea.width > 0 else { return }
        let localX = min(max(value.location.x - plotArea.minX, 0), plotArea.width)
        guard let date: Date = chartProxy.value(atX: localX, as: Date.self),
              let selection = BalanceChartScrubResolver.selection(date: date, samples: samples) else {
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
        if dragIntent == .scrub {
            onScrub(nil)
            UniHapticEngine.shared.playScrubRelease()
        }

        scrubSelection = nil
        dragIntent = .undecided
        lastHapticIndex = nil
    }

    private func hapticIntensity(at index: Int) -> Float {
        guard values.count > 1 else { return 0.3 }
        let safeIndex = max(0, min(values.count - 1, index))
        let previous = safeIndex > 0 ? values[safeIndex - 1] : values[safeIndex]
        let current = values[safeIndex]
        let range = max(maxValue - minValue, 0.0001)
        let normalizedSlope = abs(current - previous) / range
        return Float(min(0.8, 0.15 + normalizedSlope * 2.2))
    }
}
