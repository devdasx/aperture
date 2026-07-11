import SwiftUI

/// The single-recipient amount HERO — a large, calm, monospaced-digit
/// amount the user types in the active unit (crypto or fiat), with the
/// conversion shown beneath, a crypto⇄fiat toggle, a MAX button, and the
/// available balance line.
///
/// **Restraint (Rule #2).** The amount is the one large element; everything
/// else is quiet support. No decorative chrome. The number is LTR-locked
/// (Rule #11) because it's a value the user reads and transcribes.
struct SendAmountHero: View {
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    @Bindable var model: SendComposeModel
    @Binding var selectionTapCount: Int
    let onReview: () -> Void

    /// Largest the amount renders when the value is short (≈ one or two
    /// glyphs). Cash-App-class confidence; the design's calm is the size
    /// itself, not chrome (Rule #2). The flanking symbol / ticker scale
    /// proportionally from this so they stay visually tied to the number.
    private let idealSize: CGFloat = 56
    /// Hard floor. Even a full-precision Max value (≈ 20 glyphs) renders no
    /// smaller than this; combined with `.minimumScaleFactor` below it can
    /// never overflow.
    private let minSize: CGFloat = 24

    var body: some View {
        VStack(spacing: UniSpacing.m) {
            // Recipient line — who this amount goes to.
            if let first = model.amounts.first {
                Text(verbatim: recipientLabel(first))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity)
            }

            // The amount field — big, centered, monospaced digits that
            // auto-scale DOWN to always fit one line within the available
            // width (Cash-App behavior). The size is driven off the rendered
            // length and the measured width; `.lineLimit(1)` +
            // `.minimumScaleFactor` are the structural floor so overflow is
            // impossible even at the smallest computed size.
            GeometryReader { geo in
                let size = dynamicSize(availableWidth: geo.size.width)
                HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
                    if model.entryUnit == .fiat {
                        Text(verbatim: currencySymbol)
                            .font(.system(size: flankSize(size), weight: .semibold, design: .default).monospacedDigit())
                            .foregroundStyle(UniColors.Text.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .contentTransition(.numericText())
                    }
                    amountDisplay(size: size)
                        .layoutPriority(1)
                    if model.entryUnit == .crypto {
                        Text(verbatim: model.assetSymbol)
                            .font(.system(size: flankSize(size), weight: .semibold, design: .default).monospacedDigit())
                            .foregroundStyle(UniColors.Text.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .contentTransition(.numericText())
                    }
                }
                // Fill the fixed band and center, so the assembly never
                // jumps vertically as the font size springs up/down.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: size)
            }
            .frame(height: idealSize * 1.18)
            .frame(maxWidth: .infinity)

            // Conversion line (the inactive unit) — only when priced.
            conversionLine

            // Toggle + MAX row.
            HStack(spacing: UniSpacing.s) {
                if model.assetUnitPrice != nil {
                    quietButton(unitToggleLabel, systemImage: "arrow.up.arrow.down") {
                        model.toggleEntryUnit()
                        selectionTapCount &+= 1
                    }
                }
                // P3-018: Max is single-recipient only (multi uses explicit amounts).
                // Always tappable for single-recipient: zero balance (or fee not
                // loaded yet) still fills the field with 0 — never greyed out
                // while Available shows a positive balance waiting on fee quote.
                quietButton("Max", systemImage: "arrow.up.to.line.compact",
                            isEnabled: model.amounts.count == 1) {
                    model.engageMax()
                    selectionTapCount &+= 1
                }
            }
            .padding(.top, UniSpacing.xxs)

            // Available balance.
            availableLine

            Spacer(minLength: UniSpacing.m)

            GlassEffectContainer(spacing: UniSpacing.s) {
                UniButton(
                    title: "Review",
                    variant: .primary,
                    isEnabled: model.canReview,
                    action: onReview
                )
            }

            UniNumberKeypad(
                isEnabled: true,
                leadingKey: .decimal("."),
                isLeadingKeyEnabled: canAppendDecimal,
                showsDigitLetters: true,
                canDelete: !model.primaryAmountText.isEmpty,
                onDigit: appendDigit,
                onDelete: deleteDigit,
                onLeadingKey: appendDecimalSeparator
            )
            .padding(.horizontal, 36)
        }
        .padding(.top, UniSpacing.m)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Dynamic, never-overflowing amount sizing

    /// The point size for the number so the whole assembly (flanking
    /// symbol / ticker + the number) fits one line within `availableWidth`.
    ///
    /// Cheap by construction (Rule #28): it's arithmetic on the string
    /// length, no per-frame layout/measurement. The monospaced-digit SF
    /// Rounded glyph advance is ≈ `0.62 × size`; the flanking symbol /
    /// ticker occupy a proportional share. Inverting `width ≈ advance ×
    /// glyphCount` gives the largest size that fits, clamped to
    /// `[minSize, idealSize]`. `.minimumScaleFactor` is the belt-and-
    /// suspenders floor for any residual (narrow `.`, currency glyph
    /// proportions), so the assembly can never clip the screen.
    private func dynamicSize(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return idealSize }
        let typed = model.primaryAmountText.isEmpty ? "0" : model.primaryAmountText
        // Effective glyph budget: the number's glyphs + the flanking
        // symbol/ticker expressed as number-glyph-equivalents (they render
        // at ~0.62 of the number size, so their advance is ~0.62² of a
        // full-size digit; counting each flank char as ~0.45 equivalents
        // keeps the estimate conservative — it errs toward shrinking, never
        // toward overflow).
        let flankChars = CGFloat(model.entryUnit == .fiat
            ? currencySymbol.count
            : model.assetSymbol.count)
        let glyphBudget = CGFloat(typed.count) + flankChars * 0.45 + 1 // +1 = inter-element gap
        let advanceRatio: CGFloat = 0.62
        let fitted = availableWidth / (glyphBudget * advanceRatio)
        return min(idealSize, max(minSize, fitted))
    }

    private func amountDisplay(size: CGFloat) -> some View {
        HStack(alignment: .center, spacing: UniSpacing.xxs) {
            Text(verbatim: displayedAmountText)
                .font(.system(size: size, weight: .semibold, design: .default).monospacedDigit())
                .foregroundStyle(displayedAmountColor)
                .lineLimit(1)
                .minimumScaleFactor(minSize / idealSize)
                .contentTransition(.numericText())

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(UniColors.Text.primary)
                .frame(width: 2, height: max(28, size * 1.18))
                .accessibilityHidden(true)
        }
        .animation(.snappy(duration: 0.2), value: model.isOverBalance)
        .animation(.snappy(duration: 0.18), value: model.primaryAmountText)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Amount"))
        .accessibilityValue(Text(verbatim: displayedAmountText))
    }

    private var displayedAmountText: String {
        model.primaryAmountText.isEmpty ? "0" : model.primaryAmountText
    }

    private var displayedAmountColor: Color {
        if model.isOverBalance { return UniColors.Feedback.Error.foreground }
        if model.primaryAmountText.isEmpty { return UniColors.Text.tertiary }
        return UniColors.Text.primary
    }

    private var canAppendDecimal: Bool {
        guard maximumFractionDigits > 0 else { return false }
        return !model.primaryAmountText.contains(".") && !model.primaryAmountText.contains(",")
    }

    private var maximumFractionDigits: Int {
        model.entryUnit == .fiat ? 2 : model.effectiveDecimals
    }

    private func appendDigit(_ digit: Int) {
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        var text = model.primaryAmountText
        if text == "0" {
            text = String(digit)
        } else if text == "0.", digit == 0 || fractionLength(in: text) < maximumFractionDigits {
            text.append(String(digit))
        } else if fractionLength(in: text) < maximumFractionDigits || !text.contains(".") {
            text.append(String(digit))
        }
        model.primaryAmountText = sanitizedAmountText(text)
    }

    private func appendDecimalSeparator() {
        guard canAppendDecimal else { return }
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        let current = model.primaryAmountText
        model.primaryAmountText = current.isEmpty ? "0." : "\(current)."
    }

    private func deleteDigit() {
        guard !model.primaryAmountText.isEmpty else { return }
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        var text = model.primaryAmountText
        text.removeLast()
        model.primaryAmountText = text
    }

    private func sanitizedAmountText(_ text: String) -> String {
        let allowed = text.filter { $0.isNumber || $0 == "." }
        guard let dotIndex = allowed.firstIndex(of: ".") else { return allowed }
        let whole = allowed[..<dotIndex]
        let fractionStart = allowed.index(after: dotIndex)
        let fraction = allowed[fractionStart...].prefix(maximumFractionDigits)
        return "\(whole).\(fraction)"
    }

    private func fractionLength(in text: String) -> Int {
        guard let dotIndex = text.firstIndex(of: ".") else { return 0 }
        return text.distance(from: text.index(after: dotIndex), to: text.endIndex)
    }

    /// The flanking symbol / ticker size, tied proportionally to the
    /// number so they shrink together (Cash-App keeps them visually bound).
    private func flankSize(_ numberSize: CGFloat) -> CGFloat {
        numberSize * 0.62
    }

    @ViewBuilder
    private var conversionLine: some View {
        let crypto = model.cryptoAmount(for: model.amounts.first ?? .init(address: "", name: nil))
        switch model.entryUnit {
        case .crypto:
            if let fiat = model.fiatValue(ofCrypto: crypto) {
                conversionText("≈ \(WalletFormatting.fiat(fiat, currencyCode: model.currencyCode, hidden: hideBalances))")
            }
        case .fiat:
            conversionText("≈ \(WalletFormatting.native(crypto, decimals: model.effectiveDecimals, hidden: hideBalances)) \(model.assetSymbol)")
        }
    }

    /// The conversion line carries its own no-overflow safety: one line,
    /// shrinks to fit, with a rolling-digit transition so it reads alive
    /// while typing (Cash-App), staying restrained (Rule #2).
    private func conversionText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(UniTypography.callout.monospacedDigit())
            .foregroundStyle(UniColors.Text.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.22), value: value)
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity)
    }

    private var availableLine: some View {
        return HStack(spacing: UniSpacing.xxs) {
            Text("Available")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
            Text(verbatim: availableBalanceText)
                .font(UniTypography.footnote.monospacedDigit())
                .foregroundStyle(UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    private var availableBalanceText: String {
        if model.entryUnit == .fiat, let fiat = model.availableAssetBalanceFiat {
            return WalletFormatting.fiat(fiat, currencyCode: model.currencyCode, hidden: hideBalances)
        }
        return "\(WalletFormatting.native(model.availableAssetBalance, decimals: model.effectiveDecimals, hidden: hideBalances)) \(model.assetSymbol)"
    }

    // MARK: - Quiet pill buttons (selection-class affordances, not CTAs)

    private func quietButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: UniSpacing.xxs) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(UniTypography.footnote.weight(.semibold))
            }
            .foregroundStyle(isEnabled ? UniColors.Button.text : UniColors.Text.disabled)
            .padding(.horizontal, UniSpacing.s)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .tint(isEnabled ? UniColors.Button.Secondary.tint : UniColors.Button.Secondary.disabledTint)
        .disabled(!isEnabled)
    }

    private var unitToggleLabel: LocalizedStringKey {
        model.entryUnit == .crypto ? "Enter in \(model.currencyCode.uppercased())" : "Enter in \(model.assetSymbol)"
    }

    private var currencySymbol: String {
        let formatted = Decimal(0).formatted(.currency(code: model.currencyCode))
        // Pull just the symbol prefix/suffix; fall back to the code.
        return formatted.filter { !$0.isNumber && $0 != "." && $0 != "," && !$0.isWhitespace && $0 != "0" }
            .ifEmpty(model.currencyCode.uppercased())
    }

    private func recipientLabel(_ entry: SendComposeModel.AmountEntry) -> String {
        if let name = entry.name { return "To \(name)" }
        return "To \(SendRecipientView.shorten(entry.address))"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The MULTI-recipient amount list — one row per recipient (resolved
/// address/name + its own amount field), inside one connected inset-grouped
/// `UniCard` (the iOS grouped-form pattern, matching the recipient step).
/// Shown only when the chain can pay many recipients atomically AND more
/// than one was passed from the recipient step.
struct SendAmountMultiList: View {
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    @Bindable var model: SendComposeModel
    @Binding var selectionTapCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            // Header: the row count on the left, the crypto⇄fiat unit toggle
            // on the right — offered only when the asset is priced (FIX 1).
            HStack(alignment: .firstTextBaseline) {
                Text("Amounts (\(model.amounts.count))")
                    .font(UniTypography.footnote.weight(.semibold))
                    .foregroundStyle(UniColors.Text.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: UniSpacing.s)
                if model.assetUnitPrice != nil {
                    unitToggle
                }
            }
            .padding(.horizontal, UniSpacing.xs)

            UniCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array($model.amounts.enumerated()), id: \.element.id) { offset, $entry in
                        SendAmountRow(
                            model: model,
                            entry: $entry,
                            index: offset
                        )
                        if offset < model.amounts.count - 1 {
                            UniDivider().padding(.leading, UniSpacing.m)
                        }
                    }
                }
            }

            HStack(spacing: UniSpacing.xxs) {
                Text("Total")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: totalLineText)
                    .font(UniTypography.footnote.monospacedDigit())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .padding(.leading, UniSpacing.xs)
        }
    }

    /// Quiet glass pill that flips every row between crypto and fiat entry
    /// (selection-class affordance, not a CTA — Rule #19 §C). It fires the
    /// shared `.selection` beat via `selectionTapCount` (Rule #10 §B, no
    /// double-fire).
    private var unitToggle: some View {
        Button {
            model.toggleEntryUnit()
            selectionTapCount &+= 1
        } label: {
            HStack(spacing: UniSpacing.xxs) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(unitToggleLabel)
                    .font(UniTypography.caption1.weight(.semibold))
            }
            .foregroundStyle(UniColors.Text.primary)
            .padding(.horizontal, UniSpacing.s)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .tint(UniColors.Button.Secondary.tint)
    }

    private var unitToggleLabel: LocalizedStringKey {
        model.entryUnit == .crypto
            ? "Enter in \(model.currencyCode.uppercased())"
            : "Enter in \(model.assetSymbol)"
    }

    private var totalLineText: String {
        if model.entryUnit == .fiat, let fiat = model.fiatValue(ofCrypto: model.totalCrypto) {
            return WalletFormatting.fiat(fiat, currencyCode: model.currencyCode, hidden: hideBalances)
        }
        return "\(WalletFormatting.native(model.totalCrypto, decimals: model.effectiveDecimals, hidden: hideBalances)) \(model.assetSymbol)"
    }
}

/// One recipient row in the multi-recipient amount list. Reads its funding
/// status + active unit straight off the model so the row reacts live to
/// the cascade (FIX 4), the active unit (FIX 1), and over-allocation
/// (FIX 3). Cheap by construction — the status is plain arithmetic.
private struct SendAmountRow: View {
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    @Bindable var model: SendComposeModel
    @Binding var entry: SendComposeModel.AmountEntry
    /// Zero-based position in `model.amounts`.
    let index: Int

    /// This row's own decimal-pad focus for the rare multi-recipient entry
    /// mode. The single-recipient amount screen uses the unified in-app
    /// keypad instead of the system keyboard.
    @FocusState private var fieldFocused: Bool

    private var status: SendComposeModel.RecipientFundingStatus {
        model.recipientFundingStatus(at: index)
    }
    private var isBlocked: Bool {
        if case .blocked = status { return true }
        return false
    }
    private var isOver: Bool { status == .overBalance }

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            // FIX 2 — the FULL recipient address, LTR-locked + monospaced
            // (Rule #11). When the recipient has a name, show "i. Name" then
            // the full address beneath in a quiet mono line so the user can
            // always read exactly where the funds go.
            recipientHeader

            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
                // Fiat entry shows the currency symbol as a leading flank;
                // crypto entry shows the asset ticker as a trailing flank
                // (FIX 1). The amount field shrinks to fit rather than
                // pushing the flank / conversion off the row (no-overflow).
                if model.entryUnit == .fiat {
                    Text(verbatim: currencySymbol)
                        .font(UniTypography.callout)
                        .foregroundStyle(amountColor)
                        .lineLimit(1)
                }
                TextField("0", text: $entry.amountText)
                    .font(UniTypography.title3.monospacedDigit())
                    .foregroundStyle(amountColor)
                    .keyboardType(.decimalPad)
                    .focused($fieldFocused)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
                    .disabled(isBlocked)
                    .animation(.snappy(duration: 0.2), value: amountColor)
                    .environment(\.layoutDirection, .leftToRight)
                if model.entryUnit == .crypto {
                    Text(verbatim: model.assetSymbol)
                        .font(UniTypography.callout)
                        .foregroundStyle(isBlocked ? UniColors.Text.disabled : UniColors.Text.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: UniSpacing.s)
                conversionValue
            }

            // FIX 4 — blocked rows carry an inline, honest explanation of
            // why they can't be paid; FIX 3 — over-balance rows carry a
            // short warning so the user sees which row is the problem.
            if case .blocked(let reason) = status {
                rowNote(reason, color: UniColors.Text.tertiary, icon: "nosign")
            } else if isOver {
                rowNote(String(localized: "More than your remaining balance."),
                        color: UniColors.Feedback.Error.foreground,
                        icon: "exclamationmark.triangle.fill")
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
        .opacity(isBlocked ? 0.55 : 1)
    }

    @ViewBuilder
    private var recipientHeader: some View {
        if let name = entry.name {
            Text(verbatim: "\(index + 1). \(name)")
                .font(UniTypography.caption1.weight(.medium))
                .foregroundStyle(isBlocked ? UniColors.Text.disabled : UniColors.Text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: entry.address)
                .font(UniTypography.caption2.monospaced())
                .foregroundStyle(UniColors.Text.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .environment(\.layoutDirection, .leftToRight)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xxs) {
                Text(verbatim: "\(index + 1).")
                    .font(UniTypography.caption1.weight(.medium))
                    .foregroundStyle(isBlocked ? UniColors.Text.disabled : UniColors.Text.secondary)
                Text(verbatim: entry.address)
                    .font(UniTypography.caption2.monospaced())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }

    /// The inactive-unit conversion, mirroring the hero's conversion line:
    /// in crypto mode show the fiat value; in fiat mode show the crypto
    /// value (FIX 1). Hidden for blocked rows (nothing to convert).
    @ViewBuilder
    private var conversionValue: some View {
        if !isBlocked {
            let crypto = model.cryptoAmount(for: entry)
            switch model.entryUnit {
            case .crypto:
                if let f = model.fiatValue(ofCrypto: crypto) {
                    conversionText(WalletFormatting.fiat(f, currencyCode: model.currencyCode, hidden: hideBalances))
                }
            case .fiat:
                conversionText("\(WalletFormatting.native(crypto, decimals: model.effectiveDecimals, hidden: hideBalances)) \(model.assetSymbol)")
            }
        }
    }

    private func conversionText(_ value: String) -> some View {
        Text(verbatim: "≈ \(value)")
            .font(UniTypography.caption1.monospacedDigit())
            .foregroundStyle(UniColors.Text.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .environment(\.layoutDirection, .leftToRight)
    }

    private func rowNote(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(verbatim: text)
                .font(UniTypography.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    /// Red on over-balance (FIX 3), dimmed on blocked (FIX 4), primary
    /// otherwise.
    private var amountColor: Color {
        if isBlocked { return UniColors.Text.disabled }
        if isOver { return UniColors.Feedback.Error.foreground }
        return UniColors.Text.primary
    }

    private var currencySymbol: String {
        let formatted = Decimal(0).formatted(.currency(code: model.currencyCode))
        return formatted.filter {
            !$0.isNumber && $0 != "." && $0 != "," && !$0.isWhitespace && $0 != "0"
        }.ifEmpty(model.currencyCode.uppercased())
    }
}
