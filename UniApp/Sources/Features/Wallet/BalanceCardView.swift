import SwiftUI

/// The flagship wallet-home **balance card** — rebuilt pixel-faithful to
/// the design handoff (`design_handoff_balance_card 2/`).
///
/// **Design intent (Rule #2 §D.1):** one calm surface that tells the user
/// everything about their wallet at a glance — who it is, what it's worth,
/// how it moved today, and the shape of that movement — and lets them act
/// (copy an address, switch wallet, hide the figure, scrub the history)
/// without leaving it.
///
/// **Anatomy (top → bottom, per the handoff):**
/// 1. **Header** — the iris avatar disc + wallet name with a `⌄` chevron
///    (one ≥44pt tap target → the wallet switcher) + a "Copy address"
///    action beneath the name (→ the Receive sheet); a circular eye
///    button on the right (toggles per-wallet balance visibility).
/// 2. **"Total balance"** caption.
/// 3. **Balance** — a large tabular number: currency code (muted) +
///    integer (primary) + decimals (fainter tint). Monochrome in every
///    state — only the pill + chart carry the up/down color.
/// 4. **Change row** — a pill (▲/▼ + percent; green up / red down /
///    neutral flat) + a muted "+X today" amount (true U+2212 minus for
///    losses).
/// 5. **Chart** — the full-bleed `BalanceAreaChart`.
/// 6. **Segmented selector** — `1H · 1D · 1W · 1M · 1Y · All`.
/// 7. **Watermark** — the iris behind the value, top-right, ~5% opacity.
///
/// **Surface (Rule #4 §B via `UniColors.BalanceCard`):** the card is its
/// own gradient surface — NOT the system grouped-card fill. It adapts to
/// the app's `\.colorScheme` (dark gradient in dark mode, light gradient
/// in light mode) exactly like the handoff's two-column reference.
/// 30pt radius, 24pt inner padding, chart bleeds to the edges, 22pt
/// bottom pad below the selector.
///
/// **States (handoff §States):** up / down / flat / zero / hidden — see
/// `resolvedState`. Zero hides the chart + selector and shows the
/// "receive or transfer" prompt + an Add funds button (→ Receive; never
/// buy — Rule #16 honesty). Hidden masks the figure to `••••••`, the pill
/// to `••••`, flattens the chart to a muted line, and changes the eye glyph
/// to the slashed eye-off icon; it persists per wallet.
///
/// **RTL (Rule #11):** balance / percent / amount runs pin LTR; the
/// chrome (name, copy action) follows the ambient direction.
struct BalanceCardView: View {
    // MARK: - Inputs

    /// The active wallet's stable id — keys the per-wallet hidden flag.
    let walletId: UUID?
    let walletName: String
    /// The wallet's resting total fiat (the value when not scrubbing).
    let totalFiat: Decimal
    let currencyCode: String
    /// When the wallet's balances + history were last refreshed (the latest
    /// per-chain aggregate `updatedAt`). `nil` before the first scan — the
    /// "Updated …" caption under the wallet name is hidden then.
    let lastUpdated: Date?

    /// The full transaction history + price ladders, fed straight to
    /// `BalanceHistoryReconstructor` to build the curve.
    let transactions: [TransactionRecord]
    /// The active wallet's OWN addresses (lowercased). Transactions whose
    /// counterparty is in this set are self-transfers and are dropped from the
    /// chart reconstruction (they net to zero on the balance).
    let ownAddresses: Set<String>
    let priceCache: [String: Decimal]
    let priceHistory: [String: [Int: Decimal]]
    let hourlyHoldings: [BalanceHourlyHolding]
    let hourlyPriceSnapshots: [BalanceHourlyPriceSnapshot]

    /// Scrub channel — the hero (this card's balance label) renders the
    /// touched point's value while dragging; resets to `totalFiat` on
    /// release. Shared with the parent so a drag never re-renders the
    /// whole wallet-home body.
    let scrubModel: ChartScrubModel

    // MARK: - Interactions (wired to existing surfaces)

    /// Opens the existing wallet switcher (handoff: tap name → switcher).
    let onSwitchWallet: () -> Void
    /// Opens Receive from the zero-state Add funds button.
    let onAddFunds: () -> Void

    // MARK: - Environment / persisted state

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-wallet balance-visibility flag. Keyed by wallet id so each
    /// wallet remembers its own hidden state (handoff: "persists per
    /// wallet"). A fresh `@AppStorage` whose key embeds the id; recomputed
    /// when the active wallet changes via `.id(walletId)` on the card.
    @AppStorage private var isHidden: Bool

    /// Selected range — persisted across launches (shared key with the
    /// prior chart so the user's pick survives this redesign). Default
    /// `.all`.
    @AppStorage("walletHomeBalanceHistoryRange")
    private var selectedRangeRaw: String = BalanceHistoryRange.all.rawValue

    // MARK: - Reconstructed curve (memoized off-body)

    @State private var points: [BalancePoint] = []
    @State private var values: [Double] = []
    /// Per-point horizontal position in `[0, 1]` from each sample's
    /// transaction/range timestamp — parallel to `values`.
    @State private var xFractions: [Double] = []
    @State private var minValue: Double = 0
    @State private var maxValue: Double = 0
    init(
        walletId: UUID?,
        walletName: String,
        totalFiat: Decimal,
        currencyCode: String,
        lastUpdated: Date?,
        transactions: [TransactionRecord],
        ownAddresses: Set<String>,
        priceCache: [String: Decimal],
        priceHistory: [String: [Int: Decimal]],
        hourlyHoldings: [BalanceHourlyHolding],
        hourlyPriceSnapshots: [BalanceHourlyPriceSnapshot],
        scrubModel: ChartScrubModel,
        onSwitchWallet: @escaping () -> Void,
        onAddFunds: @escaping () -> Void
    ) {
        self.walletId = walletId
        self.walletName = walletName
        self.totalFiat = totalFiat
        self.currencyCode = currencyCode
        self.lastUpdated = lastUpdated
        self.transactions = transactions
        self.ownAddresses = ownAddresses
        self.priceCache = priceCache
        self.priceHistory = priceHistory
        self.hourlyHoldings = hourlyHoldings
        self.hourlyPriceSnapshots = hourlyPriceSnapshots
        self.scrubModel = scrubModel
        self.onSwitchWallet = onSwitchWallet
        self.onAddFunds = onAddFunds
        // Per-wallet visibility key; a nil id (no active wallet) shares a
        // single fallback key — harmless because there's nothing to mask.
        let key = "balanceCardHidden." + (walletId?.uuidString ?? "none")
        self._isHidden = AppStorage(wrappedValue: false, key)
    }

    // MARK: - Derived state

    private var currentRange: BalanceHistoryRange {
        BalanceHistoryRange(rawValue: selectedRangeRaw) ?? .all
    }

    private var boostContrast: Bool { legibilityWeight == .bold }

    /// The pill's baseline = the **first point in the window** (2026-06-19
    /// Bug 4 fix). The change/percent measure from the real range-start value
    /// to the trailing edge. When the window starts at 0 — the wallet was
    /// funded DURING the window (a young wallet's 1Y, or `.all` whose first
    /// event is the funding) — a percent off a zero base is undefined, so the
    /// pill suppresses the percent (`baselineIsZero`) and shows the absolute
    /// amount only, never a fabricated/huge number. (The old code skipped to
    /// the first NON-zero point, which manufactured a baseline and produced
    /// the +1136.37% the user saw.)
    private var baselineFiat: Decimal {
        points.first?.fiat ?? 0
    }

    /// `true` when the window starts at a zero balance (funded during the
    /// window) → the percent is undefined and is suppressed in the pill.
    private var baselineIsZero: Bool { baselineFiat <= 0 }

    /// Gain / loss / flat — measured from the SAME reconstructed `points`
    /// array the chart draws: `baselineFiat` (the first HELD balance in the
    /// window) vs `points.last` (the trailing edge). **2026-06-16:**
    /// re-united with the chart so the pill and the line cannot disagree —
    /// the change, percent, and sign all read from `points`, the single
    /// transaction-derived truth source. The reconstructor anchors
    /// `points.last` to the wallet's real current balance (the hero
    /// figure) AND starts the curve at the first held balance, so the pill
    /// stays honest AND consistent with the curve. Flat when
    /// `last == baseline` (no net movement across the window).
    private var sign: UniColors.BalanceCard.Sign {
        guard let last = points.last else { return .flat }
        let baseline = baselineFiat
        if last.fiat > baseline { return .up }
        if last.fiat < baseline { return .down }
        return .flat
    }

    /// The signed change over the selected range — `points.last −
    /// baselineFiat`, off the chart's own endpoints (first HELD balance →
    /// trailing edge).
    private var change: Decimal {
        guard let last = points.last else { return 0 }
        return last.fiat - baselineFiat
    }

    /// The percent change over the range — `(last − baseline) / baseline ×
    /// 100`, off the chart's own endpoints. `0` when the baseline is a
    /// genuine zero (the degenerate all-zero curve — e.g. only an outgoing
    /// first tx): a percent off a zero base is undefined, so the pill falls
    /// back to "0.00% / No change" rather than dividing by zero or
    /// fabricating a percent.
    private var changePercent: Double {
        guard let last = points.last else { return 0 }
        let baseline = baselineFiat
        guard baseline > 0 else { return 0 }
        let baselineD = NSDecimalNumber(decimal: baseline).doubleValue
        let lastD = NSDecimalNumber(decimal: last.fiat).doubleValue
        guard baselineD != 0 else { return 0 }
        return (lastD - baselineD) / abs(baselineD) * 100
    }

    /// Which of the five states the card renders.
    private enum CardState: Equatable { case value, zero, hidden }
    private var resolvedState: CardState {
        // Hiding always wins — the eye must hide the balance even on a fresh
        // / $0 wallet. The zero state previously shadowed `.hidden` (it was
        // checked first), so tapping the eye on a zero wallet did nothing.
        if isHidden { return .hidden }
        if totalFiat <= 0 { return .zero }   // zero overrides the value/change state (handoff)
        return .value
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            watermark
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 2)
                Text("Total balance")
                    .font(UniTypography.BalanceCard.label)
                    .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                Group {
                    switch resolvedState {
                    case .zero:
                        zeroBody
                    case .hidden, .value:
                        valueBody
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous))
        // Flat white surface like the holdings / transactions cards
        // (2026-06-19 user direction) — the gradient + inner specular edge
        // were dropped; only the light-mode hairline remains.
        .overlay(hairlineOverlay)
        // No drop shadow: the card sits flat on the page like the holdings /
        // transactions cards below it (per user direction 2026-06-16 — the
        // earlier spec shadow read as a grey "tray" behind the card). The
        // inner specular edge + hairline still give the surface its depth.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: resolvedState)
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: totalFiat)
        .task(id: rebuildKey) { await rebuild() }
    }

    /// "Updated 2 min ago" — the localized relative time of the last balance/
    /// history refresh. Recomputed each render (the card re-renders on every
    /// refresh + the 30s auto-refresh), so it stays current without a timer.
    private static func updatedCaption(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return String(format: String.apertureLocalized("Updated %@"), relative)
    }

    // MARK: - Surface

    /// Flat surface — the same fill as every other content card on the
    /// home (2026-06-19 user direction: "make the card color same as
    /// other cards 'white' not gradient"). No gradient, no radial lift.
    private var cardSurface: some View {
        UniColors.Background.secondary
    }

    @ViewBuilder
    private var hairlineOverlay: some View {
        if colorScheme == .light {
            RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous)
                .stroke(UniColors.BalanceCard.hairline(colorScheme), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Watermark

    private var watermark: some View {
        // Top-LEFT corner, half-clipped (2026-06-19 user direction): the
        // iris is pinned to the leading edge and shifted half its width
        // off-screen-left so only its right half shows in the corner. The
        // card's `.clipShape` crops the overhang.
        Image(colorScheme == .dark ? "IrisWatermarkWhite" : "IrisWatermarkInk")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 220, height: 220)
            .opacity(UniColors.BalanceCard.watermarkOpacity(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: -110, y: -30)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        // 2026-06-23 — the wallet avatar moved OUT of the card and onto the
        // app bar's leading side (it opens Customise wallet there now). The
        // card header is just the name + last-updated + the eye.
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 1) {
                // Name + chevron — one ≥44pt tap target → switcher.
                Button(action: switchWallet) {
                    HStack(spacing: 3) {
                        Text(verbatim: walletName)
                            .font(UniTypography.BalanceCard.walletName)
                            .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Switch wallet, currently \(walletName)"))

                // Last refresh of balances + history. LIVE — a 1s
                // `TimelineView` re-renders the relative time so it ticks
                // ("Updated 2s ago" → "3s ago" …) without a manual timer
                // (2026-06-19 user direction: "updated in … should be
                // live"). Hidden until the first scan completes.
                if let lastUpdated {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(verbatim: Self.updatedCaption(lastUpdated))
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
                            .lineLimit(1)
                    }
                }
            }
            // Both header tap targets clear the 44pt floor via the row's
            // intrinsic height + the chevron's vertical reach.
            .frame(minHeight: 44, alignment: .top)

            Spacer(minLength: UniSpacing.xs)

            // Eye / visibility button.
            Button(action: toggleHidden) {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(UniColors.BalanceCard.eyeGlyph(colorScheme))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(UniColors.BalanceCard.eyeButtonFill(colorScheme))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel(Text(isHidden ? "Show balance" : "Hide balance"))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Value body (up / down / flat / hidden)

    @ViewBuilder
    private var valueBody: some View {
        tappableBalanceNumber
            .padding(.bottom, 14)

        // Hidden on a fresh / $0 wallet → show ONLY the masked figure + the
        // "Balance hidden" pill. No empty flat chart, no range tabs
        // (2026-06-23 user direction). A wallet with a real balance keeps the
        // (flattened) chart + ranges even when hidden.
        if !isHidden || totalFiat > 0 {
            changeRow

            BalanceAreaChart(
                values: chartValues,
                xFractions: chartXFractions,
                minValue: chartMin,
                maxValue: chartMax,
                timestamps: isHidden ? [] : points.map(\.timestamp),
                sign: chartSign,
                onScrub: { selection in
                    scrubModel.update(selection: selection)
                },
                onScrubBegin: {
                    UniHapticEngine.shared.play(.contextualImpact(.whisper))
                }
            )
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 120)
            .padding(.top, 14)
            .allowsHitTesting(resolvedState == .value) // hidden chart isn't scrubbable
            .accessibilityHidden(true)

            TimeRangeSelector(
                selectedRaw: $selectedRangeRaw,
                colorScheme: colorScheme
            )
            // +10pt breathing room between the chart and the range selector
            // (2026-06-19 user direction) — was -6.
            .padding(.top, 4)
            .padding(.bottom, UniSpacing.balanceCardBottom)
        } else {
            changeRow
                .padding(.bottom, UniSpacing.balanceCardBottom)
        }
    }

    /// The chart series — flattened to a single neutral mid value in the
    /// hidden state so no value shape is exposed (handoff §Hidden).
    private var chartValues: [Double] {
        isHidden ? Array(repeating: 0, count: max(values.count, 2)) : values
    }
    /// Time-proportional x for the real curve; `[]` while hidden so the
    /// masked flat line falls back to (visually identical) index spacing.
    private var chartXFractions: [Double] {
        isHidden ? [] : xFractions
    }
    private var chartMin: Double { isHidden ? 0 : minValue }
    private var chartMax: Double { isHidden ? 0 : maxValue }
    private var chartSign: UniColors.BalanceCard.Sign { isHidden ? .flat : sign }

    // MARK: - Balance number (3 runs)

    private var tappableBalanceNumber: some View {
        balanceNumber
            // Tapping the balance toggles hide/show — same as the eye
            // button. This is deliberately shared by the value, hidden, and
            // zero states so a fresh wallet's "0.000" behaves exactly like a
            // funded wallet's balance.
            .contentShape(Rectangle())
            .onTapGesture { toggleHidden() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(isHidden ? "Show balance" : "Hide balance"))
    }

    private var balanceNumber: some View {
        let parts = WalletFormatting.fiatParts(totalFiat, currencyCode: currencyCode)
        let animatedFiat = NSDecimalNumber(decimal: scrubModel.fiat ?? totalFiat).doubleValue
        let scrubActive = scrubModel.isActive
        // Currency-code run (muted), shown only when it leads (en).
        let currencyRun = Text(verbatim: parts.currency + (parts.currency.isEmpty ? "" : " "))
            .font(UniTypography.BalanceCard.currency)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))

        return Group {
            if isHidden {
                // Masked figure — currency code + dots. iOS 26 deprecates
                // `Text + Text`; compose via string interpolation, which
                // preserves each run's own font + color.
                let dots = Text(verbatim: "••••••")
                    .font(UniTypography.BalanceCard.balance)
                    .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
                Text("\(currencyRun)\(dots)")
                    .tracking(2)
            } else {
                composedBalance(parts)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .tracking(-1.3) // ≈ −0.03em at 44pt
        .contentTransition(reduceMotion || scrubActive ? .identity : .numericText())
        .environment(\.layoutDirection, .leftToRight) // numbers always LTR (Rule #11)
        .animation(reduceMotion || scrubActive ? nil : .smooth(duration: 0.28), value: animatedFiat)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: isHidden)
    }

    /// The integer (primary) + decimals (fainter), with the currency code
    /// run placed per the locale (lead for en, trail for de). While
    /// scrubbing, the displayed value is the scrubbed point.
    private func composedBalance(_ restingParts: WalletFormatting.FiatParts) -> Text {
        let displayed = scrubModel.fiat ?? totalFiat
        let parts = WalletFormatting.fiatParts(displayed, currencyCode: currencyCode)

        let currency = Text(verbatim: parts.currency)
            .font(UniTypography.BalanceCard.currency)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
        let integer = Text(verbatim: parts.integer)
            .font(UniTypography.BalanceCard.balance)
            .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme))
        let fraction = Text(verbatim: parts.fraction ?? "")
            .font(UniTypography.BalanceCard.balance)
            .foregroundStyle(UniColors.BalanceCard.decimals(colorScheme, boostContrast: boostContrast))
        let gap = Text(verbatim: " ")
            .font(UniTypography.BalanceCard.currency)

        // iOS 26 deprecates `Text + Text`; compose via string
        // interpolation — each interpolated `Text` keeps its own font +
        // foregroundStyle.
        if parts.currency.isEmpty {
            return Text("\(integer)\(fraction)")
        }
        return parts.currencyLeads
            ? Text("\(currency)\(gap)\(integer)\(fraction)")
            : Text("\(integer)\(fraction)\(gap)\(currency)")
    }

    // MARK: - Change row

    @ViewBuilder
    private var changeRow: some View {
        HStack(spacing: 10) {
            if isHidden {
                // Masked pill + "Balance hidden".
                changePill(text: "••••", systemImage: nil, sign: .flat)
                Text("Balance hidden")
                    .font(UniTypography.BalanceCard.amount)
                    .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
            } else if let scrubbedAt = scrubModel.timestamp {
                // **Scrubbing (2026-06-19).** Hide the PnL + percent and show
                // the touched point's date & time instead (the hero shows that
                // point's value). The time reuses `changePill` (a neutral
                // chip) so the row height — and the card — stays identical to
                // the resting [percent pill][amount] layout; no resize on drag.
                changePill(text: scrubTimeText(scrubbedAt), systemImage: nil, sign: .flat)
                    .frame(minWidth: 86, alignment: .center)
                Text(verbatim: scrubDateText(scrubbedAt))
                    .font(UniTypography.BalanceCard.amount)
                    .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
                    .monospacedDigit()
                    .frame(minWidth: 104, alignment: .leading)
                    .environment(\.layoutDirection, .leftToRight) // date reads LTR with the time chip
            } else {
                // The pill is ALWAYS present so the card never resizes when the
                // user switches ranges (2026-06-19 fix). Off a zero baseline
                // (funded during the window) the percent is undefined, so the
                // pill reads "New" — no fabricated number, no arrow — instead
                // of being hidden (which made the change row, and the whole
                // card, shorter on those ranges).
                changePill(
                    text: percentText,
                    systemImage: baselineIsZero
                        ? nil
                        : (sign == .up ? "arrow.up" : (sign == .down ? "arrow.down" : nil)),
                    sign: sign
                )
                Text(verbatim: amountText)
                    .font(UniTypography.BalanceCard.amount)
                    .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
                    .environment(\.layoutDirection, .leftToRight) // amount + sign LTR
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { transaction in
            if scrubModel.isActive {
                transaction.disablesAnimations = true
            }
        }
    }

    private func changePill(text: String, systemImage: String?, sign: UniColors.BalanceCard.Sign) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
            }
            Text(verbatim: text)
                .font(UniTypography.BalanceCard.pill)
                .monospacedDigit()
                .tracking(systemImage == nil && isHidden ? 2 : 0)
        }
        .foregroundStyle(UniColors.BalanceCard.accent(sign, colorScheme))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(UniColors.BalanceCard.pillBackground(sign, colorScheme))
        )
        .environment(\.layoutDirection, .leftToRight) // ▲/▼ + percent LTR
    }

    /// `2.41%` — always with two decimals, no sign (the arrow carries it).
    /// **2026-06-16:** the pill always reads a REAL percent (off the first
    /// HELD balance — see `baselineFiat`), the same as the shorter ranges.
    /// In the degenerate all-zero curve `changePercent` is `0`, so this
    /// reads `0.00%` (paired with "No change") — never an em-dash, never a
    /// divide-by-zero.
    private var percentText: String {
        // Off a zero baseline the percent is undefined (funded during the
        // window) — show "New" rather than a fabricated/huge number. The pill
        // stays present either way so the card height is constant across ranges.
        if baselineIsZero { return String.apertureLocalized("New") }
        let pct = abs(changePercent)
        return String(format: "%.2f%%", pct)
    }

    /// The range-correct trailing label (2026-06-19 Bug 4 fix) — the old
    /// code hardcoded "today" on every range (the "+JOD 742.993 today" the
    /// user saw on All). Each range now reads its own window.
    private var rangeLabel: String {
        switch currentRange {
        case .hour:  return String.apertureLocalized("past hour")
        case .day:   return String.apertureLocalized("today")
        case .week:  return String.apertureLocalized("past week")
        case .month: return String.apertureLocalized("past month")
        case .year:  return String.apertureLocalized("past year")
        case .all:   return String.apertureLocalized("all time")
        }
    }

    /// `+293.10 past week` / `−391.20 today` / `No change past month`. The
    /// minus is a true U+2212 (handoff §States: "not a hyphen"). The amount
    /// reads `last − baselineFiat` over the selected range, so the label and
    /// the value always describe the same window.
    private var amountText: String {
        let label = rangeLabel
        if change == 0 {
            return "\(String.apertureLocalized("No change")) \(label)"
        }
        let magnitude = abs(change)
        let formatted = WalletFormatting.fiat(magnitude, currencyCode: currencyCode)
        let signGlyph = sign == .up ? "+" : "\u{2212}"
        return "\(signGlyph)\(formatted) \(label)"
    }

    // MARK: - Scrub readout (date & time of the touched point)

    /// The scrubbed point's clock time in the device locale + timezone, e.g.
    /// "3:45 PM" — shown in the neutral pill while dragging. `FormatStyle`
    /// localizes it; no catalog string needed.
    private func scrubTimeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The scrubbed point's date in the device locale, e.g. "Jun 18, 2026" —
    /// shown beside the time chip while dragging.
    private func scrubDateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Zero state

    @ViewBuilder
    private var zeroBody: some View {
        // Balance reads 0.00 (no chart, no selector — handoff §Zero).
        tappableBalanceNumber

        Text("Add crypto to get started — receive or transfer it from another wallet.")
            .font(UniTypography.BalanceCard.zeroPrompt)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
            .padding(.bottom, 16)

        // The unified primary CTA (2026-06-20 user direction) — same glass
        // capsule + haptic as every other primary button, not a bespoke fill.
        UniButton(title: "Add funds", variant: .primary, systemImage: "plus") {
            onAddFunds()
        }
        .padding(.bottom, UniSpacing.l)
        .accessibilityLabel(Text("Add funds, opens Receive"))
    }

    // MARK: - Actions (+ handoff haptics)

    private func switchWallet() {
        UniHapticEngine.shared.play(.contextualImpact(.tap)) // `tap` on press
        onSwitchWallet()
    }

    private func toggleHidden() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
            isHidden.toggle()
        }
        UniHapticEngine.shared.play(.toggle) // `toggle` on value change
    }

    // MARK: - Accessibility

    /// One combined VoiceOver label (handoff §Accessibility): "Total
    /// balance, 12,480.25 …, up 2.41% today".
    private var accessibilityLabel: Text {
        if isHidden {
            return Text("Total balance hidden, double tap the eye button to reveal")
        }
        let value = WalletFormatting.fiat(totalFiat, currencyCode: currencyCode)
        if resolvedState == .zero {
            return Text("Total balance \(value). Add crypto to get started.")
        }
        let dir: String
        switch sign {
        case .up:   dir = String.apertureLocalized("up")
        case .down: dir = String.apertureLocalized("down")
        case .flat: dir = ""
        }
        if sign == .flat {
            return Text("Total balance \(value), no change today")
        }
        return Text("Total balance \(value), \(dir) \(percentText) today")
    }

    // MARK: - Reconstruction (off-main, per handoff range)

    /// Cheap dependency key over the transaction ledger, selected range,
    /// currency, and local price inputs. It gates the heavy reconstruction
    /// behind real changes while keeping balance rows out of the chart path.
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
        hasher.combine(totalFiat)
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
        hasher.combine(hourlyHoldings.count)
        for holding in hourlyHoldings {
            hasher.combine(holding.symbol)
            hasher.combine(holding.amount)
            hasher.combine(holding.currentPrice)
        }
        hasher.combine(hourlyPriceSnapshots.count)
        var hourlyPriceSum = Decimal.zero
        for snapshot in hourlyPriceSnapshots {
            hasher.combine(snapshot.symbol)
            hasher.combine(snapshot.fetchedAt)
            hourlyPriceSum += snapshot.price
        }
        hasher.combine(hourlyPriceSum)
        return hasher.finalize()
    }

    private func rebuild() async {
        // Snapshot the few needed transaction fields on the main actor (these
        // are main-context @Models), then run the transaction-only
        // reconstruction OFF the main actor. Prices only translate transaction
        // amounts into the active local currency.
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
        let currentTotal = totalFiat
        let hourHoldingsSnapshot = hourlyHoldings
        let hourPriceSnapshots = hourlyPriceSnapshots
        let now = Date()
        let hourCutoff = BalanceHistoryRange.hour.cutoff(from: now)
        let hasInHourTransaction = txSnapshots.contains {
            $0.statusRaw != TransactionStatus.failed.rawValue
                && $0.occurredAt >= hourCutoff
                && $0.occurredAt <= now
                && ($0.counterparty.isEmpty || !own.contains($0.counterparty.lowercased()))
        }

        let reconstructed = await Task.detached(priority: .userInitiated) {
            let transactionPoints = BalanceHistoryReconstructor.reconstruct(
                txSnapshots: txSnapshots,
                priceCache: cache,
                priceHistory: history,
                ownAddresses: own,
                range: range,
                now: now
            )
            guard range == .hour, !hasInHourTransaction else {
                return transactionPoints
            }
            return BalanceHourPortfolioReconstructor.reconstruct(
                holdings: hourHoldingsSnapshot,
                priceSnapshots: hourPriceSnapshots,
                currentTotalFiat: currentTotal,
                now: now
            )
        }.value

        guard !Task.isCancelled else { return }
        let resolved = Self.downsample(
            reconstructed.count >= 2 ? reconstructed : Self.zeroBaseline(for: range),
            maxCount: Self.maxRenderedChartSamples
        )
        points = resolved
        let projected = resolved.map { NSDecimalNumber(decimal: $0.fiat).doubleValue }
        let fractions = Self.timeFractions(for: resolved)
        // Refresh writes can arrive in dense bursts. Publishing chart arrays
        // without numeric/layout animation keeps scrolling and tab navigation
        // responsive while the normal range-selector interaction remains
        // animated by its own controls.
        withTransaction(Transaction(animation: nil)) {
            values = projected
            xFractions = fractions
            minValue = projected.min() ?? 0
            maxValue = projected.max() ?? 0
        }
    }

    private static let maxRenderedChartSamples = 180

    private static func downsample(_ points: [BalancePoint], maxCount: Int) -> [BalancePoint] {
        guard maxCount > 1, points.count > maxCount else { return points }
        var result: [BalancePoint] = []
        result.reserveCapacity(maxCount)
        var lastIndex: Int?
        for outputIndex in 0..<maxCount {
            let rawIndex = Double(outputIndex) * Double(points.count - 1) / Double(maxCount - 1)
            let sourceIndex = max(0, min(points.count - 1, Int(rawIndex.rounded())))
            guard sourceIndex != lastIndex else { continue }
            result.append(points[sourceIndex])
            lastIndex = sourceIndex
        }
        if result.first?.timestamp != points.first?.timestamp {
            result.insert(points[0], at: 0)
        }
        if result.last?.timestamp != points.last?.timestamp {
            result.append(points[points.count - 1])
        }
        return result
    }

    /// Per-point horizontal position in `[0, 1]` from each sample's
    /// timestamp — `(t − first) / (last − first)`. This is the real-time
    /// x-axis: a one-hour gap and a one-year gap occupy proportional width.
    /// Returns `[]` for a degenerate span (≤1 point or all-same-time); the
    /// renderer then falls back to equal-index spacing.
    private static func timeFractions(for points: [BalancePoint]) -> [Double] {
        guard let first = points.first?.timestamp,
              let last = points.last?.timestamp,
              last > first else { return [] }
        let span = last.timeIntervalSince(first)
        return points.map { max(0, min(1, $0.timestamp.timeIntervalSince(first) / span)) }
    }

    /// A 2-point flat baseline at 0 spanning the range — used when the
    /// reconstructor returns < 2 points.
    private static func zeroBaseline(for range: BalanceHistoryRange) -> [BalancePoint] {
        let now = Date()
        let span: TimeInterval
        switch range {
        case .hour:  span = 3_600
        case .day:   span = 86_400
        case .week:  span = 86_400 * 7
        case .month: span = 86_400 * 30
        case .year:  span = 86_400 * 365
        // "All time" — give the empty-state zero baseline a year-wide x-range
        // (was mistakenly a 30-day span, identical to .month).
        case .all:   span = 86_400 * 365
        }
        return [
            BalancePoint(timestamp: now.addingTimeInterval(-span), fiat: 0),
            BalancePoint(timestamp: now, fiat: 0)
        ]
    }
}

// MARK: - TimeRangeSelector

/// The segmented `1H · 1D · 1W · 1M · 1Y · All` selector inside the
/// balance card. A track of equal-width pills; the active one carries the
/// fill + (light-mode) soft shadow; the rest render muted text. Ported to
/// the handoff's exact track / pill geometry.
///
/// **1H is a REAL 1-hour window (2026-06-16).** Each tab is one
/// `BalanceHistoryRange` case 1:1 — `.hour` reconstructs a true trailing
/// 3600 s window (no longer folded to `.day`). The selected case persists
/// across launches via the shared `walletHomeBalanceHistoryRange`
/// `@AppStorage` key, so 1H survives relaunch like every other range. The
/// common 1H case (no transactions in the last hour) draws an honest flat
/// line at the current balance with 0% change — see the reconstructor's
/// "zero in-window transactions" branch.
///
/// **Rule #19 §C carve-out:** these are selection chips inside a picker,
/// not CTAs — plain `Button` + `.buttonStyle(.plain)` is correct (a
/// `UniButton` would force glass material on flat selection chrome).
private struct TimeRangeSelector: View {
    @Binding var selectedRaw: String
    let colorScheme: ColorScheme

    /// The currently-selected range, read from the persisted raw value.
    /// Each picker pill IS one `BalanceHistoryRange` case (1:1) — no
    /// visual-vs-reconstruction split anymore, so the persisted value is
    /// exactly what reconstructs and what the pill highlights.
    private var activeRange: BalanceHistoryRange {
        BalanceHistoryRange(rawValue: selectedRaw) ?? .all
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BalanceHistoryRange.allCases, id: \.self) { range in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedRaw = range.rawValue
                    }
                } label: {
                    Text(verbatim: range.shortLabel)
                        .font(UniTypography.BalanceCard.segment)
                        .foregroundStyle(
                            activeRange == range
                                ? UniColors.BalanceCard.segmentActiveText(colorScheme)
                                : UniColors.BalanceCard.textMuted(colorScheme)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if activeRange == range {
                                RoundedRectangle(cornerRadius: UniRadius.segmentPill, style: .continuous)
                                    .fill(UniColors.BalanceCard.segmentActiveFill(colorScheme))
                                    .shadow(
                                        color: UniColors.BalanceCard.segmentActiveShadow(colorScheme),
                                        radius: 4, x: 0, y: 2
                                    )
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: UniRadius.segmentPill, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(verbatim: range.shortLabel))
                .accessibilityAddTraits(activeRange == range ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.segmentTrack, style: .continuous)
                .fill(UniColors.BalanceCard.segmentTrack(colorScheme))
        )
        .environment(\.layoutDirection, .leftToRight) // 1H→All never mirrors
        .uniHaptic(.selection, trigger: activeRange) // `select` on touch-up
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Balance history range"))
    }
}
