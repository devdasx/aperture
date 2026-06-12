import SwiftUI
import SwiftData
import UIKit
import TipKit

/// The post-onboarding shell for Aperture. Hosts the four top-level
/// tabs the user navigates between — **Wallet**, **Swap**, **Browser**,
/// **Settings** — via the native iOS 26 `TabView` + `Tab(...)` API.
///
/// **Design intent (one sentence, Rule #2 §D.1):** give the user one
/// always-visible, thumb-reachable map of where they are in Aperture
/// — so the wallet, the swap, the dApp browser, and the settings live
/// at the same depth and feel like four faces of the same calm
/// surface, never one buried inside another.
///
/// **2026-06-09 — Wallet tab is the active wallet's identity.** The
/// Wallet `Tab`'s `label:` closure renders the active wallet's
/// `WalletAvatar` at `.tabIcon` size (28pt circular brand-color
/// surface + centered SF Symbol in white) — replacing the prior
/// `Label("Wallet", systemImage: "wallet.pass.fill")`. The wallet's
/// identity reads in the tab bar.
///
/// **2026-06-09 (correction) — long-press switcher moved to the
/// wallet-home toolbar pill.** The first cut of this view attached
/// `.contextMenu { … }` to the Wallet `Tab` itself, then moved it
/// inside the `label:` closure on the assumption iOS would route the
/// long-press through. Verified live on Thuglife: it does NOT.
/// SwiftUI's iOS 26 `TabView` is bridged to a UIKit `UITabBar` whose
/// item buttons swallow `.contextMenu` modifiers — there is no
/// public API to attach a long-press menu to an iPhone tab-bar item
/// (`tabBarController(_:sidebar:contextMenuConfigurationFor:)` is
/// the iPad-sidebar variant only). Apple Mail's account switcher
/// uses UIKit private APIs we cannot reach from SwiftUI.
///
/// The correct shape — and the one we ship — is to attach the
/// long-press context menu to the **wallet-home toolbar pill**
/// (`UniButton(variant: .walletPill)` in `WalletHomeView`'s
/// `.principal` toolbar slot). That pill IS the active-account
/// affordance on the wallet screen — the analogue of Telegram's /
/// Instagram's profile-tab avatar. SwiftUI's `.contextMenu`
/// modifier works natively on toolbar items because they're not
/// bridged into UITabBar's item-button hierarchy — toolbar items
/// are SwiftUI views all the way down. Tap = open switcher sheet;
/// long-press = open native context menu. Same spirit, working
/// affordance.
///
/// **Why a TabView, not a sheet-per-section.** Through 2026-06-08 the
/// post-onboarding shell was a single `NavigationStack` rooted at
/// `WalletHomeView`, with Settings reached via a `.sheet(...)` from
/// the wallet-home toolbar's gear icon. That shape made Wallet feel
/// like THE app and Settings like an aside — even though Settings is
/// the user's home for Security, Wallets, Currency, Language. The
/// iOS-canonical resolution is to give each top-level section its own
/// tab, equal depth, equal reachability.
///
/// **Liquid Glass (Rule #2 §B + Rule #3).** The bar IS the iOS 26
/// Liquid Glass tab bar. We don't paint it — we compose it. The
/// translucency + specular + motion-responsiveness contract (Rule #2
/// §B.1) is delivered by the system when feature code uses the native
/// `TabView { Tab { … } label: { … } }` shape with no manual chrome.
///
/// **Selection persistence (`@AppStorage("selectedTab")`).** A user
/// who leaves the app on the Swap tab returns to the Swap tab.
///
/// **RTL (Rule #11).** Native TabView automatically mirrors tab
/// order under RTL — Settings becomes the leading tab in Arabic /
/// Hebrew / Persian / Urdu — and the SF Symbols (`arrow.left.arrow.right`
/// notably) auto-flip when directional. We do not, and must not,
/// reorder the tabs manually based on layout direction.
struct MainTabView: View {
    /// Persisted across launches so the user lands on whichever tab
    /// they last had open. Default `.wallet`. Restoration nuance
    /// (2026-06-13): `ScreenRestoration.resolveOnLaunch()` resets this
    /// key to `.wallet` during `UniAppApp.init()` when the user was
    /// away ≥ 2 minutes — so "lands on the last tab" only holds within
    /// the 2-minute restoration window.
    @AppStorage(MainTab.storageKey) private var selectedTabRaw: String = MainTab.wallet.rawValue

    /// The active wallet's UUID string. Drives the Wallet tab's
    /// avatar AND the wallet-home `WalletHomeView`. The two surfaces
    /// share the same source so switching wallets via long-press
    /// updates both atomically.
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    /// Every persisted wallet, sorted by user-chosen display order.
    /// Drives the Wallet tab icon's active-wallet lookup. `@Query`
    /// reactivity means adding / deleting / renaming / re-skinning
    /// a wallet from any surface shows up here live without any
    /// per-surface refresh logic.
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]

    /// Long-press on the Wallet tab now surfaces a NATIVE
    /// `UIContextMenuInteraction` menu (per 2026-06-09 user direction:
    /// *"it should be apple native"*). The menu items mutate these
    /// `@State` flags; SwiftUI presents the corresponding sheets /
    /// fullScreenCovers in reaction.
    @State private var isShowingCreate: Bool = false
    @State private var isShowingPicker: Bool = false
    /// "Wallet settings" in the wallet-tab context menu presents the
    /// ACTIVE wallet's `WalletDetailView` as a sheet — it must never
    /// just switch to the app Settings tab (2026-06-13 fix).
    @State private var isShowingWalletSettings: Bool = false
    @State private var isShowingImport: Bool = false
    @State private var createPath: NavigationPath = NavigationPath()
    @State private var importPath: NavigationPath = NavigationPath()

    /// Computed binding that round-trips the persisted raw through
    /// the `MainTab` enum. Unknown rawValues (manual UserDefaults
    /// fiddling, future tab renames) fall back to `.wallet`.
    private var selectedTab: Binding<MainTab> {
        Binding(
            get: { MainTab(rawValue: selectedTabRaw) ?? .wallet },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    /// The active wallet's record — looked up by UUID against the
    /// `@Query` result. Falls back to the first wallet if the
    /// persisted id is missing (manual UserDefaults fiddling or a
    /// wallet that was deleted from another device through future
    /// CloudKit sync). When `allWallets` itself is empty, returns
    /// `nil` and the tab icon falls back to the default avatar.
    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    var body: some View {
        TabView(selection: selectedTab) {
            // MARK: - Wallet (custom avatar label)
            //
            // The Wallet tab's `label:` closure renders the active
            // wallet's `WalletAvatar` instead of a generic SF Symbol.
            // The text "Wallet" stays — iOS tab bars show both glyph
            // and text by default. The avatar replaces the glyph
            // role; the text role is unchanged.
            //
            // `.contextMenu` is NOT attached here. The long-press
            // wallet switcher lives on the wallet-home toolbar
            // pill instead — see the type-level doc comment for
            // the verification trail.
            Tab(value: MainTab.wallet) {
                WalletHomeView()
                    // Zero-size UIKit installer. On first appear,
                    // resolves the surrounding `UITabBarController`,
                    // attaches a `UIContextMenuInteraction` to its
                    // public `UITabBar`, and on long-press surfaces
                    // the native iOS context menu built from
                    // `buildWalletTabMenu()`. The menu's `UIAction`s
                    // mutate `@State` flags on this view; SwiftUI
                    // reacts via the modifiers below.
                    .background(alignment: .bottom) {
                        TabBarLongPressInstaller(tabIndex: 0) {
                            buildWalletTabMenu()
                        }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                    }
            } label: {
                walletTabLabel
                // 2026-06-09 — `popoverTip` REMOVED from the Tab
                // label. iOS 26's new TabView renders its `label:`
                // closure inside the UIKit tab-bar button image
                // slot, which has no SwiftUI popover presentation
                // context — the popover never anchored. The same
                // `WalletTabSwitcherTip` is now rendered inline as
                // a `TipView` from `WalletHomeView`'s content
                // hierarchy, where a real SwiftUI parent exists.
            }

            // MARK: - Swap
            Tab("Swap", systemImage: "arrow.left.arrow.right", value: MainTab.swap) {
                NavigationStack {
                    SwapPlaceholderView()
                }
            }

            // MARK: - Browser
            //
            // 2026-06-10 — `BrowserPlaceholderView` retired; replaced
            // by `BrowserHomeView` (Aperture's in-wallet dApp
            // browser surface). The home view owns the URL field,
            // favorites grid, recent list, connected sessions, and
            // the router's four confirmation sheets. Pushing into
            // `BrowserSessionView` carries the actively-browsed
            // page; the wrapping `NavigationStack` here provides
            // the push surface and the `.toolbar` ladder
            // `BrowserHomeView` populates with the QR / settings
            // icons.
            Tab("Browser", systemImage: "globe", value: MainTab.browser) {
                NavigationStack {
                    BrowserHomeView()
                }
            }

            // MARK: - Settings
            Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
                SettingsView()
            }
        }
        // Fire a selection haptic on tab change. Per Rule #10 §A,
        // tab selection IS the canonical `.selection` haptic.
        .uniHaptic(.selection, trigger: selectedTabRaw)
        // Wallet icon picker — surfaced by the "Customise icon" item
        // in the long-press context menu. Reuses
        // `WalletIconPickerSheet`, the same primitive presented from
        // the wallet-home toolbar pill's existing entry point.
        .sheet(isPresented: $isShowingPicker) {
            if let active = activeWallet {
                WalletIconPickerSheet(walletId: active.id)
                    .uniAppEnvironment()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(UniColors.Background.primary)
            }
        }
        // Wallet settings — surfaced by the "Wallet settings" item in
        // the long-press context menu. Presents the active wallet's
        // detail screen (the same `WalletDetailView` Settings →
        // Wallets pushes) wrapped in its own NavigationStack per
        // Rule #15. Its sub-links use closure-form NavigationLink,
        // so the standalone stack needs no destination registrations.
        .sheet(isPresented: $isShowingWalletSettings) {
            if let active = activeWallet {
                NavigationStack {
                    WalletDetailView(walletId: active.id)
                }
                .uniAppEnvironment()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
            }
        }
        .fullScreenCover(isPresented: $isShowingCreate, onDismiss: {
            createPath = NavigationPath()
        }) {
            RecoveryPhraseFlow(
                navigationPath: $createPath,
                onDismiss: { isShowingCreate = false },
                onUserSkippedBackup: {},
                onUserCompletedBackup: {}
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        // Import flow — surfaced directly from the long-press
        // context menu's "Import existing wallet" item. The prior
        // implementation only switched to the Settings tab and
        // forced the user to navigate through Settings → Wallets to
        // find the entry point; the fullScreenCover takes them
        // straight there.
        .fullScreenCover(isPresented: $isShowingImport, onDismiss: {
            importPath = NavigationPath()
        }) {
            ImportWalletFlow(
                navigationPath: $importPath,
                onDismiss: { isShowingImport = false },
                onCompleted: { _ in isShowingImport = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Wallet tab label (avatar only — no "Wallet" text)
    //
    // iOS 26's `Tab(value:content:label:)` initializer accepts an
    // arbitrary `label:` closure. The Wallet tab is the only one
    // that ships WITHOUT visible text — the per-wallet avatar IS
    // the identity, and adding "Wallet" underneath would compete
    // with the wallet name shown in the toolbar pill above. The
    // other three tabs (Swap, Browser, Settings) keep their
    // `Label(_:systemImage:)` text by design — they are generic
    // sections, not personalized identities.
    //
    // `.accessibilityLabel("Wallet")` preserves VoiceOver — the
    // screenreader announces "Wallet, Tab" even though the visible
    // label is image-only.
    /// Stable fallback spec for the no-wallet case (clean launch
    /// before `ensureActiveWalletSet()` lands one). Hoisted to a
    /// `static let` so every body pass hands `WalletAvatarTabImage`
    /// the *same* `Hashable` value instead of constructing a fresh
    /// `auto(name:)` spec inline — stable inputs let the tab image's
    /// internal cache key actually hit.
    private static let fallbackAvatarSpec = WalletAvatarSpec.auto(name: "Wallet")

    @ViewBuilder
    private var walletTabLabel: some View {
        // 2026-06-09 — gradient-disc avatar per the design handoff.
        // `WalletRecord.avatarSpec` hydrates the persisted columns
        // through `WalletAvatarSpec.hydrate(...)` with auto(name)
        // fallback so the disc is never blank even pre-migration.
        // When there's no wallet yet (clean launch before
        // `ensureActiveWalletSet()` lands one), we render the
        // hoisted `fallbackAvatarSpec` above.
        //
        // **2026-06-09 v2 (Thuglife `8588`) — `WalletAvatarTabImage`,
        // not the raw `WalletAvatar`.** iOS UITabBar renders the icon
        // slot's view as a template by default — alpha mask kept,
        // colors replaced with the unselected-tab gray (or the
        // selected-tab tint). The user observed this live: their
        // green disc + W rendered correctly in the toolbar pill but
        // appeared as a gray W in the bottom tab. The wrapper snapshots
        // the SwiftUI avatar to a `UIImage` marked `.alwaysOriginal`,
        // which opts the icon out of template rendering and preserves
        // the gradient + sheen + edge + badge as drawn. See
        // `WalletAvatarTabImage.swift` for the rationale.
        let spec: WalletAvatarSpec = activeWallet?.avatarSpec
            ?? Self.fallbackAvatarSpec
        // 2026-06-09 v3 — bumped from 28pt → 36pt per user request.
        // The disc carries the wallet's identity; at 28pt it read as
        // a small dot next to the other tabs' SF Symbols. 36pt gives
        // the gradient the room to do its job without breaking out
        // of iOS's tab-icon envelope.
        // Pass a source size larger than the system envelope so the
        // wrapper's `ImageRenderer` produces a high-resolution bitmap
        // even after iOS clamps it. `.imageScale(.large)` inside
        // `WalletAvatarTabImage`'s body nudges the displayed envelope
        // up by ~15% — the only public-API knob iOS 26 gives us.
        WalletAvatarTabImage(spec: spec, size: 60, walletId: activeWallet?.id)
            .accessibilityLabel(Text("Wallet"))
    }

    // MARK: - Context menu builder
    //
    // Builds the native iOS `UIMenu` presented by
    // `UIContextMenuInteraction` when the user long-presses the
    // Wallet tab. Per 2026-06-09 user direction the menu surfaces
    // wallet identity, customisation, switching, and the create /
    // import flows — replacing the prior `WalletSwitcherSheet` with
    // an apple-native primitive.
    //
    // **Reactivity.** `buildWalletTabMenu()` runs every time the
    // interaction fires (the `TabBarLongPressInstaller` calls the
    // closure lazily, not at view body), so the menu reflects the
    // live `@Query` snapshot. A wallet renamed in Settings shows up
    // with its new name on the next long-press without any cache
    // invalidation step.
    //
    // **Menu shape.**
    //   ┌─────────────────────────────┐
    //   │ Customise icon              │  ← active wallet only
    //   │ Wallet settings             │
    //   ├─────────────────────────────┤
    //   │ Switch wallet → submenu     │  ← only when count > 1
    //   │   • Wallet A ✓               │
    //   │   • Wallet B                 │
    //   ├─────────────────────────────┤
    //   │ Create new wallet           │
    //   │ Import existing wallet      │
    //   └─────────────────────────────┘
    private func buildWalletTabMenu() -> UIMenu {
        var children: [UIMenuElement] = []

        // 1. Primary group — Customise + Settings.
        var primaryActions: [UIAction] = []
        if activeWallet != nil {
            primaryActions.append(
                UIAction(
                    title: String(localized: "Customise icon"),
                    image: UIImage(systemName: "paintbrush")
                ) { _ in
                    isShowingPicker = true
                }
            )
            primaryActions.append(
                UIAction(
                    title: String(localized: "Wallet settings"),
                    image: UIImage(systemName: "gearshape")
                ) { _ in
                    // Open the ACTIVE WALLET's settings directly —
                    // not the app Settings tab (2026-06-13 user
                    // report: "it navigates me to app settings, it
                    // doesn't open the wallet settings").
                    isShowingWalletSettings = true
                }
            )
        }
        if !primaryActions.isEmpty {
            children.append(
                UIMenu(title: "", options: .displayInline, children: primaryActions)
            )
        }

        // 2. Switch wallet — only when the user has more than one
        //    wallet. Each item is a UIAction; the active wallet
        //    carries state `.on` (the iOS native checkmark).
        if allWallets.count > 1 {
            let switchActions: [UIAction] = allWallets.map { wallet in
                let isActive = wallet.id == activeWallet?.id
                return UIAction(
                    title: wallet.name,
                    image: renderWalletAvatarMenuImage(for: wallet),
                    state: isActive ? .on : .off
                ) { _ in
                    activeWalletIdRaw = wallet.id.uuidString
                }
            }
            let switchMenu = UIMenu(
                title: String(localized: "Switch wallet"),
                image: UIImage(systemName: "rectangle.stack"),
                children: switchActions
            )
            children.append(
                UIMenu(title: "", options: .displayInline, children: [switchMenu])
            )
        }

        // 3. Add wallet group — Create + Import.
        let addGroup = UIMenu(
            title: "",
            options: .displayInline,
            children: [
                UIAction(
                    title: String(localized: "Create new wallet"),
                    image: UIImage(systemName: "plus")
                ) { _ in
                    isShowingCreate = true
                },
                UIAction(
                    title: String(localized: "Import existing wallet"),
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { _ in
                    isShowingImport = true
                }
            ]
        )
        children.append(addGroup)

        return UIMenu(title: "", children: children)
    }

    /// Snapshot a wallet's `WalletAvatar` to a `UIImage` with
    /// `.alwaysOriginal` rendering so the iOS context menu shows
    /// the user's real chosen identity (gradient disc + glyph /
    /// monogram / custom SVG) instead of a generic SF Symbol.
    ///
    /// **Why `.alwaysOriginal`.** `UIAction.image` is template-rendered
    /// by `UIMenu` — the system takes the alpha channel and fills with
    /// the menu's chrome tint (gray on light, light gray on dark).
    /// Without `.alwaysOriginal`, the avatar's gradient gets stripped
    /// and the user sees a flat silhouette. Same trick the bottom
    /// `WalletAvatarTabImage` uses for the tab icon (see that file's
    /// doc-comment for the deeper rationale).
    ///
    /// **Source size.** 96pt — large enough that the iOS menu's
    /// downscale produces a crisp result at the system's ~22-26pt
    /// menu-icon envelope.
    @MainActor
    private func renderWalletAvatarMenuImage(for wallet: WalletRecord) -> UIImage {
        let renderer = ImageRenderer(
            content: WalletAvatar(spec: wallet.avatarSpec, size: .row)
                .frame(width: 96, height: 96)
        )
        renderer.scale = UITraitCollection.current.displayScale
        let image = renderer.uiImage ?? UIImage()
        return image.withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - MainTab

/// Stable, persistable identity for each top-level destination in
/// the post-onboarding shell. RawValue is the persistence key
/// stored in `@AppStorage("selectedTab")`. RawValues are stable
/// forever — renaming a tab in the future never changes the
/// persistence key.
///
/// Order in the enum mirrors visual order in the tab bar (Wallet,
/// Swap, Browser, Settings). RTL layout flips visual order
/// automatically via SwiftUI — the enum declaration order does
/// not change.
enum MainTab: String, Hashable, CaseIterable {
    case wallet
    case swap
    case browser
    case settings

    /// The `@AppStorage` / `UserDefaults` key the selected tab persists
    /// under. Single source of truth shared by `MainTabView`,
    /// `WalletHomeView`'s long-press deep link, and
    /// `ScreenRestoration.resolveOnLaunch()` (which resets the value to
    /// `.wallet` when the user has been away ≥ 2 minutes).
    static let storageKey = "selectedTab"
}
