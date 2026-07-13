import SwiftUI
import UIKit
import Combine

/// Live wallet-pager identity chrome shared between the hero and the app bar.
///
/// Updated **every horizontal swipe tick** from `WalletHomeHeroPager` without
/// going through `WalletHomeView` `@State` — so the home `ScrollView` is not
/// rebuilt mid-gesture (that was snapping the pager back to the previous wallet).
///
/// Consumers must be **leaf** views / modifiers that `@ObservedObject` this
/// store, not the home root body.
@MainActor
final class WalletHomeSwipeChrome: ObservableObject {
    static let shared = WalletHomeSwipeChrome()

    /// Fractional page progress `0…count-1`.
    @Published private(set) var progress: CGFloat = 0
    /// Blend factor between `from` and `to` (0…1).
    @Published private(set) var blendT: CGFloat = 0
    @Published private(set) var fromColor: Color = UniColors.Brand.mark
    @Published private(set) var toColor: Color = UniColors.Brand.mark
    @Published private(set) var nearerSpec: WalletAvatarSpec = WalletAvatarSpec.auto(name: "Wallet")
    @Published private(set) var nearerWalletId: UUID?
    @Published private(set) var nearerWalletName: String = "Wallet"

    private init() {}

    /// Solid identity colour for the current swipe blend.
    var blendedIdentityColor: Color {
        Self.mix(fromColor, toColor, t: blendT)
    }

    var prefersLightForeground: Bool {
        UniColors.WalletAvatar.prefersLightForeground(for: nearerSpec)
    }

    var contentPrimary: Color {
        UniColors.WalletAvatar.contentPrimary(for: nearerSpec)
    }

    var contentChipFill: Color {
        UniColors.WalletAvatar.contentChipFill(for: nearerSpec)
    }

    /// Publish from the hero pager. Safe to call every frame; no-ops small noise.
    func publish(progress rawProgress: CGFloat, wallets: [WalletRecord]) {
        guard !wallets.isEmpty else { return }
        let maxIndex = CGFloat(wallets.count - 1)
        let progress = min(maxIndex, max(0, rawProgress))
        let pair = WalletHomeHeroPager.swipePair(wallets: wallets, progress: progress)
        let nearer = pair.t < 0.5 ? pair.from : pair.to
        let nearerIndex = min(max(Int((progress + 0.0001).rounded()), 0), wallets.count - 1)
        let nearerWallet = wallets[nearerIndex]

        let from = UniColors.WalletAvatar.identityColor(for: pair.from)
        let to = UniColors.WalletAvatar.identityColor(for: pair.to)

        // Skip pure noise — but always accept identity changes (colour
        // pick from the icon sheet updates the same wallet in place).
        let identityUnchanged =
            nearerSpec.gradient == nearer.gradient
            && nearerSpec.customColorHex == nearer.customColorHex
        if abs(progress - self.progress) < 0.004,
           abs(pair.t - blendT) < 0.004,
           nearerWalletId == nearerWallet.id,
           identityUnchanged {
            return
        }

        self.progress = progress
        self.blendT = pair.t
        self.fromColor = from
        self.toColor = to
        self.nearerSpec = nearer
        self.nearerWalletId = nearerWallet.id
        self.nearerWalletName = nearerWallet.name
    }

    /// Force re-read of wallet identity after an avatar write (icon picker).
    /// Does not require a page swipe — progress stays put.
    func refreshIdentity(from wallets: [WalletRecord]) {
        guard !wallets.isEmpty else { return }
        // Bypass the noise filter by always writing colours from current wallets.
        let pair = WalletHomeHeroPager.swipePair(wallets: wallets, progress: progress)
        let nearerIndex = min(max(Int((progress + 0.0001).rounded()), 0), wallets.count - 1)
        let nearerWallet = wallets[nearerIndex]
        self.fromColor = UniColors.WalletAvatar.identityColor(for: pair.from)
        self.toColor = UniColors.WalletAvatar.identityColor(for: pair.to)
        self.nearerSpec = pair.t < 0.5 ? pair.from : pair.to
        self.nearerWalletId = nearerWallet.id
        self.nearerWalletName = nearerWallet.name
        objectWillChange.send()
    }

    /// Immediate identity paint after a picker write, even before GRDB
    /// observation re-emits the wallet list.
    func applyIdentity(walletId: UUID, name: String, spec: WalletAvatarSpec) {
        let color = UniColors.WalletAvatar.identityColor(for: spec)
        // Always paint when this is the nearer / only wallet, **or** when
        // nearer has not been seeded yet (sheet can open before first
        // hero publish). Never leave the balance card on a stale colour.
        guard nearerWalletId == nil || nearerWalletId == walletId else { return }

        nearerSpec = spec
        nearerWalletId = walletId
        nearerWalletName = name
        // Solid identity fill for the balance card + pull gap + app bar.
        fromColor = color
        toColor = color
        objectWillChange.send()
    }

    static func mix(_ a: Color, _ b: Color, t: CGFloat) -> Color {
        let t = min(1, max(0, t))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard UIColor(a).getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              UIColor(b).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        else {
            return t < 0.5 ? a : b
        }
        return Color(
            red: Double(r1 + (r2 - r1) * t),
            green: Double(g1 + (g2 - g1) * t),
            blue: Double(b1 + (b2 - b1) * t),
            opacity: Double(a1 + (a2 - a1) * t)
        )
    }
}

// MARK: - Leaf consumers (observe store; do not sit on WalletHomeView root state)

/// Pull-gap / top safe-area identity sheet — updates live mid-swipe.
struct WalletHomeLiveIdentityFill: View {
    @ObservedObject private var chrome = WalletHomeSwipeChrome.shared

    var body: some View {
        chrome.blendedIdentityColor
    }
}

/// Applies live identity → page-floor toolbar fill without the home root
/// owning mid-swipe `@State` progress.
struct WalletHomeLiveToolbarChrome: ViewModifier {
    @ObservedObject private var chrome = WalletHomeSwipeChrome.shared
    /// 0 = identity bar, 1 = page floor (vertical scroll).
    var verticalBlend: CGFloat
    var pageFloor: Color

    func body(content: Content) -> some View {
        let identity = chrome.blendedIdentityColor
        let bar = WalletHomeSwipeChrome.mix(identity, pageFloor, t: verticalBlend)
        let scheme: ColorScheme = {
            if verticalBlend < 0.9 {
                return chrome.prefersLightForeground ? .dark : .light
            }
            return floorColorScheme(pageFloor)
        }()

        return content
            .toolbarBackground(bar, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(scheme, for: .navigationBar)
    }

    private func floorColorScheme(_ floor: Color) -> ColorScheme {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(floor).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? .light : .dark
    }
}

/// App-bar wallet pill that tracks live nearer-wallet identity mid-swipe.
struct WalletHomeLiveAppBarPill<Menu: View>: View {
    @ObservedObject private var chrome = WalletHomeSwipeChrome.shared
    let verticalBlend: CGFloat
    let scrolledLabel: Color
    let scrolledChip: Color
    let onTap: () -> Void
    @ViewBuilder let contextMenu: () -> Menu

    var body: some View {
        let t = verticalBlend
        let label = WalletHomeSwipeChrome.mix(chrome.contentPrimary, scrolledLabel, t: t)
        let chip = WalletHomeSwipeChrome.mix(chrome.contentChipFill, scrolledChip, t: t)
        let name = chrome.nearerWalletName
        // Stable identity for avatar only — do **not** put `.contentTransition`
        // / snappy animation on the name. On cold open those animate the
        // label through opacity 0 while the capsule already paints, so the
        // pill looks broken (logo + chevron, empty middle).
        let walletKey = chrome.nearerWalletId?.uuidString ?? name
        Button(action: onTap) {
            HStack(spacing: UniSpacing.xs) {
                WalletAvatar(
                    spec: chrome.nearerSpec,
                    size: .toolbarPill,
                    walletId: chrome.nearerWalletId
                )
                .id("pill-avatar-\(walletKey)")

                Text(verbatim: name)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(label)
                    .lineLimit(1)
                    .layoutPriority(1)
                    // Keep intrinsic width so UIKit toolbar never collapses
                    // the title slot to zero during first layout.
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(label.opacity(0.85))
                    .layoutPriority(0)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Capsule(style: .continuous).fill(chip))
            .contentShape(Capsule(style: .continuous))
        }
        // Custom expand + bounce + shimmer (no system Liquid Glass).
        .buttonStyle(.uniInteractivePress)
        .controlSize(.regular)
        .accessibilityLabel(Text(verbatim: String(
            format: String.apertureLocalized("Switch wallet, currently %@"),
            name
        )))
        .contextMenu { contextMenu() }
    }
}
