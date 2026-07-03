import Charts
import SwiftUI

/// Isolated chart prototype surface.
///
/// This screen intentionally does not share the production chart renderer or
/// wallet data. It exists so we can evaluate a replacement chart interaction
/// model without changing `BalanceAreaChart`, `BalanceCardView`, or the asset
/// detail charts.
struct ChartLabView: View {
    @State private var scenario: ChartLabScenario = .wallet
    @State private var selectedRange: ChartLabRange = .all
    @State private var curve: ChartLabCurve = .smooth
    @State private var scrubSelection: ChartLabScrubSelection?

    private var allPoints: [ChartLabPoint] {
        ChartLabFixtures.points(for: scenario)
    }

    private var visiblePoints: [ChartLabPoint] {
        selectedRange.filter(allPoints)
    }

    private var currentValue: Double {
        scrubSelection?.value ?? visiblePoints.last?.value ?? 0
    }

    private var firstValue: Double {
        visiblePoints.first?.value ?? currentValue
    }

    private var valueDelta: Double {
        currentValue - firstValue
    }

    private var isPositive: Bool {
        valueDelta >= 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                header
                chartCard
                controlCard
                auditCard
            }
            .padding(.horizontal, UniSpacing.mPlus)
            .padding(.top, UniSpacing.l)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Chart Lab")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text("Chart Lab")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(UniColors.Text.primary)

            Text("A separate prototype for the next wallet chart. Production charts are not modified on this screen.")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.mPlus) {
            HStack(alignment: .center, spacing: UniSpacing.m) {
                Circle()
                    .fill(chartColor.opacity(0.16))
                    .frame(width: 58, height: 58)
                    .overlay {
                        Image(systemName: scenario.symbolName)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(chartColor)
                    }

                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    Text(scenario.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(UniColors.Text.primary)

                    Text(scenario.subtitle)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(UniColors.Text.secondary)
                }

                Spacer(minLength: UniSpacing.s)
            }

            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text(formatCurrency(currentValue))
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(UniColors.Text.primary)
                    .contentTransition(scrubSelection == nil ? .numericText() : .identity)
                    .animation(scrubSelection == nil ? .snappy(duration: 0.22) : nil, value: currentValue)

                HStack(spacing: UniSpacing.s) {
                    Text(deltaText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(chartColor)
                        .padding(.horizontal, UniSpacing.s)
                        .padding(.vertical, UniSpacing.xs)
                        .background(chartColor.opacity(0.12), in: Capsule())

                    Text(scrubSelection.map { formatScrubDate($0.date) } ?? selectedRange.readoutLabel)
                        .font(.system(size: 15, weight: .regular, design: .monospaced))
                        .foregroundStyle(UniColors.Text.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer(minLength: 0)
                }
                .frame(height: 32)
            }

            ChartLabRenderer(
                points: visiblePoints,
                curve: curve,
                color: chartColor,
                selection: $scrubSelection
            )
            .frame(height: 238)

            rangePicker
        }
        .padding(UniSpacing.mPlus)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous)
                .stroke(UniColors.Card.stroke, lineWidth: 1)
        }
        .containerShape(.rect(cornerRadius: UniRadius.balanceCard))
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            Text("Prototype switches")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UniColors.Text.secondary)

            Picker("Scenario", selection: $scenario) {
                ForEach(ChartLabScenario.allCases) { scenario in
                    Text(scenario.title).tag(scenario)
                }
            }
            .pickerStyle(.segmented)

            Picker("Curve", selection: $curve) {
                ForEach(ChartLabCurve.allCases) { curve in
                    Text(curve.title).tag(curve)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(UniSpacing.mPlus)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private var auditCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            Text("What this prototype fixes")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(UniColors.Text.primary)

            ChartLabAuditRow(title: "Real time domain", detail: "The x-axis uses Date values. Wide gaps and dense periods keep their real spacing.")
            ChartLabAuditRow(title: "Plot-area scrubbing", detail: "Finger location is mapped through ChartProxy's plot area, not the full overlay rectangle.")
            ChartLabAuditRow(title: "Stable readout", detail: "The scrub row reserves space and disables numeric animation while the finger is down.")
            ChartLabAuditRow(title: "No fake empty chart", detail: "Empty data shows an empty state instead of a flat synthetic baseline.")
        }
        .padding(UniSpacing.mPlus)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private var rangePicker: some View {
        HStack(spacing: UniSpacing.xs) {
            ForEach(ChartLabRange.allCases) { range in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedRange = range
                        scrubSelection = nil
                    }
                } label: {
                    Text(range.title)
                        .font(.system(size: 16, weight: selectedRange == range ? .semibold : .medium))
                        .foregroundStyle(selectedRange == range ? UniColors.Text.primary : UniColors.Text.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background {
                            if selectedRange == range {
                                RoundedRectangle(cornerRadius: UniRadius.segmentPill, style: .continuous)
                                    .fill(UniColors.Card.background)
                                    .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(UniColors.Fill.secondary, in: RoundedRectangle(cornerRadius: UniRadius.segmentTrack, style: .continuous))
    }

    private var chartColor: Color {
        if scenario == .empty {
            return UniColors.Text.secondary
        }
        return isPositive ? UniColors.Text.success : UniColors.Text.error
    }

    private var deltaText: String {
        guard firstValue != 0 else { return "0.00%" }
        let percentage = (valueDelta / abs(firstValue)) * 100
        let arrow = percentage >= 0 ? "up" : "down"
        return "\(arrow) \(String(format: "%.2f", abs(percentage)))%"
    }

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value >= 1_000 ? 0 : 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "US$0.00"
    }

    private func formatScrubDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ChartLabRenderer: View {
    let points: [ChartLabPoint]
    let curve: ChartLabCurve
    let color: Color
    @Binding var selection: ChartLabScrubSelection?

    @State private var dragIntent: ChartLabDragIntent = .undecided

    var body: some View {
        Group {
            if points.isEmpty {
                emptyState
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            if curve == .smooth {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Baseline", yDomain.lowerBound),
                        yEnd: .value("Value", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(.init(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        yStart: .value("Baseline", yDomain.lowerBound),
                        yEnd: .value("Value", point.value)
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Value", point.value)
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(color)
                    .lineStyle(.init(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
            }

            if let selection {
                RuleMark(x: .value("Selected", selection.date))
                    .foregroundStyle(UniColors.Separator.regular)
                    .lineStyle(.init(lineWidth: 1.2, dash: [3, 4]))

                PointMark(
                    x: .value("Selected", selection.date),
                    y: .value("Value", selection.value)
                )
                .foregroundStyle(color)
                .symbolSize(140)
            } else if let lastPoint = points.last {
                PointMark(
                    x: .value("Endpoint", lastPoint.date),
                    y: .value("Value", lastPoint.value)
                )
                .foregroundStyle(color)
                .symbolSize(110)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartOverlay { chartProxy in
            GeometryReader { proxy in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(chartProxy: chartProxy, proxy: proxy))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(UniColors.Text.tertiary)

            Text("No chart data")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(UniColors.Text.primary)

            Text("The production chart currently draws a fake flat line for empty input. This prototype leaves the chart empty.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 238)
        .padding(.horizontal, UniSpacing.l)
        .background(UniColors.Fill.secondary, in: RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private func scrubGesture(chartProxy: ChartProxy, proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                switch dragIntent {
                case .undecided:
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    if dy > dx, dy > 8 {
                        dragIntent = .scroll
                        selection = nil
                        return
                    }
                    if dx >= 8 {
                        dragIntent = .scrub
                    }
                case .scroll:
                    return
                case .scrub:
                    break
                }

                guard dragIntent == .scrub,
                      let plotFrame = chartProxy.plotFrame
                else { return }

                let plotArea = proxy[plotFrame]
                guard plotArea.width > 0 else { return }
                let localX = min(max(value.location.x - plotArea.minX, 0), plotArea.width)
                guard let date: Date = chartProxy.value(atX: localX, as: Date.self),
                      let resolved = ChartLabScrubSelection.resolve(date: date, points: points)
                else { return }

                selection = resolved
            }
            .onEnded { _ in
                dragIntent = .undecided
                selection = nil
            }
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = points.first?.date,
              let last = points.last?.date,
              first < last
        else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        return first...last
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let minValue = values.min(),
              let maxValue = values.max()
        else { return 0...1 }

        let spread = max(maxValue - minValue, max(abs(maxValue), 1) * 0.04)
        let padding = spread * 0.18
        return (minValue - padding)...(maxValue + padding)
    }
}

private struct ChartLabAuditRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(UniColors.Text.success)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(UniColors.Text.primary)

                Text(detail)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum ChartLabScenario: String, CaseIterable, Identifiable {
    case wallet
    case asset
    case empty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallet: return "Wallet"
        case .asset: return "Asset"
        case .empty: return "Empty"
        }
    }

    var subtitle: String {
        switch self {
        case .wallet: return "Portfolio value from persisted samples"
        case .asset: return "Single asset value across networks"
        case .empty: return "No synthetic baseline"
        }
    }

    var symbolName: String {
        switch self {
        case .wallet: return "wallet.bifold"
        case .asset: return "bitcoinsign.circle"
        case .empty: return "tray"
        }
    }
}

private enum ChartLabRange: String, CaseIterable, Identifiable {
    case oneHour
    case oneDay
    case oneWeek
    case oneMonth
    case oneYear
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: return "1H"
        case .oneDay: return "1D"
        case .oneWeek: return "1W"
        case .oneMonth: return "1M"
        case .oneYear: return "1Y"
        case .all: return "All"
        }
    }

    var readoutLabel: String {
        switch self {
        case .oneHour: return "past hour"
        case .oneDay: return "today"
        case .oneWeek: return "past week"
        case .oneMonth: return "past month"
        case .oneYear: return "past year"
        case .all: return "all time"
        }
    }

    private var interval: TimeInterval? {
        switch self {
        case .oneHour: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        case .oneWeek: return 7 * 24 * 60 * 60
        case .oneMonth: return 30 * 24 * 60 * 60
        case .oneYear: return 365 * 24 * 60 * 60
        case .all: return nil
        }
    }

    func filter(_ points: [ChartLabPoint]) -> [ChartLabPoint] {
        guard let interval,
              let lastDate = points.last?.date
        else { return points }

        let cutoff = lastDate.addingTimeInterval(-interval)
        let filtered = points.filter { $0.date >= cutoff }
        if filtered.count >= 2 {
            return filtered
        }
        return Array(points.suffix(min(points.count, 2)))
    }
}

private enum ChartLabCurve: String, CaseIterable, Identifiable {
    case smooth
    case step

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .step: return "Step"
        }
    }
}

private enum ChartLabDragIntent {
    case undecided
    case scrub
    case scroll
}

private struct ChartLabPoint: Identifiable, Equatable {
    let id: Int
    let date: Date
    let value: Double
}

private struct ChartLabScrubSelection: Equatable {
    let date: Date
    let value: Double
    let lowerIndex: Int
    let upperIndex: Int
    let progress: Double

    static func resolve(date: Date, points: [ChartLabPoint]) -> ChartLabScrubSelection? {
        guard !points.isEmpty else { return nil }
        let sorted = points.sorted { $0.date < $1.date }

        guard sorted.count > 1 else {
            return ChartLabScrubSelection(
                date: sorted[0].date,
                value: sorted[0].value,
                lowerIndex: 0,
                upperIndex: 0,
                progress: 0
            )
        }

        let target = date.timeIntervalSinceReferenceDate
        let firstTime = sorted[0].date.timeIntervalSinceReferenceDate
        let lastIndex = sorted.count - 1
        let lastTime = sorted[lastIndex].date.timeIntervalSinceReferenceDate

        if target <= firstTime {
            return ChartLabScrubSelection(date: sorted[0].date, value: sorted[0].value, lowerIndex: 0, upperIndex: 0, progress: 0)
        }
        if target >= lastTime {
            return ChartLabScrubSelection(date: sorted[lastIndex].date, value: sorted[lastIndex].value, lowerIndex: lastIndex, upperIndex: lastIndex, progress: 0)
        }

        var low = 0
        var high = lastIndex
        while low < high {
            let mid = (low + high) / 2
            let midTime = sorted[mid].date.timeIntervalSinceReferenceDate
            if midTime < target {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let upperIndex = low
        let lowerIndex = max(upperIndex - 1, 0)
        let lower = sorted[lowerIndex]
        let upper = sorted[upperIndex]
        let lowerTime = lower.date.timeIntervalSinceReferenceDate
        let upperTime = upper.date.timeIntervalSinceReferenceDate
        guard upperTime > lowerTime else {
            return ChartLabScrubSelection(date: lower.date, value: lower.value, lowerIndex: lowerIndex, upperIndex: upperIndex, progress: 0)
        }

        let progress = min(max((target - lowerTime) / (upperTime - lowerTime), 0), 1)
        let value = lower.value + ((upper.value - lower.value) * progress)

        return ChartLabScrubSelection(
            date: Date(timeIntervalSinceReferenceDate: target),
            value: value,
            lowerIndex: lowerIndex,
            upperIndex: upperIndex,
            progress: progress
        )
    }
}

private enum ChartLabFixtures {
    static func points(for scenario: ChartLabScenario) -> [ChartLabPoint] {
        switch scenario {
        case .wallet:
            return makeWalletPoints()
        case .asset:
            return makeAssetPoints()
        case .empty:
            return []
        }
    }

    private static func makeWalletPoints() -> [ChartLabPoint] {
        let now = Date()
        let raw: [(TimeInterval, Double)] = [
            (-390 * day, 82),
            (-330 * day, 98),
            (-270 * day, 121),
            (-210 * day, 116),
            (-180 * day, 410),
            (-179 * day, 118),
            (-125 * day, 140),
            (-92 * day, 1_730),
            (-91 * day, 142),
            (-38 * day, 155),
            (-31 * day, 205),
            (-30 * day, 980),
            (-28 * day, 1_110),
            (-25 * day, 1_720),
            (-12 * day, 1_706),
            (-9 * day, 1_689),
            (-7 * day, 1_620),
            (-6 * day, 1_685),
            (-5 * day, 1_682),
            (-2 * day, 1_510),
            (-20 * hour, 1_512),
            (-12 * hour, 1_690),
            (-6 * hour, 1_665),
            (-60 * minute, 1_662),
            (-42 * minute, 1_708),
            (-28 * minute, 1_642),
            (-15 * minute, 1_721),
            (-5 * minute, 1_733)
        ]
        return raw.enumerated().map { index, entry in
            ChartLabPoint(id: index, date: now.addingTimeInterval(entry.0), value: entry.1)
        }
    }

    private static func makeAssetPoints() -> [ChartLabPoint] {
        let now = Date()
        let raw: [(TimeInterval, Double)] = [
            (-240 * day, 0),
            (-180 * day, 0),
            (-110 * day, 0),
            (-92 * day, 0.3),
            (-91 * day, 12),
            (-90 * day, 63),
            (-88 * day, 344),
            (-40 * day, 343),
            (-20 * day, 340),
            (-19 * day, 321),
            (-18 * day, 340),
            (-7 * day, 339),
            (-6 * day, 310),
            (-5 * day, 295),
            (-4 * day, 260),
            (-3 * day, 66),
            (-14 * hour, 65),
            (-6 * hour, 68),
            (-58 * minute, 70),
            (-34 * minute, 120),
            (-12 * minute, 198),
            (-4 * minute, 200)
        ]
        return raw.enumerated().map { index, entry in
            ChartLabPoint(id: index, date: now.addingTimeInterval(entry.0), value: entry.1)
        }
    }

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * minute
    private static let day: TimeInterval = 24 * hour
}
