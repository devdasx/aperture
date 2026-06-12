import SwiftUI

/// Shared building blocks for the asset-shaped Advanced sheets — a fee
/// preset row, a labeled value slider, and a labeled read-out input box.
/// Factored out so the four sheets (Bitcoin fee, EVM gas, Solana
/// priority, + the simple fee display) stay small and read as
/// compositions of the same primitives.

// MARK: - Fee preset row

/// One selectable fee preset — an icon, a name + sub line, and a
/// right-aligned rate + fiat. Selected state draws a brand-Ink border +
/// inverted icon chip (the handoff's `.feeopt.on`).
struct SendFeePresetRow: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let rate: String
    let fiat: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: UniSpacing.s) {
                iconChip
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(subtitle)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                Spacer(minLength: UniSpacing.s)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: rate)
                        .font(UniTypography.subheadlineEmphasized)
                        .monospacedDigit()
                        .foregroundStyle(UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(verbatim: fiat)
                        .font(UniTypography.caption1)
                        .monospacedDigit()
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }
            .padding(UniSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(UniColors.Background.secondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                            .strokeBorder(
                                isSelected ? UniColors.Text.primary : UniColors.Separator.regular,
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var iconChip: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isSelected ? UniColors.Icon.onTint : UniColors.Icon.secondary)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous)
                    .fill(isSelected ? UniColors.Brand.mark : UniColors.Fill.tertiary)
            )
    }
}

// MARK: - Labeled slider

/// A custom-fee slider with a label, a big right-aligned value + unit, the
/// native `Slider`, and tick labels beneath. The big value reads as the
/// live result of the drag (the handoff's `.slider`). Fires `.increase` /
/// `.decrease` haptics directionally (Rule #10).
struct SendValueSlider: View {
    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: LocalizedStringKey
    /// Tick labels under the track (e.g. ["1", "slow", "fast", "100+"]).
    let ticks: [String]
    /// How to render the live value (so callers control precision /
    /// grouping per chain).
    let valueText: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Spacer(minLength: UniSpacing.s)
                HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xxs) {
                    Text(verbatim: valueText(value))
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(UniColors.Text.primary)
                    Text(unit)
                        .font(UniTypography.caption1.weight(.semibold))
                        .foregroundStyle(UniColors.Text.secondary)
                }
                .environment(\.layoutDirection, .leftToRight)
            }

            Slider(value: $value, in: range)
                .tint(UniColors.Tint.accent)
                .uniHaptic(trigger: value) { old, new in
                    new > old ? .increase : .decrease
                }

            if !ticks.isEmpty {
                HStack {
                    ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                        Text(verbatim: tick)
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.Text.quaternary)
                        if index < ticks.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: valueText(value)))
    }
}

// MARK: - Read-out / editable input box

/// A labeled box for an advanced numeric field (gas limit, nonce, max
/// fee, hex data). Editable via a bound `TextField`; LTR + numeric
/// keyboard for technical content (Rule #11).
struct SendInputBox: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var placeholder: LocalizedStringKey = ""
    var keyboard: UIKeyboardType = .decimalPad

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            Text(label)
                .font(UniTypography.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(UniColors.Text.tertiary)
            TextField(placeholder, text: $text)
                .font(UniTypography.subheadline.monospaced())
                .keyboardType(keyboard)
                .autocorrectionDisabled(true)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                .fill(UniColors.Background.secondary)
                .overlay(
                    RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                        .strokeBorder(UniColors.Separator.regular, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Toggle row

/// A labeled toggle row with an optional badge (e.g. "RBF", "CU") and a
/// sub line. Uses `UniToggle` per Rule #10 §H (fires the `.toggle` haptic).
struct SendToggleRow: View {
    let title: LocalizedStringKey
    var badge: String? = nil
    let subtitle: LocalizedStringKey
    @Binding var isOn: Bool
    /// Optional guide action — when set, an `info.circle` button sits
    /// beside the title (Rule #18 — jargon gets a guide one tap away).
    var onInfo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                HStack(spacing: UniSpacing.xs) {
                    Text(title)
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    if let badge {
                        Text(verbatim: badge)
                            .font(UniTypography.caption2.weight(.bold))
                            .foregroundStyle(UniColors.Text.tertiary)
                            .padding(.horizontal, UniSpacing.xxs)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: UniRadius.chip, style: .continuous)
                                    .fill(UniColors.Fill.tertiary)
                            )
                    }
                    if let onInfo {
                        Button(action: onInfo) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(UniColors.Icon.tertiary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Learn more"))
                    }
                }
                Text(subtitle)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UniSpacing.s)
            UniToggle(isOn: $isOn) { EmptyView() }
                .labelsHidden()
        }
        .padding(UniSpacing.s)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }
}
