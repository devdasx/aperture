import SwiftUI

// MARK: - Send v2 bare keypad
//
// The handoff's bare keypad: *"No key backgrounds. Bare numerals
// (25px/500) on the bloom; a soft white wash appears only on press."*
// This supersedes v1's `SendAmountKeypad` (which carried a resting
// `Fill.tertiary` press fill) for the v2 Amount screen.
//
// Mirrors `PinCodeView`'s `LazyVGrid` approach. Per Rule #11 the keypad is
// LTR + Western-Arabic digits in every locale (scoped to the grid subtree
// only); digit glyphs are `Text(verbatim:)` so they render as ASCII
// regardless of locale. The keypad fires no haptic itself — the parent
// owns the amount string and fires the per-keystroke `.selection`
// (handoff: keypad digit → `tap`; the parent maps the string change to a
// throttled tap), avoiding double-fire.

struct SendV2Keypad: View {
    /// The amount string the keypad mutates. The parent renders the big
    /// numerals from this and fires the per-keystroke haptic on change.
    @Binding var amount: String

    /// Max fractional digits allowed (the asset's decimals). Prevents
    /// typing more precision than the asset supports.
    let maxFractionDigits: Int

    private let columns = [
        GridItem(.flexible(), spacing: UniSpacing.xs),
        GridItem(.flexible(), spacing: UniSpacing.xs),
        GridItem(.flexible(), spacing: UniSpacing.xs)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: UniSpacing.xxs) {
            ForEach(1...9, id: \.self) { digit in
                key(label: String(digit)) { append(String(digit)) }
            }
            key(label: ".") { appendDecimal() }
            key(label: "0") { append("0") }
            deleteKey
        }
        // Rule #11 — keypad is LTR + Western digits in every locale,
        // scoped to the grid subtree only.
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.locale, Locale(identifier: "en"))
    }

    // MARK: - Keys

    @ViewBuilder
    private func key(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: 28, weight: .medium, design: .default))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .contentShape(RoundedRectangle(cornerRadius: UniRadius.xl, style: .continuous))
        }
        .buttonStyle(BareKeyStyle())
        .accessibilityLabel(Text(verbatim: label))
    }

    private var deleteKey: some View {
        Button(action: deleteLast) {
            Image(systemName: "delete.left")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(UniColors.Text.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .contentShape(RoundedRectangle(cornerRadius: UniRadius.xl, style: .continuous))
        }
        .buttonStyle(BareKeyStyle())
        .accessibilityLabel(Text("Delete"))
    }

    // MARK: - Mutation

    private func append(_ digit: String) {
        if amount == "0", digit != "." {
            amount = digit
            return
        }
        if let dotIndex = amount.firstIndex(of: ".") {
            let fraction = amount.distance(from: amount.index(after: dotIndex), to: amount.endIndex)
            if fraction >= maxFractionDigits { return }
        }
        amount.append(digit)
    }

    private func appendDecimal() {
        if amount.contains(".") { return }
        if amount.isEmpty { amount = "0." } else { amount.append(".") }
    }

    private func deleteLast() {
        guard !amount.isEmpty else { return }
        amount.removeLast()
    }
}

// MARK: - Bare key style

/// No resting chrome — only a soft white (light) / soft fill (dark) wash
/// on press, per the handoff. The wash is a faint circle-shaped fill so
/// the press reads as a touch wash, not a button.
private struct BareKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: UniRadius.xl, style: .continuous)
                    .fill(UniColors.Send.cardSpecular.opacity(configuration.isPressed ? 0.9 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Big amount display

/// The handoff's big amount: SF Pro Display, tabular, tight tracking
/// (`−0.035em` ≈ `-1.9pt` at 54pt), with the integer part in ink and the
/// decimal part faint. A flip button swaps fiat ⇄ crypto.
///
/// The amount is presented LTR + tabular (Rule #11 display-content
/// carve-out — figures the user reads).
struct SendAmountDisplay: View {
    /// The string to display (already in the active mode — crypto or fiat).
    let displayString: String
    /// The unit shown beside the numerals (ticker or currency code).
    let unit: String
    /// The "≈" secondary line (the opposite-mode equivalent).
    let secondary: String
    /// Whether the screen is in fiat-first mode (drives the flip glyph
    /// inversion per the handoff: *"the flip button inverts to dark"*).
    let isShowingFiat: Bool
    /// Fires when the flip is tapped.
    let onFlip: () -> Void

    var body: some View {
        VStack(spacing: UniSpacing.s) {
            amountRow
            flipButton
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var amountRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
            Text(attributedAmount)
                .font(.system(size: 54, weight: .bold, design: .default))
                .monospacedDigit()
                .tracking(-1.9)   // ≈ −0.035em at 54pt
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            Text(verbatim: unit)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(UniColors.Text.secondary)
        }
        .padding(.horizontal, UniSpacing.m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Amount"))
        .accessibilityValue(Text(verbatim: "\(displayString) \(unit)"))
    }

    /// Integer part in `Text.primary`, fractional part (incl. the dot) in
    /// `Text.tertiary` — the handoff's "decimals in faint".
    private var attributedAmount: AttributedString {
        var result = AttributedString(displayString)
        result.foregroundColor = UniColors.Text.primary
        if let dotRange = result.range(of: ".") {
            var faint = AttributedString(String(displayString[displayString.range(of: ".")!.lowerBound...]))
            faint.foregroundColor = UniColors.Text.tertiary
            result.replaceSubrange(dotRange.lowerBound..<result.endIndex, with: faint)
        }
        return result
    }

    private var flipButton: some View {
        Button(action: onFlip) {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: secondary)
                    .font(UniTypography.callout)
                    .monospacedDigit()
            }
            .foregroundStyle(isShowingFiat ? UniColors.Send.onDarkGlass : UniColors.Text.secondary)
            .padding(.horizontal, UniSpacing.s)
            .frame(height: 36)
            .modifier(FlipSurface(isShowingFiat: isShowingFiat))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // `.toggle` per the handoff (fires when values swap).
        .uniHaptic(.toggle, trigger: isShowingFiat)
        .accessibilityLabel(Text("Switch between crypto and fiat"))
    }

    private struct FlipSurface: ViewModifier {
        let isShowingFiat: Bool
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        func body(content: Content) -> some View {
            if isShowingFiat {
                content.background(Capsule().fill(UniColors.Send.darkGlass))
            } else if reduceTransparency {
                content
                    .background(Capsule().fill(UniColors.Send.cardSolidFallback))
                    .overlay(Capsule().stroke(UniColors.Send.cardHairline, lineWidth: 0.5))
            } else {
                content.glassEffect(.regular, in: .capsule)
            }
        }
    }
}
