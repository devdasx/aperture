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
}

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
    /// **2026-06-12 — per-symbol price fallback.** For tokens the
    /// wallet held in the past but no longer holds, currentBalances
    /// has zero rows for that token → fiatPerUnit map can't price
    /// it. This dict (keyed by uppercased symbol) is the fallback
    /// the reconstructor uses to value past holdings of fully
    /// cashed-out tokens. Default empty so old call sites still
    /// compile; new call sites read PriceCacheRepository.
    let priceCache: [String: Decimal]
    /// **2026-06-12 — per-day historical close prices.** Keyed by
    /// uppercased symbol → `[yyyymmdd: close]`. The reconstructor
    /// values each curve point at its day's close, so a token
    /// whose price has fallen 99% since the user held it renders
    /// past peaks at their honest then-value ($4000) rather than
    /// today's collapsed valuation ($50). Populated by the chart's
    /// `.task` from `HistoricalPriceRepository`.
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
            // Pre-task fallback: the zero baseline projects to two
            // zero values (min = max = 0), exactly what
            // `rebuildPoints()` would produce for the same input.
            let values = chartPoints.isEmpty
                ? points.map { fiatAsDouble($0.fiat) }
                : sparkValues
            SparklineChart(
                points: values,
                minValue: chartPoints.isEmpty ? 0 : sparkMin,
                maxValue: chartPoints.isEmpty ? 0 : sparkMax,
                onScrub: { index in
                    // Map the scrubbed index → the touched point's fiat
                    // and publish it to the hero via the @Observable
                    // model. Called from the gesture; does NOT
                    // re-evaluate this body (no `scrubIndex` @State here
                    // anymore — that was the long-scrub freeze).
                    let scrubbed: Decimal? = {
                        guard let idx = index, idx >= 0, idx < points.count else { return nil }
                        return points[idx].fiat
                    }()
                    withAnimation(.snappy(duration: 0.18)) {
                        scrubModel?.fiat = scrubbed
                    }
                }
            )
            .frame(height: 140)
            .padding(.horizontal, -(UniSpacing.l - 5))
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
    /// transaction set (count + newest timestamp), the current
    /// balances' total cached fiat (a refresh can re-price rows
    /// without changing counts), the selected range, and the display
    /// currency. O(N) scalar scans per body pass — orders of
    /// magnitude cheaper than the reconstruction they gate.
    private var rebuildKey: Int {
        // **2026-06-13 perf.** `rebuildKey` is read on every chart body
        // pass (it gates the `.task(id:)` reconstruction). The previous
        // version summed every `Decimal` in `priceCache` AND in the
        // whole `priceHistory` nest (thousands of slow Decimal adds) and
        // scanned every transaction — hundreds of ms per render once the
        // wallet had deep history, which froze the screen on unlock /
        // navigation. Now it uses COUNTS only: O(symbols + balances),
        // all tiny collections. Trade-off: an in-place price-value edit
        // or a confirmed→failed status flip at an unchanged row count
        // won't re-trigger the reconstruction until the next count/
        // balance change — a rare edge the next refresh closes, well
        // worth a smooth main screen.
        var hasher = Hasher()
        hasher.combine(transactions.count)
        hasher.combine(currentBalances.count)
        // O(balances) — a handful of held rows, not the tx history.
        var fiatTotal = Decimal.zero
        for balance in currentBalances {
            fiatTotal += balance.fiatValueCached
        }
        hasher.combine(fiatTotal)
        hasher.combine(selectedRangeRaw)
        hasher.combine(currencyCode)
        hasher.combine(priceCache.count)
        hasher.combine(priceHistory.count)
        // O(symbols) — number of day-keys per symbol, no value summing.
        var histDayCount = 0
        for series in priceHistory.values { histDayCount += series.count }
        hasher.combine(histDayCount)
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
        // Snapshot on the main actor (these are main-context @Models).
        let txSnapshots = transactions.map {
            BalanceHistoryReconstructor.HistoryTx(
                occurredAt: $0.occurredAt,
                statusRaw: $0.statusRaw,
                tokenSymbol: $0.tokenSymbol,
                tokenContract: $0.tokenContract,
                amountRaw: $0.amountRaw,
                directionRaw: $0.directionRaw
            )
        }
        let balanceSnapshots = currentBalances.map {
            BalanceHistoryReconstructor.HistoryBalance(
                tokenSymbol: $0.tokenSymbol,
                tokenContract: $0.tokenContract,
                rawBalance: $0.rawBalance,
                decimals: $0.decimals,
                fiatValueCached: $0.fiatValueCached
            )
        }
        let cache = priceCache
        let history = priceHistory
        let range = currentRange

        // Heavy Decimal reconstruction OFF the main actor.
        let reconstructed = await Task.detached(priority: .userInitiated) {
            BalanceHistoryReconstructor.reconstruct(
                txSnapshots: txSnapshots,
                balanceSnapshots: balanceSnapshots,
                priceCache: cache,
                priceHistory: history,
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

    /// Precomputed `points.min()` / `points.max()`, supplied by the
    /// parent alongside the memoized series so the per-drag-tick
    /// normalization + haptic math never rescans the array.
    let minValue: Double
    let maxValue: Double

    /// Published per scrub index change (and `nil` on release). The
    /// parent writes the scrubbed point's fiat into its `ChartScrubModel`
    /// in this closure — a closure rather than a `@Binding` so a scrub
    /// tick never re-evaluates the PARENT's body (the 2026-06-13
    /// long-scrub freeze: the binding invalidated `BalanceHistoryChart`,
    /// re-running its reconstruction-gating `rebuildKey` + value
    /// projection ~60×/s).
    let onScrub: (Int?) -> Void

    /// The scrubbed index — LOCAL `@State`, so a tick invalidates ONLY
    /// this view, never the parent.
    @State private var scrubIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // **The static curve.** Its inputs (points / min / max)
                // are INVARIANT during a scrub — only the cursor moves.
                // Extracting it into an `Equatable` subview makes SwiftUI
                // skip recomputing the two O(N) Catmull-Rom paths (stroke
                // + gradient fill) on every drag tick. THIS is the
                // long-scrub freeze fix: the reconstructor emits up to
                // ~2,000 points (two per in-window transaction), and the
                // old body rebuilt both paths over all of them ~60×/s
                // while scrubbing, saturating the main thread.
                SparklineCurve(points: points, minValue: minValue, maxValue: maxValue)
                    .equatable()
                    // **2026-06-14 scroll-lag fix.** Flatten the curve into a
                    // cached Metal-backed bitmap. The reconstructor emits up
                    // to ~2,000 points (two per in-window transaction), so the
                    // stroke + gradient-fill are heavy vector paths; without
                    // this, the GPU re-rasterized them on EVERY scroll frame
                    // while the chart row was on screen → the "laggy while
                    // scrolling the list" the user reported. `.drawingGroup()`
                    // rasterizes once (and only re-rasterizes when `.equatable()`
                    // lets the data-driven body actually change), so scrolling
                    // just composites a flat texture. The scrub cursor is a
                    // SIBLING in the ZStack (not inside this), so it stays live
                    // vector and is unaffected.
                    .drawingGroup()

                // **Scrub cursor — the only thing that moves per tick.**
                // Its position is computed O(1) from the index, never by
                // rescanning / re-projecting all N points.
                if let index = scrubIndex,
                   points.count > 1,
                   index >= 0,
                   index < points.count
                {
                    let pt = cursorPoint(index: index, in: size)
                    Rectangle()
                        .fill(UniColors.Text.tertiary.opacity(0.4))
                        .frame(width: 1)
                        .position(x: pt.x, y: size.height / 2)
                    Circle()
                        .stroke(UniColors.Text.primary.opacity(0.3), lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .position(pt)
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
        // Time order is data, not language — pin the canvas to L→R
        // in every locale (Rule #11 §C carve-out).
        .environment(\.layoutDirection, .leftToRight)
    }

    /// O(1) cursor point for `index` — x from the index fraction, y from
    /// the single value's normalization (the same mapping
    /// `SparklineCurve.normalizedPoints` uses, but for one point so a
    /// scrub tick never rebuilds the whole projected array).
    private func cursorPoint(index: Int, in size: CGSize) -> CGPoint {
        let count = points.count
        let x = count > 1 ? CGFloat(index) / CGFloat(count - 1) * size.width : 0
        let range = maxValue - minValue
        let padding: CGFloat = 0.1
        let normalized = range > 0 ? (CGFloat(points[index] - minValue) / CGFloat(range)) : 0.5
        let y = size.height - (normalized * size.height * (1 - 2 * padding) + size.height * padding)
        return CGPoint(x: x, y: y)
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
        // comparable across days vs. years vs. flat wallets. The
        // band comes precomputed from the parent — no per-tick
        // `min()` / `max()` rescans.
        let range = max(maxValue - minValue, 0.0001)
        let normalizedSlope = abs(curr - prev) / range
        return Float(min(0.8, 0.15 + normalizedSlope * 2.2))
    }

}

// MARK: - SparklineCurve (static, equatable — skips per-scrub recompute)

/// The INVARIANT part of the sparkline: the gradient fill + the
/// Catmull-Rom stroke. Split out of `SparklineChart` (2026-06-13
/// long-scrub freeze fix) so that a scrub tick — which moves only the
/// cursor — does NOT recompute the two O(N) Bézier paths. Conforming to
/// `Equatable` and applying `.equatable()` at the call site makes
/// SwiftUI skip this view's body whenever `(points, minValue, maxValue)`
/// are unchanged — exactly the case on every drag frame, when the curve
/// is fixed and only `scrubIndex` (which lives in the parent) changed.
private struct SparklineCurve: View, Equatable {

    let points: [Double]
    let minValue: Double
    let maxValue: Double

    // `nonisolated` — SwiftUI `View` structs are `@MainActor`-isolated
    // under Swift 6, but `Equatable.==` must be callable off-actor by
    // the `.equatable()` diffing machinery; the compared values are
    // immutable `let`s, so it's race-free.
    nonisolated static func == (lhs: SparklineCurve, rhs: SparklineCurve) -> Bool {
        lhs.minValue == rhs.minValue
            && lhs.maxValue == rhs.maxValue
            && lhs.points == rhs.points
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let canvasPoints = normalizedPoints(in: size)
            ZStack {
                // Gradient fill — the Catmull-Rom path closed at the
                // baseline, top-to-bottom 25%→0% fade so the area reads
                // as glow, not a hard fill.
                gradientFill(points: canvasPoints, in: size)
                // The sparkline stroke — 2pt, rounded caps + joins.
                sparklinePath(points: canvasPoints)
                    .stroke(
                        UniColors.Text.primary,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }

    // MARK: - Path math

    /// Project the data series into canvas space with a 10% top
    /// and bottom padding band so the curve never grazes the edges
    /// of the chart frame. Empty input returns an empty array; the
    /// caller renders nothing in that case.
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard points.count > 1 else { return [] }
        let minVal = minValue
        let range = maxValue - minValue
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
