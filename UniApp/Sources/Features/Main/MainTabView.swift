import SwiftUI

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
/// **Why a TabView, not a sheet-per-section.** Through 2026-06-08 the
/// post-onboarding shell was a single `NavigationStack` rooted at
/// `WalletHomeView`, with Settings reached via a `.sheet(...)` from
/// the wallet-home toolbar's gear icon. That shape made Wallet feel
/// like THE app and Settings like an aside — even though Settings is
/// the user's home for Security, Wallets, Currency, Language. The
/// iOS-canonical resolution is to give each top-level section its own
/// tab, equal depth, equal reachability. The 2026-06-09 user
/// direction names this directly: *"add navigation bar now, it
/// should contain this 'Wallet, Swap, Browser, and Settings' and
/// remove settings screen from the app bar as well."*
///
/// **Liquid Glass (Rule #2 §B + Rule #3).** The bar IS the iOS 26
/// Liquid Glass tab bar. We don't paint it — we compose it. The
/// translucency + specular + motion-responsiveness contract (Rule #2
/// §B.1) is delivered by the system when feature code uses the native
/// `TabView { Tab { … } label: { … } }` shape with no manual chrome.
/// Hand-rolling a custom bar would forfeit all three properties (the
/// M-002 / M-003 / M-008 family of mistakes) plus the auto-adapting
/// scroll-edge effect, plus the auto-mirroring under RTL, plus the
/// auto-handling of Dynamic Type / Reduce Motion / Increase Contrast.
///
/// **Selection persistence (`@AppStorage("selectedTab")`).** A user
/// who leaves the app on the Swap tab returns to the Swap tab. iOS
/// Settings does the same. No flag-gating; the calm, expected
/// behavior. The persisted raw is `MainTab.RawValue` (a stable
/// String); migrating tabs in the future is a non-event because
/// unknown rawValues fall back to `.wallet`.
///
/// **RTL (Rule #11).** Native TabView automatically mirrors tab
/// order under RTL — Settings becomes the leading tab in Arabic /
/// Hebrew / Persian / Urdu — and the SF Symbols (`arrow.left.arrow.right`
/// notably) auto-flip when directional. We do not, and must not,
/// reorder the tabs manually based on layout direction (double-flip
/// is the M-class anti-pattern Rule #11 §C names).
///
/// **Accessibility (Rule #2 §B.2).** Each `Tab(...)` initializer with
/// a localizable title + `systemImage:` carries VoiceOver labels,
/// large-content viewer support, Dynamic Type at the tab label, and
/// the "Tab 1 of 4 — Wallet" rotor metadata for free. We do not need
/// `.accessibilityLabel` overrides on tabs.
struct MainTabView: View {
    /// Persisted across launches so the user lands on whichever tab
    /// they last had open. Default `.wallet` because that's the
    /// first impression we want a returning user to have — their
    /// balance — and it's the de-facto home of the app.
    @AppStorage("selectedTab") private var selectedTabRaw: String = MainTab.wallet.rawValue

    /// Computed binding that round-trips the persisted raw through
    /// the `MainTab` enum. Unknown rawValues (manual UserDefaults
    /// fiddling, future tab renames) fall back to `.wallet` so the
    /// app never lands on a non-existent selection.
    private var selectedTab: Binding<MainTab> {
        Binding(
            get: { MainTab(rawValue: selectedTabRaw) ?? .wallet },
            set: { selectedTabRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabView(selection: selectedTab) {
            // Wallet — primary destination. Lands a returning user
            // on their balance + holdings + recent activity. The
            // wallet-pill identity affordance lives inside this
            // tab's own NavigationStack (in WalletHomeView's
            // `.principal` toolbar slot) — the tab bar identifies
            // which APP SECTION you're in; the wallet pill
            // identifies which WALLET you're in. Different facets.
            Tab("Wallet", systemImage: "wallet.pass.fill", value: MainTab.wallet) {
                WalletHomeView()
            }

            // Swap — on-chain DEX-aggregator swap. Placeholder for
            // now; the real screen replaces this exact `Tab`
            // content with the swap-flow root when it lands. Tab
            // wiring stays unchanged.
            Tab("Swap", systemImage: "arrow.left.arrow.right", value: MainTab.swap) {
                // `SwapPlaceholderView` already wraps itself in a
                // `.navigationTitle` (`Swap`, inline) — so for the
                // tab-rooted nav stack we wrap it in a
                // `NavigationStack` so the title chrome attaches
                // correctly. (Previously this view was pushed onto
                // the wallet-home's stack; as a tab root it owns
                // its own stack.)
                NavigationStack {
                    SwapPlaceholderView()
                }
            }

            // Browser — in-wallet dApp browser. Placeholder for
            // now per Rule #16 §E (no false security claims while
            // the surface is honest about not-yet-built).
            Tab("Browser", systemImage: "globe", value: MainTab.browser) {
                NavigationStack {
                    BrowserPlaceholderView()
                }
            }

            // Settings — the user's home for Security, Wallets,
            // Currency, Language, Privacy, About. Was a `.sheet`
            // from the wallet-home toolbar through 2026-06-08;
            // promoted to a top-level tab 2026-06-09 per direct
            // user direction. SettingsView now owns its own
            // `@State NavigationPath` (it no longer accepts a
            // parent `@Binding` because there's no parent sheet
            // to thread the rebuild-preservation through anymore
            // — Rule #12 §G's direction-flip rebuild was a
            // sheet-host concern; a tab root rebuilds normally
            // via SwiftUI's environment propagation).
            Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
                SettingsView()
            }
        }
        // Fire a selection haptic on tab change. Per Rule #10 §A,
        // tab selection IS the canonical `.selection` haptic — it
        // matches the iOS-system feel a user already has muscle
        // memory for from every other iOS app. The haptic respects
        // the user's `hapticFeedbackEnabled` preference through
        // `UniHaptic`'s view-modifier (no-op when disabled).
        .uniHaptic(.selection, trigger: selectedTabRaw)
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
