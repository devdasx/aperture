import SwiftUI

/// Receive / Swap action pair for the wallet-home screen. Circular
/// Liquid Glass buttons centered with labels beneath — the iOS Wallet /
/// Apple-app pattern. `GlassEffectContainer` wraps them so the material
/// reads as one cohesive surface.
///
/// **Disabled state.** Watch-only wallets cannot swap (no signing key);
/// `canSend` gates Swap. Receive is always on because receiving doesn't
/// require a key.
struct WalletActionRegion: View {
    let canSend: Bool
    let onReceive: () -> Void
    let onSwap: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            // `HStack` defaults to hugging its intrinsic content at
            // the leading edge — fine when an outer VStack centers
            // it, but inside a `List` row (post-2026-06-08 native-
            // List rebuild) the row's content area is wider than the
            // triplet, so the triplet was rendering shifted to the
            // left. `Spacer()`s on both sides + `.frame(maxWidth:
            // .infinity)` on the HStack distribute the buttons
            // around the row's center regardless of the parent. The
            // old ScrollView placement worked by coincidence; the
            // List placement requires the explicit centering.
            HStack(spacing: UniSpacing.xl) {
                Spacer(minLength: 0)
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
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
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
