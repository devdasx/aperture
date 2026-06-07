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
        VStack(spacing: UniSpacing.xs) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glassProminent)
            .tint(UniColors.Button.primaryTint)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1.0 : 0.5)
            .accessibilityLabel(Text(label))

            Text(label)
                .font(UniTypography.caption1)
                .foregroundStyle(isEnabled ? UniColors.Text.secondary : UniColors.Text.tertiary)
        }
    }
}
