import SwiftUI

/// Send / Receive action pair for asset-detail screens, plus an optional Scan
/// action for wallet home.
///
/// **Style toggle.** Flip `WalletActionRegion.chromeStyle` to compare designs:
/// - `.circularGlass` — circular Liquid Glass + caption under each (current)
/// - `.filledCapsule` — UniButton capsules with icon + title
///
/// **Disabled state.** Watch-only wallets cannot send (no signing key).
/// Receive remains available because receiving doesn't require a key.
/// `canSend` gates Send; Receive is always on.
struct WalletActionRegion: View {
    /// Revert path: set to `.circularGlass` to restore the icon-circle design.
    enum ChromeStyle: Sendable {
        /// Full capsule UniButtons (icon + title inside). Default.
        case filledCapsule
        /// Legacy: 56pt glass circles with captions underneath.
        case circularGlass
    }

    /// Single switch for A/B. Change this one value to revert.
    static var chromeStyle: ChromeStyle = .circularGlass

    let canSend: Bool
    let onSend: () -> Void
    let onReceive: () -> Void
    var onScan: (() -> Void)? = nil

    var body: some View {
        Group {
            switch Self.chromeStyle {
            case .filledCapsule:
                filledCapsuleChrome
            case .circularGlass:
                circularGlassChrome
            }
        }
        .padding(.vertical, UniSpacing.m)
    }

    // MARK: - Filled capsule (current)

    private var filledCapsuleChrome: some View {
        HStack(spacing: UniSpacing.s) {
            UniButton(
                title: "Send",
                variant: .primary,
                systemImage: "arrow.up.right",
                isEnabled: canSend,
                action: onSend
            )
            .accessibilityLabel(Text("Send"))

            UniButton(
                title: "Receive",
                variant: .secondary,
                systemImage: "arrow.down.left",
                isEnabled: true,
                action: onReceive
            )
            .accessibilityLabel(Text("Receive"))

            if let onScan {
                UniButton(
                    title: "Scan",
                    variant: .secondary,
                    systemImage: "qrcode.viewfinder",
                    isEnabled: true,
                    action: onScan
                )
                .accessibilityLabel(Text("Scan"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Circular glass (legacy — set chromeStyle = .circularGlass)

    private var circularGlassChrome: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            HStack(spacing: UniSpacing.xl) {
                Spacer(minLength: 0)
                circularActionButton(
                    icon: "arrow.up.right",
                    label: "Send",
                    isEnabled: canSend,
                    action: onSend
                )
                circularActionButton(
                    icon: "arrow.down.left",
                    label: "Receive",
                    isEnabled: true,
                    action: onReceive
                )
                if let onScan {
                    circularActionButton(
                        icon: "qrcode.viewfinder",
                        label: "Scan",
                        isEnabled: true,
                        action: onScan
                    )
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func circularActionButton(
        icon: String,
        label: LocalizedStringKey,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
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
                .foregroundStyle(isEnabled ? UniColors.Text.secondary : UniColors.Text.disabled)
        }
    }
}
