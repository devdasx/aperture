import SwiftUI
import SwiftData
import UIKit
import TipKit

/// The post-onboarding shell for Aperture. Hosts the top-level tabs the user
/// navigates between — **Wallet**, **Browser**, and the **Actions** trigger —
/// via the native iOS 26 `TabView` + `Tab(...)` API. **Settings is no longer a
/// tab (2026-06-23):** it moved to the wallet-home toolbar's trailing gear and
/// is presented full screen (the historical "why a TabView, not a sheet" note
/// below predates that reversal).
///
/// **Design intent (one sentence, Rule #2 §D.1):** give the user one
/// always-visible, thumb-reachable map of where they are in Aperture
/// — so the wallet, the dApp browser, and the settings live
/// at the same depth and feel like faces of the same calm
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
/// who leaves the app on the Browser tab returns to the Browser tab.
///
/// **RTL (Rule #11).** Native TabView automatically mirrors tab
/// order under RTL — Settings becomes the leading tab in Arabic /
/// Hebrew / Persian / Urdu — and the SF Symbols (`arrow.left.arrow.right`
/// notably) auto-flip when directional. We do not, and must not,
/// reorder the tabs manually based on layout direction.
/// Cross-view signal for "the user re-tapped the active tab" (2026-06-18).
/// `MainTabView` bumps `walletReselectToken` when the already-selected
/// Wallet tab is tapped again; `WalletHomeView` observes it (via the
/// Observation framework) and pops its navigation stack to root. A shared
/// singleton — not an environment object — so `WalletHomeView()` needs no
/// init change and there's no missing-environment trap.
@MainActor
@Observable
final class TabReselectSignal {
    static let shared = TabReselectSignal()
    private init() {}
    /// Monotonic counter, bumped on each Wallet-tab re-tap.
    var walletReselectToken: Int = 0
}

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

    /// **iPad / Mac adaptation (2026-06-16).** `.tabViewStyle(.sidebarAdaptable)`
    /// makes the SAME four `Tab(...)` render as the Liquid Glass bottom
    /// tab bar at COMPACT width (iPhone, iPad portrait, narrow Mac
    /// window) and lift into a native Liquid Glass sidebar at REGULAR
    /// width (iPad landscape, wide Mac window). The compact path is
    /// byte-for-byte the shipping iPhone experience. At regular width
    /// the UITabBar the long-press installer reaches through does not
    /// exist, so we read the size class to (a) skip mounting the
    /// installer there and (b) expose the native SwiftUI wallet-switch
    /// `Menu` on the wallet pill instead (see `WalletHomeView`).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

    /// **Actions button (2026-06-24).** A native Liquid-Glass circular button
    /// floating bottom-trailing over the bar — the 1inch-style action launcher.
    /// It lives here (not as a tab) so the picker can zoom natively out of it:
    /// `matchedTransitionSource` on the button ↔ `navigationTransition(.zoom)`
    /// on the sheet, both in this view sharing one `@Namespace`, driven by local
    /// `@State` (a tab item can't be a zoom source on iOS 26, and the
    /// `@Observable`-driven variant of the zoom is broken — FB21812568).
    @State private var isShowingActions: Bool = false
    /// The tile the user tapped; applied in the picker's `onDismiss` so the
    /// wallet-home flow opens only after the picker has fully dismissed.
    @State private var pendingActionFlow: WalletShellSignal.Flow?
    @Namespace private var actionsZoom
    private let actionsZoomID = "actions"
    /// Drives the sliding active-tab highlight in the custom bar — the single
    /// highlight capsule animates between Wallet/Browser via `matchedGeometryEffect`
    /// (the Liquid-Glass-style left↔right move).
    @Namespace private var tabHighlight

    /// **Custom-bar sizing (single source of truth).** The left pill and the
    /// Actions circle are BOTH framed to `barHeight`, so they can never differ.
    /// `tabWidth` is each Wallet/Browser cell's width. Tune these two numbers.
    private let barHeight: CGFloat = 60
    private let tabWidth: CGFloat = 84

    /// Computed binding that round-trips the persisted raw through
    /// the `MainTab` enum. Unknown rawValues (manual UserDefaults
    /// fiddling, future tab renames) fall back to `.wallet`.
    private var selectedTab: Binding<MainTab> {
        Binding(
            get: {
                // Only Wallet / Browser are real tabs now (Settings → toolbar,
                // Actions → floating glass button). Any other persisted/legacy
                // value resolves to the Wallet tab so the TabView never lands on
                // a missing tab.
                let resolved = MainTab(rawValue: selectedTabRaw) ?? .wallet
                return (resolved == .wallet || resolved == .browser) ? resolved : .wallet
            },
            set: { newValue in
                // Re-tapping the already-selected Wallet tab pops its nav
                // stack back to the home root — the standard iOS tab gesture,
                // which `TabView` does NOT perform automatically for a
                // NavigationStack (2026-06-18 user report). SwiftUI calls
                // this setter with the SAME value on a re-tap, so detect it
                // here and bump the shared token; `WalletHomeView` observes
                // it and clears its path.
                if newValue == (MainTab(rawValue: selectedTabRaw) ?? .wallet),
                   newValue == .wallet {
                    TabReselectSignal.shared.walletReselectToken &+= 1
                }
                selectedTabRaw = newValue.rawValue
            }
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
            // MARK: - Wallet (icon-only — 2026-06-24)
            //
            // Icon-only by direction (2026-06-24: "remove the texts at all").
            // iOS 26's `Tab(value:content:label:)` takes a `label:` closure;
            // rendering ONLY the SF Symbol (no `Text`) makes the native Liquid
            // Glass bar show the glyph alone. The VoiceOver name is preserved via
            // `.accessibilityLabel`. The long-press wallet menu still installs
            // onto the `UITabBar` at index 0 (compact width only).
            Tab(value: MainTab.wallet) {
                WalletHomeView()
                    // Hide the system tab bar — the custom bar (below) replaces it.
                    .toolbar(.hidden, for: .tabBar)
            } label: {
                Image(systemName: "wallet.pass.fill")
                    .accessibilityLabel(Text("Wallet"))
            }

            // MARK: - Browser (icon-only — 2026-06-24)
            //
            // The `safari` glyph, icon-only. On iOS 26 `BrowserHomeView`'s
            // `.searchable` docks the domain search field at the bottom above the
            // bar; this is NOT a `.search`-role tab, so the bar keeps the safari
            // icon and the tabs stay put instead of morphing away.
            Tab(value: MainTab.browser) {
                NavigationStack {
                    BrowserHomeView()
                }
                // Hide the system tab bar — the custom bar (below) replaces it.
                // The browser's `.searchable` lives in the nav bar (top), so the
                // custom bottom bar never hides it.
                .toolbar(.hidden, for: .tabBar)
            } label: {
                Image(systemName: "safari")
                    .accessibilityLabel(Text("Browser"))
            }

            // 2026-06-23 — Settings is no longer a tab (wallet-home toolbar gear).
            // 2026-06-24 — Actions is no longer a tab either; it's in the custom bar.
        }
        // Fire a selection haptic on tab change. Per Rule #10 §A,
        // tab selection IS the canonical `.selection` haptic.
        .uniHaptic(.selection, trigger: selectedTabRaw)
        // **Custom bottom bar (2026-06-24, user direction — bigger, 1inch-style).**
        // The system tab bar is hidden (above) and replaced with a larger
        // Liquid-Glass bar docked via `safeAreaInset` — the only way to control
        // the bar's SIZE, which iOS 26 doesn't expose for the system bar. The
        // `TabView` still owns content, state, and the browser's native search;
        // this is purely the visual control. `safeAreaInset` reserves the space
        // so no content is ever hidden behind the bar.
        .safeAreaInset(edge: .bottom) {
            customBar
        }
        // **Actions picker — zooms out of the button.** Local `@State` trigger +
        // shared `actionsZoom` namespace = the import-passphrase pattern. On
        // dismiss, the chosen flow is handed to the wallet home (see below).
        .sheet(isPresented: $isShowingActions, onDismiss: {
            // The picker has FULLY dismissed — now open the chosen flow on the
            // wallet home (switch to Wallet so it's mounted). Deferring to
            // `onDismiss` preserves the dismiss-then-present ordering across the
            // two views (you can't present one sheet while another dismisses).
            if let flow = pendingActionFlow {
                pendingActionFlow = nil
                selectedTabRaw = MainTab.wallet.rawValue
                WalletShellSignal.shared.requestFlow(flow)
            }
        }) {
            WalletActionsSheet(
                canSend: activeWallet?.kind != .watchOnly,
                onSend: { pendingActionFlow = .send; isShowingActions = false },
                onReceive: { pendingActionFlow = .receive; isShowingActions = false },
                onConnect: { pendingActionFlow = .connect; isShowingActions = false }
            )
            .uniAppEnvironment()
            .uniSheetDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
            // Native iOS 26 zoom — the picker morphs out of the Actions button.
            .navigationTransition(.zoom(sourceID: actionsZoomID, in: actionsZoom))
        }
        // Wallet icon picker — surfaced by the "Customise icon" item
        // in the long-press context menu. Reuses
        // `WalletIconPickerSheet`, the same primitive presented from
        // the wallet-home toolbar pill's existing entry point.
        .sheet(isPresented: $isShowingPicker) {
            if let active = activeWallet {
                WalletIconPickerSheet(walletId: active.id)
                    .uniAppEnvironment()
                    .uniSheetDetents([.large])
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
                .uniSheetDetents([.large])
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

    // MARK: - Custom bottom bar (2026-06-24 — bigger, 1inch-style, native glass)
    //
    // Wallet · Browser sit in a left glass capsule (active tab highlighted); the
    // Actions launcher is a separate glass circle on the right — the 1inch split
    // layout, all native (`.glassEffect`, SF Symbols). The sizes here are
    // deliberately larger than the system bar (that's the whole point — iOS 26
    // won't resize the system bar). Tune the frame sizes / paddings to taste.
    private var customBar: some View {
        HStack(spacing: UniSpacing.s) {
            // Left — Wallet · Browser. The `GlassEffectContainer` lets the active
            // highlight's glass MORPH between tabs natively (Liquid-Glass flow)
            // via `glassEffectID` (see `barButton`).
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    barButton(.wallet, systemImage: "wallet.pass.fill", name: "Wallet")
                    barButton(.browser, systemImage: "safari", name: "Browser")
                }
                .frame(height: barHeight)
                .glassEffect(.regular, in: .capsule)
            }

            Spacer(minLength: 0)

            // Right — the Actions launcher (zoom source), also barHeight tall.
            actionsButton
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.top, UniSpacing.xs)
    }

    /// One tab inside the left glass capsule. The active tab gets a solid
    /// highlight; re-tapping the active Wallet tab pops its stack to root (the
    /// same gesture the system bar gave us).
    private func barButton(_ tab: MainTab, systemImage: String, name: LocalizedStringKey) -> some View {
        let isActive = (MainTab(rawValue: selectedTabRaw) ?? .wallet) == tab
        return Button {
            if tab == .wallet, isActive {
                TabReselectSignal.shared.walletReselectToken &+= 1
            }
            // Animate the selection so the active highlight SLIDES between tabs
            // (the Liquid-Glass left↔right move) instead of snapping.
            withAnimation(.snappy(duration: 0.34)) {
                selectedTabRaw = tab.rawValue
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isActive ? UniColors.Text.primary : UniColors.Icon.secondary)
                // Fill the full bar height + the wider tab width.
                .frame(width: tabWidth, height: barHeight)
                .background {
                    // The active highlight is a GLASS element with a stable
                    // `glassEffectID`. Inside the `GlassEffectContainer` above,
                    // when the active tab changes the glass MORPHS to the new
                    // position — the native iOS 26 Liquid-Glass flow (default
                    // `.matchedGeometry` glass transition), not a rigid slide.
                    if isActive {
                        Capsule(style: .continuous)
                            .fill(Color.clear)
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("activeTab", in: tabHighlight)
                            .padding(6)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
    }

    // MARK: - Actions launcher (the bar's right glass button — zoom source)
    //
    // `matchedTransitionSource(id:in:)` here pairs with the picker sheet's
    // `navigationTransition(.zoom(sourceID:in:))` (above), sharing the
    // `actionsZoom` namespace, so the picker scales out of THIS button.
    private var actionsButton: some View {
        Button {
            isShowingActions = true
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(UniColors.Text.primary)
                // Framed to `barHeight` × `barHeight` — IDENTICAL height to the
                // left pill (both framed to `barHeight`), so they CAN'T differ.
                // The wide two-arrows glyph is set 2pt smaller than the pill icons
                // (20 vs 22) so it doesn't read as visually larger.
                .frame(width: barHeight, height: barHeight)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: actionsZoomID, in: actionsZoom)
        .accessibilityLabel(Text("Actions"))
    }

    // MARK: - Wallet tab label (avatar only — no "Wallet" text)
    //
    // iOS 26's `Tab(value:content:label:)` initializer accepts an
    // arbitrary `label:` closure. The Wallet tab is the only one
    // that ships WITHOUT visible text — the per-wallet avatar IS
    // the identity, and adding "Wallet" underneath would compete
    // with the wallet name shown in the toolbar pill above. The
    // other tabs (Browser, Settings) keep their
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
/// Browser, Settings). RTL layout flips visual order
/// automatically via SwiftUI — the enum declaration order does
/// not change.
enum MainTab: String, Hashable, CaseIterable {
    case wallet
    case browser
    case settings
    /// Not a destination — the bar item that opens the Actions sheet
    /// (2026-06-23). The selection binding intercepts it and never lands on
    /// it; `WalletHomeView` presents the sheet in reaction.
    case actions

    /// The `@AppStorage` / `UserDefaults` key the selected tab persists
    /// under. Single source of truth shared by `MainTabView`,
    /// `WalletHomeView`'s long-press deep link, and
    /// `ScreenRestoration.resolveOnLaunch()` (which resets the value to
    /// `.wallet` when the user has been away ≥ 2 minutes).
    static let storageKey = "selectedTab"
}
