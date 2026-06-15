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
/// to `••••`, flattens the chart to a muted line, and swaps the eye glyph
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

    /// The full transaction history + current balances + price ladders,
    /// fed straight to `BalanceHistoryReconstructor` to build the curve.
    let transactions: [TransactionRecord]
    let currentBalances: [TokenBalanceRecord]
    /// The active wallet's OWN addresses (lowercased). Transactions whose
    /// counterparty is in this set are self-transfers and are dropped from the
    /// chart reconstruction (they net to zero on the balance).
    let ownAddresses: Set<String>
    let priceCache: [String: Decimal]
    let priceHistory: [String: [Int: Decimal]]

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
    @State private var minValue: Double = 0
    @State private var maxValue: Double = 0

    init(
        walletId: UUID?,
        walletName: String,
        totalFiat: Decimal,
        currencyCode: String,
        transactions: [TransactionRecord],
        currentBalances: [TokenBalanceRecord],
        ownAddresses: Set<String>,
        priceCache: [String: Decimal],
        priceHistory: [String: [Int: Decimal]],
        scrubModel: ChartScrubModel,
        onSwitchWallet: @escaping () -> Void,
        onAddFunds: @escaping () -> Void
    ) {
        self.walletId = walletId
        self.walletName = walletName
        self.totalFiat = totalFiat
        self.currencyCode = currencyCode
        self.transactions = transactions
        self.currentBalances = currentBalances
        self.ownAddresses = ownAddresses
        self.priceCache = priceCache
        self.priceHistory = priceHistory
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

    /// The pill's baseline — the FIRST point the wallet actually HELD a
    /// balance at: the first `points` element with `fiat > 0`, falling
    /// back to `points.first` only when every point is 0 (the degenerate
    /// "only an outgoing first tx" curve). **2026-06-16 user direction:**
    /// the percent + amount read from the first balance the wallet held in
    /// the window — so 1M/1Y/All show a REAL percent like the shorter
    /// ranges, never a "—". The reconstructor already drops the leading $0
    /// before-step, so `points.first` is normally the first held balance
    /// and this fold is just defensive against any residual $0 lead.
    private var baselineFiat: Decimal {
        points.first(where: { $0.fiat > 0 })?.fiat ?? points.first?.fiat ?? 0
    }

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
        if totalFiat <= 0 { return .zero }   // Zero overrides change (handoff)
        if isHidden { return .hidden }
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

                switch resolvedState {
                case .zero:
                    zeroBody
                case .hidden, .value:
                    valueBody
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous))
        .overlay(innerEdgeOverlay)
        .overlay(hairlineOverlay)
        // No drop shadow: the card sits flat on the page like the holdings /
        // transactions cards below it (per user direction 2026-06-16 — the
        // earlier spec shadow read as a grey "tray" behind the card). The
        // inner specular edge + hairline still give the surface its depth.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .task(id: rebuildKey) { await rebuild() }
    }

    // MARK: - Surface

    private var cardSurface: some View {
        ZStack {
            LinearGradient(
                colors: [
                    UniColors.BalanceCard.surfaceTop(colorScheme),
                    UniColors.BalanceCard.surfaceBottom(colorScheme)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Radial lift at (12%, 0%) — the bright top-left corner.
            RadialGradient(
                colors: [
                    UniColors.BalanceCard.surfaceLift(colorScheme),
                    UniColors.BalanceCard.surfaceLift(colorScheme).opacity(0)
                ],
                center: UnitPoint(x: 0.12, y: 0.0),
                startRadius: 0,
                endRadius: 320
            )
        }
    }

    private var innerEdgeOverlay: some View {
        // 1pt top-edge specular highlight (inset 0 1px 0 …).
        RoundedRectangle(cornerRadius: UniRadius.balanceCard, style: .continuous)
            .stroke(UniColors.BalanceCard.innerEdge(colorScheme), lineWidth: 1)
            .mask(
                // A top→center opacity ramp so the specular hairline
                // shows only along the top edge and fades out. A mask
                // uses only the alpha channel, so the opaque stop is an
                // arbitrary fully-opaque role (`Text.primary`, opaque
                // `.label`) — never a literal (Rule #4). `Color.clear`
                // is the explicitly-allowed absence-of-color.
                LinearGradient(
                    colors: [UniColors.Text.primary, Color.clear],
                    startPoint: .top,
                    endPoint: .center
                )
            )
            .allowsHitTesting(false)
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
        Image(colorScheme == .dark ? "IrisWatermarkWhite" : "IrisWatermarkInk")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 220, height: 220)
            .opacity(UniColors.BalanceCard.watermarkOpacity(colorScheme))
            .offset(x: 44, y: -26)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            // Iris avatar disc (the in-app logo).
            Image("IrisAvatar")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(UniColors.BalanceCard.avatarRing(colorScheme), lineWidth: 1)
                )
                .accessibilityHidden(true)

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
        balanceNumber
            .padding(.bottom, 14)

        changeRow

        // Full-bleed chart — negative inset cancels the card's 24pt
        // horizontal pad so the curve bleeds to the card edges.
        BalanceAreaChart(
            values: chartValues,
            minValue: chartMin,
            maxValue: chartMax,
            sign: chartSign,
            onScrub: { index in
                let scrubbed: Decimal? = {
                    guard let index, index >= 0, index < points.count else { return nil }
                    return points[index].fiat
                }()
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    scrubModel.fiat = scrubbed
                }
            },
            onScrubBegin: {
                UniHapticEngine.shared.play(.contextualImpact(.whisper))
            }
        )
        .frame(height: 120)
        .padding(.horizontal, -UniSpacing.l)
        .padding(.top, 14)
        .allowsHitTesting(resolvedState == .value) // hidden chart isn't scrubbable
        .accessibilityHidden(true)

        TimeRangeSelector(
            selectedRaw: $selectedRangeRaw,
            colorScheme: colorScheme
        )
        .padding(.top, -6)
        .padding(.bottom, UniSpacing.balanceCardBottom)
    }

    /// The chart series — flattened to a single neutral mid value in the
    /// hidden state so no value shape is exposed (handoff §Hidden).
    private var chartValues: [Double] {
        isHidden ? Array(repeating: 0, count: max(values.count, 2)) : values
    }
    private var chartMin: Double { isHidden ? 0 : minValue }
    private var chartMax: Double { isHidden ? 0 : maxValue }
    private var chartSign: UniColors.BalanceCard.Sign { isHidden ? .flat : sign }

    // MARK: - Balance number (3 runs)

    private var balanceNumber: some View {
        let parts = WalletFormatting.fiatParts(totalFiat, currencyCode: currencyCode)
        // Currency-code run (muted), shown only when it leads (en).
        let currencyRun = Text(verbatim: parts.currency + (parts.currency.isEmpty ? "" : " "))
            .font(UniTypography.BalanceCard.currency)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))

        return Group {
            if isHidden {
                // Masked figure — currency code + dots.
                (currencyRun
                 + Text(verbatim: "••••••")
                    .font(UniTypography.BalanceCard.balance)
                    .foregroundStyle(UniColors.BalanceCard.textPrimary(colorScheme)))
                    .tracking(2)
            } else {
                composedBalance(parts)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .tracking(-1.3) // ≈ −0.03em at 44pt
        .contentTransition(reduceMotion ? .identity : .numericText())
        .environment(\.layoutDirection, .leftToRight) // numbers always LTR (Rule #11)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: scrubModel.fiat)
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

        if parts.currency.isEmpty {
            return integer + fraction
        }
        return parts.currencyLeads
            ? currency + gap + integer + fraction
            : integer + fraction + gap + currency
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
            } else {
                changePill(
                    text: percentText,
                    systemImage: sign == .up ? "arrow.up" : (sign == .down ? "arrow.down" : nil),
                    sign: sign
                )
                Text(verbatim: amountText)
                    .font(UniTypography.BalanceCard.amount)
                    .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
                    .environment(\.layoutDirection, .leftToRight) // amount + sign LTR
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changePill(text: String, systemImage: String?, sign: UniColors.BalanceCard.Sign) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
            }
            Text(verbatim: text)
                .font(UniTypography.BalanceCard.pill)
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
        let pct = abs(changePercent)
        return String(format: "%.2f%%", pct)
    }

    /// `+293.10 today` / `−391.20 today` / `No change today`. The minus is
    /// a true U+2212 (handoff §States: "not a hyphen"). **2026-06-16:** the
    /// amount reads `last − baselineFiat` (the first held balance), so
    /// 1M/1Y/All show the real signed amount consistent with the line and
    /// the percent. `No change today` only when the net delta is exactly 0.
    private var amountText: String {
        if change == 0 {
            return String.apertureLocalized("No change today")
        }
        let magnitude = abs(change)
        let formatted = WalletFormatting.fiat(magnitude, currencyCode: currencyCode)
        let signGlyph = sign == .up ? "+" : "\u{2212}"
        let today = String.apertureLocalized("today")
        return "\(signGlyph)\(formatted) \(today)"
    }

    // MARK: - Zero state

    @ViewBuilder
    private var zeroBody: some View {
        // Balance reads 0.00 (no chart, no selector — handoff §Zero).
        let parts = WalletFormatting.fiatParts(0, currencyCode: currencyCode)
        composedBalance(parts)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .tracking(-1.3)
            .environment(\.layoutDirection, .leftToRight)

        Text("Add crypto to get started — receive or transfer it from another wallet.")
            .font(UniTypography.BalanceCard.zeroPrompt)
            .foregroundStyle(UniColors.BalanceCard.textMuted(colorScheme, boostContrast: boostContrast))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 18)
            .padding(.bottom, 16)

        Button(action: addFunds) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("Add funds")
                    .font(UniTypography.BalanceCard.fundButton)
            }
            .foregroundStyle(UniColors.BalanceCard.fundButtonLabel(colorScheme))
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(UniColors.BalanceCard.fundButtonFill(colorScheme))
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.bottom, UniSpacing.l)
        .accessibilityLabel(Text("Add funds, opens Receive"))
    }

    // MARK: - Actions (+ handoff haptics)

    private func switchWallet() {
        UniHapticEngine.shared.play(.contextualImpact(.tap)) // `tap` on press
        onSwitchWallet()
    }

    private func addFunds() {
        UniHapticEngine.shared.play(.contextualImpact(.tap)) // `tap` on touch-up
        onAddFunds()
    }

    private func toggleHidden() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
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

    /// Cheap dependency key — counts only (no Decimal summing), so this is
    /// O(symbols + balances) per body pass, gating the heavy reconstruction
    /// behind a real change (the 2026-06-13 perf shape).
    private var rebuildKey: Int {
        var hasher = Hasher()
        hasher.combine(transactions.count)
        hasher.combine(currentBalances.count)
        var fiatTotal = Decimal.zero
        for balance in currentBalances { fiatTotal += balance.fiatValueCached }
        hasher.combine(fiatTotal)
        hasher.combine(selectedRangeRaw)
        hasher.combine(currencyCode)
        hasher.combine(priceCache.count)
        var histDayCount = 0
        for series in priceHistory.values { histDayCount += series.count }
        hasher.combine(histDayCount)
        return hasher.finalize()
    }

    private func rebuild() async {
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
        let own = ownAddresses

        let reconstructed = await Task.detached(priority: .userInitiated) {
            BalanceHistoryReconstructor.reconstruct(
                txSnapshots: txSnapshots,
                balanceSnapshots: balanceSnapshots,
                priceCache: cache,
                priceHistory: history,
                ownAddresses: own,
                range: range
            )
        }.value

        guard !Task.isCancelled else { return }
        let resolved = reconstructed.count >= 2 ? reconstructed : Self.zeroBaseline(for: range)
        points = resolved
        let projected = resolved.map { NSDecimalNumber(decimal: $0.fiat).doubleValue }
        // Reload chart + pill together — handoff §Interactions ~300ms ease.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            values = projected
            minValue = projected.min() ?? 0
            maxValue = projected.max() ?? 0
        }
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
        case .all:   span = 86_400 * 30
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
