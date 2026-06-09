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
    /// they last had open. Default `.wallet`.
    @AppStorage("selectedTab") private var selectedTabRaw: String = MainTab.wallet.rawValue

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

    /// Long-press on the Wallet tab's `UITabBarButton` flips this
    /// flag (via the UIKit-bridge installer below); the `.sheet`
    /// presents `WalletSwitcherSheet` over the whole tab shell.
    /// `.contextMenu` on SwiftUI's iOS 26 `Tab` doesn't reach the
    /// rendered UITabBar button — `M-016` audits the prior dead
    /// approaches; `TabBarLongPressInstaller` is the working one.
    @State private var isShowingWalletSwitcher: Bool = false
    @State private var isShowingCreate: Bool = false
    @State private var createPath: NavigationPath = NavigationPath()

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
                    // walks up to the window, finds the UITabBar,
                    // and attaches a UILongPressGestureRecognizer
                    // to the wallet tab's UITabBarButton. The
                    // recognizer's `.began` closure flips
                    // `isShowingWalletSwitcher`, which surfaces
                    // the SwiftUI sheet. Idempotent — see the
                    // installer's coordinator for the weak-ref
                    // de-dup logic.
                    .background(alignment: .bottom) {
                        TabBarLongPressInstaller(tabIndex: 0) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            isShowingWalletSwitcher = true
                        }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                    }
            } label: {
                walletTabLabel
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
        // Wallet switcher sheet — surfaced by the long-press
        // recognizer installed via `TabBarLongPressInstaller`
        // above. Reuses the existing `WalletSwitcherSheet`
        // primitive that the wallet-home toolbar pill also
        // presents (single canonical switcher UI, two entry
        // points).
        .sheet(isPresented: $isShowingWalletSwitcher) {
            WalletSwitcherSheet(
                onSelect: { isShowingWalletSwitcher = false },
                onCreateNew: {
                    isShowingWalletSwitcher = false
                    isShowingCreate = true
                },
                onImport: {
                    // No import flow plumbed here yet — defer to
                    // Settings → Wallets where the import flow
                    // already lives. Dismiss the switcher first
                    // so the next session lands cleanly.
                    isShowingWalletSwitcher = false
                    selectedTabRaw = MainTab.settings.rawValue
                }
            )
            .uniAppEnvironment()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
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
