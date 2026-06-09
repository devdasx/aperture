import SwiftUI
import SwiftData

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
/// `Label("Wallet", systemImage: "wallet.pass.fill")`. Long-press on
/// the Wallet tab opens a native iOS 26 `contextMenu` listing every
/// persisted wallet with a checkmark on the active one — tapping a
/// non-active wallet flips `@AppStorage("activeWalletId")` to that
/// wallet's UUID, and the existing reactive `@Query` machinery in
/// `WalletHomeView` (plus the tab icon itself) re-renders with the
/// new active wallet instantly. Same UX as Telegram's
/// account-switcher (long-press the avatar tab) and Instagram's
/// account-switcher (long-press the profile tab).
///
/// **Why long-press, not tap-and-hold-then-menu-button.** iOS 26's
/// `contextMenu(menuItems:)` modifier on a `Tab` is the native idiom
/// — the system applies the standard 0.5s long-press recognition,
/// the standard preview lift, and the standard glass menu surface.
/// We never reach for a custom `LongPressGesture`. Tapping the tab
/// still navigates to the wallet (system default behavior); the
/// long-press is a non-destructive shortcut.
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
    /// they last had open. Default `.wallet`.
    @AppStorage("selectedTab") private var selectedTabRaw: String = MainTab.wallet.rawValue

    /// The active wallet's UUID string. Drives the Wallet tab's
    /// avatar AND the wallet-home `WalletHomeView`. The two surfaces
    /// share the same source so switching wallets via long-press
    /// updates both atomically.
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    /// Every persisted wallet, sorted by user-chosen display order.
    /// Drives the long-press `contextMenu` switcher. `@Query`
    /// reactivity means adding / deleting / renaming / re-skinning
    /// a wallet from any surface (Settings → Wallets, the
    /// wallet-detail sheet, the customisation sheet) shows up in
    /// the switcher live without any per-surface refresh logic.
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]

    /// Customisation sheet trigger — invoked from the long-press
    /// menu's "Customise" item. Hoisted to the tab view so the
    /// sheet survives tab changes; dismissed by the user, never by
    /// us.
    @State private var customiseTargetId: UUID?

    /// "Add wallet" sheet — opens the existing create flow.
    @State private var isShowingCreate: Bool = false
    @State private var createPath: NavigationPath = .init()

    /// "Manage wallets" jump — selects the Settings tab and
    /// programmatically pushes onto its NavigationStack via a
    /// shared `@AppStorage("settingsDeepLink")` token that
    /// `SettingsView` reads on appear. The simplest non-coupling
    /// implementation; surfaces a deep-link surface we'll reuse
    /// for future menu entries.
    @AppStorage("settingsDeepLink") private var settingsDeepLink: String = ""

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
            // MARK: - Wallet (custom avatar label + long-press switcher)
            //
            // The Wallet tab's `label:` closure renders the active
            // wallet's `WalletAvatar` instead of a generic SF Symbol.
            // The text "Wallet" stays — iOS tab bars show both glyph
            // and text by default. The avatar replaces the glyph
            // role; the text role is unchanged.
            //
            // `.contextMenu` on the Tab surfaces the long-press
            // wallet switcher. Each menu row is the wallet's name
            // prefixed with its `WalletAvatar` glyph (via a
            // `Button`'s `Label` slot — iOS renders the avatar in
            // the menu's icon column). The active wallet's row
            // shows a check via `Image(systemName: "checkmark")` in
            // a row immediately below — iOS 26 menus support the
            // standard "selected" hint that way.
            //
            // The `value: MainTab.wallet` parameter ties the tab
            // to the selection binding above; tapping it sets
            // `selectedTab = .wallet`. Long-press surfaces the
            // menu without changing the selection — the user's
            // current tab is preserved.
            Tab(value: MainTab.wallet) {
                WalletHomeView()
            } label: {
                walletTabLabel
            }
            .contextMenu {
                walletContextMenu
            }

            // MARK: - Swap
            Tab("Swap", systemImage: "arrow.left.arrow.right", value: MainTab.swap) {
                NavigationStack {
                    SwapPlaceholderView()
                }
            }

            // MARK: - Browser
            Tab("Browser", systemImage: "globe", value: MainTab.browser) {
                NavigationStack {
                    BrowserPlaceholderView()
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
        // Customisation sheet — Rule #15: NavigationStack + nav
        // title + Done button. The sheet's content reads the same
        // `@Query` for the wallet so it sees live edits.
        .sheet(item: customiseTargetBinding) { target in
            WalletIconPickerSheet(walletId: target.walletId)
                .uniAppEnvironment()
                .presentationDetents([.large])
                .presentationBackground(UniColors.Background.primary)
        }
        // "Add wallet" — the existing create flow, presented from
        // the long-press menu. Reuses `RecoveryPhraseFlow` so the
        // create UX is identical to the Settings / onboarding path.
        .fullScreenCover(isPresented: $isShowingCreate, onDismiss: { createPath = .init() }) {
            RecoveryPhraseFlow(
                navigationPath: $createPath,
                onDismiss: { isShowingCreate = false },
                onUserSkippedBackup: {},
                onUserCompletedBackup: {}
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Wallet tab label (the avatar replaces the glyph)
    //
    // iOS 26's `Tab(value:content:label:)` initializer accepts an
    // arbitrary `label:` closure — it does NOT require
    // `Label(_:systemImage:)`. We hand it a `Label` whose `icon`
    // slot is our `WalletAvatar` view; iOS will use the icon as the
    // tab glyph (auto-sized into the tab bar's glyph envelope) and
    // the title as the tab text below.
    @ViewBuilder
    private var walletTabLabel: some View {
        Label {
            Text("Wallet")
        } icon: {
            WalletAvatar(
                symbol: activeWallet?.iconSymbol ?? WalletAvatarDefaults.symbol,
                colorHex: activeWallet?.iconColorHex ?? WalletAvatarDefaults.colorHex,
                size: .tabIcon
            )
        }
    }

    // MARK: - Long-press context menu
    //
    // Apple's pattern for this kind of switcher (Mail's account
    // switcher, the Telegram / Instagram pattern the user named):
    // a single `.contextMenu { … }` containing one `Button` per
    // entity to switch to, followed by `Divider()`s separating
    // the cross-cutting actions ("Add", "Manage"). iOS renders
    // each `Button`'s `Label` with the icon view we hand it; we
    // hand `Label`'s icon slot our `WalletAvatar` at `.menuLeading`
    // size.
    //
    // The Button's `role:` parameter is `.none` for switch
    // actions (semantic-neutral) and `.destructive` would only
    // apply to a "Delete" — we don't ship a delete from the
    // tab menu (delete lives in Settings → Wallets → <wallet>).
    @ViewBuilder
    private var walletContextMenu: some View {
        // One row per persisted wallet. The active one carries a
        // checkmark via the system's selection-indicator slot
        // (iOS menus render `.selected` traits with a system
        // check).
        ForEach(allWallets) { wallet in
            Button {
                // Set the active wallet. WalletHomeView's
                // @AppStorage("activeWalletId") observation
                // re-renders. The tab icon itself also reads
                // `activeWalletIdRaw` and re-renders.
                activeWalletIdRaw = wallet.id.uuidString
            } label: {
                Label {
                    HStack {
                        Text(verbatim: wallet.name)
                        if wallet.id.uuidString == activeWalletIdRaw {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                } icon: {
                    WalletAvatar(
                        symbol: wallet.iconSymbol.isEmpty ? WalletAvatarDefaults.symbol : wallet.iconSymbol,
                        colorHex: wallet.iconColorHex.isEmpty ? WalletAvatarDefaults.colorHex : wallet.iconColorHex,
                        size: .menuLeading
                    )
                }
            }
        }

        Divider()

        // Customise — opens the icon picker sheet against the
        // active wallet. Only surfaces when there IS an active
        // wallet (i.e. allWallets is non-empty).
        if let active = activeWallet {
            Button {
                customiseTargetId = active.id
            } label: {
                Label("Customise wallet", systemImage: "paintpalette")
            }
        }

        // Add wallet — presents the existing create flow.
        Button {
            isShowingCreate = true
        } label: {
            Label("Add wallet", systemImage: "plus")
        }

        // Manage wallets — flips the tab to Settings and stamps
        // the deep-link token. `SettingsView` reads the token on
        // appear and pushes onto its NavigationPath.
        Button {
            settingsDeepLink = "wallets"
            selectedTabRaw = MainTab.settings.rawValue
        } label: {
            Label("Manage wallets", systemImage: "list.bullet")
        }
    }

    // MARK: - Sheet item binding (Identifiable shim)
    //
    // `.sheet(item:)` needs an Identifiable binding. Our state is
    // a plain `UUID?` so we wrap it in a tiny Identifiable shim.
    private var customiseTargetBinding: Binding<WalletAvatarCustomiseTarget?> {
        Binding(
            get: { customiseTargetId.map { WalletAvatarCustomiseTarget(walletId: $0) } },
            set: { customiseTargetId = $0?.walletId }
        )
    }
}

/// Identifiable shim so `.sheet(item:)` can present the icon picker
/// from the optional `customiseTargetId`. Stays private to this file
/// because no other surface presents the picker by way of a sheet
/// item — `WalletDetailView` uses `@State Bool` because it presents
/// only against its own wallet.
private struct WalletAvatarCustomiseTarget: Identifiable {
    let walletId: UUID
    var id: UUID { walletId }
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
}
