import SwiftUI

/// **Send · Screen 2 — Amount (the emotional peak).**
///
/// Oversized tabular numerals with a blinking cursor, the token unit, a
/// flip between crypto and fiat, an "Available" line, a MAX button, and
/// the custom keypad. Per the handoff: a soft per-keystroke `.selection`
/// haptic (throttled), `.contextualImpact(.tap)` on MAX.
///
/// **Layers (Rule #2 §B.3):** content layer — the big numerals + keypad
/// on `Background.primary`. Functional layer — the nav bar + the bottom
/// `UniButton(.primary)` Review.
///
/// **Rule #11.** The numerals + ticker force LTR (English-shaped figures
/// the user reads); the keypad is LTR via its own override. The "To"
/// chip and Available line follow ambient.
struct SendAmountView: View {
    @Bindable var draft: SendDraft
    let onReview: () -> Void

    /// Drives the blinking cursor.
    @State private var cursorVisible: Bool = true
    /// Throttle gate for the per-keystroke haptic — fired on `amountInput`
    /// change but the modifier already coalesces; we additionally guard
    /// MAX (which sets a long string) from spamming.
    @State private var lastHapticLength: Int = 0

    private let cursorTimer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            recipientChip
                .padding(.top, UniSpacing.s)

            Spacer(minLength: 0)

            amountDisplay

            secondaryLine
                .padding(.top, UniSpacing.s)

            availableLine
                .padding(.top, UniSpacing.xs)

            maxButton
                .padding(.top, UniSpacing.m)

            Spacer(minLength: 0)

            SendAmountKeypad(
                amount: $draft.amountInput,
                maxFractionDigits: draft.asset?.decimals ?? 8
            )
            .padding(.horizontal, UniSpacing.l)

            footer
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Amount")
        .navigationBarTitleDisplayMode(.inline)
        // Per-keystroke haptic — `.selection`, fired on the typed string
        // changing. The `.uniHaptic` modifier coalesces to actual changes
        // and respects the user's haptic preference (Rule #10).
        .uniHaptic(.selection, trigger: draft.amountInput)
        .onReceive(cursorTimer) { _ in
            cursorVisible.toggle()
        }
    }

    // MARK: - Recipient chip

    private var recipientChip: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(UniColors.Icon.secondary)
            Text("To")
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.secondary)
            Text(verbatim: draft.recipientDisplay)
                .font(UniTypography.caption1.weight(.semibold).monospaced())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, UniSpacing.s)
        .padding(.vertical, UniSpacing.xs)
        .background(
            Capsule().fill(UniColors.Background.secondary)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Amount display

    private var amountDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
            // Big tabular numerals. 52pt / bold / tabular per the handoff.
            Text(verbatim: displayedAmount)
                .font(.system(size: 52, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            // Blinking cursor (3pt × ~46pt, brand Ink).
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(UniColors.Text.primary)
                .frame(width: 3, height: 44)
                .opacity(cursorVisible ? 1 : 0)
                .accessibilityHidden(true)

            Text(verbatim: unitLabel)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(UniColors.Text.secondary)
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, UniSpacing.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Amount"))
        .accessibilityValue(Text(verbatim: "\(displayedAmount) \(unitLabel)"))
    }

    // MARK: - Secondary line (fiat flip)

    private var secondaryLine: some View {
        Button {
            draft.isShowingFiat.toggle()
        } label: {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.secondary)
                Text(verbatim: secondaryText)
                    .font(UniTypography.callout)
                    .monospacedDigit()
                    .foregroundStyle(UniColors.Text.secondary)
            }
            .padding(.horizontal, UniSpacing.s)
            .padding(.vertical, UniSpacing.xxs)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Switch between crypto and fiat"))
    }

    private var availableLine: some View {
        HStack(spacing: UniSpacing.xxs) {
            Text("Available")
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
            Text(verbatim: "\(WalletFormatting.native(draft.availableBalance, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)")
                .font(UniTypography.caption1.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .combine)
    }

    private var maxButton: some View {
        Button {
            draft.applyMax()
        } label: {
            Text("MAX")
                .font(UniTypography.footnote.weight(.bold))
                .foregroundStyle(UniColors.Text.primary)
                .padding(.horizontal, UniSpacing.m)
                .padding(.vertical, UniSpacing.xs)
                .background(Capsule().fill(UniColors.Fill.tertiary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // `.tap` impact on MAX per the handoff.
        .uniHaptic(.contextualImpact(.tap), trigger: draft.availableBalance == draft.cryptoAmount && !draft.amountInput.isEmpty)
        .accessibilityLabel(Text("Send maximum"))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            UniButton(
                title: "Review",
                variant: .primary,
                isEnabled: draft.isAmountValid,
                action: onReview
            )
            .padding(.horizontal, UniSpacing.m)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
        .background(UniColors.Background.primary)
    }

    // MARK: - Derived display

    /// The numerals shown — the typed string when there's input, else a
    /// calm "0" so the screen is never blank.
    private var displayedAmount: String {
        if draft.amountInput.isEmpty { return "0" }
        return draft.amountInput
    }

    /// The unit shown beside the numerals — the ticker in crypto mode,
    /// the active currency code in fiat mode.
    private var unitLabel: String {
        draft.isShowingFiat ? activeCurrencyCode : draft.unitTicker
    }

    /// The "≈" secondary line — the opposite-mode equivalent of the typed
    /// amount.
    private var secondaryText: String {
        if draft.isShowingFiat {
            return "≈ \(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)"
        } else {
            return "≈ \(WalletFormatting.fiat(draft.fiatAmount, currencyCode: activeCurrencyCode))"
        }
    }

    /// The user's active currency code, read from the same preference
    /// every other surface uses.
    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey)
            ?? CurrencyPreference.defaultCode
    }
}
