import SwiftUI

/// Send / Receive / Swap action triplet for the wallet-home screen.
/// Three circular Liquid Glass buttons centered with labels beneath —
/// the iOS Wallet / Apple-app pattern. `GlassEffectContainer` wraps
/// them so the material reads as one cohesive surface.
///
/// **Disabled state.** Watch-only wallets cannot send or swap (no
/// signing key). Receive remains available because receiving doesn't
/// require a key. `canSend` gates Send + Swap; Receive is always on.
struct WalletActionRegion: View {
    let canSend: Bool
    let onSend: () -> Void
    let onReceive: () -> Void
    let onSwap: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            HStack(spacing: UniSpacing.xl) {
                actionButton(
                    icon: "arrow.up.right",
                    label: "Send",
                    isEnabled: canSend,
                    action: onSend
                )
                actionButton(
                    icon: "arrow.down.left",
                    label: "Receive",
                    isEnabled: true,
                    action: onReceive
                )
                actionButton(
                    icon: "arrow.left.arrow.right",
                    label: "Swap",
                    isEnabled: canSend,
                    action: onSwap
                )
            }
        }
        .padding(.vertical, UniSpacing.m)
    }

    @ViewBuilder
    private func actionButton(
        icon: String,
        label: LocalizedStringKey,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        // Per Rule #19: every glass CTA flows through `UniButton`. The
        // `.actionCircle` variant carries the circular hit-shape that
        // matches the painted glass — fixing the 2026-06-08 bug where
        // taps near the corners of the 56×56 square frame fell outside
        // the visible circle's hit region. (Hit-test was using the SF
        // Symbol's intrinsic bounds — only the central glyph was
        // tappable.) `UniButton` now owns the haptic, the disabled-state
        // opacity, and the accessibility label.
        VStack(spacing: UniSpacing.xs) {
            UniButton(
                title: label,
                variant: .actionCircle,
                isEnabled: isEnabled,
                icon: icon,
                action: action
            )
            .accessibilityLabel(Text(label))

            Text(label)
                .font(UniTypography.caption1)
                .foregroundStyle(isEnabled ? UniColors.Text.secondary : UniColors.Text.tertiary)
        }
    }
}
