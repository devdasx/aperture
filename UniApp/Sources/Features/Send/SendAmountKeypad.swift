import SwiftUI

/// The custom numeric keypad for the Amount screen — 1–9, then `.`, `0`,
/// delete. **Not** the system number-pad keyboard: the amount field is a
/// bespoke big-numeral display with a blinking cursor, so a custom keypad
/// is the honest control (mirrors `PinCodeView`'s `LazyVGrid` approach,
/// per the prompt's grounding).
///
/// **Rule #11.** The keypad is LTR + Western-Arabic digits in every
/// locale — the override is scoped to the grid subtree only (like
/// `PinCodeView`'s keypad). Digit glyphs are `Text(verbatim:)` so they
/// render as ASCII regardless of locale.
///
/// **Haptics.** The keypad doesn't fire haptics itself — the parent
/// (`SendAmountView`) owns the amount string and fires a throttled
/// `.selection` on change (per-keystroke) and `.contextualImpact(.tap)`
/// on MAX, per the handoff + Rule #10. Keeping the haptic at the state
/// owner avoids double-firing.
///
/// **Decimal rule.** The keypad enforces a single decimal point and
/// (caller-supplied) max fractional digits, so the displayed string is
/// always a valid amount-in-progress.
struct SendAmountKeypad: View {
    /// The amount string the keypad mutates. The parent renders the big
    /// numerals from this and fires the per-keystroke haptic on change.
    @Binding var amount: String

    /// Max fractional digits allowed (the asset's decimals). Prevents
    /// typing more precision than the asset supports.
    let maxFractionDigits: Int

    private let columns = [
        GridItem(.flexible(), spacing: UniSpacing.s),
        GridItem(.flexible(), spacing: UniSpacing.s),
        GridItem(.flexible(), spacing: UniSpacing.s)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: UniSpacing.xs) {
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
                .font(.system(size: 26, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous))
        }
        .buttonStyle(KeypadKeyStyle())
        .accessibilityLabel(Text(verbatim: label))
    }

    private var deleteKey: some View {
        Button(action: deleteLast) {
            Image(systemName: "delete.left")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(UniColors.Text.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous))
        }
        .buttonStyle(KeypadKeyStyle())
        .accessibilityLabel(Text("Delete"))
    }

    // MARK: - Mutation

    private func append(_ digit: String) {
        // Block extra leading zeroes ("00" → "0", "01" → "1").
        if amount == "0", digit != "." {
            amount = digit
            return
        }
        // Enforce max fractional digits.
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

// MARK: - Key style

/// A flat, restrained keypad-key press style — a faint fill on press, no
/// glass (the keypad is a dense content control, not chrome; glass on 12
/// keys would be glass-on-glass clutter per Rule #2 §B.7).
private struct KeypadKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(configuration.isPressed ? UniColors.Fill.tertiary : Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
