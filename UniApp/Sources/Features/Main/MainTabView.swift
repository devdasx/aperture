import SwiftUI
import UIKit
import TipKit

/// The post-onboarding shell for Aperture. Hosts the top-level surfaces the
/// user navigates between — Wallet, Activity, Markets, and Settings — via the native
/// iOS 26 `TabView` + `Tab(...)` API.
///
/// **Design intent (one sentence, Rule #2 §D.1):** give the user one
/// always-visible, thumb-reachable map of where they are in Aperture
/// — so the wallet and the settings live at the same depth and feel
/// like faces of the same calm surface, never one buried inside another.
///
/// **2026-06-29 — icon-only native tabs.** The compact tab bar uses SF
/// Symbols only — no custom-drawn icons, no filled wallet/settings icons,
/// and no visible tab titles. The wallet identity + switcher live on the
/// wallet-home toolbar pill instead of the tab bar.
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
/// **Selection persistence (`@GRDBStorage("selectedTab")`).** The
/// selected tab is persisted across launches.
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
    @GRDBStorage(MainTab.storageKey) private var selectedTabRaw: String = MainTab.wallet.rawValue

    /// The active wallet's UUID string. Drives the Wallet tab's
    /// avatar AND the wallet-home `WalletHomeView`. The two surfaces
    /// share the same source so switching wallets via long-press
    /// updates both atomically.
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    @StateObject private var walletList = WalletListObservation()

    /// iPad adaptation: compact width uses the shipping iPhone
    /// `TabView`; regular width uses one root `NavigationSplitView`
    /// with the sidebar pinned open. The split view owns the sidebar
    /// so the detail column is resized across Wallet, Activity,
    /// Markets, and Settings instead of overlaying sidebar chrome.
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

    /// Computed binding that round-trips the persisted raw through
    /// the `MainTab` enum. Unknown rawValues (manual GRDB edits or
    /// fiddling, future tab renames) fall back to `.wallet`.
    private var selectedTab: Binding<MainTab> {
        Binding(
            get: {
                MainTab(rawValue: selectedTabRaw) ?? .wallet
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

    /// The active wallet's record — looked up by the persisted wallet ID.
    /// An explicit stale ID returns nil instead of falling back to another
    /// wallet, so the tab bar never shows the previous wallet's avatar while
    /// a switch/create/import is settling.
    private var allWallets: [WalletListRowDTO] {
        walletList.wallets
    }

    private var activeWallet: WalletListRowDTO? {
        walletList.activeWallet(rawID: activeWalletIdRaw)
    }

    private var currentTab: MainTab {
        MainTab(rawValue: selectedTabRaw) ?? .wallet
    }

    private var sidebarSelection: Binding<MainTab?> {
        Binding(
            get: { currentTab },
            set: { newValue in
                guard let newValue else { return }
                selectedTab.wrappedValue = newValue
            }
        )
    }

    var body: some View {
        shellBody
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

    @ViewBuilder
    private var shellBody: some View {
        if horizontalSizeClass == .regular {
            iPadSplitBody
        } else {
            compactTabBody
        }
    }

    @ViewBuilder
    private var compactTabBody: some View {
        TabView(selection: selectedTab) {
            // MARK: - Wallet (icon-only native tab — 2026-06-29)
            //
            // The wallet avatar moved OFF the bar (user direction): the Wallet
            // tab is an outline SF Symbol only. The wallet identity +
            // switcher live on the wallet-home pill. The long-press wallet
            // menu still installs onto the `UITabBar` at index 0
            // (compact width only).
            Tab(value: MainTab.wallet) {
                WalletHomeView()
                    .background(alignment: .bottom) {
                        if horizontalSizeClass == .compact {
                            TabBarLongPressInstaller(tabIndex: 0) {
                                buildWalletTabMenu()
                            }
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                        }
                    }
            } label: {
                tabLabel(.wallet)
            }

            Tab(value: MainTab.activity) {
                NavigationStack {
                    WalletActivityView()
                        .navigationDestination(for: WalletHomeDestination.self) { destination in
                            walletDestination(destination)
                        }
                }
            } label: {
                tabLabel(.activity)
            }

            Tab(value: MainTab.markets) {
                NavigationStack {
                    MarketsView()
                }
            } label: {
                tabLabel(.markets)
            }

            Tab(value: MainTab.settings) {
                SettingsView()
            } label: {
                tabLabel(.settings)
            }
        }
    }

    @ViewBuilder
    private var iPadSplitBody: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: sidebarSelection) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    MainSidebarRow(tab: tab)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationTitle(Text("Aperture"))
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            selectedTabContent
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
    }

    private var selectedTabContent: some View {
        Group {
            switch currentTab {
            case .wallet:
                WalletHomeView()
            case .activity:
                NavigationStack {
                    WalletActivityView()
                        .navigationDestination(for: WalletHomeDestination.self) { destination in
                            walletDestination(destination)
                        }
                }
            case .markets:
                NavigationStack {
                    MarketsView()
                }
            case .settings:
                SettingsView(allowsSplitLayout: false)
            }
        }
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: - Compact tab label

    private func tabLabel(_ tab: MainTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(systemName: tab.systemImage)
                .symbolVariant(.none)
                .symbolRenderingMode(.monochrome)
                .imageScale(.large)
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(Text(tab.title))
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
    // live GRDB observation snapshot. A wallet renamed in Settings shows up
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
                    ActiveWalletPointer.set(wallet.id)
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
    private func renderWalletAvatarMenuImage(for wallet: WalletListRowDTO) -> UIImage {
        let renderer = ImageRenderer(
            content: WalletAvatar(spec: wallet.avatarSpec, size: .row)
                .frame(width: 96, height: 96)
        )
        renderer.scale = UITraitCollection.current.displayScale
        let image = renderer.uiImage ?? UIImage()
        return image.withRenderingMode(.alwaysOriginal)
    }

    @ViewBuilder
    private func walletDestination(_ destination: WalletHomeDestination) -> some View {
        switch destination {
        case .transaction(let id):                  TransactionDetailView(transactionId: id)
        case .allSupported:                         AllSupportedAssetsView()
        case .assetDetail(let identity):            AssetDetailView(identity: identity)
        case .assetNetworkDetail(let identity, let chainRaw):
            if let chain = SupportedChain(rawValue: chainRaw) {
                AssetNetworkDetailView(identity: identity, chain: chain)
            } else {
                AssetDetailView(identity: identity)
            }
        case .assetActivity(let identity):          AssetActivityView(identity: identity)
        case .allActivity:                          WalletActivityView()
        }
    }
}

// MARK: - MainTab

/// Stable, persistable identity for each top-level destination in
/// the post-onboarding shell. RawValue is the persistence key
/// stored in `@GRDBStorage("selectedTab")`. RawValues are stable
/// forever — renaming a tab in the future never changes the
/// persistence key.
///
/// Order in the enum mirrors visual order in the tab bar. RTL layout
/// flips visual order automatically via SwiftUI — the enum declaration
/// order does not change.
enum MainTab: String, Hashable, CaseIterable {
    case wallet
    case activity
    case markets
    case settings

    /// The `@GRDBStorage` key the selected tab persists
    /// under. Single source of truth shared by `MainTabView`,
    /// `WalletHomeView`'s long-press deep link, and
    /// `ScreenRestoration.resolveOnLaunch()` (which resets the value to
    /// `.wallet` when the user has been away ≥ 2 minutes).
    static let storageKey = "selectedTab"

    var title: LocalizedStringKey {
        switch self {
        case .wallet:   return "Wallet"
        case .activity: return "Activity"
        case .markets:  return "Markets"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .wallet:   return "wallet.bifold"
        case .activity: return "clock.arrow.circlepath"
        case .markets:  return "chart.line.uptrend.xyaxis"
        case .settings: return "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .wallet:   return .blue
        case .activity: return .orange
        case .markets:  return .green
        case .settings: return .gray
        }
    }
}

private struct MainSidebarRow: View {
    let tab: MainTab

    var body: some View {
        Label {
            Text(tab.title)
        } icon: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tab.tint)
                .frame(width: 29, height: 29)
                .overlay {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.72)
                        .padding(4)
                }
        }
    }
}
