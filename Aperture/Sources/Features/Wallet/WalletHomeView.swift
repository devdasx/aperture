import SwiftUI
import UIKit
import GRDB

// MARK: - RootGate

/// App-launch routing gate. Reads the wallet count reactively via
/// GRDB; routes to `MainTabView` (the post-onboarding shell) if
/// the user has at least one wallet,
/// otherwise to `OnboardingView`. When the create/import flows
/// insert a wallet row, the gate flips automatically — no
/// explicit navigation needed from those flows.
///
/// **2026-06-09 — `MainTabView` replaces `WalletHomeView` as the
/// wallets-exist branch.** Through 2026-06-08 this branch was
/// `WalletHomeView()` directly; Settings was reached via a `.sheet`
/// from the wallet-home toolbar's gear. Per direct user direction
/// the shell is now a native iOS 26 `TabView`. `WalletHomeView` is
/// still the root of the Wallet tab; the Settings sheet is
/// retired.
///
/// **Splash → onboarding shared element (2026-06-07).** `AppRoot`
/// (in `ApertureApp.swift`) wraps the gate so it can thread the
/// `@Namespace logoNamespace` + `AppPhase` machine into onboarding —
/// onboarding consumes both to attach `matchedGeometryEffect` to its
/// welcome-slide logo and to drive the staggered chrome fade-in.
/// The wallets-exist branch ignores both: the shared-element
/// transition only applies to first-launch onboarding, not to
/// returning users.
struct RootGate: View {
    let logoNamespace: Namespace.ID
    let phase: AppPhase

    @StateObject private var walletList = WalletListObservation()

    /// Keeps onboarding mounted while a create/import flow's full-screen
    /// cover is up — so `WalletReadyView`, which persists the wallet on
    /// appear and thus flips `wallets` non-empty, isn't torn down by this
    /// gate before the flow dismisses itself (2026-06-20 fix).
    /// Session-only `@State`: a force-quit mid-flow resets it, so it can
    /// never strand a real wallet on the onboarding slides.
    @State private var onboardingFlowActive = false

    var body: some View {
        if walletList.wallets.isEmpty || onboardingFlowActive {
            OnboardingView(
                logoNamespace: logoNamespace,
                phase: phase,
                flowActive: $onboardingFlowActive
            )
        } else {
            MainTabView()
        }
    }
}

// MARK: - WalletHomeView

/// The main screen — the destination after onboarding's create or
/// import flow succeeds, and the cold-launch destination for any
/// user with at least one wallet persisted.
///
/// **Design intent (one sentence, Rule #2 §D.1):** show the user the
/// calm, undeniable truth of what they own — total in their fiat
/// first, holdings second, recent activity third — with the active
/// wallet's identity always visible and the boundary statement
/// always present.
///
/// **Layers (Rule #2 §B.3):** lab-promoted solid identity hero (paged
/// balance + Receive/Send/Scan/Hide) scrolls as one unit with an opaque
/// primary body (holdings / activity). No legacy GroupBox balance card.
///
/// **Empty / partial states (Rule #2 §A.2 — designed not deferred):**
/// - No balances yet (fresh wallet, scanner hasn't filled) → calm
///   "Add funds to see balance" surface in the holdings section.
/// - No transactions → unified `UniEmptyState` (same family as empty holdings).
/// - Price unavailable per row → `Text.tertiary` "Price unavailable"
///   (never fake `$—`).
/// - Backup required → top banner (`BackupRequiredBanner`).
/// - Biometric drift detected → top banner
///   (`BiometricReenrollmentBanner`).
struct WalletHomeView: View {
    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @StateObject private var metadataObservation = AppMetadataObservation()
    @StateObject private var assetCatalogObservation = AssetCatalogObservation()
    @StateObject private var activeBalancesObservation = ActiveWalletBalancesObservation()
    @StateObject private var activeTransactionsObservation = ActiveWalletTransactionsObservation()
    @StateObject private var cachedPricesObservation = CachedPricesObservation()

    private var allWallets: [WalletRecord] { walletRecordsObservation.wallets }

    private var metadataRows: [AppMetadataRecord] { metadataObservation.metadataRows }
    // Cached prices stay here only for the recent-activity preview. The balance
    // card no longer subscribes to price rows now that charts are removed from
    // the home screen.
    /// **Local-first asset universe (Rule #27 §D).** The supported
    /// chains + tokens, read from the DB (seeded by `AssetCatalogSeeder`
    /// from the static registries). `catalogChains` / `catalogAssets`
    /// map these to the registry-agnostic shape the display builders
    /// consume, falling back to the identical static `AssetCatalog`
    /// during the pre-seed cold-launch window so the list never blanks.
    private var chainRecords: [ChainRecord] { assetCatalogObservation.chainRecords }
    private var assetRecords: [AssetRecord] { assetCatalogObservation.assetRecords }
    /// User-added custom tokens (2026-06-19). Merged into the home's
    /// token holdings so a token the user pasted into "Add custom token"
    /// shows in the Tokens section with its (scanned) balance — or a 0
    /// placeholder — exactly like the catalog tokens, not only in the asset picker.
    private var customTokenRecords: [CustomTokenRecord] { assetCatalogObservation.customTokenRecords }

    // **Per-chain aggregate rows (2026-06-17).** The `chainStateRecords`
    // GRDB observation that drives the hero total now lives in the
    // `BalanceCardLiveSection` leaf (2026-06-18 native perf fix), NOT here.
    // The refresh coordinator rebuilds a chain's `ChainStateRecord` on a
    // ~300ms cadence during every scan; a top-level GRDB observation here made each
    // of those commits re-evaluate this entire 2,790-line body (Apple's
    // documented GRDB observation/DynamicProperty invalidation — a declared query
    // invalidates the owning view's body on ANY result change, read or not).
    // Moving the query into the small leaf that actually renders the total
    // localizes that 300ms invalidation to the card alone — the parent body
    // no longer re-evaluates on balance commits. A local reconciliation task
    // rebuilds those rows from persisted TokenBalanceRecord rows, so the card
    // stays database-backed without summing live rows in this parent.
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @GRDBStorage(WalletFirstRefreshPresentationCenter.walletIdKey) private var firstRefreshPresentationWalletIdRaw: String = ""
    @GRDBStorage(WalletFirstRefreshPresentationCenter.startedAtKey) private var firstRefreshPresentationStartedAt: Double = 0
    @GRDBStorage(WalletFirstRefreshPresentationCenter.completionDismissedAtKey) private var firstRefreshPresentationDismissedAt: Double = 0
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @GRDBStorage(HideBalancesPreference.thresholdKey) private var hideSmallThreshold: Double = HideBalancesPreference.defaultThreshold

    /// **iPad / Mac adaptation (2026-06-16).** Two regular-width-only
    /// changes hang off this: (1) the content column is capped to a
    /// centered 640pt so the hero + rows read as a column, not a
    /// stretched iPhone; (2) the native SwiftUI wallet-switch `Menu`
    /// is exposed on the wallet pill (at compact width the iPhone
    /// bottom-tab-bar long-press installer owns that gesture instead —
    /// the UITabBar it reaches through only exists at compact width).
    /// At `.compact` BOTH are inert, so the iPhone experience is
    /// byte-for-byte unchanged.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.balancePrivacyEnabled) private var hideBalances
    @Environment(\.colorScheme) private var colorScheme
    /// Cloud / Midnight / Dark (system resolves light→Cloud, dark→Midnight).
    @Environment(\.apertureAppearance) private var apertureAppearance

    /// One-shot-per-session guard for the iCloud backup-index reconcile
    /// (2026-06-20). Heals the query-free restore index for any wallet backed
    /// up before that index existed, so Restore from iCloud lists it with no
    /// CloudKit Console step. See the `.task` below.
    @State private var didHealBackupIndex = false

    // MARK: - Filter & Sort preferences (Rule #14-class declarative reads)
    //
    // The wallet home reads every Filter & Sort preference reactively
    // via `@GRDBStorage`. The filter sheet (`WalletHomeFilterSheet`)
    // writes through the same keys; SwiftUI's environment propagation
    // pushes new values into this view's body within the next
    // evaluation. No imperative "apply" call needed — every value is
    // a published source.
    //
    // **Why declare them here at all** when `WalletHomeFilterApply.Inputs.current()`
    // could read them on the fly? Because `@GRDBStorage` participates in
    // SwiftUI's invalidation graph; reading the keys outside the
    // graph (via a one-shot direct preference read)
    // does NOT cause the view to recompute when the keys change. The
    // sheet's writes would land in GRDB but the home would
    // keep rendering the stale layout until the next unrelated body
    // evaluation. Declaring them as `@GRDBStorage` here closes the loop.
    @GRDBStorage(WalletHomeFilterPreferences.viewModeKey)
    private var filterViewModeRaw: String = WalletHomeFilterPreferences.defaultViewMode.rawValue
    @GRDBStorage(WalletHomeFilterPreferences.sortKeyKey)
    private var filterSortKeyRaw: String = WalletHomeFilterPreferences.defaultSortKey.rawValue
    @GRDBStorage(WalletHomeFilterPreferences.sortDirectionKey)
    private var filterSortDirectionRaw: String = WalletHomeFilterPreferences.defaultSortDirection.rawValue
    @GRDBStorage(WalletHomeFilterPreferences.onlyWithBalanceKey)
    private var filterOnlyWithBalance: Bool = WalletHomeFilterPreferences.defaultOnlyWithBalance
    @GRDBStorage(WalletHomeFilterPreferences.hiddenAssetsKey)
    private var filterHiddenAssetsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    @GRDBStorage(WalletHomeFilterPreferences.hiddenChainsKey)
    private var filterHiddenChainsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    // v2 filter preferences (2026-06-09)
    @GRDBStorage(WalletHomeFilterPreferences.assetTypeKey)
    private var filterAssetTypeRaw: String = WalletHomeFilterPreferences.defaultAssetType.rawValue
    @GRDBStorage(WalletHomeFilterPreferences.groupByKey)
    private var filterGroupByRaw: String = WalletHomeFilterPreferences.defaultGroupBy.rawValue
    @GRDBStorage(WalletHomeFilterPreferences.minFiatThresholdKey)
    private var filterMinFiatThreshold: Double = WalletHomeFilterPreferences.defaultMinFiatThreshold
    @GRDBStorage(WalletHomeFilterPreferences.selectedNetworksKey)
    private var filterSelectedNetworksJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    @GRDBStorage(WalletHomeFilterPreferences.pinnedAssetsKey)
    private var filterPinnedAssetsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    /// Transient search query — per the v2 prompt, NOT a persisted
    /// preference. The user types per session; clearing the search
    /// field resets to no-filter. Threaded into `filterInputs` and
    /// into the filter sheet's preview message via the sheet's
    /// `searchPreview` parameter.
    @State private var filterSearchText: String = ""
    /// Language code drives the Rule #12 §G direction-only rebuild key.
    /// The key flips only on LTR↔RTL transitions; everyday theme +
    /// same-direction language changes propagate via SwiftUI's
    /// environment without rebuilding the sheet content, preserving
    /// the user's nav-stack position inside Settings.
    @GRDBStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    // The auto-lock surface (`AppLockView`) is presented by
    // `AppRoot` at the window root — not from this view. See
    // `ApertureApp.swift` for the gating logic and the privacy
    // mask that bridges the foreground reveal.

    /// Rule #12 §G direction-only key for sheet content rebuild.
    /// `"ltr"` or `"rtl"`. Identical pattern to `OnboardingView`.
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    @State private var isShowingSwitcher: Bool = false
    /// Hero page — kept in sync with the active wallet; swiping writes
    /// `ActiveWalletPointer` so holdings/activity follow the page.
    @State private var selectedPageWalletId: UUID?
    /// Fractional hero page index for app-bar colour blend (settled only).
    @State private var pageSwipeProgress: CGFloat = 0
    /// True while we are applying a pager-driven active-wallet write so the
    /// `activeWalletIdRaw` handler does not fight the pager selection.
    @State private var isApplyingPagerActiveWallet: Bool = false
    /// Vertical scroll offset (negative while pulling) — drives app-bar fade.
    @State private var homeScrollOffsetY: CGFloat = 0
    /// Resisted in-hero pull (capped) — what the balance card actually stretches.
    @State private var heroPullDisplay: CGFloat = 0
    /// Refresh armed once the in-card chrome is fully revealed.
    @State private var pullRefreshArmed: Bool = false
    /// True while the hero is spring-settling after finger-up (ignore raw pull).
    @State private var isPullSettling: Bool = false
    /// Lottie phase for `mark-refresh-kit` (pull scrub → loop → success).
    @State private var markRefreshPhase: WalletHomeMarkRefreshPhase = .idle
    /// Home vertical scroll phase — used so **rubber-band decay after
    /// finger-up is not treated as an active pull** (that was shrinking the
    /// mark strip to 0, then re-opening it for loading = hide → show).
    @State private var homeScrollPhase: ScrollPhase = .idle
    /// Measured balance-card height (rest, excluding temporary pull stretch).
    @State private var balanceCardHeight: CGFloat = 0
    /// True while programmatic mid-hero snap is in flight.
    @State private var isHeroSnapInFlight: Bool = false
    @State private var isShowingCreate: Bool = false
    @State private var isShowingImport: Bool = false
    /// Receive v2 (2026-06-06) — the Receive surface is a sheet, not
    /// a push. Owned here on the parent so its path can be reset on
    /// dismiss per Rule #12 §G.
    @State private var isShowingReceive: Bool = false
    /// Drives the Send sheet (the Receive twin). Its own NavigationPath
    /// lives here so the sheet survives Rule #12 §G direction rebuilds.
    @State private var isShowingSend: Bool = false
    @State private var sendPath: NavigationPath = NavigationPath()
    /// The wallet-home **Aperture Scanner** action. Auto-detects a wallet
    /// address on any supported chain and opens Send.
    @State private var isShowingScanner: Bool = false
    /// A scanned address staged to open Send pre-filled, applied in the
    /// scanner's `onDismiss` (dismiss-then-present).
    @State private var scanPrefill: SendView.ScanPrefill?
    /// **Filter & Sort sheet (2026-06-09).** Drives the
    /// `.sheet(isPresented: $isShowingFilter)` block below. The sheet
    /// reads + writes preferences through `@GRDBStorage` against
    /// `WalletHomeFilterPreferences`'s keys; changes propagate to
    /// this view's body the moment the sheet writes them.
    @State private var isShowingFilter: Bool = false
    @State private var receivePath: NavigationPath = NavigationPath()
    /// **Navigation mirror (2026-06-13, launch reset 2026-07-09).**
    /// Seeded from `ScreenRestoration`'s mirror in `init` (below) and
    /// mirrored back on every change. New app processes clear the mirror
    /// before this view is constructed; in-session root rebuilds, such as
    /// direction flips, can still re-seed the current stack.
    ///
    /// **Why a typed `[WalletHomeDestination]`, not `NavigationPath`.**
    /// An opaque `NavigationPath` can't be inspected, so restoration
    /// had to take whatever was mirrored — including a deep path whose
    /// top was the full Activity list (reachable when the user taps
    /// "View all", then leaves the Wallet tab via the tab bar, or iOS
    /// kills the app while that tab still has Activity pushed). A cold
    /// launch then dropped the user onto Activity even though, to them,
    /// they "weren't there" (2026-06-14 bug report). A typed stack is
    /// inspectable: `ScreenRestoration.restoredWalletHomeStack()`
    /// truncates at the first non-`isColdLaunchRestorable` destination,
    /// so the app never auto-opens onto a list/action screen — only
    /// genuine "where I was reading" screens (asset detail, etc.)
    /// resume. The whole stack is `Codable`, so it round-trips.
    @State private var navigationPath: [WalletHomeDestination]
    @State private var createPath: NavigationPath = NavigationPath()
    @State private var importPath: NavigationPath = NavigationPath()
    @GRDBStorage(MainTab.storageKey) private var selectedTabRaw: String = MainTab.wallet.rawValue
    @State private var isRefreshing: Bool = false
    @State private var firstRefreshSkeletonWalletId: UUID?
    @State private var firstRefreshSkeletonRunId: UUID?
    @State private var firstRefreshSkeletonTask: Task<Void, Never>?

    /// `true` while a refresh this view started is in flight. Refresh now
    /// fetches nothing (data-fetching layer removed 2026-06-25), so this stays
    /// `false`; kept because the Retry control still reads it.
    private var isAnyRefreshInFlight: Bool {
        isRefreshing
    }

    /// First-refresh skeleton UI was removed (no shimmer / placeholder
    /// animations on home). Markers still clear via
    /// `updateFirstRefreshSkeletonFromPresentationMarker` so create/import
    /// handoff state does not linger.
    private var isShowingFirstRefreshSkeleton: Bool {
        false
    }

    private var firstRefreshSkeletonUsesEmptyState: Bool {
        false
    }

    private var firstRefreshPresentationFingerprint: String {
        [
            firstRefreshPresentationWalletIdRaw,
            String(firstRefreshPresentationStartedAt),
            String(firstRefreshPresentationDismissedAt)
        ].joined(separator: "|")
    }

    /// Network-error state retired with the data-fetching layer (2026-06-25):
    /// with no balance scan there is no scan failure to surface, so the honest
    /// holdings / empty states always render.
    private var showsNetworkErrorState: Bool {
        false
    }

    // MARK: - Long-press wallet switcher (the Telegram / Instagram pattern)
    //
    // 2026-06-09 — the long-press context menu lives on the toolbar
    // pill, NOT on the tab bar. SwiftUI's `.contextMenu` modifier
    // does not propagate through `Tab`'s label closure into UIKit's
    // `UITabBar` item buttons; verified live on Thuglife
    // (`databaseSequenceNumber 8500` and `8524`). The wallet-home's
    // `UniButton(variant: .walletPill)` IS the active-account
    // affordance on this screen, and toolbar items are pure SwiftUI
    // surfaces — `.contextMenu` works on them natively. Tap on the
    // pill opens `WalletSwitcherSheet`; long-press opens the native
    // iOS 26 Liquid Glass context menu. See `MainTabView.swift`'s
    // type-level doc for the full audit trail.

    /// Drives the `.sheet(item:)` that presents `WalletIconPickerSheet`
    /// from the long-press menu's "Customise wallet" row. Identifiable
    /// shim defined at the bottom of this file.
    @State private var customiseTargetId: UUID?

    /// Deep-link token consumed by `SettingsView` on appear. The
    /// long-press menu's "Manage wallets" row stamps `"wallets"`;
    /// Settings pushes onto its NavigationPath and clears the token.
    @GRDBStorage("settingsDeepLink") private var settingsDeepLink: String = ""

    /// Active tab for the holdings region. Per the 2026-06-09 user
    /// direction, the home no longer shows Coins AND Tokens as
    /// stacked List sections — a native segmented switcher sits at
    /// the top of the holdings list and the user picks which
    /// collection to view. Defaults to `.coins` because that's the
    /// broader vocabulary (every chain has one); Tokens is the
    /// deeper dive.
    @State private var selectedHoldingsTab: HoldingsTab = .coins

    // MARK: - Memoized derived state (computed off-body)
    //
    // The row builders + JSON-decoded filter inputs used to be
    // computed properties evaluated on EVERY body pass (4+ JSON
    // decodes and three full registry enumerations + sorts per
    // frame). They are now `@State` snapshots rebuilt only when an
    // actual dependency changes: the filter preferences (via
    // `.onChange` of `filterPreferenceFingerprint`), the active
    // wallet / currency, the GRDB row-count proxies, and
    // refresh completion. Behavior is unchanged — only the
    // computation timing moved out of the render path.

    @State private var filterInputs: WalletHomeFilterApply.Inputs = .current()
    @State private var coinDisplayRows: [WalletCoinSupportedRow] = []
    @State private var tokenDisplayRows: [WalletTokenSupportedDisplayRow] = []
    @State private var filteredCoinRows: [WalletCoinSupportedRow] = []
    @State private var filteredTokenRows: [WalletTokenSupportedDisplayRow] = []
    @State private var combinedFilteredRows: [CombinedHoldingRow] = []

    // MARK: - Base-collection memos (2026-06-14 perf — idle-CPU/heat fix)
    //
    // `balances`, `allHeldRows`, and `allTransactions` were plain
    // computed properties that each rebuilt from scratch on EVERY body
    // pass — `balances` alone did a nested loop over addresses × balances
    // plus an O(n log n) sort, and it was read ~5× per render (chart,
    // hero total, coin/token holdings, counts). With the body re-evaluating
    // in bursts on every 10 s refresh write, that became sustained CPU
    // (constant lag + device heat, even idle). These caches hold the
    // built collections; the computed properties below read the cache and
    // fall back to a live compute ONLY when unseeded (`nil`) — so the very
    // first paint (before `.onAppear` seeds them) is still correct, with no
    // empty-flash, and every render afterward is an O(1) cache read.
    //
    // Freshness: the caches are rebuilt by `rebuildBalanceMemos()` /
    // `rebuildTransactionMemos()`, folded into `rebuildDisplayRows()` —
    // which already fires on the COMPLETE set of change triggers (wallet
    // switch, currency change, balance-count change, asset seed, refresh
    // completion incl. the 10 s auto-refresh, and the currency re-price).
    // The stored rows are GRDB references, so their scalar values
    // stay live between rebuilds; a rebuild re-applies the non-zero filter
    // + fiat sort whenever a refresh/re-price changes those values.
    @State private var balancesMemo: [(chain: SupportedChain, balance: TokenBalanceRecord)]? = nil
    @State private var allHeldRowsMemo: [(chain: SupportedChain, balance: TokenBalanceRecord)]? = nil
    @State private var allTransactionsMemo: [TransactionRecord]? = nil
    /// USD unit prices for the feed's symbols, used ONLY for the $0.20-USD
    /// dust gate on the Recent-activity preview (2026-06-19 user direction:
    /// "never show transactions with less than $0.20, always in dollars").
    /// Loaded async (see `loadDustPrices`); until it arrives every row shows.
    @State private var usdActivityPrices: [String: Decimal] = [:]
    /// **Live transaction feed (2026-06-13).** A TOP-LEVEL GRDB observation,
    /// NOT a `wallet.addresses[].transactions` relationship traversal.
    /// GRDB merges scalar UPDATES to already-materialized rows
    /// (which is why balances refresh live) but does NOT append newly-
    /// INSERTED children to an already-materialized to-many array — so a
    /// transaction the background scanner inserted on pull-to-refresh
    /// never appeared until an app relaunch re-fetched the relationship
    /// (the Rule #25 live-state violation the user reported: "received
    /// 11 USDT, had to close & reopen to see it in activity"). A
    /// top-level GRDB observation re-runs its fetch whenever ANY context on the
    /// shared container inserts a `TransactionRecord`, so new activity
    /// shows the instant it's persisted — no relaunch, no navigate-away.
    private var allTransactionRecords: [TransactionRecord] { activeTransactionsObservation.transactions }

    /// **Live balance feed (2026-06-21).** A TOP-LEVEL GRDB observation, NOT a
    /// `wallet.addresses[].balances` relationship traversal — for the SAME
    /// reasons as `allTransactionRecords` above. The holdings list, chart,
    /// rollup, and the hero's fallback sum were all fed by the memoized
    /// `balances`/`allHeldRows` projections, which read the `balances`
    /// relationship and rebuilt only when the relationship-COUNT changed.
    /// That broke live balance updates two ways: (1) GRDB does NOT append
    /// a newly-INSERTED balance (a token received for the FIRST time) to an
    /// already-materialized to-many array, so a new asset never showed until
    /// relaunch; and (2) a scalar VALUE update (receiving MORE of an asset you
    /// already hold) leaves the row count unchanged, so the count trigger
    /// never fired and the holdings stayed frozen. Reading the rows from this
    /// top-level query — and driving the rebuild off a VALUE fingerprint of it
    /// (`balanceRowsRevision`) — makes every balance change render live, no
    /// relaunch, no manual refresh (Rule #25, now honoured for balances as it
    /// already was for transactions). The hero total itself was already live
    /// via `BalanceCardLiveSection`'s own `chainStateRecords` query.
    private var allBalanceRecords: [TokenBalanceRecord] { activeBalancesObservation.balances }

    /// The active wallet's transactions, newest first — the live
    /// top-level GRDB observation filtered to the active wallet's address ids.
    /// Address ids are stable (addresses aren't inserted during normal
    /// use), so reading them off the GRDB observation-backed `activeWallet` is
    /// safe; only per-tx membership changes, and the top-level query
    /// sees those inserts live. The in-memory filter is O(total tx) —
    /// a few thousand rows at most (the scanner caps history per chain),
    /// well under a millisecond per render, and there is no per-render
    /// SORT (the GRDB observation sorts at the store level).
    /// Cached (`allTransactionsMemo`); falls back to a live compute only
    /// when unseeded. Rebuilt by `rebuildTransactionMemos()` on wallet
    /// switch, refresh completion, and `allTransactionRecords` count
    /// changes — see the memo block near the `@State` declarations.
    private var allTransactions: [TransactionRecord] {
        allTransactionsMemo ?? computeAllTransactions()
    }

    /// The live filter: top-level GRDB observation narrowed to the active
    /// wallet's address ids, newest-first (the GRDB observation sorts at the
    /// store level). O(total tx) — moved out of the render path by the
    /// memo above; this runs only on a rebuild trigger.
    private func computeAllTransactions() -> [TransactionRecord] {
        guard let wallet = contentWallet else { return [] }
        // Solana: only the active (preferred) path — default Phantom; Trust
        // when the user selects it in Receive. Other chains: every address.
        let ids = displayAddressIds(for: wallet)
        guard !ids.isEmpty else { return [] }
        return allTransactionRecords.filter { tx in
            guard let aid = tx.addressId else { return false }
            return ids.contains(aid)
        }
    }

    /// Address ids whose balances/activity appear on home: all chains except
    /// Solana non-preferred dual-path rows.
    private func displayAddressIds(for wallet: WalletRecord) -> Set<UUID> {
        SolanaPathBalanceBreakdown.displayAddressIds(walletAddresses: wallet.addresses)
    }

    /// The five newest transactions for the home's Recent activity
    /// window. `allTransactions` is already newest-first; sub-$0.20-USD
    /// dust is dropped FIRST (2026-06-19 user direction) so the preview
    /// shows five real transactions, not five dust rows — then the cheap
    /// prefix. The "View all" affordance routes to the unbounded
    /// `WalletActivityView` (which applies the same gate).
    private var recentTransactions: [TransactionRecord] {
        var rows: [TransactionRecord] = []
        rows.reserveCapacity(5)
        for tx in allTransactions {
            guard !ActivityFiat.isDust(
                amountRaw: tx.amountRaw,
                symbol: tx.tokenSymbol,
                usdMap: usdActivityPrices
            ) else {
                continue
            }
            rows.append(tx)
            if rows.count == 5 { break }
        }
        return rows
    }

    /// Value-typed, TRANSACTION-only snapshot of `recentTransactions` for the
    /// `RecentActivityRows` leaf (2026-06-18) — chain + decoded/raw amount +
    /// symbol, NO fiat (the leaf computes fiat from the prices it now owns, so
    /// this snapshot has no price dependency and the parent no longer needs the
    /// `cachedPrices` query). Cheap (≤5 rows).
    private var recentActivityModels: [ActivityRowModel] {
        recentTransactions.compactMap { tx in
            // Skip a transaction whose chain can't be resolved rather than
            // silently misattributing it to Ethereum. In practice the
            // repository never produces an orphaned tx, so this never drops a
            // real row — it's data-integrity insurance.
            guard let chain = chainFor(tx) else { return nil }
            return ActivityRowModel(
                id: tx.id,
                chain: chain,
                direction: TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing,
                amount: Decimal(string: tx.amountRaw) ?? .zero,
                amountRaw: tx.amountRaw,
                tokenSymbol: tx.tokenSymbol,
                tokenContract: tx.tokenContract,
                counterparty: tx.counterparty,
                occurredAt: tx.occurredAt,
                status: TransactionStatus(rawValue: tx.statusRaw) ?? .pending,
                kind: tx.kind,
                txHash: tx.txHash
            )
        }
    }

    /// Follow-up action staged by the wallet-switcher sheet's
    /// create/import rows. Consumed in the sheet's `onDismiss` so
    /// the full-screen cover presents only after the sheet has
    /// fully dismissed (deterministic dismiss-then-present, no
    /// main-queue timing hop).
    private enum SwitcherFollowUp {
        case create
        case importWallet
    }

    @State private var pendingSwitcherFollowUp: SwitcherFollowUp?

    /// Tracked currency-change pipeline (re-price + refresh). A rapid
    /// second currency flip cancels the first pass so two re-prices
    /// never interleave writes for different currencies.
    @State private var currencyChangeTask: Task<Void, Never>?
    /// Coalesces high-frequency GRDB merge waves into one display
    /// projection rebuild. Balance refreshes can write dozens of rows in
    /// bursts; rebuilding the holdings lists after every individual merge is
    /// the main-screen hitch.
    @State private var displayRebuildTask: Task<Void, Never>?
    /// Rebuilds the persisted chain read model after balance merges settle.
    /// Kept cancellable so repeated refresh writes never stack reconciliation
    /// jobs on top of the active scan.
    @State private var chainReconcileTask: Task<Void, Never>?

    init() {
        // Navigation mirror seed. `@State` reads its initial value only when
        // the view's identity is fresh — launch, where the mirror has already
        // been cleared, and root direction-flip rebuilds, where preserving the
        // current path is intentional.
        _navigationPath = State(initialValue: ScreenRestoration.restoredWalletHomeStack())
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listSurface
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                // Scroll-driven chrome: identity at rest → page floor when scrolled.
                // No tree-wide `.animation(.snappy)` here — springs on this surface
                // made the hero/holdings overshoot on PTR release and bar fade.
                .toolbar { labStyleAppBarToolbar }
                // Live identity mid-swipe via `WalletHomeSwipeChrome` (leaf observer).
                // Do not drive bar fill from parent `pageSwipeProgress` — that
                // re-rendered the pager and snapped back to the previous wallet.
                .modifier(WalletHomeLiveToolbarChrome(
                    // iPad: no wallet-identity colour in the bar — always page floor.
                    verticalBlend: horizontalSizeClass == .regular
                        ? 1
                        : appBarBlendProgress,
                    pageFloor: pageFloorAppBarColor
                ))
                .navigationDestination(for: WalletHomeDestination.self) { destination in
                    switch destination {
                    case .transaction(let id):                  TransactionDetailView(transactionId: id)
                    case .allSupported:                         AllSupportedAssetsView()
                    case .assetDetail(let identity):            AssetDetailView(identity: identity)
                    case .assetNetworkDetail(let identity, let chainRaw):
                        if let chain = SupportedChain(rawValue: chainRaw) {
                            AssetNetworkDetailView(identity: identity, chain: chain)
                        } else {
                            // Defensive — invalid raw value would
                            // mean a stale NavigationPath restoration.
                            // Fall back to the asset detail.
                            AssetDetailView(identity: identity)
                        }
                    case .assetActivity(let identity):          AssetActivityView(identity: identity)
                    case .allActivity:                          WalletActivityView()
                    }
                }
                // PTR is lab-style custom (in-hero), not List `.refreshable`.
                .task(id: observationScopeKey) {
                    syncObservationScopes()
                }
                .task(id: activeWalletIdRaw) {
                    ensureActiveWalletSet()
                    // Seed the memoized DISPLAY projections (balances /
                    // coin / token rows) before the first refresh lands
                    // so the home renders the persisted state
                    // immediately. Transactions need no seeding — they
                    // read live from the top-level GRDB observation.
                    rebuildFilterInputs()
                    rebuildDisplayRows()
                    scheduleChainStateReconcile(after: 0)
                    // Auto-refresh on appear AND on active-wallet
                    // change so the wallet shows live balances +
                    // transaction history without forcing the user
                    // to pull-to-refresh. `.task(id:)` re-fires when
                    // `activeWalletIdRaw` flips — a freshly imported
                    // or switched-to wallet gets its balance and
                    // history fetch immediately (2026-06-12; the
                    // prior id-less `.task` ran once per view
                    // lifecycle, so an import landed on a home that
                    // never scanned it). The refresh registry dedupes
                    // concurrent same-wallet refreshes, so racing the
                    // import flow's own scan is safe. The refresh is
                    // silent unless it produces a change — the user
                    // sees the `mostRecentScanAt` footer tick over
                    // honestly.
                    await runRefresh()
                }
                .task {
                    // One-shot per session: heal the query-free iCloud
                    // backup index for any wallet backed up BEFORE that index
                    // existed (2026-06-20). The index record lives in iCloud,
                    // so populating it once here makes Restore from iCloud list
                    // the backup on a later fresh install — with no CloudKit
                    // Console step and no manual re-backup. Best-effort,
                    // background; per-wallet failures (no backup / offline) are
                    // ignored.
                    guard !didHealBackupIndex else { return }
                    didHealBackupIndex = true
                    let ids = allWallets.map(\.id)
                    guard !ids.isEmpty else { return }
                    await CloudKitBackupStore().reconcileIndex(walletIds: ids)
                }
                .task(id: dustPriceKey) {
                    // USD unit prices for the $0.20-USD dust gate on the
                    // Recent-activity preview. Off-body, engine-cached;
                    // re-fires on wallet switch / new tx (2026-06-19).
                    await loadDustPrices()
                }
                .onChange(of: filterPreferenceFingerprint) { _, _ in
                    rebuildFilterInputs()
                    rebuildFilteredRows()
                }
                .onChange(of: activeWalletIdRaw) { _, newValue in
                    cancelFirstRefreshSkeleton(unless: UUID(uuidString: newValue))
                    let newId = UUID(uuidString: newValue)
                    // Always clear the pager-write flag. Never use it to *skip*
                    // a page resync — that left hero on wallet A and holdings
                    // on wallet B (Imported Wallet 2 balances under Wallet 3).
                    isApplyingPagerActiveWallet = false
                    // External (create / import / switcher) or recovered desync:
                    // hero page must match the stored active id.
                    if selectedPageWalletId != newId {
                        syncPageSelectionFromActiveWallet(animated: false)
                    }
                    applyHomeContentWalletScope(newId)
                }
                .onChange(of: selectedPageWalletId) { _, newId in
                    guard let newId else { return }
                    activateWalletFromPager(newId)
                }
                .onChange(of: sortedWallets.map(\.id)) { _, newIds in
                    // Prefer the active wallet when it just joined the list
                    // (create/import). Previously we only re-seeded when the
                    // *current page* vanished, so a new active wallet left the
                    // hero stuck on the previous card.
                    if let activeId = UUID(uuidString: activeWalletIdRaw),
                       newIds.contains(activeId) {
                        if selectedPageWalletId != activeId {
                            syncPageSelectionFromActiveWallet(animated: false)
                        }
                        return
                    }
                    if let selected = selectedPageWalletId, newIds.contains(selected) {
                        return
                    }
                    syncPageSelectionFromActiveWallet(animated: false)
                }
                .onAppear {
                    syncPageSelectionFromActiveWallet()
                }
                .onChange(of: firstRefreshPresentationFingerprint) { _, _ in
                    updateFirstRefreshSkeletonFromPresentationMarker()
                }
                // Navigation mirror for root rebuilds. Cold launch clears it
                // before this view's `init`; live rebuilds can consume it.
                .onChange(of: navigationPath) { _, newPath in
                    ScreenRestoration.saveWalletHomeStack(newPath)
                }
                // Re-tapping the Wallet tab (MainTabView bumps this token)
                // pops the nav stack back to the home root — the standard
                // iOS tab gesture (2026-06-18 user report). Reading the
                // token here registers the Observation dependency so the
                // bump re-evaluates this body and fires the handler.
                .onChange(of: TabReselectSignal.shared.walletReselectToken) { _, _ in
                    if !navigationPath.isEmpty {
                        withAnimation(.snappy) { navigationPath.removeAll() }
                    }
                }
                .onChange(of: currencyCode) { _, _ in
                    // Labels react immediately (the hero + unheld rows
                    // read `currencyCode` directly)…
                    scheduleDisplayRowsRebuild(after: 50_000_000)
                    // …and the VALUES project from cached fiat through
                    // FX immediately, then refine with live token prices.
                    currencyChangeTask?.cancel()
                    currencyChangeTask = Task { await repriceForCurrencyChange() }
                    syncObservationScopes()
                }
                .onChange(of: balanceRowsRevision) { _, _ in
                    scheduleDisplayRowsRebuild()
                    scheduleChainStateReconcile()
                }
                // "Hide small balances" threshold (a Settings preference,
                // a DIFFERENT @GRDBStorage key than the filter sheet's
                // `filterMinFiatThreshold`) is read inside `computeBalances()`.
                // The pre-memo `balances` re-read it every body pass, so
                // changing it updated the home live; the cache must rebuild
                // explicitly or the hero/holdings/chart stay on the old
                // threshold until the next refresh (Rule #25). 2026-06-14.
                .onChange(of: hideSmallThreshold) { _, _ in
                    scheduleDisplayRowsRebuild(after: 50_000_000)
                }
                // New transactions landed in the top-level GRDB observation (live
                // cross-context inserts, Rule #25) — refresh the cached
                // `allTransactions` so the Recent activity list + chart
                // reflect them immediately, not only after a refresh ends.
                .onChange(of: activeTransactionsObservation.revision) { _, _ in
                    scheduleDisplayRowsRebuild()
                }
                // Re-derive when the DB asset seed lands (Rule #27 §D — the
                // list moves from the static fallback to DB `AssetRecord`
                // rows; output identical) OR when a custom token is
                // added/removed (2026-06-19 — the Tokens section reflects
                // it immediately, not only after the next refresh). One
                // combined key keeps the body's modifier chain inside the
                // Swift type-checker's complexity budget.
                .onChange(of: assetCatalogObservation.revision) { _, _ in
                    scheduleDisplayRowsRebuild()
                }
                .onDisappear {
                    displayRebuildTask?.cancel()
                    chainReconcileTask?.cancel()
                    cancelFirstRefreshSkeleton()
                }
        }
        // Settings is now reached via the four-tab shell (`MainTabView`
        // — 2026-06-09). The previous `.sheet { SettingsView }` block
        // and its direction-keyed rebuild are retired with the toolbar
        // gear. Receive remains a sheet because its surface is
        // commit-shaped (pick chain → render QR → share), not a
        // top-level section.
        .sheet(isPresented: $isShowingReceive, onDismiss: handleReceiveSheetDismiss) {
            // Receive v2 — asset-first bottom sheet. `.large` detent
            // only (per M-005, avoids `.medium` clipping locale-
            // sensitive list rows in RTL languages). Rule #12 §G
            // direction-only rebuild key + `.apertureEnvironment()` so
            // theme + locale propagate into the sheet's own scope.
            ReceiveView(navigationPath: $receivePath)
                .id(sheetDirectionKey)
                .apertureEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        // Send — asset-first bottom sheet, the twin of Receive. Same
        // `.large`-only detent, same Rule #12 §G direction rebuild key +
        // `.apertureEnvironment()` so theme + locale propagate into the
        // sheet's own scope.
        .sheet(isPresented: $isShowingSend, onDismiss: handleSendSheetDismiss) {
            SendView(
                navigationPath: $sendPath,
                prefill: scanPrefill
            )
                .id(sheetDirectionKey)
                .apertureEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        // Wallet-home Aperture Scanner. Auto-detects a wallet address on any
        // supported chain and opens Send pre-filled. The chosen action is
        // staged and applied in `onDismiss` so we never present Send over a
        // still-dismissing full-screen scanner.
        .fullScreenCover(isPresented: $isShowingScanner, onDismiss: {
            if scanPrefill != nil { isShowingSend = true }
        }) {
            UniQRScannerSheet(
                expectedContent: .walletAddress,
                onSend: { chain, address in
                    scanPrefill = SendView.ScanPrefill(chain: chain, recipient: address)
                    isShowingScanner = false
                }
            )
            .apertureEnvironment()
        }
        // Filter & Sort sheet (2026-06-09). `.large` detent only per
        // M-008's nav-shaped-sheet rule. Rule #12 §G direction key +
        // `.apertureEnvironment()` so theme + locale propagate into the
        // sheet's own scope and an LTR↔RTL flip mid-presentation
        // rebuilds the host instead of stranding it on the prior
        // direction.
        .sheet(isPresented: $isShowingFilter) {
            // Pass the wallet-home's active search query so the
            // filter sheet's live preview can read "Found N for
            // query" instead of "Showing N of M" while the user
            // is searching.
            WalletHomeFilterSheet(searchPreview: filterSearchText)
                .id(sheetDirectionKey)
                .apertureEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingSwitcher, onDismiss: {
            // Dismiss-then-present: the create/import cover presents
            // from `onDismiss` so it never races a sheet that is
            // still animating out. The prior `DispatchQueue.main.async`
            // hop was a timing guess; this is the deterministic
            // hand-off point.
            switch pendingSwitcherFollowUp {
            case .create:       isShowingCreate = true
            case .importWallet: isShowingImport = true
            case nil:           break
            }
            pendingSwitcherFollowUp = nil
        }) {
            WalletSwitcherSheet(
                onSelect: {
                    // Selection writes activeWalletIdRaw in the sheet
                    // itself; here we just acknowledge with a haptic.
                },
                onCreateNew: {
                    pendingSwitcherFollowUp = .create
                    isShowingSwitcher = false
                },
                onImport: {
                    pendingSwitcherFollowUp = .importWallet
                    isShowingSwitcher = false
                }
            )
            .apertureEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingCreate, onDismiss: { createPath = NavigationPath() }) {
            RecoveryPhraseFlow(
                navigationPath: $createPath,
                onDismiss: { isShowingCreate = false },
                onUserContinuedWithoutVerifiedBackup: {}
            )
            .apertureEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingImport, onDismiss: { importPath = NavigationPath() }) {
            ImportWalletFlow(
                navigationPath: $importPath,
                onDismiss: { isShowingImport = false },
                onCompleted: { _ in isShowingImport = false }
            )
            .apertureEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        // Wallet-identity customisation — presented from the
        // long-press menu on the toolbar pill. Reuses the
        // canonical `WalletIconPickerSheet` (the same sheet
        // `WalletDetailView` presents); the wallet-home owns
        // the presentation here so the menu lives on the same
        // screen as the affordance that opened it.
        .sheet(item: customiseTargetBinding) { target in
            WalletIconPickerSheet(walletId: target.walletId)
                .apertureEnvironment()
                .uniSheetDetents([.large])
                .presentationBackground(UniColors.Background.primary)
        }
    }

    private var observationScopeKey: String {
        [
            // Scope must track the *settled hero page*, not only the GRDB
            // active pointer — otherwise holdings lag or desync from the pill.
            contentWalletId?.uuidString ?? "",
            activeWalletIdRaw,
            walletRecordsObservation.revision,
            currencyCode
        ].joined(separator: "|")
    }

    private func syncObservationScopes() {
        let scopedWalletId = contentWalletId
            ?? activeWallet?.id
            ?? UUID(uuidString: activeWalletIdRaw)
        activeBalancesObservation.setWalletId(scopedWalletId)
        activeTransactionsObservation.setWalletId(scopedWalletId)
        cachedPricesObservation.setCurrencyCode(currencyCode)
    }

    /// Rebind balance/tx observations + rebuild holdings for one wallet id
    /// immediately (pager settle must not wait for `activeWalletId` prop).
    private func applyHomeContentWalletScope(_ walletId: UUID?) {
        activeBalancesObservation.setWalletId(walletId)
        activeTransactionsObservation.setWalletId(walletId)
        cachedPricesObservation.setCurrencyCode(currencyCode)
        displayRebuildTask?.cancel()
        chainReconcileTask?.cancel()
        clearWalletScopedSnapshots()
        rebuildFilterInputs()
        rebuildDisplayRows()
        scheduleChainStateReconcile(after: 0)
    }

    // MARK: - Layout

    /// The whole wallet-home content is a native iOS grouped list
    /// (`List(.insetGrouped)`) — the same chrome Apple's Settings,
    /// Health, Mail, and Wallet use. Converted from a hand-built
    /// `ScrollView { VStack { … } }` on 2026-06-08 per direct user
    /// direction:
    ///
    /// > "instead of using just a card, it should use a REAL NATIVE
    /// > LIST FROM iOS same as settings"
    ///
    /// **Section composition.**
    /// 1. **Chrome section** — hero balance + banners + glass action
    ///    triplet. These rows use `Color.clear` row backgrounds and
    ///    hidden separators so the inset-card chrome doesn't fight
    ///    the floating glass; the rows read as chrome above the data,
    ///    not as list rows.
    /// 2. **Coins section** — native inset card with one `AssetRow`
    ///    per chain the wallet holds a native coin balance for.
    ///    Capped at 10 rows, sorted by fiat desc. When the wallet
    ///    holds more than 10 coins, a final "Show all" navigation
    ///    row appears under the 10 — pushing
    ///    `WalletHomeDestination.allSupported`. When the wallet
    ///    holds fewer than 10, no Show all row (the section already
    ///    shows everything held).
    /// 3. **Tokens section** — sibling to Coins. One
    ///    `TokenHoldingRow` per non-native token balance, capped
    ///    + Show all under the same rules. Sections appear
    ///    independently — a wallet that holds only coins skips the
    ///    Tokens section entirely (and vice versa).
    /// 4. **Holdings empty section** — appears ONLY when both
    ///    `coinHoldings` and `tokenHoldings` are empty. Shows the
    ///    single `UniEmptyState` in a section labeled "Holdings"
    ///    so the empty state lives inside the same chrome the held
    ///    rows would.
    /// 5. **Recent activity section** — native inset card with one
    ///    row per transaction. Each row wraps an `ActivityRow` in a
    ///    `Button` so the row tap routes to the transaction detail
    ///    via `WalletHomeDestination.transaction(id)`.
    /// 6. **Footer** — (removed) marketing boundary line no longer shown.
    ///
    /// **Why two sections, not one.** User direction 2026-06-08:
    /// *"coins (native network) should be in a window, and all
    /// other tokens should be in different window in the main
    /// screen."* The split is honest about what each kind of
    /// holding IS — a native coin is the chain's own unit; a token
    /// is a smart-contract asset deployed onto a chain. Treating
    /// them as one mixed list (the prior shape) blurred the
    /// distinction and produced visually deep chain → tokens
    /// nesting that the flat split now resolves.
    ///
    /// **Refresh model (no system PTR):** never attach `.refreshable` /
    /// `UIRefreshControl` here. Apple’s list/scroll chrome paints a white
    /// gap and fights the identity hero. Pull is measured via
    /// `onScrollGeometryChange`; the spinner lives **inside** the balance
    /// card (`WalletHomeHeroPager`). Auto-refresh still runs from `.task`.
    ///
    /// **Lab-identical layout:** ScrollView + identity hero + opaque
    /// primary body cards. Real coins/tokens/activity.
    /// iPad / regular width: no full-bleed wallet identity colour wash.
    private var usesIdentityColorChrome: Bool {
        horizontalSizeClass != .regular
    }

    private var listSurface: some View {
        ZStack(alignment: .top) {
            // Identity sheet under the pull gap — iPhone only. iPad keeps a
            // neutral page background (no coloured wash behind the split pane).
            if usesIdentityColorChrome, showsHeroPullBackdrop {
                WalletHomeLiveIdentityFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220 + heroPullDisplay)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Mark strip is inside the hero so it rubber-bands
                        // with the card — never a screen-fixed overlay that
                        // jumps on finger-up.
                        WalletHomeHeroPager(
                            wallets: sortedWallets,
                            selectedWalletId: $selectedPageWalletId,
                            currencyCode: currencyCode,
                            canSend: displayedWallet?.kind != .watchOnly,
                            onReceive: { isShowingReceive = true },
                            onSend: { isShowingSend = true },
                            onScan: { isShowingScanner = true },
                            pullDistance: heroPullDisplay,
                            markRefreshPhase: markRefreshPhase,
                            onMarkRefreshSuccessFinished: {
                                // Success check finished — strong double-beat.
                                UniHapticEngine.shared.play(
                                    .contextualImpact(.consequential)
                                )
                                withAnimation(WalletHomePullMetrics.settleSpring) {
                                    heroPullDisplay = 0
                                    markRefreshPhase = .idle
                                    isRefreshing = false
                                    isPullSettling = false
                                }
                            },
                            onSwipeProgressChange: { progress in
                                // Idle / seed only (hero never streams mid-drag).
                                if abs(progress - pageSwipeProgress) >= 0.01 {
                                    pageSwipeProgress = progress
                                }
                            }
                        )
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: WalletHomeBalanceCardHeightKey.self,
                                    // Rest height excludes temporary pull strip.
                                    value: max(0, geo.size.height - heroPullDisplay)
                                )
                            }
                        }
                        .id(WalletHomeScrollAnchor.balanceCard)

                        VStack(spacing: UniSpacing.m) {
                            if requiresBiometricReenrollment {
                                BiometricReenrollmentBanner()
                            }
                            productionHoldingsCard
                            productionActivityCard
                        }
                        .padding(.horizontal, UniSpacing.m)
                        .padding(.top, UniSpacing.m)
                        .padding(.bottom, UniSpacing.xxl)
                        .frame(maxWidth: .infinity)
                        .background(UniColors.Background.primary)
                        .id(WalletHomeScrollAnchor.mainContent)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectHidden(true, for: .top)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, newOffset in
                    handleHomeScrollOffset(newOffset)
                }
                .onScrollPhaseChange { oldPhase, newPhase in
                    homeScrollPhase = newPhase
                    // Finger lifted: lock pull → hold/loading immediately.
                    // Do **not** wait for rubber-band rawPull to decay (that
                    // path used to scrub strip height 80→0, then re-open).
                    if oldPhase == .interacting,
                       newPhase == .decelerating || newPhase == .idle
                    {
                        commitPullFingerUp()
                    }
                    if newPhase == .idle {
                        snapBalanceCardIfNeeded(proxy: proxy)
                    }
                }
                .onPreferenceChange(WalletHomeBalanceCardHeightKey.self) { height in
                    if height > 1, abs(height - balanceCardHeight) >= 1 {
                        balanceCardHeight = height
                    }
                }
            }
        }
        .frame(maxWidth: horizontalSizeClass == .regular ? 640 : .infinity)
        .frame(maxWidth: .infinity)
        .background {
            // iPad: solid page floor only. iPhone: identity colour under the
            // hero + primary below (matches the connected balance card).
            if usesIdentityColorChrome {
                VStack(spacing: 0) {
                    WalletHomeLiveIdentityFill()
                        .ignoresSafeArea(edges: .top)
                    UniColors.Background.primary
                }
                .ignoresSafeArea()
            } else {
                UniColors.Background.primary
                    .ignoresSafeArea()
            }
        }
    }

    /// If the user releases with the balance card only half-scrolled, settle
    /// natively to fully open (offset 0) or fully past the card (holdings top).
    private func snapBalanceCardIfNeeded(proxy: ScrollViewProxy) {
        guard !isHeroSnapInFlight else { return }
        guard !isRefreshing, !isPullSettling else { return }
        // Don't fight pull-to-refresh rubber-band.
        guard homeScrollOffsetY >= 0, heroPullDisplay < 1 else { return }

        let heroH = balanceCardHeight
        guard heroH > 40 else { return }

        let y = homeScrollOffsetY
        // Already at an end — leave free scrolling in holdings alone.
        let edge: CGFloat = 14
        guard y > edge, y < heroH - edge else { return }

        let snapToContent = y >= heroH * 0.5
        isHeroSnapInFlight = true
        withAnimation(.smooth(duration: 0.32)) {
            if snapToContent {
                proxy.scrollTo(WalletHomeScrollAnchor.mainContent, anchor: .top)
            } else {
                proxy.scrollTo(WalletHomeScrollAnchor.balanceCard, anchor: .top)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(360))
            isHeroSnapInFlight = false
        }
    }

    private var showsHeroPullBackdrop: Bool {
        // Any active pull / loading strip needs identity colour under the mark.
        heroPullDisplay >= WalletHomePullMetrics.revealThreshold
            || markRefreshPhase != .idle
            || isRefreshing
    }

    /// App bar pill: live nearer-wallet identity mid-swipe (via chrome store).
    @ToolbarContentBuilder
    private var labStyleAppBarToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            WalletHomeLiveAppBarPill(
                // iPad has no identity colour wash — always use page-floor
                // ink (black on Cloud, white on Midnight/Dark). Identity
                // light-on-colour labels read as white-on-white.
                verticalBlend: usesIdentityColorChrome ? appBarBlendProgress : 1,
                scrolledLabel: scrolledPillLabelColor,
                scrolledChip: scrolledPillChipColor,
                onTap: { isShowingSwitcher = true },
                contextMenu: { walletPillContextMenu }
            )
            .modifier(
                WalletPillRegularWidthMenu(
                    isRegularWidth: horizontalSizeClass == .regular,
                    menu: { walletPillContextMenu }
                )
            )
        }
    }

    /// Resistance-limited pull while the finger is down. Rubber-band decay
    /// after lift is **ignored** so the strip never collapses to empty rest
    /// before the loading hold opens (video: hide at ~1.8s → show at ~2.0s).
    private func handleHomeScrollOffset(_ newOffset: CGFloat) {
        var noAnim = Transaction()
        noAnim.disablesAnimations = true

        // App-bar fade still tracks raw scroll (positive = scrolled down).
        withTransaction(noAnim) {
            if newOffset >= 0 {
                if homeScrollOffsetY < 0 || abs(newOffset - homeScrollOffsetY) >= 1 {
                    homeScrollOffsetY = newOffset
                }
            } else {
                homeScrollOffsetY = newOffset
            }
        }

        // Refresh state machine owns the strip — never shrink from geometry.
        if isRefreshing || isPullSettling { return }
        switch markRefreshPhase {
        case .loading, .success:
            return
        case .idle, .pulling:
            break
        }

        // Only grow/track pull while the user is **touching**. After lift the
        // scroll phase is decelerating/idle and rubber-band would otherwise
        // scrub heroPullDisplay 80→0 (mark vanishes) before loading reopens it.
        guard homeScrollPhase == .interacting else { return }

        let rawPull = max(0, -newOffset)
        guard rawPull > WalletHomePullMetrics.releaseRaw else { return }

        let resisted = WalletHomePullMetrics.resisted(raw: rawPull)
        withTransaction(noAnim) {
            heroPullDisplay = resisted
            markRefreshPhase = .pulling(progress: {
                let span = max(
                    1,
                    WalletHomePullMetrics.armThreshold - WalletHomePullMetrics.revealThreshold
                )
                return min(
                    1,
                    max(0, (resisted - WalletHomePullMetrics.revealThreshold) / span)
                )
            }())
            if resisted >= WalletHomePullMetrics.armThreshold, !pullRefreshArmed {
                pullRefreshArmed = true
                UniHapticEngine.shared.play(.selection)
            }
        }
    }

    /// Finger left the scroll view — commit pull → hold/loading **now**,
    /// at the current stretch. Do not wait for rubber-band rawPull to hit 0.
    private func commitPullFingerUp() {
        if isRefreshing || isPullSettling { return }
        switch markRefreshPhase {
        case .loading, .success:
            return
        case .idle, .pulling:
            break
        }

        if pullRefreshArmed || heroPullDisplay >= WalletHomePullMetrics.armThreshold {
            pullRefreshArmed = false
            beginPullRelease(shouldRefresh: true)
        } else if heroPullDisplay > WalletHomePullMetrics.revealThreshold {
            pullRefreshArmed = false
            beginPullRelease(shouldRefresh: false)
        } else {
            pullRefreshArmed = false
            var noAnim = Transaction()
            noAnim.disablesAnimations = true
            withTransaction(noAnim) {
                heroPullDisplay = 0
                markRefreshPhase = .idle
            }
        }
    }

    /// Spring strip to hold (refresh) or closed (cancel). Hold chrome is locked
    /// synchronously — never passes through empty rest between pull and load.
    private func beginPullRelease(shouldRefresh: Bool) {
        isPullSettling = true
        if shouldRefresh {
            isRefreshing = true
            // Spring stretch → hold only. Never set 0 first (video hide→show).
            withAnimation(WalletHomePullMetrics.settleSpring) {
                heroPullDisplay = WalletHomePullMetrics.holdHeight
                markRefreshPhase = .loading
            }
            // Refresh animation starts (loop) — light lifecycle tick.
            UniHapticEngine.shared.play(.start)
            Task { @MainActor in
                try? await Task.sleep(
                    for: .milliseconds(WalletHomePullMetrics.settleDurationMs)
                )
                isPullSettling = false
                await runRefresh(userInitiated: true)
            }
        } else {
            withAnimation(WalletHomePullMetrics.settleSpring) {
                heroPullDisplay = 0
                markRefreshPhase = .idle
            }
            Task { @MainActor in
                try? await Task.sleep(
                    for: .milliseconds(WalletHomePullMetrics.settleDurationMs)
                )
                if !isRefreshing {
                    isPullSettling = false
                }
            }
        }
    }

    // 2026-06-14 — sync is background-only and has NO UI surface.

    /// Lab-shaped holdings card with **real** filtered coin/token rows.
    private var productionHoldingsCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text("Holdings")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)

            VStack(spacing: 0) {
                HStack(spacing: UniSpacing.s) {
                    holdingsTabPicker
                        .disabled(filterViewMode == .combined)
                        .opacity(filterViewMode == .combined ? 0.46 : 1)
                    filterButton
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.vertical, UniSpacing.s)

                Divider().opacity(0.35)

                if showsNetworkErrorState {
                    networkErrorCardBody
                } else if filterViewMode == .combined {
                    combinedCardRows
                } else {
                    // Simple fade between Coins ↔ Tokens (no slide).
                    holdingsTabContent
                        .id(selectedHoldingsTab)
                        .transition(.opacity)
                        .animation(.snappy(duration: 0.28), value: selectedHoldingsTab)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.List.rowBackground)
            )
            .clipped()
        }
    }

    @ViewBuilder
    private var holdingsTabContent: some View {
        switch selectedHoldingsTab {
        case .coins:
            coinCardRows
        case .tokens:
            tokenCardRows
        }
    }

    @ViewBuilder
    private var coinCardRows: some View {
        let allRows = filteredCoinRows
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = WalletHomeFilterApply.partitionPinned(coins: allRows, pinned: pinnedSet)
        let displayed = Array(nonPinned.prefix(holdingsDisplayCap))
        let hasMore = nonPinned.count > holdingsDisplayCap
        let rows = pinned + displayed

        if rows.isEmpty {
            holdingsCardEmptyState(kind: .coins)
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.chain.rawValue) { index, row in
                coinNavigationRow(row)
                if index < rows.count - 1 || hasMore {
                    Divider().opacity(0.28).padding(.leading, UniSpacing.m + 44)
                }
            }
            if hasMore {
                showAllRow
                    .padding(.horizontal, UniSpacing.m)
                    .padding(.vertical, UniSpacing.s)
            }
        }
    }

    @ViewBuilder
    private var tokenCardRows: some View {
        let allRows = filteredTokenRows
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = WalletHomeFilterApply.partitionPinned(tokens: allRows, pinned: pinnedSet)
        let displayed = Array(nonPinned.prefix(holdingsDisplayCap))
        let hasMore = nonPinned.count > holdingsDisplayCap
        let rows = pinned + displayed

        if rows.isEmpty {
            holdingsCardEmptyState(kind: .tokens)
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                tokenNavigationRow(row)
                if index < rows.count - 1 || hasMore {
                    Divider().opacity(0.28).padding(.leading, UniSpacing.m + 44)
                }
            }
            if hasMore {
                showAllRow
                    .padding(.horizontal, UniSpacing.m)
                    .padding(.vertical, UniSpacing.s)
            }
        }
    }

    @ViewBuilder
    private var combinedCardRows: some View {
        let merged = combinedFilteredRows
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = partitionPinnedCombined(merged, pinnedSet: pinnedSet)
        let displayed = Array(nonPinned.prefix(holdingsDisplayCap))
        let hasMore = nonPinned.count > holdingsDisplayCap
        let rows = pinned + displayed

        if rows.isEmpty {
            holdingsCardEmptyState(kind: .combined)
        } else {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                combinedRow(item)
                if index < rows.count - 1 || hasMore {
                    Divider().opacity(0.28).padding(.leading, UniSpacing.m + 44)
                }
            }
            if hasMore {
                showAllRow
                    .padding(.horizontal, UniSpacing.m)
                    .padding(.vertical, UniSpacing.s)
            }
        }
    }

    /// Unified empty body for the lab-shaped holdings card (tabs already
    /// paint the parent surface — mark + copy only, same as list empty).
    private func holdingsCardEmptyState(kind: HoldingsEmptyKind) -> some View {
        UniCardEmptyState(
            title: holdingsEmptyTitle(kind: kind),
            detail: holdingsEmptyDetail(kind: kind),
            mark: holdingsEmptyMark(kind: kind),
            minHeight: 240
        )
    }

    private var networkErrorCardBody: some View {
        VStack(spacing: UniSpacing.s) {
            UniEmptyState(
                title: "Couldn't reach the network",
                detail: "Your balances will appear once Aperture can reach the chains.",
                mark: .icon(systemName: "wifi.slash")
            )
            UniButton(
                title: isAnyRefreshInFlight ? "Retrying…" : "Retry",
                variant: .secondary,
                isLoading: isAnyRefreshInFlight,
                isEnabled: !isAnyRefreshInFlight
            ) {
                Task { await runRefresh(userInitiated: true) }
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.bottom, UniSpacing.s)
        }
    }

    /// Recent activity as a real Settings-style inset list (separators,
    /// list-row press chrome), not a flat stack of rows in a pad.
    private var productionActivityCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            activityHeader

            if recentTransactions.isEmpty {
                emptyActivity
            } else {
                VStack(spacing: 0) {
                    productionActivityRows
                }
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                        .fill(UniColors.List.rowBackground)
                )
                .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
            }
        }
    }

    /// The Coins/Tokens segment paired with the Filter & Sort control.
    private var holdingsChromeRow: some View {
        HStack(spacing: UniSpacing.s) {
            holdingsTabPicker
                .disabled(filterViewMode == .combined)
                .opacity(filterViewMode == .combined ? 0.46 : 1)
            filterButton
        }
    }

    /// List-row chrome (kept for any remaining List-based skeleton paths).
    private var holdingsControlsListRow: some View {
        holdingsChromeRow
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: UniSpacing.xs,
                leading: UniSpacing.m,
                bottom: UniSpacing.xs,
                trailing: UniSpacing.m
            ))
    }

    /// Classic (pre–iOS 26) Coins | Tokens segment — soft track + white
    /// sliding capsule, with snappy selection motion.
    private var holdingsTabPicker: some View {
        UniClassicSegmentedControl(
            selection: $selectedHoldingsTab,
            options: [
                (HoldingsTab.coins, "Coins"),
                (HoldingsTab.tokens, "Tokens")
            ]
        )
        .accessibilityLabel(Text("Switch between Coins and Tokens"))
    }

    /// Filter & Sort — same height as the classic Coins/Tokens segment.
    private var filterButton: some View {
        Button {
            isShowingFilter = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(UniColors.Text.primary)
                .frame(
                    width: UniClassicSegmentedMetrics.height,
                    height: UniClassicSegmentedMetrics.height
                )
                .background(
                    UniColors.Fill.tertiary,
                    in: Circle()
                )
        }
        .buttonStyle(.uniTactile)
        .accessibilityLabel(Text("Filter and sort"))
    }

    // MARK: - Holdings section (native List)

    /// Stable split-mode holdings section. Coins/Tokens picker is the first
    /// row; asset rows use system hairline separators between them.
    @ViewBuilder
    private var splitHoldingsSection: some View {
        Section {
            holdingsControlsListRow

            Group {
                switch selectedHoldingsTab {
                case .coins:
                    coinRows
                case .tokens:
                    tokenRows
                }
            }
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    // MARK: - First refresh skeleton

    /// Initial wallet scan loading state. This uses the same List section,
    /// segmented-control row, and asset row components as the production
    /// holdings surface, then applies SwiftUI's native placeholder redaction
    /// to the rows so text metrics and row heights match the final UI.
    @ViewBuilder
    private var firstRefreshHoldingsSkeletonSection: some View {
        Section {
            holdingsControlsListRow
                .disabled(true)
                .accessibilityHidden(true)

            switch filterViewMode {
            case .split:
                switch selectedHoldingsTab {
                case .coins:
                    firstRefreshCoinSkeletonRows
                case .tokens:
                    firstRefreshTokenSkeletonRows
                }
            case .combined:
                firstRefreshCombinedSkeletonRows
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private var firstRefreshCoinSkeletonRows: some View {
        ForEach(firstRefreshSkeletonCoins, id: \.chain.rawValue) { row in
            firstRefreshSkeletonRow {
                AssetRow(
                    chain: row.chain,
                    tokenSymbol: row.chain.ticker,
                    nativeAmount: row.amount,
                    nativeDecimals: min(row.chain.nativeDecimals, 8),
                    fiatValue: row.fiatValue,
                    fiatCurrencyCode: row.fiatCurrencyCode
                )
            }
        }
    }

    @ViewBuilder
    private var firstRefreshTokenSkeletonRows: some View {
        ForEach(firstRefreshSkeletonTokens, id: \.id) { row in
            firstRefreshSkeletonRow {
                supportedTokenRow(row)
            }
        }
    }

    @ViewBuilder
    private var firstRefreshCombinedSkeletonRows: some View {
        ForEach(firstRefreshSkeletonCoins.prefix(3), id: \.chain.rawValue) { row in
            firstRefreshSkeletonRow {
                AssetRow(
                    chain: row.chain,
                    tokenSymbol: row.chain.ticker,
                    nativeAmount: row.amount,
                    nativeDecimals: min(row.chain.nativeDecimals, 8),
                    fiatValue: row.fiatValue,
                    fiatCurrencyCode: row.fiatCurrencyCode
                )
            }
        }

        ForEach(firstRefreshSkeletonTokens.prefix(2), id: \.id) { row in
            firstRefreshSkeletonRow {
                supportedTokenRow(row)
            }
        }
    }

    private func firstRefreshSkeletonRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Skeleton rows are no longer shown; kept as a no-op wrapper if
        // any call site remains during first-refresh refactor.
        content()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var firstRefreshSkeletonCoins: [WalletCoinSupportedRow] {
        [
            WalletCoinSupportedRow(chain: .tron, amount: .zero, fiatValue: .zero, fiatCurrencyCode: currencyCode),
            WalletCoinSupportedRow(chain: .ton, amount: .zero, fiatValue: .zero, fiatCurrencyCode: currencyCode),
            WalletCoinSupportedRow(chain: .solana, amount: .zero, fiatValue: .zero, fiatCurrencyCode: currencyCode),
            WalletCoinSupportedRow(chain: .ethereum, amount: .zero, fiatValue: .zero, fiatCurrencyCode: currencyCode),
            WalletCoinSupportedRow(chain: .bitcoin, amount: .zero, fiatValue: .zero, fiatCurrencyCode: currencyCode)
        ]
    }

    private var firstRefreshSkeletonTokens: [WalletTokenSupportedDisplayRow] {
        [
            WalletTokenSupportedDisplayRow(
                id: "skeleton.solana.usdt",
                chain: .solana,
                symbol: "USDT",
                name: "Tether USD",
                contract: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
                amount: .zero,
                fiatValue: .zero,
                fiatCurrencyCode: currencyCode
            ),
            WalletTokenSupportedDisplayRow(
                id: "skeleton.tron.usdt",
                chain: .tron,
                symbol: "USDT",
                name: "Tether USD",
                contract: "TXLAQ63Xg1NAzckPwKHvzw7CSEmLMEqcdj",
                amount: .zero,
                fiatValue: .zero,
                fiatCurrencyCode: currencyCode
            ),
            WalletTokenSupportedDisplayRow(
                id: "skeleton.ethereum.usdc",
                chain: .ethereum,
                symbol: "USDC",
                name: "USD Coin",
                contract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                amount: .zero,
                fiatValue: .zero,
                fiatCurrencyCode: currencyCode
            ),
            WalletTokenSupportedDisplayRow(
                id: "skeleton.base.usdc",
                chain: .base,
                symbol: "USDC",
                name: "USD Coin",
                contract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
                amount: .zero,
                fiatValue: .zero,
                fiatCurrencyCode: currencyCode
            )
        ]
    }

    // MARK: - Coins rows (native coins, 10-row cap + Show all)

    /// Coin rows — one `AssetRow` per supported native chain.
    /// Capped at `holdingsDisplayCap` (10). When the wallet holds
    /// more than 10 coins, the trailing "Show all" navigation row
    /// pushes to `WalletHomeDestination.allSupported`. When the
    /// wallet holds 10 or fewer, no trailing row (everything held
    /// fits in the section).
    @ViewBuilder
    private var coinRows: some View {
        // The user's Filter & Sort preferences are applied off-body
        // via the pure `WalletHomeFilterApply.apply(coins:with:)`
        // helper inside `rebuildFilteredRows()`; this section just
        // renders the memoized result. The base `coinDisplayRows`
        // is the home-screen sort (held-first canonical); the
        // filter re-sorts per the user's chosen key + direction and
        // drops hidden chains / hidden assets / zero balances per
        // the toggles. Pinned rows ride at the head of the array.
        let allRows = filteredCoinRows
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = WalletHomeFilterApply.partitionPinned(coins: allRows, pinned: pinnedSet)
        let nonPinnedDisplayed = Array(nonPinned.prefix(holdingsDisplayCap))
        let hasMore = nonPinned.count > holdingsDisplayCap

        // **2026-06-09 perf.** Stable identity via
        // `chain.rawValue` instead of `.enumerated().offset`.
        // The offset shifts every time the array re-sorts, which
        // destroys + recreates every row and re-runs icon tasks.
        // Stable id = SwiftUI reuses the row + icon view.
        if pinned.isEmpty && nonPinned.isEmpty {
            holdingsEmptyStateRow(kind: .coins)
        } else {
            ForEach(pinned, id: \.chain.rawValue) { row in
                coinNavigationRow(row)
            }

            ForEach(nonPinnedDisplayed, id: \.chain.rawValue) { row in
                coinNavigationRow(row)
            }
            if hasMore { showAllRow }
        }
        // No section header — the segmented picker in the holdings row is
        // the canonical "you're looking at Coins" affordance now
        // (2026-06-09). Stacking a "Coins" header on top of an
        // already-selected "Coins" tab would be noise.
    }

    // MARK: - Tokens rows (registry tokens, 10-row cap + Show all)

    /// Token rows — one supported display token per row. Capped at
    /// `holdingsDisplayCap` (10) with the same "Show all" trailing-row
    /// rule as coins.
    @ViewBuilder
    private var tokenRows: some View {
        // Memoized filter + sort — same rationale as `coinRows`.
        // Pinned tokens stay at the head of this stable section.
        let allRows = filteredTokenRows
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = WalletHomeFilterApply.partitionPinned(tokens: allRows, pinned: pinnedSet)
        let nonPinnedDisplayed = Array(nonPinned.prefix(holdingsDisplayCap))
        let hasMore = nonPinned.count > holdingsDisplayCap

        if pinned.isEmpty && nonPinned.isEmpty {
            holdingsEmptyStateRow(kind: .tokens)
        } else {
            ForEach(pinned, id: \.id) { row in
                tokenNavigationRow(row)
            }

            ForEach(nonPinnedDisplayed, id: \.id) { row in
                tokenNavigationRow(row)
            }
            if hasMore { showAllRow }
        }
        // Header omitted — see the coinRows note above.
    }

    // MARK: - Navigation row wrappers (asset-detail routing)

    /// Wrap a coin row in a `NavigationLink(value:)` so tap routes
    /// to `AssetDetailView` via the wallet-home's NavigationStack.
    /// Same DNA as the activity-row Button wrapper — keeps the row
    /// composition pure and the navigation responsibility on the
    /// parent surface.
    ///
    /// Per Rule #19 §C, NavigationLink content is a navigation
    /// affordance (not a CTA), so plain composition is allowed.
    @ViewBuilder
    private func coinNavigationRow(_ row: WalletCoinSupportedRow) -> some View {
        let assetID = WalletHomeFilterPreferences.assetID(coin: row)
        NavigationLink(value: WalletHomeDestination.assetDetail(.nativeCoin(row.chain))) {
            AssetRow(
                chain: row.chain,
                tokenSymbol: row.chain.ticker,
                nativeAmount: row.amount,
                nativeDecimals: min(row.chain.nativeDecimals, 8),
                fiatValue: row.fiatValue,
                fiatCurrencyCode: row.fiatCurrencyCode,
                detailCaption: solanaPathCaption(for: row.chain)
            )
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
        .accessibilityLabel(Text(verbatim: String(format: String.apertureLocalized("%@ details"), row.chain.displayName)))
        .contextMenu {
            pinSwipeButton(assetID: assetID)
            hideSwipeButton(assetID: assetID)
        }
    }

    /// Active Solana path label under the SOL home row (Phantom default;
    /// Trust Wallet when selected in Receive).
    private func solanaPathCaption(for chain: SupportedChain) -> String? {
        guard chain == .solana, let wallet = contentWallet else { return nil }
        let solanaRows = wallet.addresses.filter { $0.chainRaw == SupportedChain.solana.rawValue }
        guard solanaRows.count > 1 else { return nil }
        let preferred = solanaRows.first(where: \.isReceivePreferred) ?? solanaRows.first
        guard let path = preferred?.derivationPath,
              let style = SolanaPathStyle.parse(path)?.style else {
            return "Phantom path"
        }
        return "\(style.title) path"
    }

    /// Wrap a token row in a `NavigationLink(value:)`. The
    /// destination is the symbol-scoped asset detail — tapping
    /// "USDC on Polygon" lands on the cross-network USDC view (not
    /// the USDC-on-Polygon-only sub-view; the user reaches that
    /// from inside the asset detail's Networks section).
    @ViewBuilder
    private func tokenNavigationRow(_ row: WalletTokenSupportedDisplayRow) -> some View {
        let assetID = WalletHomeFilterPreferences.assetID(token: row)
        NavigationLink(value: WalletHomeDestination.assetDetail(.token(symbol: row.symbol))) {
            supportedTokenRow(row)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
        .accessibilityLabel(Text(verbatim: String(format: String.apertureLocalized("%@ details"), row.symbol)))
        .contextMenu {
            pinSwipeButton(assetID: assetID)
            hideSwipeButton(assetID: assetID)
        }
    }

    // MARK: - Pin / Hide swipe actions (2026-06-20)

    private func isPinned(_ assetID: String) -> Bool {
        WalletHomeFilterPreferences.decode(filterPinnedAssetsJSON).contains(assetID)
    }

    @ViewBuilder
    private func pinSwipeButton(assetID: String) -> some View {
        Button {
            var set = WalletHomeFilterPreferences.decode(filterPinnedAssetsJSON)
            if set.contains(assetID) { set.remove(assetID) } else { set.insert(assetID) }
            filterPinnedAssetsJSON = WalletHomeFilterPreferences.encode(set)
            UniHapticEngine.shared.play(.selection)
        } label: {
            Label(isPinned(assetID) ? "Unpin" : "Pin",
                  systemImage: isPinned(assetID) ? "pin.slash.fill" : "pin.fill")
        }
        .tint(UniColors.Tint.accent)
    }

    @ViewBuilder
    private func hideSwipeButton(assetID: String) -> some View {
        Button {
            var set = WalletHomeFilterPreferences.decode(filterHiddenAssetsJSON)
            set.insert(assetID)
            filterHiddenAssetsJSON = WalletHomeFilterPreferences.encode(set)
            UniHapticEngine.shared.play(.selection)
        } label: {
            Label("Hide", systemImage: "eye.slash.fill")
        }
        .tint(UniColors.Icon.secondary)
    }

    // MARK: - Combined section (Filter view mode = .combined)

    /// **Combined holdings section** — every coin + every token in
    /// one unified, filter-sorted list. Renders only when the
    /// Filter & Sort sheet's "Style" is `.combined`. The Coins /
    /// Tokens segmented switcher stays visible in the holdings control
    /// row, but is disabled because the picker would be a no-op in this mode.
    ///
    /// **Why one ForEach and not two stacked Sections.** The whole
    /// point of `.combined` is "one portfolio, sorted by my chosen
    /// key" — stacking sections re-introduces the split that
    /// `.combined` exists to dissolve. The rows are emitted in
    /// pre-sorted order: every coin and every token together,
    /// sorted by `(filterSortKey, filterSortDirection)`.
    ///
    /// **Row anatomy.** Coin rows use `AssetRow` (44pt mark + chain
    /// name + native amount + fiat). Token rows use
    /// `supportedTokenRow(_:)` (44pt token mark + symbol + chain
    /// name + amount + fiat). Same anatomy as their respective
    /// sections in `.split` mode — visual consistency across modes
    /// means the user reads the same rows regardless of which mode
    /// they picked (Rule #2 §A.5).
    ///
    /// **Sort behavior across kinds.** The pure helper sorts each
    /// list independently then we merge. To keep the sort honest in
    /// `.combined` we apply the same comparator across an interleaved
    /// sequence by mapping both row kinds onto a common comparable
    /// surface (chain + amount + fiatValue + name + symbol).
    @ViewBuilder
    private var combinedSection: some View {
        let merged = combinedFilteredRows  // already sorted; pinned at the head
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = partitionPinnedCombined(merged, pinnedSet: pinnedSet)

        // Pinned rows always at the head, regardless of group-by.
        if !pinned.isEmpty {
            Section {
                holdingsControlsListRow

                ForEach(pinned, id: \.id) { item in
                    combinedRow(item)
                }
            } header: {
                Text("Pinned")
            }
        }

        // Group-by: chain → one Section per chain (sorted alpha by
        // chain display name); none → flat Section with the
        // 10-row cap + Show all.
        switch filterGroupBy {
        case .none:
            let displayed = Array(nonPinned.prefix(holdingsDisplayCap))
            let hasMore = nonPinned.count > holdingsDisplayCap
            Section {
                if pinned.isEmpty {
                    holdingsControlsListRow
                }

                if displayed.isEmpty {
                    holdingsEmptyStateRow(kind: .combined)
                } else {
                    ForEach(displayed, id: \.id) { item in
                        combinedRow(item)
                    }
                    if hasMore { showAllRow }
                }
            }
        case .chain:
            // Group nonPinned by chain. Sections rendered in
            // alphabetical order of `chain.displayName`. Within
            // each section, rows retain their pre-sorted order
            // (the merged sort that `combinedFilteredRows` produced).
            let groups = groupByChain(nonPinned)
            if groups.isEmpty && pinned.isEmpty {
                Section {
                    holdingsControlsListRow
                    holdingsEmptyStateRow(kind: .combined)
                }
            }
            ForEach(groups, id: \.chain) { group in
                Section {
                    if pinned.isEmpty && group.chain == groups.first?.chain {
                        holdingsControlsListRow
                    }

                    ForEach(group.items, id: \.id) { item in
                        combinedRow(item)
                    }
                } header: {
                    Text(verbatim: group.chain.displayName)
                }
            }
        }
    }

    /// Common row builder used by both `combinedSection`'s flat and
    /// grouped shapes plus the pinned head section. Switches between
    /// `AssetRow` for coins and `supportedTokenRow` for tokens. Each
    /// branch wraps in a `NavigationLink(value:)` so tap routes to the
    /// asset detail (Rule #19 §C — navigation affordance, not a CTA).
    @ViewBuilder
    private func combinedRow(_ item: CombinedHoldingRow) -> some View {
        switch item {
        case .coin(let row):
            coinNavigationRow(row)
        case .token(let row):
            tokenNavigationRow(row)
        }
    }

    /// Split a `combinedFilteredRows` array into pinned + non-pinned
    /// keeping the source order in each bucket. Mirrors the
    /// per-kind `partitionPinned` helpers in the pure applier.
    private func partitionPinnedCombined(
        _ rows: [CombinedHoldingRow],
        pinnedSet: Set<String>
    ) -> (pinned: [CombinedHoldingRow], nonPinned: [CombinedHoldingRow]) {
        guard !pinnedSet.isEmpty else { return ([], rows) }
        var pinned: [CombinedHoldingRow] = []
        var nonPinned: [CombinedHoldingRow] = []
        for item in rows {
            if pinnedSet.contains(item.assetID) {
                pinned.append(item)
            } else {
                nonPinned.append(item)
            }
        }
        return (pinned, nonPinned)
    }

    /// One chain bucket for the grouped combined section.
    private struct ChainGroup {
        let chain: SupportedChain
        let items: [CombinedHoldingRow]
    }

    /// Group an interleaved `[CombinedHoldingRow]` by chain.
    /// Sections render in alphabetical order of chain display name
    /// so the grouped view reads as an A→Z index of chains the
    /// user holds. Within each group, items keep their pre-sort
    /// order from `combinedFilteredRows`.
    private func groupByChain(_ rows: [CombinedHoldingRow]) -> [ChainGroup] {
        var buckets: [SupportedChain: [CombinedHoldingRow]] = [:]
        for item in rows {
            let chain: SupportedChain
            switch item {
            case .coin(let r):  chain = r.chain
            case .token(let r): chain = r.chain
            }
            buckets[chain, default: []].append(item)
        }
        return buckets
            .sorted { a, b in
                a.key.displayName.localizedStandardCompare(b.key.displayName) == .orderedAscending
            }
            .map { ChainGroup(chain: $0.key, items: $0.value) }
    }

    /// Inline renderer for a `WalletTokenSupportedDisplayRow`. Same
    /// 44pt mark + symbol/chain subtitle + amount/fiat anatomy as
    /// `TokenSupportedRow` in `AllSupportedAssetsView`. Inlined here
    /// rather than lifted to a top-level component because it's two
    /// call sites max and the spacing decisions are home-screen-
    /// specific.
    @ViewBuilder
    private func supportedTokenRow(_ row: WalletTokenSupportedDisplayRow) -> some View {
        // 2026-06-18 Part 3.5 — the value-typed, `.equatable()` row leaf so its
        // body (CoinMark + labels) is skipped when the row model is unchanged.
        // Not `.equatable()` — privacy hide must re-render amounts when
        // `balancePrivacyEnabled` flips (Equatable would skip the body).
        SupportedTokenRow(row: row)
    }

    // MARK: - Empty holdings section

    /// Single empty-state row in a section labeled "Holdings".
    /// Only appears when both `coinHoldings` and `tokenHoldings`
    /// are empty (a fresh wallet whose scanner hasn't filled yet,
    /// or a wallet that genuinely holds nothing).
    @ViewBuilder
    private var emptyHoldingsSection: some View {
        Section {
            holdingsEmptyStateRow(kind: .combined)
        } header: {
            Text("Holdings")
        }
    }

    private enum HoldingsEmptyKind: Equatable {
        case coins
        case tokens
        case combined
    }

    @ViewBuilder
    private func holdingsEmptyStateRow(kind: HoldingsEmptyKind) -> some View {
        UniListEmptyState(
            title: holdingsEmptyTitle(kind: kind),
            detail: holdingsEmptyDetail(kind: kind),
            mark: holdingsEmptyMark(kind: kind),
            minHeight: 240
        )
    }

    private func holdingsEmptyTitle(kind: HoldingsEmptyKind) -> LocalizedStringKey {
        if !hasHeldBalance {
            return "This wallet is empty."
        }
        switch kind {
        case .coins:
            return "No coins match the filter."
        case .tokens:
            return "No tokens match the filter."
        case .combined:
            return "No assets match the filter."
        }
    }

    private func holdingsEmptyDetail(kind: HoldingsEmptyKind) -> LocalizedStringKey {
        if !hasHeldBalance {
            return "Receive crypto or turn off Only with balance to browse supported assets."
        }
        if kind == .coins && filterInputs.assetType == .tokens {
            return "The Type filter is set to Tokens. Switch it to All or Coins to show native coins."
        }
        if kind == .tokens && filterInputs.assetType == .coins {
            return "The Type filter is set to Coins. Switch it to All or Tokens to show tokens."
        }
        return "Adjust Filter & Sort to bring hidden assets back into view."
    }

    private func holdingsEmptyMark(kind: HoldingsEmptyKind) -> UniEmptyState.Mark {
        hasHeldBalance ? .icon(systemName: "line.3.horizontal.decrease") : .iris
    }

    private var hasHeldBalance: Bool {
        coinDisplayRows.contains { $0.isHeld }
            || tokenDisplayRows.contains { $0.isHeld }
    }

    private var shouldShowFreshWalletBalanceEmptyState: Bool {
        contentWallet != nil
            && !hasAnyCurrentBalance
    }

    private var hasAnyCurrentBalance: Bool {
        allHeldRows.contains { !isZeroRawBalance($0.balance.rawBalance) }
    }

    private func isZeroRawBalance(_ rawBalance: String) -> Bool {
        let trimmed = rawBalance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let decimal = Decimal(string: trimmed) {
            return decimal == .zero
        }
        return trimmed.allSatisfy { $0 == "0" }
    }

    // MARK: - Network failure surfaces (2026-06-12)

    /// Honest total-failure state. Appears only when the most recent
    /// completed refresh for THIS wallet left failed chains AND no
    /// balance row has ever persisted (fresh import, every chain
    /// unreachable). Same `UniEmptyState` primitive as the calm empty
    /// surfaces so the error reads as part of the family — restrained,
    /// not alarming (Rule #16 §B: no red as decoration; an unreachable
    /// network is a circumstance, not an error of the user's making).
    /// Retry is a real CTA per Rule #19 — `UniButton(.secondary)`
    /// driving the same user-initiated path as pull-to-refresh, so a
    /// wedged pipeline is cancelled rather than joined.
    @ViewBuilder
    private var networkErrorSection: some View {
        Section {
            UniEmptyState(
                title: "Couldn't reach the network",
                detail: "Your balances will appear once Aperture can reach the chains.",
                mark: .icon(systemName: "wifi.slash")
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())

            UniButton(
                title: isAnyRefreshInFlight ? "Retrying…" : "Retry",
                variant: .secondary,
                isLoading: isAnyRefreshInFlight,
                isEnabled: !isAnyRefreshInFlight
            ) {
                Task { await runRefresh(userInitiated: true) }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: UniSpacing.s,
                leading: UniSpacing.m,
                bottom: 0,
                trailing: UniSpacing.m
            ))
        } header: {
            Text("Holdings")
        }
    }

    // MARK: - Show all row

    /// "Show all" navigation row that lives at the foot of an
    /// overflowed Coins or Tokens section. Uses a value-based
    /// `NavigationLink` so the parent `NavigationStack`'s
    /// `.navigationDestination(for: WalletHomeDestination.self)`
    /// owns the routing — same pattern as the transaction-detail
    /// route. Rule #19 §C allows hand-composed NavigationLink
    /// content (navigation, not commit).
    ///
    /// The row chrome matches a Settings-style "See All" footer:
    /// uppercase-style text on the leading edge, system chevron on
    /// the trailing. The chevron auto-mirrors in RTL.
    @ViewBuilder
    private var showAllRow: some View {
        NavigationLink(value: WalletHomeDestination.allSupported) {
            HStack(spacing: UniSpacing.s) {
                Text("Show all")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Button.text)
                Spacer(minLength: UniSpacing.s)
            }
            .padding(.vertical, UniSpacing.xs)
            .uniListRowHitTarget()
        }
        .accessibilityLabel(Text("Show all supported assets"))
    }

    /// Display cap for both the Coins and Tokens sections — the
    /// home screen shows the first 10 of each, then a "Show all"
    /// navigation row when the holdings exceed the cap.
    private let holdingsDisplayCap: Int = 10

    /// Coins held — the wallet's native-coin balances. One row per
    /// `(chain, native balance)`. Sorted by fiat desc so the
    /// largest holding leads.
    ///
    /// A "native" balance is identified by `tokenContract == nil`
    /// AND `tokenSymbol == chain.ticker`. The native-balance upsert
    /// path in `WalletRefreshCoordinator` writes exactly this shape.
    private var coinHoldings: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        balances.filter { entry in
            entry.balance.tokenContract == nil
                && entry.balance.tokenSymbol == entry.chain.ticker
        }
    }

    /// Tokens held — every non-native balance. One row per
    /// `(chain, token balance)`. Sorted by fiat desc.
    private var tokenHoldings: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        balances.filter { entry in
            entry.balance.tokenContract != nil
                || entry.balance.tokenSymbol != entry.chain.ticker
        }
    }

    // MARK: - Display rows (held + supported, capped at 10)
    //
    // The two computed rows below feed the home screen's Coins and
    // Tokens sections. They enumerate EVERY supported asset (held +
    // not-held) per the user's 2026-06-08 direction ("show all
    // supported coins and tokens — even if balance is 0"), then
    // sort held-first so the user's actual holdings lead. The
    // `WalletSupportedRowBuilders` builders enumerate every
    // registry — same source the "Show all" destination uses.

    /// All balances on the active wallet, raw — including zero-string
    /// rows. The supported-rows builder needs the full set so it can
    /// determine whether each registry entry is held; the existing
    /// `balances` property filters to non-zero, so we re-compute here
    /// without that filter.
    private var allHeldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        allHeldRowsMemo ?? computeAllHeldRows()
    }

    private func computeAllHeldRows() -> [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        guard let wallet = contentWallet else { return [] }
        // Read balances from the top-level `allBalanceRecords` GRDB observation (live
        // across cross-context inserts + scalar updates) and attribute each to
        // a chain via the wallet's own address records — NOT the insert-stale
        // `address.balances` relationship.
        // Solana dual-path: home shows preferred path only (matches Send + rebuild).
        let allowedIds = displayAddressIds(for: wallet)
        let chainByAddressId = chainByActiveAddressId(wallet)
        var result: [(SupportedChain, TokenBalanceRecord)] = []
        for balance in allBalanceRecords {
            guard let aid = balance.addressId ?? balance.address?.id,
                  allowedIds.contains(aid),
                  let chain = chainByAddressId[aid],
                  !balance.rawBalance.isEmpty else { continue }
            result.append((chain, balance))
        }
        return result
    }

    /// Maps each of the active wallet's address UUIDs to its chain, built from
    /// the wallet's own (stable, cross-context-safe) address records — so the
    /// balance rows from the top-level `allBalanceRecords` GRDB observation can be
    /// attributed to a chain without traversing the insert-stale `balances`
    /// relationship.
    private func chainByActiveAddressId(_ wallet: WalletRecord) -> [UUID: SupportedChain] {
        var map: [UUID: SupportedChain] = [:]
        for address in wallet.addresses {
            if let chain = SupportedChain(rawValue: address.chainRaw) {
                map[address.id] = chain
            }
        }
        return map
    }

    // MARK: - Filter & Sort derived state (rebuilt off-body)

    /// Change fingerprint over every persisted filter preference plus
    /// the transient search text. One `.onChange` over the joined
    /// string replaces eleven separate observers; any backing value
    /// change flips the fingerprint and triggers one rebuild of the
    /// memoized `filterInputs` + filtered row projections.
    private var filterPreferenceFingerprint: String {
        [
            filterViewModeRaw,
            filterSortKeyRaw,
            filterSortDirectionRaw,
            String(filterOnlyWithBalance),
            filterHiddenAssetsJSON,
            filterHiddenChainsJSON,
            filterAssetTypeRaw,
            filterGroupByRaw,
            String(filterMinFiatThreshold),
            filterSelectedNetworksJSON,
            filterPinnedAssetsJSON,
            filterSearchText
        ].joined(separator: "\u{1F}")
    }

    /// Cheap GRDB change proxy — balance-row count across the
    /// active wallet's addresses. Counting is O(addresses) per body
    /// pass; the expensive registry enumeration + flatMap + sort only
    /// runs when the count actually changes. Value-only updates (a
    /// refresh re-pricing existing rows) are caught by the explicit
    /// rebuild at the end of `runRefresh()` and the refresh-completion
    /// observer. (Transactions used to have a parallel proxy here, but
    /// they now read live from a top-level GRDB observation — see
    /// `allTransactionRecords` — so no relationship-count proxy is
    /// needed, and the relationship-count proxy never saw cross-context
    /// inserts anyway, which was the live-tx bug.)
    /// A VALUE fingerprint of the active wallet's balance rows, read from the
    /// top-level `allBalanceRecords` GRDB observation (NOT the insert-stale `balances`
    /// relationship). It changes whenever a balance row is inserted, removed,
    /// OR its value updates — so the `.onChange` rebuild of the display
    /// projections fires on every real balance change, not only when the ROW
    /// COUNT changes. This replaces the old relationship-count proxy that
    /// silently missed scalar updates and cross-context inserts (the
    /// stale-balance bug: a received transaction didn't reflect in the holdings
    /// until an app relaunch). `count` catches add/remove, `newest` catches a
    /// re-fetch even at an unchanged value, and `fiatSum` catches a value move.
    private var balanceRowsRevision: String {
        activeBalancesObservation.revision
    }

    /// Decode the `@GRDBStorage`-bound preference values into the
    /// memoized `filterInputs` snapshot. Same construction the old
    /// per-body computed property performed — now run only when the
    /// preference fingerprint changes (plus once from `.task`).
    private func rebuildFilterInputs() {
        filterInputs = WalletHomeFilterApply.Inputs(
            viewMode: WalletHomeFilterPreferences.ViewMode(rawValue: filterViewModeRaw)
                ?? WalletHomeFilterPreferences.defaultViewMode,
            sortKey: WalletHomeFilterPreferences.SortKey(rawValue: filterSortKeyRaw)
                ?? WalletHomeFilterPreferences.defaultSortKey,
            direction: WalletHomeFilterPreferences.SortDirection(rawValue: filterSortDirectionRaw)
                ?? WalletHomeFilterPreferences.defaultSortDirection,
            onlyWithBalance: filterOnlyWithBalance,
            hiddenAssets: WalletHomeFilterPreferences.decode(filterHiddenAssetsJSON),
            hiddenChains: WalletHomeFilterPreferences.decode(filterHiddenChainsJSON),
            assetType: WalletHomeFilterPreferences.AssetType(rawValue: filterAssetTypeRaw)
                ?? WalletHomeFilterPreferences.defaultAssetType,
            groupBy: WalletHomeFilterPreferences.GroupBy(rawValue: filterGroupByRaw)
                ?? WalletHomeFilterPreferences.defaultGroupBy,
            minFiatThreshold: Decimal(filterMinFiatThreshold),
            selectedNetworks: WalletHomeFilterPreferences.decode(filterSelectedNetworksJSON),
            pinnedAssets: WalletHomeFilterPreferences.decode(filterPinnedAssetsJSON),
            searchText: filterSearchText
        )
    }

    /// Typed group-by reader for the combined section's branch.
    private var filterGroupBy: WalletHomeFilterPreferences.GroupBy {
        filterInputs.groupBy
    }

    /// Typed view-mode reader for the chrome section's conditional
    /// `holdingsTabPicker` and `holdingsBody`'s branch.
    private var filterViewMode: WalletHomeFilterPreferences.ViewMode {
        filterInputs.viewMode
    }

    /// Rebuild the unfiltered display rows, then re-derive the
    /// filtered projections.
    ///
    /// Coins rows — every `SupportedChain.allCases`, held coins
    /// first (fiat desc), then unheld in canonical chain order. The
    /// home screen takes the first 10; the "Show all" destination
    /// shows the rest. Tokens rows — every supported token across
    /// all registries, held first (fiat desc), then unheld
    /// alphabetically by `(symbol, chain)`.
    /// Supported chains, read from the DB (`ChainRecord`) and mapped to
    /// the builder's shape. Falls back to the identical static
    /// `AssetCatalog` until the seed lands (Rule #27 §D).
    private var catalogChains: [CatalogChain] {
        let fromStore = chainRecords.compactMap { $0.catalogChain }
        return fromStore.isEmpty ? AssetCatalog.allChains : fromStore
    }

    /// Supported tokens, read from the DB (`AssetRecord`), same fallback.
    private var catalogAssets: [CatalogAsset] {
        let fromStore = assetRecords.compactMap { $0.catalogAsset }
        return fromStore.isEmpty ? AssetCatalog.allAssets : fromStore
    }

    /// User-added custom tokens as value snapshots, gated on a still-known
    /// chain (an unknown `chainRaw` would erase to `.ethereum` in the
    /// snapshot — never display it as such). Merged into the token rows.
    private var customTokenSnapshots: [CustomTokenSnapshot] {
        customTokenRecords
            .filter { $0.hasKnownChain }
            .map { CustomTokenSnapshot(from: $0) }
    }

    /// Rebuild the base-collection caches (`balancesMemo`,
    /// `allHeldRowsMemo`). Cheap to run on every change trigger; the
    /// point is that the expensive build+sort happens HERE, on change,
    /// instead of on every body pass. See the memo block near the
    /// `@State` declarations.
    private func rebuildBalanceMemos() {
        allHeldRowsMemo = computeAllHeldRows()
        balancesMemo = computeBalances()
    }

    /// Rebuild the transaction cache (`allTransactionsMemo`). Folded
    /// into `rebuildDisplayRows()` (refresh completion / wallet switch)
    /// and triggered directly on `allTransactionRecords` count changes.
    private func rebuildTransactionMemos() {
        allTransactionsMemo = computeAllTransactions()
        // Immediate disk USD seed so recent activity never paints dust (P1 #11).
        let symbols = Array(Set((allTransactionsMemo ?? []).lazy.map { $0.tokenSymbol.uppercased() }))
        if !symbols.isEmpty {
            let seeded = ActivityFiat.usdPriceMapFromCache(symbols: symbols)
            if !seeded.isEmpty {
                usdActivityPrices = seeded
            }
        }
    }

    private func clearWalletScopedSnapshots() {
        balancesMemo = nil
        allHeldRowsMemo = nil
        allTransactionsMemo = nil
        coinDisplayRows = []
        tokenDisplayRows = []
        filteredCoinRows = []
        filteredTokenRows = []
        combinedFilteredRows = []
        // Keep last USD dust map until the new wallet's feed seeds —
        // never leave an empty map that would hide *all* activity.
        // loadDustPrices re-seeds for the active feed immediately.
    }

    /// O(1) key for the dust-price load — re-fires on wallet switch or a
    /// tx count change, the only moments the feed's symbol set can grow.
    private var dustPriceKey: String {
        "\(activeWalletIdRaw)|\(activeTransactionsObservation.revision)"
    }

    private func scheduleDisplayRowsRebuild(after delayNanoseconds: UInt64 = 120_000_000) {
        displayRebuildTask?.cancel()
        displayRebuildTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            rebuildDisplayRows()
        }
    }

    private func scheduleChainStateReconcile(after delayNanoseconds: UInt64 = 250_000_000) {
        let rawWalletId = activeWalletIdRaw
        let code = (CurrencyPreference.currency(for: currencyCode)?.code
            ?? CurrencyPreference.defaultCode).uppercased()
        chainReconcileTask?.cancel()
        chainReconcileTask = Task {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let walletId = UUID(uuidString: rawWalletId) else { return }
            _ = try? ChainStateRepository(database: AppDatabase.shared)
                .rebuild(walletId: walletId, fiatCurrencyCode: code)
        }
    }

    /// USD prices for the $0.20 dust gate: seed from disk **synchronously**
    /// so dust never flashes, then refresh live (P1 #11).
    private func loadDustPrices() async {
        let symbols = Array(Set(allTransactions.lazy.map { $0.tokenSymbol.uppercased() }))
        let seeded = ActivityFiat.usdPriceMapFromCache(symbols: symbols)
        if !seeded.isEmpty {
            usdActivityPrices = seeded
        }
        let map = await ActivityFiat.usdPriceMap(symbols: symbols)
        guard !Task.isCancelled else { return }
        usdActivityPrices = map
    }

    private func rebuildDisplayRows() {
        rebuildBalanceMemos()
        rebuildTransactionMemos()
        let held = allHeldRows
        let coinRows = WalletSupportedRowBuilders.coinRows(
            heldRows: held,
            currencyCode: currencyCode,
            chains: catalogChains
        )
        coinDisplayRows = coinRows.sorted { a, b in
            if a.isHeld != b.isHeld { return a.isHeld }
            if a.isHeld {
                let aFiat = a.fiatValue ?? .zero
                let bFiat = b.fiatValue ?? .zero
                if aFiat != bFiat { return aFiat > bFiat }
            }
            return a.chain.displayName.localizedStandardCompare(b.chain.displayName) == .orderedAscending
        }
        // Collapse to ONE row per token symbol (USDT once, not per network) —
        // the user picks the network inside the asset detail (2026-06-18).
        let tokenRows = WalletSupportedRowBuilders.collapseBySymbol(
            WalletSupportedRowBuilders.tokenRows(
                heldRows: held,
                currencyCode: currencyCode,
                assets: catalogAssets,
                customTokens: customTokenSnapshots
            ),
            currencyCode: currencyCode
        )
        tokenDisplayRows = tokenRows.sorted { a, b in
            if a.isHeld != b.isHeld { return a.isHeld }
            if a.isHeld {
                let aFiat = a.fiatValue ?? .zero
                let bFiat = b.fiatValue ?? .zero
                if aFiat != bFiat { return aFiat > bFiat }
            }
            let symbolOrder = a.symbol.localizedStandardCompare(b.symbol)
            if symbolOrder != .orderedSame {
                return symbolOrder == .orderedAscending
            }
            return a.chain.displayName.localizedStandardCompare(b.chain.displayName) == .orderedAscending
        }
        rebuildFilteredRows()
    }

    /// Re-derive the filtered + sorted projections from the cached
    /// display rows and the memoized filter inputs.
    ///
    /// **Combined-mode merged row list.** The pure helper produces
    /// two separately-filtered + separately-sorted lists; combined
    /// mode wants one stable interleave that honors the same sort
    /// key + direction. We map each into a small enum
    /// `CombinedHoldingRow`, concat, then re-sort the union by the
    /// shared comparator so the user reads one honestly-ordered list.
    private func rebuildFilteredRows() {
        filteredCoinRows = WalletHomeFilterApply.apply(coins: coinDisplayRows, with: filterInputs)
        filteredTokenRows = WalletHomeFilterApply.apply(tokens: tokenDisplayRows, with: filterInputs)

        let merged: [CombinedHoldingRow] =
            filteredCoinRows.map { .coin($0) } + filteredTokenRows.map { .token($0) }

        let sortKey = filterInputs.sortKey
        let direction = filterInputs.direction
        let ascending = direction == .ascending

        combinedFilteredRows = merged.sorted { a, b in
            switch sortKey {
            case .name:
                let order = a.sortName.localizedStandardCompare(b.sortName)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .symbol:
                let order = a.sortSymbol.localizedStandardCompare(b.sortSymbol)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .balance:
                return ascending ? a.sortAmount < b.sortAmount : a.sortAmount > b.sortAmount
            case .value:
                let aFiat = a.sortFiat
                let bFiat = b.sortFiat
                if aFiat == bFiat {
                    return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
                }
                return ascending ? aFiat < bFiat : aFiat > bFiat
            case .chain:
                let ai = a.canonicalChainIndex
                let bi = b.canonicalChainIndex
                if ai == bi {
                    return a.sortSymbol.localizedStandardCompare(b.sortSymbol) == .orderedAscending
                }
                return ascending ? ai < bi : ai > bi
            }
        }
    }

    // MARK: - Activity section (native List)

    /// Recent-activity section. Branches two ways: empty production
    /// wallet (`UniEmptyState`) and the normal recent-ten list. Each
    /// transaction row wraps `ActivityRow` in a `Button` so the row
    /// tap routes to the transaction detail.
    @ViewBuilder
    private var activityListSection: some View {
        Section {
            if recentTransactions.isEmpty {
                emptyActivity
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            } else {
                productionActivityRows
            }
        } header: {
            activityHeader
        }
    }

    /// **Recent-activity section header.** Title leading, a quiet
    /// "View all" link trailing — the native iOS "See All" geometry
    /// (Photos, App Store, Wallet). The link routes to
    /// `WalletActivityView` for the full, uncapped history.
    ///
    /// **Restraint (Rule #2 §D.5):** the link is the section's *only*
    /// extra affordance — no second footer button. It appears ONLY
    /// when the wallet holds more transactions than the five shown
    /// (`allTransactions.count > 5`); with five or fewer there is
    /// nothing more to see, so the header is the plain title alone.
    ///
    /// **Not a CTA (Rule #19 §C):** "View all" navigates, it does not
    /// commit the user to a next state — so it is a plain `Button`
    /// styled as a quiet text link via `UniColors.Text.link`, not a
    /// `UniButton`.
    @ViewBuilder
    private var activityHeader: some View {
        if allTransactions.count > 5 {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent activity")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .textCase(nil)
                Spacer(minLength: UniSpacing.s)
                Button {
                    navigationPath.append(WalletHomeDestination.allActivity)
                } label: {
                    Text("View all")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.link)
                        .textCase(nil)
                }
                .buttonStyle(.uniTactile)
                .accessibilityHint(Text("Shows the full transaction history"))
            }
        } else {
            Text("Recent activity")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .textCase(nil)
        }
    }

    /// Production activity rows — each `TransactionRecord` becomes
    /// one tappable list row. The `Button` carries the navigation
    /// dispatch; the row's tap target is the row itself thanks to
    /// `.contentShape` on `ActivityRow` and `.buttonStyle(.uniTactile)`.
    /// Production activity rows — extracted into the value-typed, `.equatable()`
    /// `RecentActivityRows` leaf (2026-06-18, Part 3.5). The parent maps the 5
    /// recent transactions into a small `ActivityRowModel` snapshot; the leaf
    /// then skips rebuilding the `ActivityRow` subtrees whenever that snapshot +
    /// currency are unchanged — so an unrelated GRDB merge that re-evaluates
    /// this body no longer reconstructs the activity rows.
    @ViewBuilder
    private var productionActivityRows: some View {
        RecentActivityRows(
            rows: recentActivityModels,
            currencyCode: currencyCode,
            cachedPrices: cachedPricesObservation.prices,
            onSelect: { navigationPath.append(WalletHomeDestination.transaction($0)) }
        )
    }

    /// **Activity empty state.** Sibling to `emptyHoldingsSection` — same
    /// iris watermark, same elliptical lift, same copy register. The
    /// two empty surfaces sit in the same list; reading them as a
    /// pair (Holdings empty / Activity empty) confirms the wallet is
    /// alive and waiting rather than broken or stuck.
    private var emptyActivity: some View {
        UniListEmptyState(
            title: "No activity yet.",
            detail: "Transactions appear here as they confirm on-chain.",
            minHeight: 240
        )
    }

    /// Shared wallet-switcher pill chrome (avatar + name + chevron).
    private func appBarPillLabel(name: String, label: Color, chip: Color) -> some View {
        HStack(spacing: UniSpacing.xs) {
            WalletAvatar(
                spec: appBarAvatarSpec,
                size: .toolbarPill,
                walletId: displayedWallet?.id
            )
            Text(verbatim: name)
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(label)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(label.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Capsule(style: .continuous).fill(chip))
    }

    // MARK: - Long-press context menu on the toolbar wallet pill
    //
    // The native iOS 26 idiom for "long-press the active-account
    // affordance to fast-switch" — Mail's account chip, Telegram /
    // Instagram's profile-tab avatar. iOS supplies the 0.5s long-press
    // recognition, the preview lift, and the Liquid Glass menu
    // material for free. Each row is a `Button` whose `Label.icon`
    // slot is the wallet's `WalletAvatar` so the user reads each
    // wallet's identity at switch time the same way they read it on
    // the wallet home (Rule #2 §A.5 consistency — same identity,
    // every surface).
    //
    // Rule #19 §C allows hand-composed Buttons inside system chrome
    // surfaces (context menus, toolbars, list rows) — they're
    // selection / routing affordances, not commit CTAs. The active
    // wallet's row carries a system checkmark in the text-row slot
    // (the iOS 26 menu pattern for "selected" — render the check
    // inline; iOS does not surface a selected-trait API for menu
    // items).
    @ViewBuilder
    private var walletPillContextMenu: some View {
        // One row per persisted wallet. Tapping a non-active row
        // flips `activeWalletIdRaw`; the wallet-home re-renders
        // through the existing GRDB observation machinery, the tab icon
        // re-renders, every consumer updates simultaneously.
        ForEach(allWallets) { wallet in
            Button {
                ActiveWalletPointer.set(wallet.id)
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
                    // 2026-06-09 — gradient-disc avatar per the
                    // design handoff. Same identity surface as
                    // every other wallet-identity slot.
                    WalletAvatar(spec: wallet.avatarSpec, size: .menuLeading, walletId: wallet.id)
                }
            }
        }

        Divider()

        // Customise wallet — opens `WalletIconPickerSheet` against
        // the active wallet via `.sheet(item:)` below. Only surfaces
        // when an active wallet exists.
        if let active = activeWallet {
            Button {
                customiseTargetId = active.id
            } label: {
                Label {
                    Text("Customise wallet")
                } icon: {
                    Image(uiImage: Self.contextMenuSymbol("paintpalette"))
                }
            }
        }

        // Add wallet — presents the existing create flow.
        Button {
            isShowingCreate = true
        } label: {
            Label {
                Text("Add wallet")
            } icon: {
                Image(uiImage: Self.contextMenuSymbol("plus"))
            }
        }

        // Manage wallets — stamps the deep-link token, then switches to
        // the Settings tab. `SettingsView` consumes the token on appear and
        // pushes Wallets onto its NavigationPath.
        Button {
            settingsDeepLink = "wallets"
            selectedTabRaw = MainTab.settings.rawValue
        } label: {
            Label {
                Text("Manage wallets")
            } icon: {
                Image(uiImage: Self.contextMenuSymbol("list.bullet"))
            }
        }
    }

    /// SF Symbol for SwiftUI context menus at Settings gray
    /// (`UniColors.Icon.secondary`). Menu items template-render symbols
    /// and can inherit the wallet-pill’s light-on-identity white, which
    /// washes icons out on the glass menu — `.alwaysOriginal` + secondary
    /// gray matches Settings / system menu chrome.
    private static func contextMenuSymbol(_ systemName: String) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let base = UIImage(systemName: systemName, withConfiguration: config)
            ?? UIImage()
        return base.withTintColor(
            UIColor(UniColors.Icon.secondary),
            renderingMode: .alwaysOriginal
        )
    }

    /// Identifiable shim so `.sheet(item:)` can present the icon
    /// picker against an optional `UUID`. Defined at file scope at
    /// the bottom of this file.
    private var customiseTargetBinding: Binding<WalletPillCustomiseTarget?> {
        Binding(
            get: { customiseTargetId.map { WalletPillCustomiseTarget(walletId: $0) } },
            set: { customiseTargetId = $0?.walletId }
        )
    }

    // MARK: - Derived state
    //
    // The pre-2026-06-09 `avatarSymbol` / `avatarColorHex` helpers
    // were retired in the gradient-disc avatar rewrite — the toolbar
    // pill now reads `activeWallet.avatarSpec` directly (hydrated by
    // `WalletAvatarSpec.hydrate(...)` with auto(name) fallback so the
    // disc is never blank).

    /// Single resolution rule for "the active wallet" (2026-06-13).
    /// The STORED id is authoritative, verified against the store; the
    /// GRDB observation is only an index. Every projection input — hero
    /// `balances`, `allHeldRows`, the memoized display/transaction
    /// rows, the chart inputs, the revision proxies — and the toolbar
    /// pill resolve through this one property, so the displayed
    /// selection and the displayed data derive from the same wallet
    /// id on every pass and cannot disagree.
    ///
    /// Resolution order:
    /// 1. Stored id has a GRDB observation match → that record (the normal,
    ///    cheap path; no store round-trip).
    /// 2. Stored id resolves directly against the store → that
    ///    record. Covers BOTH merge windows: an import the main
    ///    context hasn't merged yet (the 2026-06-12 pattern), and a
    ///    post-delete successor write that landed before this body
    ///    pass saw the updated query results.
    /// 3. Missing / empty id → nil until `ensureActiveWalletSet()` writes
    ///    the database-backed pointer. The render path never falls back to
    ///    a different wallet.
    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(
            rawID: activeWalletIdRaw,
            wallets: allWallets
        )
    }

    /// Stable order for hero paging (matches the switcher list).
    private var sortedWallets: [WalletRecord] {
        allWallets.sorted {
            if $0.sortOrder == $1.sortOrder { return $0.createdAt < $1.createdAt }
            return $0.sortOrder < $1.sortOrder
        }
    }

    /// Wallet shown in the hero page + app bar colour. Tracks page
    /// selection immediately so bar and hero cross-fade together,
    /// before the GRDB active-wallet write settles.
    private var displayedWallet: WalletRecord? {
        if let id = selectedPageWalletId {
            return sortedWallets.first(where: { $0.id == id }) ?? activeWallet
        }
        return activeWallet
    }

    /// **Single source of truth for home data** (holdings, activity, scopes).
    /// Always the settled hero page when set — never show another wallet's
    /// balances under this wallet's name (hero/pager vs `activeWalletId` desync).
    private var contentWallet: WalletRecord? {
        if let id = selectedPageWalletId,
           let wallet = sortedWallets.first(where: { $0.id == id }) {
            return wallet
        }
        return activeWallet
    }

    private var contentWalletId: UUID? { contentWallet?.id }

    private var appBarAvatarSpec: WalletAvatarSpec {
        // Mid-swipe: follow the nearer wallet so the pill matches the fade.
        let pair = WalletHomeHeroPager.swipePair(
            wallets: sortedWallets,
            progress: pageSwipeProgress
        )
        return pair.t < 0.5 ? pair.from : pair.to
    }

    private var prefersLightForeground: Bool {
        UniColors.WalletAvatar.prefersLightForeground(for: appBarAvatarSpec)
    }

    /// Identity fill blended across neighbouring wallets while swiping.
    private var appBarWalletColor: Color {
        let pair = WalletHomeHeroPager.swipePair(
            wallets: sortedWallets,
            progress: pageSwipeProgress
        )
        return Self.mixColors(
            UniColors.WalletAvatar.identityColor(for: pair.from),
            UniColors.WalletAvatar.identityColor(for: pair.to),
            t: pair.t
        )
    }

    /// Distance over which the nav bar eases from wallet identity → page floor.
    private var appBarFadeDistance: CGFloat { 160 }

    /// 0 = on hero (identity bar), 1 = scrolled (page-floor bar).
    private var appBarBlendProgress: CGFloat {
        min(1, max(0, homeScrollOffsetY / appBarFadeDistance))
    }

    /// Resolve Cloud / Midnight / Dark for scroll chrome.
    /// System follows iOS: light → Cloud, dark → Midnight.
    private var resolvedHomeAppearance: ApertureAppearance {
        switch apertureAppearance {
        case .system:
            return colorScheme == .dark ? .midnight : .cloud
        case .cloud, .midnight, .dark:
            return apertureAppearance
        }
    }

    /// Page-floor fills matching the app background in each mode.
    /// Hardcoded sRGB (not `UniColors`) so `UIColor.getRed` mix is stable —
    /// dynamic palette colours resolve inconsistently when mixed for the bar.
    /// Hexes match the shipped page floor: Cloud `#F5F5F7`, Midnight `#191A1E`, Dark `#000000`.
    private var pageFloorAppBarColor: Color {
        switch resolvedHomeAppearance {
        case .cloud, .system:
            return Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
        case .midnight:
            return Color(red: 25 / 255, green: 26 / 255, blue: 30 / 255)
        case .dark:
            return Color(red: 0, green: 0, blue: 0)
        }
    }

    /// Pill label once the bar has faded onto the page floor.
    private var scrolledPillLabelColor: Color {
        switch resolvedHomeAppearance {
        case .cloud, .system:
            return Color(red: 0, green: 0, blue: 0)
        case .midnight, .dark:
            return Color(red: 1, green: 1, blue: 1)
        }
    }

    /// Soft chip under the pill on the page-floor bar (card-like lift).
    private var scrolledPillChipColor: Color {
        switch resolvedHomeAppearance {
        case .cloud, .system:
            return Color(red: 1, green: 1, blue: 1).opacity(0.92)
        case .midnight:
            return Color(red: 33 / 255, green: 34 / 255, blue: 41 / 255)
        case .dark:
            return Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
        }
    }

    /// Nav bar fill: wallet identity at rest → page floor as the user scrolls.
    private var scrolledAppBarColor: Color {
        Self.mixColors(appBarWalletColor, pageFloorAppBarColor, t: appBarBlendProgress)
    }

    /// Stay on identity scheme until the bar is almost fully page-floor so
    /// we don’t snap `toolbarColorScheme` mid-scroll (layout flash / bounce).
    private var scrolledAppBarColorScheme: ColorScheme {
        if appBarBlendProgress < 0.9 {
            return prefersLightForeground ? .dark : .light
        }
        switch resolvedHomeAppearance {
        case .cloud, .system: return .light
        case .midnight, .dark: return .dark
        }
    }

    /// Linear sRGB mix for scroll-driven chrome (t in 0…1).
    private static func mixColors(_ a: Color, _ b: Color, t: CGFloat) -> Color {
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

    /// Keep hero page in lockstep with the active-wallet preference
    /// (sheet pick, external switch, first load, wallet list changes).
    /// - Parameter animated: when true (and multiple wallets), the balance
    ///   pager scrolls like a finger swipe onto the active wallet.
    private func syncPageSelectionFromActiveWallet(animated: Bool = false) {
        // Prefer the stored active id once it appears in the observed list —
        // don't fall back to `first` while the new wallet is mid-merge.
        let preferredId = UUID(uuidString: activeWalletIdRaw)
        let resolved: UUID? = {
            if let preferredId, sortedWallets.contains(where: { $0.id == preferredId }) {
                return preferredId
            }
            return activeWallet?.id ?? sortedWallets.first?.id
        }()

        guard let resolved else {
            selectedPageWalletId = nil
            return
        }

        let apply = {
            selectedPageWalletId = resolved
            pageSwipeProgress = CGFloat(
                sortedWallets.firstIndex(where: { $0.id == resolved }) ?? 0
            )
        }

        if selectedPageWalletId != resolved {
            if animated, sortedWallets.count > 1 {
                withAnimation(.snappy(duration: 0.38)) { apply() }
            } else {
                apply()
            }
        } else if selectedPageWalletId == nil {
            apply()
        }
    }

    /// Pager settled on a wallet: scope holdings to that page **now**, set
    /// active pointer, and refresh. Holdings must not wait for GRDBStorage.
    @MainActor
    private func activateWalletFromPager(_ walletId: UUID) {
        let isAlreadyActive = walletId.uuidString == activeWalletIdRaw

        Task {
            await WalletBackgroundWorkCoordinator.shared.cancelAllJobs(
                exceptWalletId: walletId
            )
        }

        // Immediate content scope — hero page and holdings stay one wallet.
        applyHomeContentWalletScope(walletId)

        if !isAlreadyActive {
            isApplyingPagerActiveWallet = true
            ActiveWalletPointer.set(walletId)
            UniHapticEngine.shared.play(.selection)
            // `.task(id: activeWalletIdRaw)` also refreshes after preference
            // propagates; fire now so we don't wait on that path alone.
            Task { await runRefresh(userInitiated: false) }
        } else {
            Task { await runRefresh(userInitiated: false) }
        }
    }

    private func handleReceiveSheetDismiss() {
        receivePath = NavigationPath()
    }

    private func handleSendSheetDismiss() {
        sendPath = NavigationPath()
        scanPrefill = nil
    }

    /// All balances belonging to the active wallet, sorted by fiat
    /// value descending (the biggest holding first). Respects the
    /// "Hide small balances" preference — balances whose
    /// `fiatValueCached` is below the user's threshold are filtered
    /// out (returns showAll → 0 threshold → everything visible).
    private var balances: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        balancesMemo ?? computeBalances()
    }

    private func computeBalances() -> [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        // contentWallet (settled hero page), not activeWallet alone — prevents
        // showing Imported Wallet 2 balances under a Wallet 3 pill.
        guard let wallet = contentWallet else { return [] }
        let threshold = Decimal(hideSmallThreshold)
        // Read from the top-level `allBalanceRecords` GRDB observation (live across
        // cross-context inserts + scalar updates) attributed via the wallet's
        // own address records — NOT the insert-stale `address.balances`
        // relationship that left the holdings frozen until relaunch.
        let chainByAddressId = chainByActiveAddressId(wallet)
        var result: [(SupportedChain, TokenBalanceRecord)] = []
        for balance in allBalanceRecords {
            guard let aid = balance.addressId ?? balance.address?.id,
                  let chain = chainByAddressId[aid],
                  !balance.rawBalance.isEmpty, balance.rawBalance != "0" else { continue }
            if balance.fiatValueCached >= threshold {
                result.append((chain, balance))
            }
        }
        return result.sorted { $0.1.fiatValueCached > $1.1.fiatValueCached }
    }

    /// Distinct chains with at least one non-zero balance row. Used by
    /// the rollup line so "3 chains · 5 tokens" refers to what's *held*
    /// rather than what's *supported* (the latter falls back via
    /// `WalletHomeHeader.totalChainsSupported` when no balance exists
    /// yet, so the user sees "N chains supported" on a fresh wallet
    /// instead of "0 chains · 0 tokens").
    private var chainsHeldCount: Int {
        Set(balances.map { $0.chain }).count
    }

    // `recentTransactions` / `allTransactions` are now LIVE computed
    // properties over the top-level GRDB observation (`allTransactionRecords`)
    // — see their declarations near the top of the view. The old
    // `rebuildTransactionRows()` snapshot builder was removed
    // (2026-06-13): it read `wallet.addresses.flatMap { $0.transactions }`,
    // a relationship traversal that never reflected cross-context
    // inserts, so newly-scanned transactions only appeared after an
    // app relaunch. The live GRDB observation fixes that with no rebuild calls.

    /// Resolves the chain a `TransactionRecord` belongs to via its
    /// back-pointer to `WalletAddressRecord.chainRaw`. Returns nil when the
    /// chain can't be resolved (an orphaned / corrupted record) so callers
    /// SKIP the row rather than silently misattributing it to Ethereum —
    /// which would offer a wrong-chain explorer link and a wrong chain badge.
    /// This matches the sibling resolvers in `AssetDetailView` /
    /// `WalletActivityView`. The repository never produces an orphaned tx, so
    /// this is data-integrity insurance, not a behaviour change.
    private func chainFor(_ tx: TransactionRecord) -> SupportedChain? {
        if let raw = tx.address?.chainRaw,
           let chain = SupportedChain(rawValue: raw) {
            return chain
        }
        return nil
    }

    /// Latest `lastScannedAt` across all addresses, or nil if no scan
    /// has ever completed.
    private var mostRecentScanAt: Date? {
        guard let wallet = contentWallet else { return nil }
        return wallet.addresses.compactMap { $0.lastScannedAt }.max()
    }

    private var requiresBiometricReenrollment: Bool {
        metadataRows.first?.requiresBiometricReenrollment ?? false
    }

    // MARK: - Active-wallet bootstrap

    /// Ensures `activeWalletIdRaw` points at a real wallet — on cold
    /// launch after a fresh install, or whenever the previously-active
    /// wallet got deleted. Sets the first wallet by sortOrder as
    /// active when the stored id is empty or stale.
    private func ensureActiveWalletSet() {
        // A deliberately-set, VALID active id is TRUSTED — even when the
        // main context can't see its wallet yet (cross-context merge lag
        // right after a create / import: the new WalletRecord is saved in
        // a background repository actor context and merges a beat later, so
        // BOTH `allWallets` and a `walletExists` fetch can transiently
        // miss it). Healing it to "the first wallet" in that window
        // hijacked the just-created wallet's identity and surfaced the
        // PREVIOUS wallet's balances under it (the "new wallet briefly
        // shows 0, then the old wallet's $250" bug). The delete flow
        // re-points the id itself (`WalletRepository
        // .deleteWalletAndActivateNext`), so a valid id never legitimately
        // dangles — leave it and let the merge land. If a valid id ever
        // does point at nothing, `activeWallet` returns nil (an empty
        // home the user can recover from by switching), which is far
        // safer than showing another wallet's funds.
        if UUID(uuidString: activeWalletIdRaw) != nil {
            return
        }
        // Stored id is EMPTY or unparseable — heal from STORE truth (first
        // wallet by `sortOrder`, the same deterministic landing the delete
        // flow uses, which a direct store fetch sees correctly even
        // mid-merge).
        if let first = allWallets.sorted(by: { $0.sortOrder < $1.sortOrder }).first {
            ActiveWalletPointer.set(first.id)
        }
    }

    /// Store-truth existence check for a wallet id. A direct
    /// `fetchCount` hits the persistent store, so it sees rows the
    /// repository actor has already saved even before this view's
    /// GRDB observation has merged them.
    private func walletExists(id: UUID) -> Bool {
        if allWallets.contains(where: { $0.id == id }) {
            return true
        }
        do {
            return try AppDatabase.shared.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM wallets WHERE id = ? LIMIT 1",
                    arguments: [id.uuidString]
                ) != nil
            }
        } catch {
            return false
        }
    }

    // MARK: - Refresh

    /// Run one wallet refresh. The coordinator serializes refresh work per
    /// wallet, so user-initiated pulls and automatic refreshes share the same
    /// in-flight pipeline instead of overlapping network calls.
    ///
    /// **Pull-to-refresh UX (`mark-refresh-kit`):**
    /// pull scrubs frames 0…66 → settle to 70pt hold + loop 66…124 while
    /// loading → success 124…210 → strip dismisses.
    @MainActor
    private func runRefresh(userInitiated: Bool = false) async {
        guard let walletId = await resolveRefreshWalletId() else {
            if userInitiated {
                withAnimation(WalletHomePullMetrics.settleSpring) {
                    heroPullDisplay = 0
                    markRefreshPhase = .idle
                    isRefreshing = false
                    isPullSettling = false
                }
            }
            return
        }
        if shouldShowFirstRefreshSkeleton(for: walletId) {
            startFirstRefreshSkeleton(for: walletId)
        }

        let code = currencyCode

        if !userInitiated {
            Task {
                await WalletBackgroundWorkCoordinator.shared.refreshBalances(
                    walletId: walletId,
                    currencyCode: code,
                    database: AppDatabase.shared,
                    userInitiated: false
                )
                guard !Task.isCancelled else { return }
                await WalletBackgroundWorkCoordinator.shared.startFullRefresh(
                    walletId: walletId,
                    currencyCode: code,
                    database: AppDatabase.shared
                )
                await WalletBackgroundWorkCoordinator.shared.startChainKeyBackfill(
                    walletId: walletId,
                    database: AppDatabase.shared
                )
            }
            return
        }

        // Hold strip + `isRefreshing` are already locked in `beginPullRelease`.
        // Re-affirm if we were called without that path.
        if !isRefreshing {
            isRefreshing = true
        }
        if markRefreshPhase != .loading && markRefreshPhase != .success {
            markRefreshPhase = .loading
            withAnimation(WalletHomePullMetrics.settleSpring) {
                heroPullDisplay = WalletHomePullMetrics.holdHeight
            }
            UniHapticEngine.shared.play(.start)
        }

        Task { @MainActor in
            await WalletBackgroundWorkCoordinator.shared.refreshBalances(
                walletId: walletId,
                currencyCode: code,
                database: AppDatabase.shared,
                userInitiated: true
            )
            guard UUID(uuidString: activeWalletIdRaw) == walletId else { return }
            rebuildFilterInputs()
            rebuildDisplayRows()
            // Strong “done” haptic fires when the success Lottie finishes
            // (`onMarkRefreshSuccessFinished`) — not mid-loop on data land.
        }
        // Minimum hold so the loop is visible; then play success (kit total 3.5s).
        try? await Task.sleep(for: .seconds(1.6))
        // Only advance if we still own the strip (not cancelled).
        guard isRefreshing, case .loading = markRefreshPhase else { return }
        markRefreshPhase = .success
        // Success completion callback dismisses the strip + strong haptic.
    }

    private func shouldShowFirstRefreshSkeleton(for walletId: UUID) -> Bool {
        activeWallet?.id == walletId
            && firstRefreshPresentationWalletIdRaw == walletId.uuidString
            && firstRefreshSkeletonDeadline(for: walletId) != nil
    }

    private func startFirstRefreshSkeleton(for walletId: UUID) {
        // No skeleton UI — clear the create/import presentation marker now.
        cancelFirstRefreshSkeleton()
        finishFirstRefreshSkeleton(for: walletId)
        rebuildFilterInputs()
        rebuildDisplayRows()
    }

    private func updateFirstRefreshSkeletonFromPresentationMarker() {
        guard let walletId = UUID(uuidString: activeWalletIdRaw) else {
            cancelFirstRefreshSkeleton()
            return
        }
        // Immediately clear any pending first-refresh marker so home never
        // enters a skeleton/shimmer presentation window.
        cancelFirstRefreshSkeleton()
        if firstRefreshPresentationWalletIdRaw == walletId.uuidString {
            WalletFirstRefreshPresentationCenter.clearIfCurrent(walletId)
        }
        rebuildFilterInputs()
        rebuildDisplayRows()
    }

    private func firstRefreshSkeletonDeadline(for walletId: UUID) -> Date? {
        guard firstRefreshPresentationWalletIdRaw == walletId.uuidString,
              firstRefreshPresentationStartedAt > 0 else { return nil }
        // No success sheet anymore — bounded skeleton window from mark only.
        let startedAt = Date(timeIntervalSince1970: firstRefreshPresentationStartedAt)
        let deadline = startedAt.addingTimeInterval(5)
        guard deadline.timeIntervalSinceNow > 0 else { return nil }
        return deadline
    }

    private func clearFirstRefreshSkeleton(walletId: UUID, runId: UUID) {
        guard firstRefreshSkeletonWalletId == walletId,
              firstRefreshSkeletonRunId == runId else { return }
        firstRefreshSkeletonWalletId = nil
        firstRefreshSkeletonRunId = nil
        firstRefreshSkeletonTask = nil
        guard activeWallet?.id == walletId else { return }
        rebuildFilterInputs()
        rebuildDisplayRows()
        scheduleChainStateReconcile(after: 0)
        finishFirstRefreshSkeleton(for: walletId)
    }

    private func finishFirstRefreshSkeleton(for walletId: UUID) {
        WalletFirstRefreshPresentationCenter.clearIfCurrent(walletId)
    }

    private func cancelFirstRefreshSkeleton(unless walletId: UUID? = nil) {
        if let walletId, firstRefreshSkeletonWalletId == walletId {
            return
        }
        firstRefreshSkeletonTask?.cancel()
        firstRefreshSkeletonTask = nil
        firstRefreshSkeletonWalletId = nil
        firstRefreshSkeletonRunId = nil
    }

    /// Currency-change re-price. Project persisted fiat through an FX
    /// cross first, then refine through `TokenPricingEngine`. The first
    /// pass updates cached balances from e.g. JOD to USD without waiting
    /// for a per-token market-price batch, so the card does not rebuild
    /// from zero during a fiat switch.
    private func repriceForCurrencyChange() async {
        let code = (CurrencyPreference.currency(for: currencyCode)?.code
            ?? CurrencyPreference.defaultCode).uppercased()
        guard let walletId = activeWallet?.id ?? UUID(uuidString: activeWalletIdRaw) else { return }

        await TokenPricingEngine.shared.configure(database: AppDatabase.shared)
        let projectionRepository = WalletFiatProjectionRepository(database: AppDatabase.shared)
        let sourceCurrencies = (try? projectionRepository.sourceCurrencies(
            walletId: walletId,
            targetCurrencyCode: code
        )) ?? []

        var crosses: [String: Decimal] = [:]
        for source in sourceCurrencies.sorted() {
            guard let cross = await TokenPricingEngine.shared.crossRate(from: source, to: code) else { continue }
            crosses[source] = cross
        }
        guard !Task.isCancelled else { return }
        guard (activeWallet?.id ?? UUID(uuidString: activeWalletIdRaw)) == walletId else { return }

        let projectedCount = (try? projectionRepository.projectWalletBalances(
            walletId: walletId,
            targetCurrencyCode: code,
            ratesBySourceCurrency: crosses
        )) ?? 0

        // BUG-009: always rebuild after a currency switch. Rebuild converts via
        // USD unit prices × FX (or keeps last non-zero fiat) — never leave
        // chain_states stamped with total_fiat = 0 while balances exist.
        _ = try? ChainStateRepository(database: AppDatabase.shared)
            .rebuild(walletId: walletId, fiatCurrencyCode: code)
        rebuildBalanceMemos()
        rebuildFilterInputs()
        rebuildDisplayRows()

        let symbols = (try? projectionRepository.tokenSymbols(walletId: walletId)) ?? []
        guard !symbols.isEmpty else { return }
        // unitPrices always persists token quotes in USD and FX rates in DB.
        let prices = await TokenPricingEngine.shared.unitPrices(
            symbols: Array(symbols),
            currencyCode: code
        )
        guard !Task.isCancelled else { return }
        guard (activeWallet?.id ?? UUID(uuidString: activeWalletIdRaw)) == walletId else { return }

        let unitPrices = prices.reduce(into: [String: Decimal]()) { result, entry in
            result[entry.key.uppercased()] = entry.value.amount
        }
        let liveChanged = (try? projectionRepository.applyUnitPrices(
            walletId: walletId,
            targetCurrencyCode: code,
            unitPricesBySymbol: unitPrices
        )) ?? 0
        // Refine chain totals after live USD×FX pricing (always rebuild so
        // even a pure FX cache hit updates the portfolio summary).
        if liveChanged > 0 || projectedCount > 0 || !unitPrices.isEmpty {
            _ = try? ChainStateRepository(database: AppDatabase.shared)
                .rebuild(walletId: walletId, fiatCurrencyCode: code)
            rebuildBalanceMemos()
            rebuildFilterInputs()
            rebuildDisplayRows()
        }
    }

    /// Resolve the wallet id a refresh should run against. Prefers
    /// the stored `activeWalletId` — verified against the store
    /// directly, because the GRDB observation-backed `activeWallet` lags the
    /// import flow's actor-context insert: in the merge window right
    /// after an import it silently resolved to the WRONG wallet (the
    /// first one), so the freshly-imported wallet never got scanned
    /// in-session and showed $0.00 until relaunch (2026-06-12). The
    /// bounded retry covers the save-to-visible gap; the GRDB observation
    /// fallback keeps the legacy behavior for an empty or genuinely
    /// stale stored id.
    private func resolveRefreshWalletId() async -> UUID? {
        if let uuid = UUID(uuidString: activeWalletIdRaw) {
            if allWallets.contains(where: { $0.id == uuid }) || walletExists(id: uuid) {
                return uuid
            }
            // The id may name a wallet whose insert hasn't become
            // visible yet — re-ask the store briefly before falling
            // back to the query's resolution.
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(400))
                if walletExists(id: uuid) { return uuid }
            }
        }
        return activeWallet?.id
    }
}

// MARK: - RecentActivityRows (value-typed, equatable leaf)

/// Value-typed snapshot of one recent-activity row's TRANSACTION-derived
/// fields (2026-06-18). Fiat is intentionally NOT here — it's computed inside
/// `RecentActivityRows` from the prices that leaf now owns (Part 3.1), so the
/// snapshot has no dependency on the price table.
private struct ActivityRowModel: Identifiable, Equatable {
    let id: UUID
    let chain: SupportedChain
    let direction: TransactionDirection
    let amount: Decimal
    let amountRaw: String
    let tokenSymbol: String
    /// Token contract (nil for a native coin) — passed to `CoinMark` so a
    /// token row resolves its exact logo by contract (2026-06-19).
    let tokenContract: String?
    let counterparty: String
    let occurredAt: Date
    let status: TransactionStatus
    let kind: TransactionKind
    /// On-chain hash — drives the row's long-press copy/explorer menu.
    let txHash: String
}

/// The recent-activity `ForEach`, extracted from `WalletHomeView.body` into a
/// leaf that OWNS the spot-price GRDB observation (2026-06-18, Part 3.1). Because
/// `cachedPrices` lives here, a price-batch commit re-renders only this leaf —
/// never the parent body — and each row's fiat is computed from the leaf's own
/// prices. The transaction-derived rows arrive as a value-typed snapshot from
/// the parent (which still owns the tx query for the chart + ensure-loop), so
/// this leaf invalidates on exactly two things: those rows, and the prices.
private struct RecentActivityRows: View {
    let rows: [ActivityRowModel]
    let currencyCode: String
    let cachedPrices: [CachedPriceRecord]
    let onSelect: (UUID) -> Void

    /// Leading inset for separators — matches logo + gap so the line
    /// aligns under the title text (Settings / Holdings list geometry).
    private var separatorLeading: CGFloat {
        UniSpacing.m + AssetLogoMetrics.standard + UniSpacing.s
    }

    private var priceMap: [String: Decimal] {
        ActivityFiat.priceMap(cachedPrices, currency: currencyCode)
    }

    var body: some View {
        let map = priceMap
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            Button {
                onSelect(row.id)
            } label: {
                ActivityRow(
                    chain: row.chain,
                    direction: row.direction,
                    amount: row.amount,
                    tokenSymbol: row.tokenSymbol,
                    counterparty: row.counterparty,
                    occurredAt: row.occurredAt,
                    status: row.status,
                    kind: row.kind,
                    fiatValue: ActivityFiat.value(amountRaw: row.amountRaw, symbol: row.tokenSymbol, map: map),
                    fiatCurrencyCode: currencyCode,
                    tokenContract: row.tokenContract,
                    txHash: row.txHash
                )
                .padding(.horizontal, UniSpacing.m)
                .padding(.vertical, UniSpacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            // Settings-style full-row press fill (not plain opacity).
            .buttonStyle(.uniListRow)
            .uniListRowSurface()

            if index < rows.count - 1 {
                Divider()
                    .opacity(0.28)
                    .padding(.leading, separatorLeading)
            }
        }
    }
}

// MARK: - SupportedTokenRow (value-typed, equatable holdings row)

/// One token holdings row — the logo (`CoinMark`), name/symbol, amount, and
/// fiat — extracted from `WalletHomeView` into a value-typed `Equatable` leaf
/// (2026-06-18, Part 3.5). Rendered via `.equatable()` so a parent body
/// re-evaluation (a GRDB merge the row doesn't depend on) skips rebuilding
/// the row's body + its `CoinMark` when the row model is unchanged. `==` is
/// `nonisolated` (Equatable requirement vs main-actor `View`) and reads only
/// the Sendable value-typed row.
private struct SupportedTokenRow: View, Equatable {
    let row: WalletTokenSupportedDisplayRow
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    nonisolated static func == (lhs: SupportedTokenRow, rhs: SupportedTokenRow) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(chain: row.chain, tokenSymbol: row.symbol, contract: row.contract)
                .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                // 2026-06-17 — full NAME is the title, SHORT NAME (symbol)
                // the subtitle (user direction; matches the asset pickers).
                Text(verbatim: row.name)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(verbatim: row.symbol)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                PrivacySensitiveAmount(
                    text: WalletFormatting.native(row.amount, decimals: 6),
                    font: UniTypography.monoBody,
                    color: UniColors.Text.primary,
                    isHidden: hideBalances
                )
                // Zero/unheld → "US$0.00", never "Price unavailable"
                // (user direction 2026-06-18).
                PrivacySensitiveAmount(
                    text: WalletFormatting.fiat(row.fiatValue ?? 0, currencyCode: row.fiatCurrencyCode),
                    font: UniTypography.footnote,
                    color: UniColors.Text.tertiary,
                    isHidden: hideBalances
                )
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .uniListRowHitTarget()
    }
}

// MARK: - HoldingsTab

/// Segmented-control selection for the wallet home's holdings region.
/// User toggles between Coins (every supported native chain) and
/// Tokens (every supported registry token). Default `.coins`.
enum HoldingsTab: String, Hashable, CaseIterable {
    case coins
    case tokens
}

// MARK: - CombinedHoldingRow

/// One row in the wallet-home's combined holdings list. Either a
/// coin row or a token row; the variant carries the underlying
/// display row + exposes the shared comparable surface (name,
/// symbol, amount, fiat, chain) the merged sort uses.
///
/// **Why an enum, not a protocol.** A protocol would force every
/// downstream surface (the SwiftUI `switch` in `combinedSection`
/// most of all) to type-erase to `any WalletAssetRow` — which is
/// expensive on the hot path and breaks SwiftUI's `ForEach`
/// identity inference. An enum with two cases is the small,
/// exhaustive vocabulary the combined-mode renderer needs.
enum CombinedHoldingRow: Identifiable {
    case coin(WalletCoinSupportedRow)
    case token(WalletTokenSupportedDisplayRow)

    var id: String {
        switch self {
        case .coin(let row):
            return "coin.\(row.chain.rawValue)"
        case .token(let row):
            return "token.\(row.id)"
        }
    }

    /// The asset's canonical identifier in the pinned / hidden
    /// preference sets (`chainRaw|contract|symbol`). Used by the
    /// combined-mode partitioner to lift pinned rows out of the
    /// flat sorted body and into the head "Pinned" Section.
    var assetID: String {
        switch self {
        case .coin(let row):  return WalletHomeFilterPreferences.assetID(coin: row)
        case .token(let row): return WalletHomeFilterPreferences.assetID(token: row)
        }
    }

    /// Display name used by the `name` sort key. Coins use the
    /// chain display name (Bitcoin / Ethereum / …); tokens use the
    /// token's full name (Tether USD / USD Coin / …).
    var sortName: String {
        switch self {
        case .coin(let row):  return row.chain.displayName
        case .token(let row): return row.name
        }
    }

    /// Ticker / symbol used by the `symbol` sort key. Coins use
    /// `chain.ticker` (BTC / ETH / SOL / …); tokens use the
    /// registry's `symbol` (USDC / USDT / DAI / …).
    var sortSymbol: String {
        switch self {
        case .coin(let row):  return row.chain.ticker
        case .token(let row): return row.symbol
        }
    }

    /// Native amount used by the `balance` sort key. Already a
    /// `Decimal` from the row builder; sort comparison is direct.
    var sortAmount: Decimal {
        switch self {
        case .coin(let row):  return row.amount
        case .token(let row): return row.amount
        }
    }

    /// Fiat value used by the `value` sort key. `nil` fiat collapses
    /// to `.zero` for the comparator so unpriced rows cluster at
    /// the bottom of descending sorts (and the top of ascending) —
    /// honest about "we don't have a price for this," not buried.
    var sortFiat: Decimal {
        switch self {
        case .coin(let row):  return row.fiatValue ?? .zero
        case .token(let row): return row.fiatValue ?? .zero
        }
    }

    /// `SupportedChain.allCases` index. Memoized to avoid the
    /// per-comparison linear scan during sort (Rule #19's "fast
    /// scroll" tax).
    var canonicalChainIndex: Int {
        let chain: SupportedChain
        switch self {
        case .coin(let row):  chain = row.chain
        case .token(let row): chain = row.chain
        }
        return WalletHomeFilterApply.canonicalIndex(chain)
    }
}

// MARK: - Destinations

enum WalletHomeDestination: Hashable, Codable {
    case transaction(UUID)
    /// "All supported assets" destination — pushed when the user
    /// taps a "Show all" row in the Coins or Tokens section.
    /// Lands on `AllSupportedAssetsView` which lists every
    /// `SupportedChain` + every curated registry token with the
    /// active wallet's current balance per row.
    case allSupported
    /// **Asset detail destination** — pushed when the user taps any
    /// `AssetRow` (coin) or token row on the wallet home, OR any
    /// row on `AllSupportedAssetsView`. Lands on `AssetDetailView`
    /// which renders the per-asset roll-up: identity hero, total
    /// fiat, asset-scoped chart, per-network breakdown, and the
    /// asset-scoped transaction history. The `AssetIdentity`
    /// discriminates between native coins (carry the chain) and
    /// tokens (cross-network aggregated by symbol).
    case assetDetail(AssetIdentity)
    /// **Per-(asset, network) deep dive** — pushed when the user
    /// taps a row in `AssetDetailView`'s Networks section. The
    /// `String` is `SupportedChain.rawValue` so the destination
    /// stays Codable (raw enums round-trip cleanly through
    /// NavigationPath's restoration codec).
    case assetNetworkDetail(AssetIdentity, String)
    /// **Asset-scoped "View all" transactions** — pushed when the
    /// user taps "View all" under `AssetDetailView`'s capped
    /// activity section. Lands on `AssetActivityView` showing every
    /// transaction for the asset (no row cap).
    case assetActivity(AssetIdentity)
    /// **Wallet-wide "View all" transactions** — pushed when the user
    /// taps "View all" in the wallet-home "Recent activity" header.
    /// Lands on `WalletActivityView` showing every transaction across
    /// every address of the active wallet (no five-row cap). No
    /// associated value — the destination always means the active
    /// wallet, resolved the same store-truth way the home does.
    case allActivity

    /// **Cold-launch restoration policy (2026-06-14).** Whether this
    /// destination should be re-opened when the app restores the
    /// wallet-home stack on a fresh launch (within the 2-minute
    /// window). Restoring INTO the full Activity list, or a
    /// half-started Send flow, is surprising — the user
    /// reported the app "opening the activity screen automatically"
    /// even when they had not deliberately left it there. Those are
    /// transient browse/action screens, not "where I was reading".
    /// Content-reading destinations (asset detail, per-network detail,
    /// the all-supported list, a specific transaction) ARE genuine
    /// resume points. `ScreenRestoration.restoredWalletHomeStack()`
    /// truncates the restored stack at the first `false` here, so the
    /// app lands on home (or the asset the user was reading) instead.
    var isColdLaunchRestorable: Bool {
        switch self {
        case .allActivity, .assetActivity:
            return false
        case .transaction, .allSupported, .assetDetail, .assetNetworkDetail:
            return true
        }
    }
}

// MARK: - Wallet-pill customise target (Identifiable shim)

/// `.sheet(item:)` needs an Identifiable binding to present
/// `WalletIconPickerSheet` from a `UUID?`. The shim is private to
/// this file because no other surface presents the picker by way
/// of a sheet item from the wallet-home — `WalletDetailView` uses
/// `@State Bool` because it presents against its own wallet.
private struct WalletPillCustomiseTarget: Identifiable {
    let walletId: UUID
    var id: UUID { walletId }
}

// MARK: - Balance-card scroll snap anchors

/// Vertical snap ends for the home ScrollView: fully open balance card
/// vs. holdings flush under the app bar.
private enum WalletHomeScrollAnchor: Hashable {
    case balanceCard
    case mainContent
}

/// Reports the resting height of the identity balance card so mid-scroll
/// release can snap to the nearest end.
private struct WalletHomeBalanceCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Wallet-pill regular-width menu modifier

/// **iPad / Mac wallet switcher (2026-06-16).** Attaches the native
/// SwiftUI `walletPillContextMenu` to the wallet-home toolbar pill —
/// but ONLY at regular width. At compact width (iPhone) the bottom
/// tab bar's `TabBarLongPressInstaller` owns the long-press switch
/// gesture, so this modifier passes the content straight through
/// unchanged; the iPhone surface is byte-for-byte identical.
///
/// At regular width (iPad landscape / wide Mac) the TabView is in
/// sidebar mode — there is no UITabBar for the installer to reach,
/// so the long-press switcher would silently die. `.contextMenu`
/// is pure SwiftUI and works on the toolbar pill at any width, so we
/// surface the SAME Switch/Customise/Add/Manage actions here instead.
private struct WalletPillRegularWidthMenu<Menu: View>: ViewModifier {
    let isRegularWidth: Bool
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if isRegularWidth {
            content.contextMenu { menu() }
        } else {
            content
        }
    }
}
