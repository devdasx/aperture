import SwiftUI

/// Swap · compose + quote — the classic two-card swap layout. A FROM card
/// (asset + amount + MAX + balance) and a TO card (asset picker + the
/// estimated received amount), with a circular flip button between them.
/// Below the cards: the live quote panel (rate, route, fees, time, min
/// received, price impact), a slippage control, and the Review CTA.
///
/// **Layers (Rule #2 §B.3).** Content layer: the cards + quote panel, opaque
/// on `Background.primary`. Functional layer (Liquid Glass via system APIs
/// only): the flip button (`.actionCircle` `UniButton`) and the bottom
/// Review CTA in its own `GlassEffectContainer`. Two glass layers max;
/// content scrolls under the CTA.
///
/// **Real quote (Rule #26).** Both sides + a positive amount → the model
/// debounces ~400ms, `await`s the live `SwapQuoteService` quote off-main
/// (Rule #28), and auto-refreshes every ~25s. Honest states throughout:
/// loading spinner, the typed `SwapError.message`, the calm "not configured"
/// state. Execution (sign + broadcast) is the next increment — Review leads
/// to an honest summary, never a fabricated swap.
///
/// **RTL (Rule #11).** Amounts, tickers, and addresses are LTR-locked.
struct SwapComposeView: View {
    @Bindable var model: SwapComposeModel
    /// Whether the swap service can quote EVM/cross-chain pairs (Li.Fi key).
    let isLiFiConfigured: Bool
    /// The chains the user can swap on (EVM subset + Solana).
    let swappableChains: [SupportedChain]
    /// Holdings snapshot for the picker rows (real balances + sort).
    let holdings: AssetPickerHoldings
    /// Open the picker for a side (the view owns the sheet state + the
    /// post-pick balance/price resolution, so it hands the picked token back).
    let onRequestPicker: (SwapTokenPickerSheet.Side) -> Void
    /// Proceed to the honest Review summary.
    let onReview: (SwapReviewSummary) -> Void

    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

    @FocusState private var amountFocused: Bool
    /// One polite `.selection` beat for the flip / MAX / slippage affordances
    /// that aren't `UniButton`s (Rule #10 §B).
    @State private var selectionTapCount = 0
    /// Drives the Custom-slippage input sheet + the value the user types into it.
    @State private var isShowingCustomSlippage = false
    @State private var customSlippageText = ""

    /// Rule #12 §G direction-only key for the custom-slippage sheet's content
    /// rebuild. `"ltr"` or `"rtl"`.
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UniSpacing.m) {
                swapCards
                quotePanel
                slippageControl
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.xxxl + UniSpacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .uniHaptic(.selection, trigger: selectionTapCount)
        .safeAreaInset(edge: .bottom) { reviewBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.actionVerb)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
    }

    // MARK: - The two cards + flip button

    /// Visible diameter of the flip control. The `.actionCircle` paints a
    /// 56×56 glass; we shrink it to a seam-sized control and — critically —
    /// constrain its LAYOUT frame to the same size (`.frame(width:height:)`,
    /// not `.scaleEffect`, which leaves a 56×56 layout box). Layout bounds ==
    /// visible bounds keeps the seam-offset math and the ring size exact.
    private static let flipButtonScale: CGFloat = 0.72
    private static let actionCircleDiameter: CGFloat = 56
    private static var flipButtonDiameter: CGFloat { actionCircleDiameter * flipButtonScale }
    /// The thin page-background ring around the glass, on each side.
    private static let flipRingInset: CGFloat = UniSpacing.xxs
    /// Total laid-out size of the flip control incl. its seam ring.
    private static var flipControlDiameter: CGFloat { flipButtonDiameter + flipRingInset * 2 }
    /// How far the flip control bites into EACH card. As a VStack sibling
    /// pulled up and down into both cards by this much (negative vertical
    /// padding), the control is dead-centered on the seam by construction and
    /// overlaps the FROM and TO cards equally — visible on both, regardless of
    /// either card's height. (It can no longer ride high into the taller card
    /// the way the old bottom-anchored overlay did.)
    private static var flipSeamOverlap: CGFloat { flipControlDiameter / 2 - UniSpacing.xxs }

    private var swapCards: some View {
        // The flip control sits ON the seam between the two cards. It's a
        // VStack sibling pulled UP into the FROM card and DOWN into the TO
        // card by `flipSeamOverlap` (negative vertical padding), so it's
        // centered on the seam by construction and overlaps BOTH cards by the
        // same amount — equally visible on YOU PAY and YOU RECEIVE, never
        // riding high into the taller card.
        VStack(spacing: 0) {
            fromCard
            flipButton
                .padding(.vertical, -SwapComposeView.flipSeamOverlap)
                // Draw above both cards so the opaque seam ring reads as
                // sitting ON the boundary, not tucked under either edge.
                .zIndex(1)
            toCard
        }
    }

    /// FROM card — asset, the large amount field, MAX, available balance.
    private var fromCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                HStack {
                    Text("You pay")
                        .font(UniTypography.footnote.weight(.semibold))
                        .foregroundStyle(UniColors.Text.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    chainBadge(model.fromToken.chain)
                }

                HStack(alignment: .center, spacing: UniSpacing.s) {
                    assetButton(token: model.fromToken, side: .from)

                    SwapAmountField(
                        text: $model.amountText,
                        isOverBalance: model.isOverBalance,
                        focused: $amountFocused
                    )
                }

                // Available + MAX + the optional fiat conversion line.
                HStack(spacing: UniSpacing.xs) {
                    availableLine
                    Spacer(minLength: UniSpacing.s)
                    if let fiat = fromFiatValue {
                        Text(verbatim: "≈ \(WalletFormatting.fiat(fiat, currencyCode: model.currencyCode))")
                            .font(UniTypography.footnote.monospacedDigit())
                            .foregroundStyle(UniColors.Text.tertiary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    maxButton
                }
                // Keep the Available/MAX row clear of the seam button: the
                // control bites `flipSeamOverlap` up into this card — past the
                // card's own 16pt inset — so reserve the difference (plus a
                // little breathing room) below the row.
                .padding(.bottom, SwapComposeView.flipSeamOverlap + UniSpacing.xs - UniSpacing.m)
            }
        }
    }

    /// TO card — asset picker + the read-only estimated received amount.
    private var toCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                HStack {
                    Text("You receive")
                        .font(UniTypography.footnote.weight(.semibold))
                        .foregroundStyle(UniColors.Text.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    if let to = model.toToken {
                        chainBadge(to.chain)
                    }
                }

                HStack(alignment: .center, spacing: UniSpacing.s) {
                    if let to = model.toToken {
                        assetButton(token: to, side: .to)
                    } else {
                        choosePickerButton
                    }
                    receivedAmount
                }

                if let to = model.toToken, let bal = model.toBalance, bal > 0 {
                    HStack(spacing: UniSpacing.xxs) {
                        Text("Balance")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                        Text(verbatim: "\(WalletFormatting.native(bal, decimals: to.decimals)) \(to.symbol)")
                            .font(UniTypography.footnote.monospacedDigit())
                            .foregroundStyle(UniColors.Text.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
        }
    }

    /// The circular flip button — swaps FROM ⇄ TO. `.actionCircle` glass
    /// (Rule #19) with the matching `Circle` hit-shape; fires the commit
    /// haptic that variant owns. Disabled until a to-token exists to flip in.
    private var flipButton: some View {
        UniButton(
            title: "Flip",
            variant: .actionCircle,
            isEnabled: model.toToken != nil,
            icon: "arrow.up.arrow.down",
            action: {
                model.flipSides()
            }
        )
        .accessibilityLabel(Text("Flip the swap direction"))
        // Render the 56×56 action circle at the seam size…
        .scaleEffect(SwapComposeView.flipButtonScale)
        // …and clamp the LAYOUT footprint to that visible size so the ring
        // and the seam offset use the real on-screen diameter (scaleEffect
        // alone leaves a 56×56 layout box centered inside).
        .frame(width: SwapComposeView.flipButtonDiameter,
               height: SwapComposeView.flipButtonDiameter)
        // A thin opaque ring in the page background sits between the glass
        // and the two card edges, so the control reads as floating cleanly
        // ON the seam rather than blending into either card. No shadow —
        // the glass's own specular does the depth work (Rule #2 §B.3).
        .padding(SwapComposeView.flipRingInset)
        .background(
            Circle().fill(UniColors.Background.primary)
        )
    }

    // MARK: - Asset + picker buttons

    /// The tappable asset chip — coin mark + ticker + chevron. Opens the
    /// picker for its side. Selection-class affordance (Rule #19 §C — it
    /// selects, it doesn't commit), so it's a quiet glass capsule, not a CTA.
    private func assetButton(token: SwapToken, side: SwapTokenPickerSheet.Side) -> some View {
        Button {
            onRequestPicker(side)
            selectionTapCount &+= 1
        } label: {
            HStack(spacing: UniSpacing.xs) {
                CoinMark(
                    chain: token.chain,
                    tokenSymbol: token.symbol,
                    contract: token.isNative ? nil : token.address,
                    customIconURL: token.logoURI
                )
                .frame(width: 26, height: 26)
                Text(verbatim: token.symbol)
                    .font(UniTypography.title3)
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.secondary)
            }
            .padding(.leading, UniSpacing.xs)
            .padding(.trailing, UniSpacing.s)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .tint(UniColors.Button.secondaryTint)
    }

    /// The empty TO picker — "Select token" prompt before a to-token exists.
    private var choosePickerButton: some View {
        Button {
            onRequestPicker(.to)
            selectionTapCount &+= 1
        } label: {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.accent)
                Text("Select token")
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            }
            .padding(.horizontal, UniSpacing.s)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .tint(UniColors.Button.secondaryTint)
    }

    // MARK: - The read-only received amount

    /// The estimated received amount on the TO card. Read-only — it's the
    /// quote's `toAmount`, never typed. Shows a quiet placeholder before a
    /// quote, a spinner while fetching, and the value when quoted.
    @ViewBuilder
    private var receivedAmount: some View {
        Spacer(minLength: 0)
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .tint(UniColors.Icon.secondary)
        case .quoted(let quote):
            Text(verbatim: WalletFormatting.native(quote.toAmount, decimals: quote.toToken.decimals))
                .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.22), value: quote.toAmount)
                .environment(\.layoutDirection, .leftToRight)
        case .idle, .failed:
            Text(verbatim: "0")
                .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                .foregroundStyle(UniColors.Text.quaternary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    // MARK: - Available / MAX

    private var availableLine: some View {
        HStack(spacing: UniSpacing.xxs) {
            Text("Available")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
            Text(verbatim: "\(WalletFormatting.native(model.fromBalance, decimals: model.fromToken.decimals)) \(model.fromToken.symbol)")
                .font(UniTypography.footnote.monospacedDigit())
                .foregroundStyle(model.isOverBalance ? UniColors.Status.errorForeground : UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var maxButton: some View {
        Button {
            model.engageMax()
            selectionTapCount &+= 1
        } label: {
            Text("Max")
                .font(UniTypography.footnote.weight(.semibold))
                .foregroundStyle(model.fromBalance > 0 ? UniColors.Text.primary : UniColors.Text.disabled)
                .padding(.horizontal, UniSpacing.s)
                .frame(height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .tint(model.fromBalance > 0 ? UniColors.Button.secondaryTint : UniColors.Button.disabledFill)
        .disabled(model.fromBalance <= 0)
    }

    // MARK: - Chain badge (swap vs bridge surfacing)

    /// A small chain pill on each card. When the two chains differ, the TO
    /// card's pill is accent-tinted so the BRIDGE is visually obvious before
    /// the user even reads the panel.
    private func chainBadge(_ chain: SupportedChain) -> some View {
        let isBridgeSide = model.isCrossChain && chain == model.toToken?.chain
        return HStack(spacing: UniSpacing.xxs) {
            if isBridgeSide {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(verbatim: chain.displayName)
                .font(UniTypography.caption2.weight(.semibold))
        }
        .foregroundStyle(isBridgeSide ? UniColors.Icon.accent : UniColors.Text.tertiary)
        .padding(.horizontal, UniSpacing.xs)
        .padding(.vertical, UniSpacing.xxs)
        .background(
            Capsule().fill(isBridgeSide ? UniColors.Focus.selection : UniColors.Fill.quaternary)
        )
    }

    // MARK: - Quote panel (the honest states live here)

    @ViewBuilder
    private var quotePanel: some View {
        if !isLiFiConfigured && needsLiFi {
            notConfiguredPanel
        } else {
            switch model.phase {
            case .idle:
                // No idle instructional panel — the panel area simply
                // collapses while idle (the TO card already shows "0").
                EmptyView()
            case .loading:
                loadingPanel
            case .quoted(let quote):
                SwapQuotePanel(quote: quote, isCrossChain: model.isCrossChain, currencyCode: model.currencyCode)
            case .failed(let error):
                errorPanel(error)
            }
        }
    }

    /// True when the current pair would route through Li.Fi (anything that
    /// isn't Solana→Solana). The Solana→Solana path is keyless (Jupiter),
    /// so the "not configured" gate doesn't apply to it.
    private var needsLiFi: Bool {
        guard let to = model.toToken else { return false }
        return !(model.fromToken.chain == .solana && to.chain == .solana)
    }

    private var loadingPanel: some View {
        panelCard {
            HStack(spacing: UniSpacing.s) {
                ProgressView().controlSize(.small).tint(UniColors.Icon.secondary)
                Text(model.isCrossChain ? "Finding the best bridge route…" : "Finding the best route…")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func errorPanel(_ error: SwapError) -> some View {
        panelCard {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(UniColors.Status.warningForeground)
                Text(verbatim: error.message)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var notConfiguredPanel: some View {
        panelCard {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 16))
                    .foregroundStyle(UniColors.Icon.secondary)
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text("Swap isn't configured")
                        .font(UniTypography.footnote.weight(.semibold))
                        .foregroundStyle(UniColors.Text.primary)
                    Text("The swap service isn't set up for this network pair right now. Solana-to-Solana swaps still work.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func panelCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(UniSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Material.card)
            )
    }

    // MARK: - Slippage control

    private var slippageControl: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(spacing: UniSpacing.xxs) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.secondary)
                Text("Max slippage")
                    .font(UniTypography.footnote.weight(.semibold))
                    .foregroundStyle(UniColors.Text.secondary)
                Spacer()
                Text(verbatim: SwapComposeModel.slippageLabel(bps: model.slippageBps))
                    .font(UniTypography.footnote.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
            }

            HStack(spacing: UniSpacing.xs) {
                ForEach(slippagePresets, id: \.self) { bps in
                    slippageChip(bps)
                }
                customSlippageChip
            }

            // Honesty (Rule #16) — a quiet, restrained caution when the
            // tolerance is high. No alarm, no exclamation; just the
            // consequence stated plainly so the user understands the trade.
            if isHighSlippage {
                Text("Higher slippage can mean you receive noticeably less.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Status.warningForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, UniSpacing.xs)
        .sheet(isPresented: $isShowingCustomSlippage) {
            CustomSlippageSheet(
                text: $customSlippageText,
                onCommit: commitCustomSlippage
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
    }

    private let slippagePresets: [Int] = [10, 50, 100]

    /// Slippage at or above 1% (100 bps) reads as high enough to warrant the
    /// honest caution line (Rule #16).
    private static let highSlippageThresholdBps = 100
    private var isHighSlippage: Bool { model.slippageBps >= Self.highSlippageThresholdBps }

    /// Sane bounds the model itself never enforced: floor 0.01% (1 bps),
    /// ceiling 50% (5000 bps). Both ends are clamped on commit.
    private static let minSlippageBps = 1
    private static let maxSlippageBps = 5000

    /// One slippage preset chip. Selected → glass-prominent + accent tint;
    /// unselected → quiet glass. Both are native iOS 26 styles (Rule #3);
    /// a `@ViewBuilder` branch picks the concrete style without type erasure.
    @ViewBuilder
    private func slippageChip(_ bps: Int) -> some View {
        let isSelected = model.slippageBps == bps
        let chipLabel = Text(verbatim: SwapComposeModel.slippageLabel(bps: bps))
            .font(UniTypography.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(isSelected ? UniColors.Button.primaryLabel : UniColors.Text.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Capsule())
            .environment(\.layoutDirection, .leftToRight)

        if isSelected {
            Button { selectSlippage(bps) } label: { chipLabel }
                .buttonStyle(.glassProminent)
                .tint(UniColors.Button.primaryTint)
        } else {
            Button { selectSlippage(bps) } label: { chipLabel }
                .buttonStyle(.glass)
                .tint(UniColors.Button.secondaryTint)
        }
    }

    /// The "Custom" chip. Selected whenever the current value isn't one of
    /// the presets — so a typed value lights this chip while none of the
    /// preset chips do. When selected it shows the custom value itself so
    /// the user sees their setting at a glance; otherwise it reads "Custom".
    @ViewBuilder
    private var customSlippageChip: some View {
        let isSelected = !slippagePresets.contains(model.slippageBps)
        let title = isSelected
            ? Text(verbatim: SwapComposeModel.slippageLabel(bps: model.slippageBps))
            : Text("Custom")
        let chipLabel = title
            .font(UniTypography.footnote.weight(.semibold).monospacedDigit())
            .foregroundStyle(isSelected ? UniColors.Button.primaryLabel : UniColors.Text.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Capsule())
            .environment(\.layoutDirection, .leftToRight)

        if isSelected {
            Button { openCustomSlippage() } label: { chipLabel }
                .buttonStyle(.glassProminent)
                .tint(UniColors.Button.primaryTint)
        } else {
            Button { openCustomSlippage() } label: { chipLabel }
                .buttonStyle(.glass)
                .tint(UniColors.Button.secondaryTint)
        }
    }

    private func selectSlippage(_ bps: Int) {
        model.slippageBps = bps
        selectionTapCount &+= 1
    }

    /// Open the custom-input sheet, seeding the field with the current value
    /// when it's already a custom (non-preset) tolerance.
    private func openCustomSlippage() {
        customSlippageText = slippagePresets.contains(model.slippageBps)
            ? ""
            : SwapComposeModel.customPercentString(bps: model.slippageBps)
        isShowingCustomSlippage = true
        selectionTapCount &+= 1
    }

    /// Parse the typed percent → bps, clamp to sane bounds, apply (the model's
    /// `didSet` re-quotes for free), and fire the shared selection haptic.
    private func commitCustomSlippage() {
        guard let bps = SwapComposeModel.parseSlippagePercent(customSlippageText) else {
            isShowingCustomSlippage = false
            return
        }
        let clamped = min(max(bps, Self.minSlippageBps), Self.maxSlippageBps)
        model.slippageBps = clamped
        selectionTapCount &+= 1
        isShowingCustomSlippage = false
    }

    // MARK: - Review CTA (functional layer)

    private var reviewBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(
                title: "Review",
                variant: .primary,
                isEnabled: model.canReview,
                action: {
                    guard let summary = model.makeReview() else { return }
                    onReview(summary)
                }
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }

    // MARK: - Derived display

    /// The fiat value of the typed from-amount (when priced). Display-only.
    private var fromFiatValue: Decimal? {
        guard let price = model.fromUnitPrice, model.amount > 0 else { return nil }
        return model.amount * price
    }
}

// MARK: - Amount field (LTR-locked, auto-shrinking)

/// The FROM amount entry — a calm, monospaced-digit field that auto-shrinks
/// to fit one line (the Send hero's never-overflow behavior, scaled to the
/// card). LTR-locked (Rule #11) because it's a transcribable value.
private struct SwapAmountField: View {
    @Binding var text: String
    let isOverBalance: Bool
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField("0", text: $text)
            .font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
            .foregroundStyle(isOverBalance ? UniColors.Status.errorForeground : UniColors.Text.primary)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .focused(focused)
            // The decimal pad has no Return key — add the native dismiss
            // accessory bar (Rule #3) keyed to this field's focus.
            .numericDoneToolbar(focused)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.2), value: isOverBalance)
            .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Custom slippage sheet

/// A compact native sheet (Rule #15: NavigationStack + navigationTitle +
/// toolbar actions) for typing a custom slippage percentage. Uses the
/// canonical `UniTextField` (Rule #3) with the decimal pad; Enter dismisses
/// the keyboard (the field's app-wide submit contract). "Set" applies the
/// value and dismisses; "Cancel" leaves the current tolerance untouched.
private struct CustomSlippageSheet: View {
    @Binding var text: String
    let onCommit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                UniBody(
                    text: "Enter the maximum price movement you'll accept. Lower is safer; higher fills more often.",
                    color: UniColors.Text.secondary
                )

                HStack(spacing: UniSpacing.xs) {
                    UniTextField(
                        placeholder: "0.5",
                        text: $text,
                        directionPolicy: .forceLTR,
                        keyboardType: .decimalPad,
                        boolFocusBinding: $amountFocused
                    )
                    Text(verbatim: "%")
                        .font(UniTypography.title3)
                        .foregroundStyle(UniColors.Text.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }

                Spacer()
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            // The decimal pad has no Return key — native dismiss accessory.
            .numericDoneToolbar($amountFocused)
            .navigationTitle(Text("Custom slippage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Disabled until the field holds one clean, parseable
                    // decimal — so an empty or malformed value can't be
                    // "Set" (no silent dismiss, no silently-wrong commit).
                    Button("Set") { onCommit() }
                        .fontWeight(.semibold)
                        .disabled(SwapComposeModel.parseSlippagePercent(text) == nil)
                }
            }
        }
    }
}
