import SwiftUI
import SwiftData
import TipKit

// MARK: - RootGate

/// App-launch routing gate. Reads the wallet count reactively via
/// `@Query`; routes to `MainTabView` (the four-tab shell — Wallet /
/// Swap / Browser / Settings) if the user has at least one wallet,
/// otherwise to `OnboardingView`. When the create/import flows
/// insert a `WalletRecord`, the gate flips automatically — no
/// explicit navigation needed from those flows.
///
/// **2026-06-09 — `MainTabView` replaces `WalletHomeView` as the
/// wallets-exist branch.** Through 2026-06-08 this branch was
/// `WalletHomeView()` directly; Settings was reached via a `.sheet`
/// from the wallet-home toolbar's gear. Per direct user direction
/// the shell is now a native iOS 26 `TabView` so Wallet / Swap /
/// Browser / Settings sit at the same depth. `WalletHomeView` is
/// still the root of the Wallet tab; the Settings sheet is
/// retired.
///
/// **Splash → onboarding shared element (2026-06-07).** `AppRoot`
/// (in `UniAppApp.swift`) wraps the gate so it can thread the
/// `@Namespace logoNamespace` + `AppPhase` machine into onboarding —
/// onboarding consumes both to attach `matchedGeometryEffect` to its
/// welcome-slide logo and to drive the staggered chrome fade-in.
/// The wallets-exist branch ignores both: the shared-element
/// transition only applies to first-launch onboarding, not to
/// returning users.
struct RootGate: View {
    let logoNamespace: Namespace.ID
    let phase: AppPhase

    @Query private var wallets: [WalletRecord]

    var body: some View {
        if wallets.isEmpty {
            OnboardingView(logoNamespace: logoNamespace, phase: phase)
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
/// **Layers (Rule #2 §B.3):** content layer is opaque (hero number,
/// rows, banners); functional layer is the Liquid Glass toolbar
/// chrome + the `WalletActionRegion` glass triplet + the wallet
/// switcher pill. Two glass layers max.
///
/// **Empty / partial states (Rule #2 §A.2 — designed not deferred):**
/// - No balances yet (fresh wallet, scanner hasn't filled) → calm
///   "Add funds to see balance" surface in the holdings section.
/// - No transactions → calm "No transactions yet." footer.
/// - Price unavailable per row → `Text.tertiary` "Price unavailable"
///   (never fake `$—`).
/// - Backup required → top banner (`BackupRequiredBanner`).
/// - Biometric drift detected → top banner
///   (`BiometricReenrollmentBanner`).
struct WalletHomeView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]

    /// TipKit instance shared via type identity — every
    /// `WalletTabSwitcherTip()` reads the same persisted state, so a
    /// dismissal here is the same dismissal `MainTabView` would see.
    private let walletSwitcherTip = WalletTabSwitcherTip()
    @Query private var metadataRows: [AppMetadataRecord]
    // **2026-06-18 Part 3.1.** The spot-price `cachedPrices` @Query was MOVED
    // off this parent and into the two leaves that consume it —
    // `BalanceCardLiveSection` (the chart map) and `RecentActivityRows` (row
    // fiat). The per-refresh price-batch commit is the most frequent merge, so
    // owning the query in the leaves means that commit re-renders only those
    // small leaves, never this whole body.
    /// On-disk historical-price cache. Each row is one day's close
    /// for one `(symbol, fiat)` pair. The chart uses this to value
    /// past holdings at their **then-price** instead of today's
    /// spot, so a token that crashed 99% renders past peaks at
    /// honest historical fiat ($4000 then) not today's collapsed
    /// valuation ($50). Populated by `CoinbaseHistoricalPriceService`
    /// via the `.task` ensure-loop below.
    @Query private var historicalPrices: [HistoricalPriceRecord]
    /// **Local-first asset universe (Rule #27 §D).** The supported
    /// chains + tokens, read from the DB (seeded by `AssetCatalogSeeder`
    /// from the static registries). `catalogChains` / `catalogAssets`
    /// map these to the registry-agnostic shape the display builders
    /// consume, falling back to the identical static `AssetCatalog`
    /// during the pre-seed cold-launch window so the list never blanks.
    @Query(sort: \ChainRecord.sortIndex) private var chainRecords: [ChainRecord]
    @Query private var assetRecords: [AssetRecord]

    // **Per-chain aggregate rows (2026-06-17).** The `chainStateRecords`
    // `@Query` that drives the hero total now lives in the
    // `BalanceCardLiveSection` leaf (2026-06-18 native perf fix), NOT here.
    // The refresh coordinator rebuilds a chain's `ChainStateRecord` on a
    // ~300ms cadence during every scan; a top-level `@Query` here made each
    // of those commits re-evaluate this entire 2,790-line body (Apple's
    // documented `@Query`/DynamicProperty invalidation — a declared query
    // invalidates the owning view's body on ANY result change, read or not).
    // Moving the query into the small leaf that actually renders the total
    // localizes that 300ms invalidation to the card alone — the parent body
    // no longer re-evaluates on balance commits. The parent passes the leaf
    // the live balance-row sum (`liveBalanceSum`) as the pre-aggregate
    // fallback so a fresh wallet is never blank.
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var hideBalanceOnHome: Bool = false

    @AppStorage(HideBalancesPreference.thresholdKey) private var hideSmallThreshold: Double = HideBalancesPreference.defaultThreshold

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

    // MARK: - Filter & Sort preferences (Rule #14-class declarative reads)
    //
    // The wallet home reads every Filter & Sort preference reactively
    // via `@AppStorage`. The filter sheet (`WalletHomeFilterSheet`)
    // writes through the same keys; SwiftUI's environment propagation
    // pushes new values into this view's body within the next
    // evaluation. No imperative "apply" call needed — every value is
    // a published source.
    //
    // **Why declare them here at all** when `WalletHomeFilterApply.Inputs.current()`
    // could read them on the fly? Because `@AppStorage` participates in
    // SwiftUI's invalidation graph; reading the keys outside the
    // graph (via a one-shot `UserDefaults.standard.string(forKey:)`)
    // does NOT cause the view to recompute when the keys change. The
    // sheet's writes would land in `UserDefaults` but the home would
    // keep rendering the stale layout until the next unrelated body
    // evaluation. Declaring them as `@AppStorage` here closes the loop.
    @AppStorage(WalletHomeFilterPreferences.viewModeKey)
    private var filterViewModeRaw: String = WalletHomeFilterPreferences.defaultViewMode.rawValue
    @AppStorage(WalletHomeFilterPreferences.sortKeyKey)
    private var filterSortKeyRaw: String = WalletHomeFilterPreferences.defaultSortKey.rawValue
    @AppStorage(WalletHomeFilterPreferences.sortDirectionKey)
    private var filterSortDirectionRaw: String = WalletHomeFilterPreferences.defaultSortDirection.rawValue
    @AppStorage(WalletHomeFilterPreferences.onlyWithBalanceKey)
    private var filterOnlyWithBalance: Bool = WalletHomeFilterPreferences.defaultOnlyWithBalance
    @AppStorage(WalletHomeFilterPreferences.hiddenAssetsKey)
    private var filterHiddenAssetsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    @AppStorage(WalletHomeFilterPreferences.hiddenChainsKey)
    private var filterHiddenChainsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    // v2 filter preferences (2026-06-09)
    @AppStorage(WalletHomeFilterPreferences.assetTypeKey)
    private var filterAssetTypeRaw: String = WalletHomeFilterPreferences.defaultAssetType.rawValue
    @AppStorage(WalletHomeFilterPreferences.groupByKey)
    private var filterGroupByRaw: String = WalletHomeFilterPreferences.defaultGroupBy.rawValue
    @AppStorage(WalletHomeFilterPreferences.minFiatThresholdKey)
    private var filterMinFiatThreshold: Double = WalletHomeFilterPreferences.defaultMinFiatThreshold
    @AppStorage(WalletHomeFilterPreferences.selectedNetworksKey)
    private var filterSelectedNetworksJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    @AppStorage(WalletHomeFilterPreferences.pinnedAssetsKey)
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
    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    @Environment(\.modelContext) private var modelContext
    // The auto-lock surface (`AppLockView`) is presented by
    // `AppRoot` at the window root — not from this view. See
    // `UniAppApp.swift` for the gating logic and the privacy
    // mask that bridges the foreground reveal.

    /// Rule #12 §G direction-only key for sheet content rebuild.
    /// `"ltr"` or `"rtl"`. Identical pattern to `OnboardingView`.
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    @State private var isShowingSwitcher: Bool = false
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
    /// Drives the Swap sheet (the compose + live-quote surface). Its own
    /// NavigationPath lives here so the sheet survives Rule #12 §G
    /// direction rebuilds, reset on dismiss.
    @State private var isShowingSwap: Bool = false
    @State private var swapPath: NavigationPath = NavigationPath()
    /// Background-swap engine — drives the under-actions banner (2026-06-17).
    @State private var swapManager = SwapBackgroundManager.shared
    /// The background swap job whose status sheet is open, if any.
    @State private var openSwapJobId: SwapJob.ID?
    /// **Filter & Sort sheet (2026-06-09).** Drives the
    /// `.sheet(isPresented: $isShowingFilter)` block below. The sheet
    /// reads + writes preferences through `@AppStorage` against
    /// `WalletHomeFilterPreferences`'s keys; changes propagate to
    /// this view's body the moment the sheet writes them.
    @State private var isShowingFilter: Bool = false
    @State private var receivePath: NavigationPath = NavigationPath()
    /// **Last-screen restoration (2026-06-13, hardened 2026-06-14).**
    /// Seeded from `ScreenRestoration`'s mirror in `init` (below) and
    /// mirrored back on every change — cold launches within the
    /// 2-minute window land the user back on the screen they left;
    /// `ScreenRestoration.resolveOnLaunch()` clears the mirror for
    /// longer absences.
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
    // Settings is now a top-level tab in `MainTabView` (2026-06-09);
    // the wallet-home no longer presents it as a sheet. The previous
    // `isShowingSettings` flag and `settingsPath` NavigationPath are
    // retired in the same change.
    @State private var isRefreshing: Bool = false

    /// Shared refresh-outcome surface (2026-06-12). The coordinator
    /// publishes the chains whose balance scan yielded nothing (after
    /// its bounded retry pass) here; this view reads it to choose
    /// between the normal holdings list, the partial-failure
    /// footnote, and the total-failure "Couldn't reach the network"
    /// state. `@Observable` — property reads in `body` register
    /// dependencies; no `@State` wrapper needed for a singleton.
    private let refreshState = WalletRefreshState.shared

    /// `true` while any refresh pipeline is in flight — the local
    /// flag covers refreshes this view started; the shared flag
    /// covers a replacement pipeline still running after a cancelled
    /// run's completion flipped the local flag back early.
    private var isAnyRefreshInFlight: Bool {
        isRefreshing || refreshState.isRefreshing
    }

    /// The published refresh outcome only speaks for the wallet it
    /// ran against — never let wallet A's failure paint wallet B.
    private var refreshOutcomeAppliesToActiveWallet: Bool {
        refreshState.lastRefreshWalletId != nil
            && refreshState.lastRefreshWalletId == activeWallet?.id
    }

    /// Total failure on a wallet with nothing persisted (the fresh
    /// import whose every chain failed): rendering the all-supported
    /// $0.00 list would claim "you hold nothing" when the truth is
    /// "we couldn't ask." Show the honest error state instead.
    private var showsNetworkErrorState: Bool {
        refreshOutcomeAppliesToActiveWallet
            && !refreshState.lastRefreshFailedChains.isEmpty
            && allHeldRows.isEmpty
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

    /// Shared tab-selection writer — the long-press menu's "Manage
    /// wallets" row flips this to `.settings` to land the user on the
    /// Settings tab. `MainTabView` reads the same `@AppStorage` key
    /// reactively.
    @AppStorage(MainTab.storageKey) private var selectedTabRaw: String = MainTab.wallet.rawValue

    /// Deep-link token consumed by `SettingsView` on appear. The
    /// long-press menu's "Manage wallets" row stamps `"wallets"`;
    /// Settings pushes onto its NavigationPath and clears the token.
    @AppStorage("settingsDeepLink") private var settingsDeepLink: String = ""

    /// Active tab for the holdings region. Per the 2026-06-09 user
    /// direction, the home no longer shows Coins AND Tokens as
    /// stacked List sections — a native segmented switcher sits
    /// under the action region and the user picks which collection
    /// to view. Defaults to `.coins` because that's the broader
    /// vocabulary (every chain has one); Tokens is the deeper dive.
    @State private var selectedHoldingsTab: HoldingsTab = .coins

    /// 2026-06-09 — scrubbed fiat from `BalanceHistoryChart`, now an
    /// `@Observable` model (2026-06-13 perf fix). The chart WRITES the
    /// touched point's value to `scrubModel.fiat`; only the hero
    /// (`WalletHomeHeader`) READS it. Routing the value through an
    /// observable instead of a `@State Decimal?` means a drag frame no
    /// longer invalidates the whole `WalletHomeView.body` (which
    /// rebuilt the price dictionaries + re-sorted balances 60×/sec —
    /// the scrub-lag the user reported). `nil` `fiat` → hero shows the
    /// real `totalFiat`.
    @State private var scrubModel = ChartScrubModel()

    // MARK: - Memoized derived state (computed off-body)
    //
    // The row builders + JSON-decoded filter inputs used to be
    // computed properties evaluated on EVERY body pass (4+ JSON
    // decodes and three full registry enumerations + sorts per
    // frame). They are now `@State` snapshots rebuilt only when an
    // actual dependency changes: the filter preferences (via
    // `.onChange` of `filterPreferenceFingerprint`), the active
    // wallet / currency, the SwiftData row-count proxies, and
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
    // The stored rows are SwiftData references, so their scalar values
    // stay live between rebuilds; a rebuild re-applies the non-zero filter
    // + fiat sort whenever a refresh/re-price changes those values.
    @State private var balancesMemo: [(chain: SupportedChain, balance: TokenBalanceRecord)]? = nil
    @State private var allHeldRowsMemo: [(chain: SupportedChain, balance: TokenBalanceRecord)]? = nil
    @State private var allTransactionsMemo: [TransactionRecord]? = nil
    /// USD unit prices for the feed's symbols, used ONLY for the $0.01-USD
    /// dust gate on the Recent-activity preview (2026-06-19 user direction:
    /// "never show transactions with less than $0.01, always in dollars").
    /// Loaded async (see `loadDustPrices`); until it arrives every row shows.
    @State private var usdActivityPrices: [String: Decimal] = [:]
    /// **Live transaction feed (2026-06-13).** A TOP-LEVEL `@Query`,
    /// NOT a `wallet.addresses[].transactions` relationship traversal.
    /// SwiftData merges scalar UPDATES to already-materialized rows
    /// (which is why balances refresh live) but does NOT append newly-
    /// INSERTED children to an already-materialized to-many array — so a
    /// transaction the background scanner inserted on pull-to-refresh
    /// never appeared until an app relaunch re-fetched the relationship
    /// (the Rule #25 live-state violation the user reported: "received
    /// 11 USDT, had to close & reopen to see it in activity"). A
    /// top-level `@Query` re-runs its fetch whenever ANY context on the
    /// shared container inserts a `TransactionRecord`, so new activity
    /// shows the instant it's persisted — no relaunch, no navigate-away.
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse)
    private var allTransactionRecords: [TransactionRecord]

    /// The active wallet's transactions, newest first — the live
    /// top-level `@Query` filtered to the active wallet's address ids.
    /// Address ids are stable (addresses aren't inserted during normal
    /// use), so reading them off the `@Query`-backed `activeWallet` is
    /// safe; only per-tx membership changes, and the top-level query
    /// sees those inserts live. The in-memory filter is O(total tx) —
    /// a few thousand rows at most (the scanner caps history per chain),
    /// well under a millisecond per render, and there is no per-render
    /// SORT (the `@Query` sorts at the store level).
    /// Cached (`allTransactionsMemo`); falls back to a live compute only
    /// when unseeded. Rebuilt by `rebuildTransactionMemos()` on wallet
    /// switch, refresh completion, and `allTransactionRecords` count
    /// changes — see the memo block near the `@State` declarations.
    private var allTransactions: [TransactionRecord] {
        allTransactionsMemo ?? computeAllTransactions()
    }

    /// The live filter: top-level `@Query` narrowed to the active
    /// wallet's address ids, newest-first (the `@Query` sorts at the
    /// store level). O(total tx) — moved out of the render path by the
    /// memo above; this runs only on a rebuild trigger.
    private func computeAllTransactions() -> [TransactionRecord] {
        guard let wallet = activeWallet else { return [] }
        let ids = Set(wallet.addresses.map { $0.id })
        guard !ids.isEmpty else { return [] }
        return allTransactionRecords.filter { tx in
            guard let aid = tx.addressId else { return false }
            return ids.contains(aid)
        }
    }

    /// The five newest transactions for the home's Recent activity
    /// window. `allTransactions` is already newest-first; sub-$0.01-USD
    /// dust is dropped FIRST (2026-06-19 user direction) so the preview
    /// shows five real transactions, not five dust rows — then the cheap
    /// prefix. The "View all" affordance routes to the unbounded
    /// `WalletActivityView` (which applies the same gate).
    private var recentTransactions: [TransactionRecord] {
        Array(
            allTransactions
                .filter { tx in
                    !ActivityFiat.isDust(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, usdMap: usdActivityPrices)
                }
                .prefix(5)
        )
    }

    /// Value-typed, TRANSACTION-only snapshot of `recentTransactions` for the
    /// `RecentActivityRows` leaf (2026-06-18) — chain + decoded/raw amount +
    /// symbol, NO fiat (the leaf computes fiat from the prices it now owns, so
    /// this snapshot has no price dependency and the parent no longer needs the
    /// `cachedPrices` query). Cheap (≤5 rows).
    private var recentActivityModels: [ActivityRowModel] {
        recentTransactions.map { tx in
            ActivityRowModel(
                id: tx.id,
                chain: chainFor(tx),
                direction: TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing,
                amount: Decimal(string: tx.amountRaw) ?? .zero,
                amountRaw: tx.amountRaw,
                tokenSymbol: tx.tokenSymbol,
                counterparty: tx.counterparty,
                occurredAt: tx.occurredAt,
                status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed,
                kind: tx.kind
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

    init() {
        // Last-screen restoration seed (2026-06-13). `@State` reads
        // its initial value only when the view's identity is fresh —
        // cold launch and the root direction-flip rebuild — which are
        // exactly the restoration moments. All other properties keep
        // their declaration defaults.
        _navigationPath = State(initialValue: ScreenRestoration.restoredWalletHomeStack())
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listSurface
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                // 2026-06-17 — the toolbar holds ONLY the Filter & Sort
                // affordance (user direction). The 3-dots overflow menu
                // (Hide balance / Lock wallet) was removed: hide-balance
                // still lives on the balance card's eye toggle, and
                // auto-lock runs from `AutoLockController` without a manual
                // toolbar entry. Per Rule #19 §C the toolbar item is a plain
                // `Button` with an SF Symbol label — not a `UniButton` —
                // because toolbar items are navigation affordances, not
                // commit CTAs (the rule's documented exception).
                .toolbar {
                    // 2026-06-14 — sync has NO UI surface (user
                    // direction: "from app bar we need to remove the
                    // syncing at all we don't need it in the UI, just
                    // run in the background"). The leading app-bar mark
                    // that morphed Syncing… ⟷ iris was removed; the
                    // background sync writer (`WalletRefreshCoordinator`)
                    // still stamps `SyncStatusRecord` for freshness, but
                    // nothing renders it. The leading slot is now empty,
                    // exactly as it was before the mark was introduced.
                    // 2026-06-09 — Filter & Sort affordance. Bare
                    // `line.3.horizontal.decrease` (iOS-native filter
                    // glyph; the same symbol Mail / Files / Photos
                    // use). NOT `.circle` — `M-003` recurrence
                    // discipline forbids `.circle` SF Symbols in any
                    // toolbar surface. Tapping presents
                    // `WalletHomeFilterSheet`; the sheet writes
                    // through `@AppStorage`, this view re-renders.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingFilter = true
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .accessibilityLabel(Text("Filter and sort"))
                        }
                    }
                }
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
                // Canonical Aperture refresh (2026-06-09). Replaces
                // the iOS native pull-to-refresh spinner with the
                // iris-spin → green-check Lottie indicator. The
                // gesture, scroll-bounce, and cancellation contract
                // Native iOS pull-to-refresh — system spinner +
                // gesture + release-haptic + cancellation. The
                // 2026-06-09 Lottie indicator was reverted per
                // user direction.
                // User-initiated: a pull against a wedged in-flight
                // pipeline CANCELS it and starts fresh instead of
                // silently joining the stall (2026-06-12).
                .refreshable { await runRefresh(userInitiated: true) }
                .task(id: activeWalletIdRaw) {
                    ensureActiveWalletSet()
                    // Seed the memoized DISPLAY projections (balances /
                    // coin / token rows) before the first refresh lands
                    // so the home renders the persisted state
                    // immediately. Transactions need no seeding — they
                    // read live from the top-level `@Query`.
                    rebuildFilterInputs()
                    rebuildDisplayRows()
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
                .task(id: priceDataFingerprint) {
                    // Rebuild the chart's price dictionaries off-body
                    // when the price tables / currency change — never
                    // per render (2026-06-13 perf fix).
                    rebuildPriceMemos()
                }
                .task(id: dustPriceKey) {
                    // USD unit prices for the $0.01-USD dust gate on the
                    // Recent-activity preview. Off-body, engine-cached;
                    // re-fires on wallet switch / new tx (2026-06-19).
                    await loadDustPrices()
                }
                .task(id: historicalEnsureKey) {
                    // Historical-price ensure-loop. Per the
                    // 2026-06-12 fix: the chart values past holdings
                    // at then-prices instead of today's spot. Each
                    // unique symbol across (held balances + tx
                    // history) needs ~300 daily closes from Coinbase
                    // Exchange. Only fetches symbols we don't
                    // already have history for — idempotent.
                    await ensureHistoricalPricesLoaded()
                }
                .onChange(of: filterPreferenceFingerprint) { _, _ in
                    rebuildFilterInputs()
                    rebuildFilteredRows()
                }
                .onChange(of: activeWalletIdRaw) { _, _ in
                    rebuildDisplayRows()
                }
                // Last-screen restoration mirror (2026-06-13). Every
                // push / pop lands in `ScreenRestoration`'s
                // UserDefaults mirror so a force-quit needs no
                // last-moment save. Consumed by `init` on the next
                // fresh identity.
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
                    rebuildDisplayRows()
                    // …and the VALUES re-price right behind them
                    // (2026-06-13): a fast re-price of the persisted
                    // balances into the new currency (one price batch,
                    // no chain rescan — see `WalletRefreshCoordinator
                    // .repriceWallet` for the pricing ladder), then a
                    // full refresh that cancel-and-replaces any
                    // pipeline still pricing in the previous currency.
                    currencyChangeTask?.cancel()
                    currencyChangeTask = Task { await repriceForCurrencyChange() }
                }
                .onChange(of: balanceRowsRevision) { _, _ in
                    rebuildDisplayRows()
                }
                // "Hide small balances" threshold (a Settings preference,
                // a DIFFERENT @AppStorage key than the filter sheet's
                // `filterMinFiatThreshold`) is read inside `computeBalances()`.
                // The pre-memo `balances` re-read it every body pass, so
                // changing it updated the home live; the cache must rebuild
                // explicitly or the hero/holdings/chart stay on the old
                // threshold until the next refresh (Rule #25). 2026-06-14.
                .onChange(of: hideSmallThreshold) { _, _ in
                    rebuildDisplayRows()
                }
                // New transactions landed in the top-level @Query (live
                // cross-context inserts, Rule #25) — refresh the cached
                // `allTransactions` so the Recent activity list + chart
                // reflect them immediately, not only after a refresh ends.
                .onChange(of: allTransactionRecords.count) { _, _ in
                    rebuildTransactionMemos()
                }
                .onChange(of: assetRecords.count) { _, _ in
                    // The local-first asset seed landed (Rule #27 §D) —
                    // rebuild so the list is now sourced from the DB
                    // `AssetRecord` rows instead of the static fallback.
                    // (Output is identical; this just completes the
                    // transition to DB-sourced.)
                    rebuildDisplayRows()
                }
                .onChange(of: refreshState.isRefreshing) { wasRefreshing, isRefreshing in
                    // A refresh pipeline this view did NOT await just
                    // completed — the import flow's post-persist
                    // refresh, or a replacement pipeline after a
                    // cancelled pull. The post-`runRefresh` rebuild
                    // never runs for those, and a re-pricing pass can
                    // change row CONTENT without moving the count
                    // proxies above. Rebuild when the completed
                    // refresh belongs to the active wallet
                    // (2026-06-12). One cheap call per refresh
                    // completion — no per-frame work.
                    guard wasRefreshing, !isRefreshing else { return }
                    guard let completedId = refreshState.lastRefreshWalletId else { return }
                    let activeId = UUID(uuidString: activeWalletIdRaw) ?? activeWallet?.id
                    if completedId == activeId {
                        rebuildDisplayRows()
                    }
                }
        }
        // Settings is now reached via the four-tab shell (`MainTabView`
        // — 2026-06-09). The previous `.sheet { SettingsView }` block
        // and its direction-keyed rebuild are retired with the toolbar
        // gear. Receive remains a sheet because its surface is
        // commit-shaped (pick chain → render QR → share), not a
        // top-level section.
        .sheet(isPresented: $isShowingReceive, onDismiss: { receivePath = NavigationPath() }) {
            // Receive v2 — asset-first bottom sheet. `.large` detent
            // only (per M-005, avoids `.medium` clipping locale-
            // sensitive list rows in RTL languages). Rule #12 §G
            // direction-only rebuild key + `.uniAppEnvironment()` so
            // theme + locale propagate into the sheet's own scope.
            ReceiveView(navigationPath: $receivePath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        // Send — asset-first bottom sheet, the twin of Receive. Same
        // `.large`-only detent, same Rule #12 §G direction rebuild key +
        // `.uniAppEnvironment()` so theme + locale propagate into the
        // sheet's own scope.
        .sheet(isPresented: $isShowingSend, onDismiss: { sendPath = NavigationPath() }) {
            SendView(navigationPath: $sendPath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        // Swap / Bridge — compose + live-quote sheet. Same `.large`-only
        // detent + Rule #12 §G direction rebuild key + `.uniAppEnvironment()`
        // as Send / Receive so theme + locale propagate into the sheet's
        // own scope. Execution (sign + broadcast) is the next increment;
        // the sheet's Review is an honest summary, not a fabricated swap.
        .sheet(isPresented: $isShowingSwap, onDismiss: { swapPath = NavigationPath() }) {
            SwapView(navigationPath: $swapPath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        // Background-swap status (2026-06-17). Tapping the under-actions
        // banner reopens the live status of a swap running in
        // `SwapBackgroundManager` — the same in-flight / done / failed surface
        // the review flow shows.
        .sheet(
            isPresented: Binding(
                get: { openSwapJobId != nil },
                set: { if !$0 { openSwapJobId = nil } }
            )
        ) {
            if let id = openSwapJobId {
                SwapJobStatusView(jobId: id, onClose: { openSwapJobId = nil })
                    .uniAppEnvironment()
                    .uniSheetDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(UniColors.Background.primary)
            }
        }
        // Filter & Sort sheet (2026-06-09). `.large` detent only per
        // M-008's nav-shaped-sheet rule. Rule #12 §G direction key +
        // `.uniAppEnvironment()` so theme + locale propagate into the
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
                .uniAppEnvironment()
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
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingCreate, onDismiss: { createPath = NavigationPath() }) {
            RecoveryPhraseFlow(
                navigationPath: $createPath,
                onDismiss: { isShowingCreate = false },
                onUserSkippedBackup: {},
                onUserCompletedBackup: {}
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingImport, onDismiss: { importPath = NavigationPath() }) {
            ImportWalletFlow(
                navigationPath: $importPath,
                onDismiss: { isShowingImport = false },
                onCompleted: { _ in isShowingImport = false }
            )
            .uniAppEnvironment()
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
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationBackground(UniColors.Background.primary)
        }
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
    /// 6. **Footer section** — the boundary statement ("No accounts.
    ///    No servers."). Cleared row background + hidden separators.
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
    /// **Pull-to-refresh + auto-refresh** continue to attach to this
    /// surface (`List` consumes `.refreshable` and `.task` the same
    /// way `ScrollView` did). The bottom test-mode banner continues
    /// to ride `.safeAreaInset(edge: .bottom)` on the body. The
    /// 2026-06-09 Lottie indicator was reverted per user direction;
    /// the system pull-to-refresh spinner is back.
    ///
    /// **List background.** `.scrollContentBackground(.hidden)` strips
    /// the system's default grouped-list page tone and lets the
    /// `UniColors.Background.primary` page color (the canonical
    /// `systemGroupedBackground`) show through — matching the rest of
    /// the app's pages.
    private var listSurface: some View {
        List {
            balanceCardSection
            // 2026-06-14 — sync is background-only: it has no on-screen
            // surface at all (no under-card footnote, no app-bar mark).
            // The user removed every sync indicator from the UI; the
            // background writer keeps `SyncStatusRecord` fresh silently.
            chromeSection
            holdingsBody
            activityListSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // **Regular-width content cap (2026-06-16).** This single cap
        // is what kills the "blown-up iPhone" feel on iPad landscape /
        // wide Mac: the inset-grouped list — hero balance, action
        // triplet, holdings, activity — is capped to a centered 640pt
        // column instead of stretching to a ~1300pt-wide page. At
        // `.compact` (iPhone, iPad portrait) the frame falls through to
        // full width via `.infinity`, so the layout is byte-for-byte
        // unchanged. The `maxWidth: .infinity` wrapper centers the
        // capped column within the wider detail pane; the page-color
        // background fills the full width behind it so the column reads
        // as a centered card on the page, not a left-pinned strip.
        .frame(maxWidth: horizontalSizeClass == .regular ? 640 : .infinity)
        .frame(maxWidth: .infinity)
        .background(UniColors.Background.primary.ignoresSafeArea())
        // **Rule #14 search** — `.searchable(text:prompt:)` with NO
        // `placement:` argument. iOS 26 owns the placement: a
        // 2026-06-09 — search bar REMOVED from the main wallet
        // home per user direction. The `.searchable` modifier on
        // `listSurface` is gone; `filterSearchText` stays as
        // `@State` (always empty) so the filter pipeline's
        // step-1 search predicate naturally no-ops, and the
        // `searchPreview` parameter on the filter sheet still
        // accepts the empty string and renders the standard
        // "Showing N of M" preview rather than the search-aware
        // "Found N for query" shape. Hidden Assets sub-screen
        // keeps ITS own `.searchable` — that surface has a long
        // roster and the search is genuinely useful there.
    }

    /// Holdings region — branches by the network-error state, then by
    /// filter view mode, then by the segmented tab (in split mode only).
    ///
    /// Branches on `filterViewModeRaw`:
    /// - `.split` — the original shape: a segmented Coins/Tokens
    ///   switcher in chrome, only the selected section renders below.
    /// - `.combined` — one unified section with every coin AND every
    ///   token mixed, sorted by the user's chosen key + direction.
    ///   The segmented switcher disappears (see `chromeSection`
    ///   below).
    @ViewBuilder
    private var holdingsBody: some View {
        if showsNetworkErrorState {
            // Fresh wallet + total scan failure — nothing persisted,
            // so the all-supported $0.00 list would be a lie. Show
            // the honest error state with a Retry CTA instead
            // (2026-06-12).
            networkErrorSection
        } else {
            switch filterViewMode {
            case .split:
                switch selectedHoldingsTab {
                case .coins:  coinsSection
                case .tokens: tokensSection
                }
            case .combined:
                combinedSection
            }
        }
    }

    /// Unified balance + chart card — the hero fiat number and the
    /// sparkline chart sit inside ONE rounded white card surface,
    /// the iOS-canonical inset-grouped row chrome iOS Settings,
    /// Health, and Apple Stocks use for their hero cards.
    ///
    /// **2026-06-09 — the user direction:** *"we'll make the balance
    /// & chart inside a card and we'll make the chart work on
    /// 1d, 1w, 1M, 1Y, ALL and make all of them works %100."* The
    /// hero + chart were two separate `Color.clear`-backed rows that
    /// floated over the page color; merging them into one Section
    /// with default `Material.card` row backgrounds lets iOS draw
    /// the unified white card around both, with native concentric
    /// corners, native dark-mode tone, and native Smart Invert /
    /// Increase Contrast — for free.
    ///
    /// **Why a separate Section instead of merging with the chrome
    /// section.** The action region (Send / Receive / Swap) and the
    /// holdings tab picker are Liquid Glass chrome that floats over
    /// the page color (Rule #2 §B.3); they keep their cleared row
    /// backgrounds. The hero + chart are content — they earn the
    /// card. Splitting into two Sections lets iOS render the card
    /// around the content rows without leaking into the floating
    /// chrome rows.
    ///
    /// **Header row separator.** The `.listRowSeparator(.hidden)` on
    /// the hero row suppresses the divider between hero and chart —
    /// they read as one calm surface, not as two adjacent list rows.
    @ViewBuilder
    private var balanceCardSection: some View {
        // Production — the flagship `BalanceCardView` as ONE
        // full-bleed row. The card owns its own gradient surface,
        // 30pt radius, watermark, header, balance, change pill,
        // chart, and segmented selector (the design handoff
        // `design_handoff_balance_card 2/`), so the list row is
        // chrome-free: a `Color.clear` background, hidden
        // separators, and a 16pt horizontal inset (the handoff's
        // "screen − 2×16pt margins") with zero vertical inset (the
        // card draws its own internal padding). This replaces the
        // prior two-row hero + sparkline split.
        Section {
            // 2026-06-18 native perf fix — the balance card is wrapped in a
            // leaf that OWNS the high-churn `chainStateRecords` @Query, so the
            // refresh coordinator's ~300ms aggregate commits re-render only
            // the card, never this whole body (Apple "extract subviews to
            // localize invalidation"). The parent passes the live balance-row
            // sum as the pre-aggregate fallback; the leaf computes the hero
            // total from the per-chain aggregate rows internally.
            BalanceCardLiveSection(
                walletId: activeWallet?.id,
                walletName: activeWallet?.name ?? String.apertureLocalized("Wallet"),
                avatarSpec: activeWallet?.avatarSpec
                    ?? WalletAvatarSpec.auto(name: activeWallet?.name ?? "Wallet"),
                liveBalanceSum: liveBalanceSum,
                currencyCode: currencyCode,
                transactions: allTransactions,
                currentBalances: balances.map { $0.balance },
                // The wallet's own addresses (lowercased) so the chart can
                // drop self-transfers (counterparty == one of these).
                ownAddresses: Set((activeWallet?.addresses ?? []).map { $0.address.lowercased() }),
                priceHistory: priceHistoryMemo,
                scrubModel: scrubModel,
                onSwitchWallet: { isShowingSwitcher = true },
                onAddFunds: { isShowingReceive = true }
            )
            // Re-key on the active wallet so the per-wallet hidden
            // flag's `@AppStorage` key (which embeds the id) is
            // re-resolved when the user switches wallets — the new
            // wallet shows its own remembered hidden state.
            .id(activeWallet?.id)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            // Zero row insets so the card surface fills the inset-grouped
            // section's content width — its left/right edges then line up
            // exactly with the holdings/transactions grouped card below
            // (which uses the same section width). The card draws its own
            // internal padding; the section margin handles the screen gap.
            .listRowInsets(EdgeInsets())
        }
    }

    // 2026-06-14 — sync is background-only and has NO UI surface. The
    // under-card `freshnessStampSection` footnote AND the app-bar
    // syncing↔iris mark were both removed per user direction ("we don't
    // need it in the UI, just run in the background"). The background
    // writer still stamps `SyncStatusRecord` so freshness is tracked;
    // nothing renders it.

    // 2026-06-18 — the `walletHomeHeaderRow` helper (a standalone
    // `WalletHomeHeader`) was DEAD code: never referenced anywhere in the
    // body. `BalanceCardView` renders its own header, so the production card
    // never reused this. Removed as part of the native perf fix — it read
    // the old parent `totalFiat` (now computed inside `BalanceCardLiveSection`).

    /// Floating chrome rows — biometric banner, glass action triplet,
    /// Coins/Tokens segmented switcher. Cleared row backgrounds and
    /// hidden separators so they float over the page color rather
    /// than sitting inside an inset card. The balance + chart live
    /// in `balanceCardSection` above; this section is purely chrome.
    @ViewBuilder
    private var chromeSection: some View {
        Section {
            // First-time-feature hint anchored to the wallet home
            // (not the tab label — iOS 26's TabView label closure
            // sits inside UIKit's tab-bar button chrome which has
            // no SwiftUI popover anchor). `TipView` renders the
            // same TipKit data as a native card inline, with the
            // X dismiss button, the image, the title, the message
            // — same chrome Apple ships in Mail's tip cards.
            // Eligibility predicates on `WalletTabSwitcherTip`'s
            // `walletCount >= 2` rule + `MaxDisplayCount(1)` so the
            // card appears exactly once per user, then never
            // again. `task(id: allWallets.count)` keeps the
            // `@Parameter` in sync as wallets get created.
            TipView(walletSwitcherTip)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: UniSpacing.m,
                    bottom: UniSpacing.m,
                    trailing: UniSpacing.m
                ))
                .task(id: allWallets.count) {
                    WalletTabSwitcherTip.walletCount = allWallets.count
                }

            if requiresBiometricReenrollment {
                BiometricReenrollmentBanner()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: UniSpacing.m,
                        bottom: 0,
                        trailing: UniSpacing.m
                    ))
            }

            WalletActionRegion(
                canSend: activeWallet?.kind != .watchOnly,
                onSend: { isShowingSend = true },
                onReceive: { isShowingReceive = true },
                onSwap: { isShowingSwap = true }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: UniSpacing.m,
                bottom: 0,
                trailing: UniSpacing.m
            ))

            // Background-swap banner (2026-06-17). When a swap is running in
            // `SwapBackgroundManager` — the user tapped "Run in the
            // background" — or has just finished, it shows here directly under
            // the actions: tappable to reopen its live status, dismissable
            // once it's done.
            if let job = swapManager.bannerJob {
                SwapBackgroundBanner(
                    job: job,
                    onOpen: { openSwapJobId = job.id },
                    onDismiss: { swapManager.dismiss(job.id) }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: UniSpacing.xs,
                    leading: UniSpacing.m,
                    bottom: 0,
                    trailing: UniSpacing.m
                ))
            }

            // Coins ↔ Tokens segmented switcher. Native iOS
            // `.pickerStyle(.segmented)` — the same control iOS
            // Settings uses for its "Display & Brightness" Light /
            // Dark toggle. Swipe / tap to change the active tab;
            // `holdingsBody` renders the matching section.
            //
            // 2026-06-09 — only renders in `.split` view mode. In
            // `.combined` mode the picker would be a no-op (one
            // mixed list, no tab to switch) and would read as
            // visual noise; the filter sheet's "Style → Combined"
            // choice IS the affordance, and the picker disappears
            // to honor it.
            // Also hidden while the total-failure error state owns
            // the holdings region — switching Coins/Tokens over an
            // error card would be a no-op (2026-06-12).
            if filterViewMode == .split && !showsNetworkErrorState {
                holdingsTabPicker
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    // Tightened vertical padding per 2026-06-09 user
                    // direction so the picker sits closer to the action
                    // region above and the section below.
                    .listRowInsets(EdgeInsets(
                        top: UniSpacing.xxs,
                        leading: UniSpacing.m,
                        bottom: UniSpacing.xxs,
                        trailing: UniSpacing.m
                    ))
            }
        }
    }

    /// Native segmented picker — Coins | Tokens.
    private var holdingsTabPicker: some View {
        Picker("Holdings tab", selection: $selectedHoldingsTab) {
            Text("Coins").tag(HoldingsTab.coins)
            Text("Tokens").tag(HoldingsTab.tokens)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Switch between Coins and Tokens"))
    }

    // MARK: - Holdings section (native List)

    // MARK: - Coins section (native coins, 10-row cap + Show all)

    /// Coins section — one `AssetRow` per `coinHoldings` row.
    /// Capped at `holdingsDisplayCap` (10). When the wallet holds
    /// more than 10 coins, the trailing "Show all" navigation row
    /// pushes to `WalletHomeDestination.allSupported`. When the
    /// wallet holds 10 or fewer, no trailing row (everything held
    /// fits in the section).
    ///
    /// Section header `"COINS"` rendered uppercase by
    /// `.listStyle(.insetGrouped)` — same chrome iOS Settings uses
    /// for its "MOBILE DATA" / "GENERAL" labels.
    @ViewBuilder
    private var coinsSection: some View {
        // The user's Filter & Sort preferences are applied off-body
        // via the pure `WalletHomeFilterApply.apply(coins:with:)`
        // helper inside `rebuildFilteredRows()`; this section just
        // renders the memoized result. The base `coinDisplayRows`
        // is the home-screen sort (held-first canonical); the
        // filter re-sorts per the user's chosen key + direction and
        // drops hidden chains / hidden assets / zero balances per
        // the toggles. Pinned rows ride at the head of the array.
        let allRows = filteredCoinRows
        // Re-partition so the view can render Pinned + non-pinned
        // as two separate `Section`s (the apply helper concatenates
        // them, but the rendering needs them apart so the "Pinned"
        // header lives above the pinned rows).
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = WalletHomeFilterApply.partitionPinned(coins: allRows, pinned: pinnedSet)
        let nonPinnedDisplayed = Array(nonPinned.prefix(holdingsDisplayCap))
        let hasMore = nonPinned.count > holdingsDisplayCap

        // Pinned section — header only renders when at least one
        // coin is pinned. Pinned rows never count against the
        // 10-row cap; they're the user's stated priority.
        if !pinned.isEmpty {
            Section {
                // **2026-06-09 perf.** Stable identity via
                // `chain.rawValue` instead of `.enumerated().offset`.
                // The offset shifts every time the array re-sorts (every
                // body render under the current state-storm), which
                // destroyed + recreated every row → re-ran `.task(id:)`
                // on every `CoinMark` → re-fetched + re-decoded every
                // token icon every body render. Stable id = SwiftUI
                // reuses the row + the icon view + the cached image.
                ForEach(pinned, id: \.chain.rawValue) { row in
                    coinNavigationRow(row)
                }
            } header: {
                Text("Pinned")
            }
        }

        Section {
            ForEach(nonPinnedDisplayed, id: \.chain.rawValue) { row in
                coinNavigationRow(row)
            }
            if hasMore { showAllRow }
        }
        // No section header — the segmented picker in chrome is
        // the canonical "you're looking at Coins" affordance now
        // (2026-06-09). Stacking a "Coins" header on top of an
        // already-selected "Coins" tab would be noise.
    }

    // MARK: - Tokens section (registry tokens, 10-row cap + Show all)

    /// Tokens section — one `TokenHoldingRow` per `tokenHoldings`
    /// row. Capped at `holdingsDisplayCap` (10) with the same
    /// "Show all" trailing-row rule. Rows display the token symbol,
    /// the chain it lives on, the native amount, and the fiat
    /// equivalent. Treeline-free — these are top-level rows in the
    /// flat layout, not nested under a chain.
    @ViewBuilder
    private var tokensSection: some View {
        // Memoized filter + sort — same rationale as `coinsSection`.
        // Pinned tokens get their own Section above the rest with
        // the "Pinned" header.
        let allRows = filteredTokenRows
        let pinnedSet = filterInputs.pinnedAssets
        let (pinned, nonPinned) = WalletHomeFilterApply.partitionPinned(tokens: allRows, pinned: pinnedSet)
        let nonPinnedDisplayed = Array(nonPinned.prefix(holdingsDisplayCap))
        let hasMore = nonPinned.count > holdingsDisplayCap

        if !pinned.isEmpty {
            Section {
                ForEach(pinned, id: \.id) { row in
                    tokenNavigationRow(row)
                }
            } header: {
                Text("Pinned")
            }
        }

        Section {
            ForEach(nonPinnedDisplayed, id: \.id) { row in
                tokenNavigationRow(row)
            }
            if hasMore { showAllRow }
        }
        // Header omitted — see the coinsSection note above.
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
        NavigationLink(value: WalletHomeDestination.assetDetail(.nativeCoin(row.chain))) {
            AssetRow(
                chain: row.chain,
                tokenSymbol: row.chain.ticker,
                nativeAmount: row.amount,
                nativeDecimals: min(row.chain.nativeDecimals, 8),
                fiatValue: row.fiatValue,
                fiatCurrencyCode: row.fiatCurrencyCode
            )
            // 2026-06-18 Part 3.5 — skip the row's body re-eval when its
            // value inputs are unchanged (most parent re-evals during refresh).
            .equatable()
        }
        .accessibilityLabel(Text("\(row.chain.displayName) details"))
    }

    /// Wrap a token row in a `NavigationLink(value:)`. The
    /// destination is the symbol-scoped asset detail — tapping
    /// "USDC on Polygon" lands on the cross-network USDC view (not
    /// the USDC-on-Polygon-only sub-view; the user reaches that
    /// from inside the asset detail's Networks section).
    @ViewBuilder
    private func tokenNavigationRow(_ row: WalletTokenSupportedDisplayRow) -> some View {
        NavigationLink(value: WalletHomeDestination.assetDetail(.token(symbol: row.symbol))) {
            supportedTokenRow(row)
        }
        .accessibilityLabel(Text("\(row.symbol) details"))
    }

    // MARK: - Combined section (Filter view mode = .combined)

    /// **Combined holdings section** — every coin + every token in
    /// one unified, filter-sorted list. Renders only when the
    /// Filter & Sort sheet's "Style" is `.combined`. The Coins /
    /// Tokens segmented switcher disappears (see `chromeSection`)
    /// because the picker would be a no-op in this mode.
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
                ForEach(displayed, id: \.id) { item in
                    combinedRow(item)
                }
                if hasMore { showAllRow }
            }
        case .chain:
            // Group nonPinned by chain. Sections rendered in
            // alphabetical order of `chain.displayName`. Within
            // each section, rows retain their pre-sorted order
            // (the merged sort that `combinedFilteredRows` produced).
            let groups = groupByChain(nonPinned)
            ForEach(groups, id: \.chain) { group in
                Section {
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
        SupportedTokenRow(row: row).equatable()
    }

    // MARK: - Empty holdings section

    /// Single empty-state row in a section labeled "Holdings".
    /// Only appears when both `coinHoldings` and `tokenHoldings`
    /// are empty (a fresh wallet whose scanner hasn't filled yet,
    /// or a wallet that genuinely holds nothing).
    @ViewBuilder
    private var emptyHoldingsSection: some View {
        Section {
            UniEmptyState(
                title: "Your holdings will appear here.",
                detail: "Receive crypto to any of your addresses and it'll show up the moment it lands on-chain."
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Holdings")
        }
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
            .contentShape(Rectangle())
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
        guard let wallet = activeWallet else { return [] }
        var result: [(SupportedChain, TokenBalanceRecord)] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for balance in address.balances where !balance.rawBalance.isEmpty {
                result.append((chain, balance))
            }
        }
        return result
    }

    /// `[symbol-uppercased: price]` map filtered to the active fiat,
    /// used by `BalanceHistoryChart` so the reconstructor can value
    /// past holdings of fully cashed-out tokens (the 2026-06-12
    /// USDT-flat-chart bug). Reads from the `cachedPrices` `@Query`
    /// which observes `CachedPriceRecord` rows — the same rows
    /// `CoinbasePriceService` writes through. The cache stays warm
    /// across launches per `PriceCacheRepository`'s no-TTL policy.
    /// **2026-06-13 perf — memoized price dictionaries.** These two
    /// dicts feed `BalanceHistoryChart`. They were computed properties
    /// rebuilt INSIDE `body` on every render — `priceHistoryBySymbol`
    /// iterates the entire `historicalPrices` `@Query` (≈300 closes ×
    /// every token × every currency). With deep history that's hundreds
    /// of ms per render, and the unlock / navigation transition renders
    /// several times in a row → the 2-second freeze the user reported.
    /// Now they live in `@State`, rebuilt only when the underlying
    /// price data actually changes (see `priceDataFingerprint` +
    /// `rebuildPriceMemos()`), so `body` just reads the cached dicts.
    @State private var priceHistoryMemo: [String: [Int: Decimal]] = [:]

    /// Cheap (O(1)) fingerprint that flips whenever the price tables or
    /// the active currency change — gates `rebuildPriceMemos()` via
    /// `.task(id:)`. Counts only; no per-row iteration here.
    private var priceDataFingerprint: String {
        // `cachedPrices` moved to the leaves (Part 3.1); the parent now only
        // memoizes the historical close series the chart needs.
        "\(historicalPrices.count)|\(currencyCode)"
    }

    /// Rebuild the two memoized price dictionaries. The only place that
    /// pays the O(N) iteration over the price `@Query` results — called
    /// from `.task(id: priceDataFingerprint)`, not from `body`.
    private func rebuildPriceMemos() {
        var history: [String: [Int: Decimal]] = [:]
        for row in historicalPrices where row.fiat == currencyCode {
            history[row.symbol.uppercased(), default: [:]][row.dayKey] = row.price
        }
        priceHistoryMemo = history
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

    /// Cheap SwiftData change proxy — balance-row count across the
    /// active wallet's addresses. Counting is O(addresses) per body
    /// pass; the expensive registry enumeration + flatMap + sort only
    /// runs when the count actually changes. Value-only updates (a
    /// refresh re-pricing existing rows) are caught by the explicit
    /// rebuild at the end of `runRefresh()` and the refresh-completion
    /// observer. (Transactions used to have a parallel proxy here, but
    /// they now read live from a top-level `@Query` — see
    /// `allTransactionRecords` — so no relationship-count proxy is
    /// needed, and the relationship-count proxy never saw cross-context
    /// inserts anyway, which was the live-tx bug.)
    private var balanceRowsRevision: Int {
        guard let wallet = activeWallet else { return 0 }
        return wallet.addresses.reduce(0) { $0 + $1.balances.count }
    }

    /// Decode the `@AppStorage`-bound preference values into the
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
    }

    /// O(1) key for the dust-price load — re-fires on wallet switch or a
    /// tx count change, the only moments the feed's symbol set can grow.
    private var dustPriceKey: String {
        "\(activeWalletIdRaw)|\(allTransactionRecords.count)"
    }

    /// Resolve USD unit prices for the recent feed's distinct symbols so
    /// the $0.01-USD dust gate can run on the home preview. Cheap after
    /// the first call (engine-cached) and cancellation-safe — a wallet
    /// switch re-keys the task, cancelling this before a stale write.
    private func loadDustPrices() async {
        let symbols = allTransactions.map(\.tokenSymbol)
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
                assets: catalogAssets
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
                Spacer(minLength: UniSpacing.s)
                Button {
                    navigationPath.append(WalletHomeDestination.allActivity)
                } label: {
                    Text("View all")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.link)
                        .textCase(nil)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows the full transaction history"))
            }
        } else {
            Text("Recent activity")
        }
    }

    /// Production activity rows — each `TransactionRecord` becomes
    /// one tappable list row. The `Button` carries the navigation
    /// dispatch; the row's tap target is the row itself thanks to
    /// `.contentShape` on `ActivityRow` and `.buttonStyle(.plain)`.
    /// Production activity rows — extracted into the value-typed, `.equatable()`
    /// `RecentActivityRows` leaf (2026-06-18, Part 3.5). The parent maps the 5
    /// recent transactions into a small `ActivityRowModel` snapshot; the leaf
    /// then skips rebuilding the `ActivityRow` subtrees whenever that snapshot +
    /// currency are unchanged — so an unrelated SwiftData merge that re-evaluates
    /// this body no longer reconstructs the activity rows.
    @ViewBuilder
    private var productionActivityRows: some View {
        RecentActivityRows(
            rows: recentActivityModels,
            currencyCode: currencyCode,
            onSelect: { navigationPath.append(WalletHomeDestination.transaction($0)) }
        )
    }

    /// **Activity empty state.** Sibling to `emptyHoldingsSection` — same
    /// iris watermark, same elliptical lift, same copy register. The
    /// two empty surfaces sit in the same list; reading them as a
    /// pair (Holdings empty / Activity empty) confirms the wallet is
    /// alive and waiting rather than broken or stuck.
    private var emptyActivity: some View {
        UniEmptyState(
            title: "No activity yet.",
            detail: "Transactions appear here as they confirm on-chain."
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 2026-06-09 — the four-tab shell (`MainTabView`) replaced
        // the wallet-home's Settings sheet, so the leading-edge
        // gear is gone. The toolbar now carries one item: the
        // wallet-pill in `.principal`, which is the wallet-identity
        // affordance (tap to switch wallets). The tab bar handles
        // top-level navigation; the nav bar handles wallet
        // identity. Different facets, both legitimate.
        ToolbarItem(placement: .principal) {
            // 2026-06-09 — the pill now leads with the active
            // wallet's `WalletAvatar` (symbol + colorHex). The
            // text remains the wallet's name; the trailing chevron
            // signals "tap to switch."
            //
            // **Tap** opens the full `WalletSwitcherSheet` (the
            // index of every wallet with create/import affordances
            // at the bottom). **Long-press** opens the native iOS
            // 26 Liquid Glass `contextMenu` (the Telegram /
            // Instagram fast-switch pattern). Both gestures land
            // on the same affordance because the pill IS the
            // active-wallet identity on this screen — same affordance,
            // two depths.
            //
            // 2026-06-09 — pass the active wallet's gradient-disc
            // spec to the pill so the leading slot renders the
            // new avatar. Falls back to an auto(name)-derived
            // spec from the default "Wallet" name when no active
            // wallet exists yet (cold launch before
            // `ensureActiveWalletSet()` lands one).
            let pillSpec: WalletAvatarSpec = activeWallet?.avatarSpec
                ?? WalletAvatarSpec.auto(name: "Wallet")
            UniButton(
                verbatim: activeWallet?.name ?? String.apertureLocalized("Wallet"),
                variant: .walletPill,
                walletSpec: pillSpec,
                walletId: activeWallet?.id
            ) {
                isShowingSwitcher = true
            }
            .accessibilityLabel(Text("Switch wallet, currently \(activeWallet?.name ?? "")"))
            // **Long-press switcher — split by size class
            // (2026-06-16).**
            //
            // COMPACT (iPhone): no `.contextMenu` here. The
            // long-press wallet switcher lives on the bottom
            // tab bar's Wallet button (via
            // `TabBarLongPressInstaller`). Tap on this toolbar
            // pill opens the switcher SHEET; the tab-bar
            // long-press is the Telegram/Instagram-style fast
            // switcher. This path is unchanged from 2026-06-09.
            //
            // REGULAR (iPad landscape / wide Mac): in sidebar
            // mode there is no UITabBar, so the installer can't
            // attach — the switcher would silently die. We
            // attach the native SwiftUI `walletPillContextMenu`
            // here instead (Switch wallet / Customise / Add /
            // Manage — the SAME actions). `.contextMenu` is a
            // pure-SwiftUI modifier, so it works on the toolbar
            // pill at any width; gating to `.regular` keeps the
            // iPhone gesture exactly as it was.
            .modifier(
                WalletPillRegularWidthMenu(
                    isRegularWidth: horizontalSizeClass == .regular,
                    menu: { walletPillContextMenu }
                )
            )
        }
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
        // through the existing `@Query` machinery, the tab icon
        // re-renders, every consumer updates simultaneously.
        ForEach(allWallets) { wallet in
            Button {
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
        // the deep-link token. `SettingsView` consumes it on
        // appear and pushes onto its NavigationPath.
        Button {
            settingsDeepLink = "wallets"
            selectedTabRaw = MainTab.settings.rawValue
        } label: {
            Label("Manage wallets", systemImage: "list.bullet")
        }
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
    /// `@Query` is only an index. Every projection input — hero
    /// `balances`, `allHeldRows`, the memoized display/transaction
    /// rows, the chart inputs, the revision proxies — and the toolbar
    /// pill resolve through this one property, so the displayed
    /// selection and the displayed data derive from the same wallet
    /// id on every pass and cannot disagree.
    ///
    /// Resolution order:
    /// 1. Stored id has a `@Query` match → that record (the normal,
    ///    cheap path; no store round-trip).
    /// 2. Stored id resolves directly against the store → that
    ///    record. Covers BOTH merge windows: an import the main
    ///    context hasn't merged yet (the 2026-06-12 pattern), and a
    ///    post-delete successor write that landed before this body
    ///    pass saw the updated query results.
    /// 3. No / dangling stored id → the first query record that still
    ///    exists in the store. Skipping store-deleted rows matters:
    ///    during the post-delete merge window the `@Query` can still
    ///    contain the deleted record, and the prior unconditional
    ///    `allWallets.first` fallback let the pill and the memoized
    ///    projections resolve DIFFERENT wallets at different instants
    ///    — the "$50 wallet selected, $700 wallet's data" report.
    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw) {
            if let match = allWallets.first(where: { $0.id == uuid }) {
                return match
            }
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == uuid }
            )
            descriptor.fetchLimit = 1
            if let stored = try? modelContext.fetch(descriptor).first {
                return stored
            }
            // A deliberately-set, VALID active id that the main context
            // can't see yet (cross-context merge lag right after a
            // create / import — the new WalletRecord is saved in a
            // background `@ModelActor` context and merges a beat later).
            // Return nil → render the empty/loading state — NEVER fall
            // back to a DIFFERENT wallet, which surfaced the previous
            // wallet's balances under the new wallet's identity (the
            // "new wallet briefly shows 0, then the old wallet's $250"
            // bug). The id is trusted; the wallet appears the instant
            // the merge lands.
            return nil
        }
        // Only when NO valid active id is set (first launch / a cleared
        // pointer) do we heal to the first wallet.
        return allWallets.first(where: { walletExists(id: $0.id) })
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
        guard let wallet = activeWallet else { return [] }
        let threshold = Decimal(hideSmallThreshold)
        var result: [(SupportedChain, TokenBalanceRecord)] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for balance in address.balances where !balance.rawBalance.isEmpty && balance.rawBalance != "0" {
                if balance.fiatValueCached >= threshold {
                    result.append((chain, balance))
                }
            }
        }
        return result.sorted { $0.1.fiatValueCached > $1.1.fiatValueCached }
    }

    /// The live balance-row sum — the pre-aggregate fallback the hero shows
    /// until the per-chain `ChainStateRecord` rows land. Sums ONLY rows whose
    /// persisted fiat is denominated in the ACTIVE currency (the hero formats
    /// with `currencyCode`, so a row still carrying the previous currency's
    /// value would render 35 JOD as "$35" — the 2026-06-13 currency-change
    /// bug). Rows in the old currency drop out until `repriceWallet`
    /// re-denominates them.
    ///
    /// **The aggregate (preferred) total is computed inside
    /// `BalanceCardLiveSection`** (2026-06-18), which owns the
    /// `chainStateRecords` @Query, so the coordinator's 300ms commits don't
    /// re-evaluate this whole body. This view only computes the cheap live
    /// sum and hands it down as the fallback.
    private var liveBalanceSum: Decimal {
        balances.reduce(Decimal.zero) { running, entry in
            entry.balance.fiatCurrencyCode == currencyCode
                ? running + entry.balance.fiatValueCached
                : running
        }
    }

    /// Distinct chains with at least one non-zero balance row. Used by
    /// the rollup line so "3 chains · 5 tokens" refers to what's *held*
    /// rather than what's *supported* (the latter falls back via
    /// `WalletHomeHeader.totalChainsSupported` when no balance exists
    /// yet, so the user sees "26 chains supported" on a fresh wallet
    /// instead of "0 chains · 0 tokens").
    private var chainsHeldCount: Int {
        Set(balances.map { $0.chain }).count
    }

    // `recentTransactions` / `allTransactions` are now LIVE computed
    // properties over the top-level `@Query` (`allTransactionRecords`)
    // — see their declarations near the top of the view. The old
    // `rebuildTransactionRows()` snapshot builder was removed
    // (2026-06-13): it read `wallet.addresses.flatMap { $0.transactions }`,
    // a relationship traversal that never reflected cross-context
    // inserts, so newly-scanned transactions only appeared after an
    // app relaunch. The live `@Query` fixes that with no rebuild calls.

    /// Resolves the chain a `TransactionRecord` belongs to via its
    /// back-pointer to `WalletAddressRecord.chainRaw`. The schema
    /// guarantees the back-pointer (transactions are cascade-children
    /// of addresses), so the fallback to `.ethereum` is defensive
    /// only — it only fires if the record is orphaned, which the
    /// repository never produces.
    private func chainFor(_ tx: TransactionRecord) -> SupportedChain {
        if let raw = tx.address?.chainRaw,
           let chain = SupportedChain(rawValue: raw) {
            return chain
        }
        return .ethereum
    }

    /// Latest `lastScannedAt` across all addresses, or nil if no scan
    /// has ever completed.
    private var mostRecentScanAt: Date? {
        guard let wallet = activeWallet else { return nil }
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
        // a background `@ModelActor` context and merges a beat later, so
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
        var descriptor = FetchDescriptor<WalletRecord>(
            sortBy: [SortDescriptor(\WalletRecord.sortOrder)]
        )
        descriptor.fetchLimit = 1
        if let first = try? modelContext.fetch(descriptor).first {
            activeWalletIdRaw = first.id.uuidString
        }
    }

    /// Store-truth existence check for a wallet id. A direct
    /// `fetchCount` hits the persistent store, so it sees rows the
    /// repository actor has already saved even before this view's
    /// `@Query` has merged them.
    private func walletExists(id: UUID) -> Bool {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    // MARK: - Historical-price ensure-loop (2026-06-12)

    /// `(walletId, currencyCode, txCount, balanceCount)` fingerprint —
    /// re-runs the ensure-loop when any of these change so a new tx
    /// involving an asset we don't have history for triggers a
    /// fetch. Counts are cheap; symbol-set scans are not, so we
    /// gate on count first.
    private var historicalEnsureKey: String {
        [
            activeWallet?.id.uuidString ?? "",
            currencyCode,
            String(allTransactions.count),
            String(allHeldRows.count)
        ].joined(separator: "|")
    }

    /// Fetch historical close prices for every unique symbol the
    /// wallet has touched (current holdings + tx history), skipping
    /// any (symbol, fiat) pair we already have rows for in
    /// `HistoricalPriceRepository`. Best-effort; failures degrade
    /// silently to today's spot via the reconstructor's fallback
    /// chain.
    private func ensureHistoricalPricesLoaded() async {
        // Collect unique symbols from held balances + tx history.
        var symbols = Set<String>()
        for entry in allHeldRows {
            symbols.insert(entry.balance.tokenSymbol.uppercased())
        }
        for tx in allTransactions {
            symbols.insert(tx.tokenSymbol.uppercased())
        }
        guard !symbols.isEmpty else { return }

        // Symbols we already have history for in the target fiat —
        // skip those.
        let existing = Set(historicalPrices
            .filter { $0.fiat == currencyCode }
            .map { $0.symbol.uppercased() })

        // Rule #27 §A — the view does NOT touch the network. It hands
        // the sync layer the desired symbols + what the store already
        // has (both DB-derived) and lets the coordinator own the fetch,
        // the store write, and the freshness stamp.
        // **Part 4.6 — age-driven history depth.** The default 400 days
        // (~13 months) starves `All` (and the older end of `1Y`) on a wallet
        // older than that: its early period has no price coverage, so the chart
        // goes flat/straight there. Drive `days` from the wallet's OLDEST
        // transaction so the full lifetime is covered. Capped at ~5.5y so a
        // single request stays bounded (the server's own max also applies);
        // deeper history beyond the cap is the deferred chunking case.
        // `allTransactions` is newest-first, so `.last` is the oldest.
        let oldestTxDate = allTransactions.last?.occurredAt
        let lifetimeDays = oldestTxDate.map { Int(ceil(Date().timeIntervalSince($0) / 86_400)) + 5 } ?? 400
        let days = min(max(400, lifetimeDays), 2_000)

        let coordinator = WalletRefreshCoordinator(container: modelContext.container)
        await coordinator.syncHistoricalCloses(
            symbols: Array(symbols),
            fiat: currencyCode,
            alreadyHave: existing,
            days: days
        )
    }

    // MARK: - Refresh

    /// Run one wallet refresh. `userInitiated` distinguishes a
    /// pull-to-refresh / Retry tap from the auto-refresh: a user
    /// pull CANCELS any wedged in-flight pipeline and starts fresh
    /// (the user asked for *now*, not for "whenever the stalled one
    /// finishes"); the auto-refresh keeps the cheaper join
    /// semantics. The refresh outcome (failed chains, if any) is
    /// published on `WalletRefreshState.shared`, which this view
    /// observes to render the honest network-error surfaces.
    private func runRefresh(userInitiated: Bool = false) async {
        guard let walletId = await resolveRefreshWalletId() else { return }
        await MainActor.run { isRefreshing = true }
        let coordinator = WalletRefreshCoordinator(container: modelContext.container)
        await coordinator.refreshWallet(
            walletId: walletId,
            fiatCode: currencyCode,
            userInitiated: userInitiated
        )
        await MainActor.run {
            isRefreshing = false
            // A refresh can re-price existing balance rows without
            // changing row counts, which the count-based change proxy
            // can't see — rebuild the memoized DISPLAY projections
            // explicitly now that the coordinator has finished writing.
            // Transactions need no rebuild — they read live from the
            // top-level `@Query`.
            rebuildDisplayRows()
            // **2026-06-10 handoff signature.** Pull-to-refresh
            // complete fires the iris-settle pattern (soft tick →
            // medium tap). Per Rule #10 §I, signatures are gated
            // through `UniHapticEngine` so the AppStorage toggle
            // and Reduce Motion are both honored.
            //
            // **userInitiated-only (2026-06-12).** Silent automatic
            // refreshes (on appear, on wallet switch, post-import)
            // used to fire this too — a phantom buzz with no touch
            // behind it (part of the user's "haptics while doing
            // nothing" report). A settle haptic answers the user's
            // own pull; the system's background work stays silent.
            //
            // Also skipped while a replacement pipeline is still
            // running (this run was cancelled by a user pull, or
            // superseded by a wallet switch) — "settled" before the
            // spinner stops would be a lie in the hand (2026-06-12).
            if userInitiated, !refreshState.isRefreshing {
                UniHapticEngine.shared.play(.signature(.irisSettle))
            }
        }
    }

    /// Currency-change re-price (2026-06-13, **deep fix 2026-06-13b**).
    ///
    /// **The bug this replaces.** The previous version re-priced via
    /// `WalletRefreshCoordinator.repriceWallet`, which writes the new
    /// `fiatValueCached` / `fiatCurrencyCode` through a background
    /// `@ModelActor` context. SwiftData reliably propagates *inserts*
    /// from another context into an observing `@Query` (that's why a
    /// first scan / import shows balances), but it does **not**
    /// reliably refresh already-materialized to-many CHILD objects
    /// when another context UPDATES their scalar fields — the main
    /// view's `activeWallet.addresses[].balances` kept their old JOD
    /// values until the context was recreated (app relaunch). Because
    /// `totalFiat` sums **only** rows whose `fiatCurrencyCode` equals
    /// the active currency, every still-JOD row dropped out → the hero
    /// read `$0.00`, a refresh "did nothing" (same stale objects), and
    /// only a cold launch (fresh context, fresh fetch from the store)
    /// healed it. Exactly the user's report.
    ///
    /// **The fix.** Re-price by mutating the LIVE `@Query` objects on
    /// the MAIN context, then `save()`. The view's own context owns
    /// these objects, so `totalFiat` and the per-row display see the
    /// new currency the instant the save returns — zero cross-context
    /// lag, no relaunch. Prices are fetched off-main through the full
    /// `TokenPricingEngine` ladder (live Coinbase / CoinGecko →
    /// per-currency cache → balance-derived FX cross), then applied
    /// on-main. Quantities don't change when the currency does, so no
    /// chain rescan is needed; the user can pull-to-refresh for fresh
    /// on-chain balances. (Dropping the old trailing background refresh
    /// also removes a hazard: a rate-limited scan firing right after a
    /// currency switch could write `fiatValueCached: 0` and re-zero the
    /// hero.)
    private func repriceForCurrencyChange() async {
        let code = (CurrencyPreference.currency(for: currencyCode)?.code
            ?? CurrencyPreference.defaultCode).uppercased()

        // Snapshot the live balance objects + the symbols to price,
        // on the main actor (the view is `@MainActor`-isolated).
        let rows = allHeldRows.map(\.balance)
        guard !rows.isEmpty else { return }
        let symbols = Array(Set(rows.map { $0.tokenSymbol.uppercased() }))

        // Fetch unit prices in the new currency (off-main hop).
        let prices = await TokenPricingEngine.shared.unitPrices(
            symbols: symbols,
            currencyCode: code
        )
        guard !Task.isCancelled else { return }

        // For any row the ladder couldn't price directly, fetch one FX
        // cross per old currency so its existing fiat can be
        // re-denominated rather than dropped to zero.
        var crosses: [String: Decimal] = [:]
        for row in rows where prices[row.tokenSymbol.uppercased()] == nil {
            let from = row.fiatCurrencyCode.uppercased()
            guard from != code, row.fiatValueCached > 0, crosses[from] == nil else { continue }
            crosses[from] = await TokenPricingEngine.shared.crossRate(from: from, to: code)
        }
        guard !Task.isCancelled else { return }

        // Apply on the MAIN context's own objects, then save once.
        var changed = 0
        for row in rows {
            let amount = WalletFormatting.decimalAmount(
                rawBalance: row.rawBalance,
                decimals: row.decimals
            )
            var newFiat: Decimal?
            if let price = prices[row.tokenSymbol.uppercased()] {
                newFiat = amount * price.amount
            } else if row.fiatCurrencyCode.uppercased() != code,
                      row.fiatValueCached > 0,
                      let cross = crosses[row.fiatCurrencyCode.uppercased()] {
                newFiat = row.fiatValueCached * cross
            }
            guard let newFiat else { continue }  // can't price → leave honest in old currency
            row.fiatValueCached = newFiat
            row.fiatCurrencyCode = code
            changed += 1
        }
        if changed > 0 {
            try? modelContext.save()
        }
        // Value-only updates don't move the count proxies — rebuild the
        // memoized display projections explicitly.
        rebuildDisplayRows()
    }

    /// Resolve the wallet id a refresh should run against. Prefers
    /// the stored `activeWalletId` — verified against the store
    /// directly, because the `@Query`-backed `activeWallet` lags the
    /// import flow's actor-context insert: in the merge window right
    /// after an import it silently resolved to the WRONG wallet (the
    /// first one), so the freshly-imported wallet never got scanned
    /// in-session and showed $0.00 until relaunch (2026-06-12). The
    /// bounded retry covers the save-to-visible gap; the `@Query`
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

// MARK: - BalanceCardLiveSection (native invalidation-localization leaf)

/// The flagship balance card, wrapped in a leaf that **owns** the high-churn
/// `chainStateRecords` `@Query`.
///
/// **Why this exists (2026-06-18 native perf fix).** The refresh coordinator
/// rebuilds each chain's `ChainStateRecord` aggregate on a ~300ms cadence
/// during every balance scan. When the `chainStateRecords` `@Query` was
/// declared on `WalletHomeView`, each of those commits re-evaluated the entire
/// 2,790-line `WalletHomeView.body` — Apple's documented `@Query` /
/// `DynamicProperty` behavior is that a *declared* query invalidates the
/// owning view's body on ANY change to its results, whether or not the body
/// reads them. That whole-screen re-evaluation, ~3×/second for the duration of
/// every 30 s auto-refresh, was the periodic main-screen hitch.
///
/// Moving the query into this small leaf (Apple's "extract subviews to localize
/// invalidation zones" guidance) means a 300ms aggregate commit re-renders ONLY
/// the card — the parent body stays put. Behavior is identical: the hero total
/// still prefers the per-chain aggregate and falls back to the parent's live
/// balance-row sum until the first rebuild lands.
private struct BalanceCardLiveSection: View {
    let walletId: UUID?
    let walletName: String
    let avatarSpec: WalletAvatarSpec
    /// The parent's live balance-row sum (active currency) — the pre-aggregate
    /// fallback shown until the per-chain `ChainStateRecord` rows land.
    let liveBalanceSum: Decimal
    let currencyCode: String
    let transactions: [TransactionRecord]
    let currentBalances: [TokenBalanceRecord]
    let ownAddresses: Set<String>
    let priceHistory: [String: [Int: Decimal]]
    let scrubModel: ChartScrubModel
    let onSwitchWallet: () -> Void
    let onAddFunds: () -> Void

    /// The high-churn aggregate rows — owned HERE, not on the parent, so their
    /// 300ms refresh-commits re-render only this card.
    @Query private var chainStateRecords: [ChainStateRecord]

    /// On-disk spot prices — owned HERE (2026-06-18, Part 3.1) instead of on
    /// the parent, so the per-refresh price-batch commit re-renders only this
    /// card, not the whole `WalletHomeView` body. Filtered to the active fiat
    /// into the `[symbol: price]` map the chart consumes (the exact shape the
    /// parent's old `priceCacheMemo` produced).
    @Query private var cachedPrices: [CachedPriceRecord]

    private var priceCacheMap: [String: Decimal] {
        var map: [String: Decimal] = [:]
        for row in cachedPrices where row.fiat == currencyCode {
            map[row.symbol.uppercased()] = row.price
        }
        return map
    }

    /// Hero total. Prefers the per-chain aggregate (active wallet + currency);
    /// falls back to the parent's live balance-row sum so a transiently-zero
    /// aggregate (mid-refresh / stale rebuild) never hides a real, already-
    /// persisted balance — the two converge once the final rebuild runs. This
    /// is the exact resolution the parent's old `totalFiat` performed.
    private var totalFiat: Decimal {
        if let walletId {
            let perChainSum = chainStateRecords
                .filter { $0.walletId == walletId && $0.fiatCurrencyCode == currencyCode }
                .reduce(Decimal.zero) { $0 + $1.totalFiat }
            if perChainSum > 0 { return perChainSum }
        }
        return liveBalanceSum
    }

    /// When the active wallet's balances + history were last refreshed — the
    /// latest per-chain aggregate `updatedAt` (the rebuild runs after the
    /// balance + history passes complete). `nil` before the first scan.
    private var lastUpdated: Date? {
        guard let walletId else { return nil }
        return chainStateRecords
            .filter { $0.walletId == walletId && $0.fiatCurrencyCode == currencyCode }
            .compactMap(\.lastSyncedAt)
            .max()
    }

    var body: some View {
        BalanceCardView(
            walletId: walletId,
            walletName: walletName,
            avatarSpec: avatarSpec,
            totalFiat: totalFiat,
            currencyCode: currencyCode,
            lastUpdated: lastUpdated,
            transactions: transactions,
            currentBalances: currentBalances,
            ownAddresses: ownAddresses,
            priceCache: priceCacheMap,
            priceHistory: priceHistory,
            scrubModel: scrubModel,
            onSwitchWallet: onSwitchWallet,
            onAddFunds: onAddFunds
        )
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
    let counterparty: String
    let occurredAt: Date
    let status: TransactionStatus
    let kind: TransactionKind
}

/// The recent-activity `ForEach`, extracted from `WalletHomeView.body` into a
/// leaf that OWNS the spot-price `@Query` (2026-06-18, Part 3.1). Because
/// `cachedPrices` lives here, a price-batch commit re-renders only this leaf —
/// never the parent body — and each row's fiat is computed from the leaf's own
/// prices. The transaction-derived rows arrive as a value-typed snapshot from
/// the parent (which still owns the tx query for the chart + ensure-loop), so
/// this leaf invalidates on exactly two things: those rows, and the prices.
private struct RecentActivityRows: View {
    let rows: [ActivityRowModel]
    let currencyCode: String
    let onSelect: (UUID) -> Void

    @Query private var cachedPrices: [CachedPriceRecord]

    private var priceMap: [String: Decimal] {
        var map: [String: Decimal] = [:]
        for row in cachedPrices where row.fiat == currencyCode {
            map[row.symbol.uppercased()] = row.price
        }
        return map
    }

    var body: some View {
        let map = priceMap
        ForEach(rows) { row in
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
                    fiatCurrencyCode: currencyCode
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - SupportedTokenRow (value-typed, equatable holdings row)

/// One token holdings row — the logo (`CoinMark`), name/symbol, amount, and
/// fiat — extracted from `WalletHomeView` into a value-typed `Equatable` leaf
/// (2026-06-18, Part 3.5). Rendered via `.equatable()` so a parent body
/// re-evaluation (a SwiftData merge the row doesn't depend on) skips rebuilding
/// the row's body + its `CoinMark` when the row model is unchanged. `==` is
/// `nonisolated` (Equatable requirement vs main-actor `View`) and reads only
/// the Sendable value-typed row.
private struct SupportedTokenRow: View, Equatable {
    let row: WalletTokenSupportedDisplayRow

    nonisolated static func == (lhs: SupportedTokenRow, rhs: SupportedTokenRow) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(chain: row.chain, tokenSymbol: row.symbol, contract: row.contract)
                .frame(width: 44, height: 44)
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
                Text(WalletFormatting.native(row.amount, decimals: 6))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                // Zero/unheld → "US$0.00", never "Price unavailable"
                // (user direction 2026-06-18).
                Text(WalletFormatting.fiat(row.fiatValue ?? 0, currencyCode: row.fiatCurrencyCode))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
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
    /// half-started Send / Swap flow, is surprising — the user
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
