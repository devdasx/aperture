import SwiftUI

/// Carries the chart's currently-scrubbed fiat value to the wallet-home
/// hero **without** re-rendering the whole screen on every drag frame.
///
/// **Why this exists (2026-06-13 perf fix).** The hero shows the
/// scrubbed point's value while the user drags the sparkline. The
/// previous design pushed that value into a `@State Decimal?` on
/// `WalletHomeView`, so each drag frame invalidated the ENTIRE
/// `WalletHomeView.body` — which rebuilt the price-history /
/// price-cache dictionaries from the full SwiftData `@Query` and
/// re-sorted every balance, 60×/sec. Routing the value through an
/// `@Observable` object instead means SwiftUI's Observation only
/// invalidates the views that READ `fiat` (the hero balance label) —
/// the chart writes it, the hero reads it, and nothing else on the
/// screen re-evaluates while scrubbing.
@Observable
final class ChartScrubModel {
    /// The touched point's fiat value, or `nil` at rest (hero shows the
    /// wallet's real total).
    var fiat: Decimal?
    /// The touched point's timestamp, or `nil` at rest. While scrubbing, the
    /// change row hides the PnL + percent and shows this date & time instead
    /// (the hero shows the point's value). `nil` on release → the row returns
    /// to the resting percent + amount.
    var timestamp: Date?
}

/// Balance-over-time chart wrapper for the token detail screens — owns the
/// data (transaction-sourced reconstruction), the period pill, the scrub
/// wiring, and accessibility, then renders through the **single canonical
/// `BalanceAreaChart`** (2026-06-19 Bug 2 fix — the private `SparklineChart`
/// / `SparklineCurve`, a second divergent renderer, was deleted so a render
/// fix lands once for every screen). Much of the prose below predates that
/// unification and is kept for history; the live renderer is `BalanceAreaChart`
/// (linear step segments, semantic stroke/fill, glow), not a local spline.
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
    /// The wallet's own addresses (lowercased) so self-transfers (counterparty
    /// == one of these) are dropped from the reconstruction, same as the
    /// flagship balance card. Defaults to empty (no filtering) for callers
    /// that don't supply it.
    var ownAddresses: Set<String> = []
    /// Local spot-price fallback keyed by uppercased symbol. The chart uses
    /// this only to convert a transaction's native amount into the user's
    /// local currency when no historical close exists for that transaction day.
    let priceCache: [String: Decimal]
    /// Per-day historical local closes keyed by uppercased symbol →
    /// `[yyyymmdd: close]`. The chart uses this only at transaction
    /// timestamps, never to create market-only points between transactions.
    let priceHistory: [String: [Int: Decimal]]
    let currencyCode: String
    /// 2026-06-09 — published scrubbed fiat. When the user drags
    /// across the sparkline, the touched point's fiat value is written
    /// to this `@Observable` model so the hero amount can render the
    /// scrubbed value (animated via `.contentTransition(.numericText())`).
    /// Set back to `nil` when the user lifts off — the hero returns to
    /// the wallet's actual total. **2026-06-13:** changed from a
    /// `Binding<Decimal?>` (which re-rendered the whole wallet-home
    /// body per drag frame) to `ChartScrubModel` so only the hero
    /// re-renders while scrubbing. The chart WRITES `fiat`; it never
    /// reads it, so the chart itself is not invalidated by its own
    /// writes. `nil` (default) → no hero wiring (previews, asset
    /// detail's own chart).
    var scrubModel: ChartScrubModel? = nil

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

    // MARK: - Memoized reconstruction (computed off-body)
    //
    // The full history reconstruction used to run inside `body` —
    // on EVERY body evaluation, including every scrub tick (the
    // `scrubIndex` `@State` invalidates the body per drag move).
    // It now runs once into `@State` via `.task(id:)` keyed on the
    // actual dependencies (transactions identity/count, current
    // balances, range, currency); the body only reads the cached
    // arrays. The min/max band the sparkline normalizes against is
    // computed alongside the points (instead of `points.min()` /
    // `points.max()` per drag tick inside the canvas math).

    /// Reconstructed (or zero-baseline-synthesized) balance points.
    /// Empty only before the first `.task(id:)` pass; the body
    /// falls back to the zero baseline for that single frame.
    @State private var chartPoints: [BalancePoint] = []
    /// `chartPoints` projected to `Double` for the canvas math.
    @State private var sparkValues: [Double] = []
    /// Cached `sparkValues.min()` / `.max()` so the scrub layer's
    /// per-tick math never rescans the series.
    @State private var sparkMin: Double = 0
    @State private var sparkMax: Double = 0

    var body: some View {
        // Spacing 0 (was UniSpacing.s) so the delta caption sits
        // directly under the hero amount with no gap per the
        // 2026-06-09 user direction. The internal layout still
        // gives breathing room around the sparkline and pill via
        // their own padding.
        VStack(alignment: .leading, spacing: 0) {
            // 2026-06-09 — empty-state copy removed per user
            // direction (*"remove balance history + subtitle, show
            // the chart even with 0 balance and 0 history"*). When
            // the reconstructor returns < 2 points (fresh wallet,
            // no transactions yet) `rebuildPoints()` synthesizes a
            // flat baseline at fiat = 0 across the current range so
            // the sparkline STILL renders — a calm horizontal line
            // at the zero axis. The chart surface is consistent at
            // every wallet age; the user reads "no history yet"
            // from the flat shape, not from a missing affordance.
            let points = chartPoints.isEmpty
                ? Self.zeroBaseline(for: currentRange)
                : chartPoints

            // 2026-06-09 — deltaCaption removed entirely per user
            // direction. The hero amount alone carries the displayed
            // number; the chart provides shape, not a second numeric
            // readout. The scrub publishes its value up through the
            // `onScrub` closure below (2026-06-13 — replaced the
            // `@Binding scrubIndex` + `.onChange` anchor, which
            // re-evaluated THIS body on every drag tick; the closure
            // writes the hero's `ChartScrubModel` without invalidating
            // the chart body, so a long scrub never re-runs the
            // reconstruction-gating `rebuildKey` or re-projects values).
            //
            // Pre-task fallback: the zero baseline projects to two
            // zero values (min = max = 0), exactly what
            // `rebuildPoints()` would produce for the same input.
            let values = chartPoints.isEmpty
                ? points.map { fiatAsDouble($0.fiat) }
                : sparkValues
            // Per-point time fractions (Part 4.3 — real time x-axis). Parallel
            // to `values`; `[]` for a degenerate span → renderer uses index
            // spacing (a 2-point flat baseline reads the same either way).
            let xFractions = Self.timeFractions(for: points)
            // **One renderer (2026-06-19 Bug 2 fix).** The token screens now
            // render through the SAME canonical `BalanceAreaChart` the main
            // card uses — the private `SparklineChart`/`SparklineCurve` (a
            // second, divergent copy of the spline + scrub + normalization)
            // is gone, so a render fix is written once and applies everywhere.
            BalanceAreaChart(
                values: values,
                xFractions: xFractions,
                minValue: chartPoints.isEmpty ? 0 : sparkMin,
                maxValue: chartPoints.isEmpty ? 0 : sparkMax,
                sign: Self.chartSign(for: points),
                onScrub: { index in
                    // Map the scrubbed index → the touched point's fiat
                    // and publish it to the hero via the @Observable model.
                    let scrubbed: Decimal? = {
                        guard let idx = index, idx >= 0, idx < points.count else { return nil }
                        return points[idx].fiat
                    }()
                    withAnimation(.snappy(duration: 0.18)) {
                        scrubModel?.fiat = scrubbed
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 140)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Balance history chart"))
            .accessibilityValue(chartAccessibilityValue(points: points))
            ChartPeriodPill(selection: selectedRange)
                // 24pt gap above the period pill row — the
                // sparkline above sits closer to the curve so
                // the pill reads as the next discrete control,
                // not as part of the chart canvas.
                .padding(.top, 24)
        }
        // No outer vertical padding — caption sits flush against
        // the balance hero above. The List row's bottom inset
        // contributes the gap to the card's bottom edge.
        .task(id: rebuildKey) { await rebuildPoints() }
    }

    /// Dependency key for the memoized reconstruction. Captures the
    /// transaction set, selected range, display currency, and local price
    /// inputs. O(N) scalar scans per body pass — orders of magnitude cheaper
    /// than the reconstruction they gate.
    private var rebuildKey: Int {
        var hasher = Hasher()
        hasher.combine(transactions.count)
        for tx in transactions {
            hasher.combine(tx.id)
            hasher.combine(tx.occurredAt)
            hasher.combine(tx.statusRaw)
            hasher.combine(tx.directionRaw)
            hasher.combine(tx.amountRaw)
            hasher.combine(tx.tokenSymbol)
            hasher.combine(tx.tokenContract)
            hasher.combine(tx.counterparty)
        }
        hasher.combine(selectedRangeRaw)
        hasher.combine(currencyCode)
        hasher.combine(priceCache.count)
        var priceSum = Decimal.zero
        for price in priceCache.values { priceSum += price }
        hasher.combine(priceSum)
        hasher.combine(priceHistory.count)
        var histDayCount = 0
        var histValueSum = Decimal.zero
        for series in priceHistory.values {
            histDayCount += series.count
            for value in series.values { histValueSum += value }
        }
        hasher.combine(histDayCount)
        hasher.combine(histValueSum)
        return hasher.finalize()
    }

    /// Run the reconstructor once and cache every projection the body
    /// needs: the points, the `Double` series for the canvas, and the
    /// min/max band the sparkline normalizes against.
    ///
    /// **2026-06-13 perf.** The reconstruction is heavy `Decimal` math
    /// over the full (now up to 1,000-tx/chain) history. It used to run
    /// synchronously on the main actor inside `.task`, freezing the
    /// wallet home for 1–2s on unlock and when the lazy `List` rebuilt
    /// this row on back-navigation. Now we copy the few needed fields
    /// into `Sendable` snapshots on the main actor (cheap — no Decimal
    /// math, no extra faulting) and run the reconstruction on a detached
    /// background task; only the small result lands back on the main
    /// actor. The chart paints a frame later, but the screen never
    /// freezes.
    private func rebuildPoints() async {
        // Snapshot on the main actor (these are main-context @Models), then
        // run the transaction-only reconstruction OFF the main actor. Prices
        // are used only to convert each transaction amount into local currency;
        // they never create chart points.
        let txSnapshots = transactions.map {
            BalanceHistoryReconstructor.HistoryTx(
                occurredAt: $0.occurredAt,
                statusRaw: $0.statusRaw,
                tokenSymbol: $0.tokenSymbol,
                tokenContract: $0.tokenContract,
                amountRaw: $0.amountRaw,
                directionRaw: $0.directionRaw,
                counterparty: $0.counterparty
            )
        }
        let cache = priceCache
        let history = priceHistory
        let range = currentRange
        let own = ownAddresses

        // Reconstruction OFF the main actor.
        let reconstructed = await Task.detached(priority: .userInitiated) {
            BalanceHistoryReconstructor.reconstruct(
                txSnapshots: txSnapshots,
                priceCache: cache,
                priceHistory: history,
                ownAddresses: own,
                range: range
            )
        }.value

        // Back on the main actor — bail if the inputs changed while we
        // were computing (a newer `.task(id:)` pass superseded us).
        guard !Task.isCancelled else { return }
        let resolved = reconstructed.count >= 2
            ? reconstructed
            : Self.zeroBaseline(for: range)
        chartPoints = resolved
        sparkValues = resolved.map { fiatAsDouble($0.fiat) }
        sparkMin = sparkValues.min() ?? 0
        sparkMax = sparkValues.max() ?? 0
    }

    /// Synthesize a 2-point flat baseline at fiat = 0 spanning the
    /// current range — used when the reconstructor returns < 2 real
    /// points (fresh wallet, no transactions yet). The sparkline
    /// renders a calm horizontal line at the zero axis instead of
    /// the prior "Balance history / Your balance changes will
    /// appear here" empty card per 2026-06-09 user direction.
    private static func zeroBaseline(for range: BalanceHistoryRange) -> [BalancePoint] {
        let now = Date()
        let span: TimeInterval
        switch range {
        case .hour:  span = 3_600           // 1 hour
        case .day:   span = 86_400          // 1 day
        case .week:  span = 86_400 * 7      // 1 week
        case .month: span = 86_400 * 30     // ~1 month
        case .year:  span = 86_400 * 365    // ~1 year
        case .all:   span = 86_400 * 30     // ~1 month as a calm default for "all" without any data
        }
        let earlier = now.addingTimeInterval(-span)
        return [
            BalancePoint(timestamp: earlier, fiat: 0),
            BalancePoint(timestamp: now, fiat: 0)
        ]
    }

    /// Per-point horizontal position in `[0, 1]` from each sample's timestamp —
    /// `(t − first) / (last − first)` (Part 4.3, 2026-06-19). This is the real
    /// time x-axis: samples sit at their true time, so sparse-then-dense history
    /// is spaced honestly instead of every sample getting equal width. Returns
    /// `[]` for a degenerate span (≤1 point or all-same-time) — the renderer
    /// then falls back to index spacing (a flat 2-point baseline looks the same
    /// either way).
    private static func timeFractions(for points: [BalancePoint]) -> [Double] {
        guard let first = points.first?.timestamp,
              let last = points.last?.timestamp,
              last > first else { return [] }
        let span = last.timeIntervalSince(first)
        return points.map { max(0, min(1, $0.timestamp.timeIntervalSince(first) / span)) }
    }

    /// Up / down / flat from the windowed curve's endpoints (first vs last) —
    /// drives `BalanceAreaChart`'s semantic stroke/fill/glow color, the same
    /// way the main card derives its sign.
    private static func chartSign(for points: [BalancePoint]) -> UniColors.BalanceCard.Sign {
        guard let first = points.first?.fiat, let last = points.last?.fiat else { return .flat }
        if last > first { return .up }
        if last < first { return .down }
        return .flat
    }

    // MARK: - Delta caption

    /// Signed-delta text for the accessibility readout. (The on-screen
    /// `deltaCaption` was removed per the 2026-06-09 direction — the
    /// hero amount carries the displayed number; the chart provides
    /// shape, not a second numeric readout. `2026-06-13`: removed the
    /// now-dead `deltaCaption` / `deltaColor` that lingered after that
    /// and referenced the relocated `scrubIndex`.)
    private func deltaText(delta: Decimal) -> String {
        let sign: String
        if delta > 0 { sign = "+" } else if delta < 0 { sign = "−" } else { sign = "" }
        let magnitude = abs(delta)
        return sign + WalletFormatting.fiat(magnitude, currencyCode: currencyCode)
    }

    /// Localized "this week" / "this month" / "this year" / "all
    /// time" / "today" suffix on the resting delta caption.
    private var rangeLabel: LocalizedStringKey {
        switch currentRange {
        case .hour:  return "this hour"
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

    // 2026-06-09 — `emptyState` removed per user direction. The
    // chart now renders a flat baseline at fiat = 0 when the
    // reconstructor returns < 2 points (see `zeroBaseline(for:)`
    // above) so the surface is consistent at every wallet age. The
    // old "Balance history" headline + "Your balance changes will
    // appear here" subtitle copy are gone.

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
