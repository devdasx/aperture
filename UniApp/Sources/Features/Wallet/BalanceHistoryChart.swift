import SwiftUI
import Charts

/// Native iOS 26 balance-over-time chart for the wallet home.
///
/// **Design intent (one sentence per Rule #2 §D.1):** show the user
/// the shape of their balance changing through time — calm,
/// monochrome, undeniable — so they can read "what happened to my
/// money?" in one glance.
///
/// **Layer (Rule #2 §B.3):** content. No `.glassEffect()`. The
/// chart is data, not chrome — the two glass layers already in the
/// home (toolbar pill + action triplet) preserve the §B.3 two-layer
/// maximum unchanged.
///
/// **Visual register.**
/// - Single graphite stroke (`UniColors.Text.primary`). No green-up
///   / red-down theatre on the line itself — Aperture is
///   monochrome (Rule #16 §B). Direction shows in the delta
///   caption only.
/// - No axis chrome, no grid, no tick labels. The hero number above
///   the row already reports the absolute value; the chart's job is
///   the SHAPE.
/// - Native segmented range picker (1D / 1W / 1M / 1Y / All) —
///   `.pickerStyle(.segmented)`, the same control that powers
///   Coins ↔ Tokens elsewhere on this screen.
/// - One honest caveat line under the picker: "Valued at today's
///   prices." Rule #2 §A.7. Restrained — a footnote, not a banner.
///
/// **Scrub interaction (iOS 17+ Charts `.chartXSelection`).** Drag
/// across the curve to surface a per-point readout above the line:
/// the historical fiat value at that timestamp plus its relative
/// date. A `.selection` haptic fires when the selected point moves
/// (Rule #10 §A — picker-class state change). Releasing returns to
/// the resting caption.
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
    @State private var scrubDate: Date?

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
                chart(points: points)
                rangePicker
                caveatLine
            }
        }
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - Chart

    @ViewBuilder
    private func chart(points: [BalancePoint]) -> some View {
        let minFiat = points.map { $0.fiat }.min() ?? 0
        let maxFiat = points.map { $0.fiat }.max() ?? 0
        // Pad the y-domain by 4% so the line never grazes the top
        // or bottom edge of the plot — visual breathing room with
        // no tick chrome to do the job otherwise. When everything
        // is zero the domain collapses; let Charts handle it.
        let pad = (maxFiat - minFiat) * Decimal(0.04)
        let domainLower = NSDecimalNumber(decimal: max(0, minFiat - pad)).doubleValue
        let domainUpper = NSDecimalNumber(decimal: maxFiat + pad).doubleValue

        Chart {
            ForEach(points, id: \.timestamp) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Fiat", NSDecimalNumber(decimal: point.fiat).doubleValue)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(UniColors.Text.primary)
            }
            // Scrub crosshair — a thin vertical rule + a 5pt
            // point on the curve. Surfaces only while the user
            // actively scrubs (RuleMark vanishes on release).
            if let scrub = scrubDate,
               let nearest = nearestPoint(to: scrub, in: points)
            {
                RuleMark(x: .value("Selected", nearest.timestamp))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(UniColors.Separator.regular)
                PointMark(
                    x: .value("Selected time", nearest.timestamp),
                    y: .value("Selected fiat", NSDecimalNumber(decimal: nearest.fiat).doubleValue)
                )
                .foregroundStyle(UniColors.Text.primary)
                .symbolSize(60)
            }
        }
        .chartYScale(domain: domainLower...domainUpper)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXSelection(value: $scrubDate)
        .frame(height: 140)
        // Selection haptic fires per Rule #10 §A — picker-class
        // state change as the highlighted point moves under the
        // user's finger. Coalesces naturally because Charts
        // re-publishes only on cross of the nearest-point boundary.
        .uniHaptic(.selection, trigger: nearestPoint(to: scrubDate ?? .distantPast, in: points)?.timestamp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Balance history chart"))
        .accessibilityValue(chartAccessibilityValue(points: points))
    }

    // MARK: - Range picker

    /// Native segmented picker — same control as the Coins ↔ Tokens
    /// switcher above this row, so the chart row reads as part of
    /// the same family. Localized via `Localizable.xcstrings`
    /// through the per-case `LocalizedStringKey` initializers below.
    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            Text("1D").tag(BalanceHistoryRange.day)
            Text("1W").tag(BalanceHistoryRange.week)
            Text("1M").tag(BalanceHistoryRange.month)
            Text("1Y").tag(BalanceHistoryRange.year)
            Text("All").tag(BalanceHistoryRange.all)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Balance history range"))
        .uniHaptic(.selection, trigger: selectedRange)
    }

    // MARK: - Delta caption

    /// Caption above the curve. When scrubbing — shows the
    /// scrubbed-point's fiat value + its relative timestamp. When
    /// at rest — shows the range's signed delta from leading-edge
    /// to trailing-edge with a directional color hint on the delta
    /// only (the line itself stays monochrome). Rule #16 §B.
    @ViewBuilder
    private func deltaCaption(points: [BalancePoint]) -> some View {
        if let scrub = scrubDate,
           let nearest = nearestPoint(to: scrub, in: points)
        {
            // Scrubbing mode — historical readout at the
            // selected timestamp.
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

    /// Find the point on the curve closest to the dragged
    /// timestamp. Used both for the scrub caption and for the
    /// crosshair `PointMark`.
    private func nearestPoint(to date: Date, in points: [BalancePoint]) -> BalancePoint? {
        guard !points.isEmpty else { return nil }
        return points.min(by: { a, b in
            abs(a.timestamp.timeIntervalSince(date)) <
                abs(b.timestamp.timeIntervalSince(date))
        })
    }

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
}
