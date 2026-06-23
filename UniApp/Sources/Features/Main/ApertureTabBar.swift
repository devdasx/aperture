import SwiftUI

/// The custom 1inch-style floating bottom bar (2026-06-23 user direction —
/// replaces the native `TabView` bar).
///
/// Layout: a Liquid Glass **pill** holding the two tabs (Wallet · Browser) and
/// a separate round **Actions** FAB (the two-arrows / `arrow.left.arrow.right`
/// mark) that opens the `WalletActionsSheet`. The selected tab carries a white
/// rounded fill, exactly like 1inch's bar. Hosted via `.safeAreaInset(.bottom)`
/// so it floats over content and reserves its own space.
///
/// The wallet item carries the wallet's avatar and a `.contextMenu` (the
/// long-press switcher / customise / create / import menu) supplied by
/// `MainTabView` — the SwiftUI-native replacement for the old UITabBar
/// reach-through installer, which no longer applies without a `UITabBar`.
struct ApertureTabBar<WalletMenu: View>: View {
    let selected: MainTab
    let walletSpec: WalletAvatarSpec
    let walletId: UUID?
    let onWallet: () -> Void
    let onBrowser: () -> Void
    let onActions: () -> Void
    @ViewBuilder var walletMenu: () -> WalletMenu

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                pill
                fab
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // MARK: Pill (Wallet · Browser)

    private var pill: some View {
        HStack(spacing: 4) {
            walletTab
            browserTab
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity)
    }

    private var walletTab: some View {
        Button {
            onWallet()
        } label: {
            WalletAvatar(spec: walletSpec, size: .toolbarPill, walletId: walletId)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(selectionFill(for: .wallet))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu { walletMenu() }
        .accessibilityLabel(Text("Wallet"))
        .accessibilityAddTraits(selected == .wallet ? [.isSelected] : [])
    }

    private var browserTab: some View {
        Button {
            onBrowser()
        } label: {
            Image(systemName: "safari")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(
                    selected == .browser
                        ? UniColors.Text.primary
                        : UniColors.Text.secondary
                )
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(selectionFill(for: .browser))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Browser"))
        .accessibilityAddTraits(selected == .browser ? [.isSelected] : [])
    }

    @ViewBuilder
    private func selectionFill(for tab: MainTab) -> some View {
        if selected == tab {
            Capsule().fill(UniColors.Background.secondary)
        } else {
            Color.clear
        }
    }

    // MARK: Actions FAB (two arrows)

    private var fab: some View {
        Button {
            onActions()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(UniColors.Button.primaryLabel)
                .frame(width: 56, height: 56)
                .background(Circle().fill(UniColors.Text.primary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Actions"))
    }
}
