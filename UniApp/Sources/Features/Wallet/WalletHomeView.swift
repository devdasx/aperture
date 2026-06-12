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
    /// On-disk price cache, read by the `BalanceHistoryChart` so the
    /// reconstruction can value past holdings of fully cashed-out
    /// tokens (e.g., a user who received 747 USDT then sent every
    /// unit — currentBalances has no USDT row, so without this
    /// cached price the chart would value the historical USDT
    /// position at zero). The chart filters by the active fiat in
    /// its `priceCacheBySymbol` helper.
    @Query private var cachedPrices: [CachedPriceRecord]
    /// On-disk historical-price cache. Each row is one day's close
    /// for one `(symbol, fiat)` pair. The chart uses this to value
    /// past holdings at their **then-price** instead of today's
    /// spot, so a token that crashed 99% renders past peaks at
    /// honest historical fiat ($4000 then) not today's collapsed
    /// valuation ($50). Populated by `CoinbaseHistoricalPriceService`
    /// via the `.task` ensure-loop below.
    @Query private var historicalPrices: [HistoricalPriceRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var hideBalanceOnHome: Bool = false

    /// 2026-06-09 — toolbar overflow menu reaches `lockNow()` when
    /// the user taps "Lock wallet". The controller's `lockNow()`
    /// is a no-op when PIN isn't configured (Rule #17 §C) — the
    /// menu item is still surfaced; tapping it just doesn't lock
    /// anything, matching iOS Notes' "Lock Note" behavior when
    /// no Notes password is set.
    @Environment(\.autoLockController) private var lockController
    @AppStorage(HideBalancesPreference.thresholdKey) private var hideSmallThreshold: Double = HideBalancesPreference.defaultThreshold

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
    /// **Filter & Sort sheet (2026-06-09).** Drives the
    /// `.sheet(isPresented: $isShowingFilter)` block below. The sheet
    /// reads + writes preferences through `@AppStorage` against
    /// `WalletHomeFilterPreferences`'s keys; changes propagate to
    /// this view's body the moment the sheet writes them.
    @State private var isShowingFilter: Bool = false
    @State private var receivePath: NavigationPath = NavigationPath()
    @State private var navigationPath: NavigationPath = NavigationPath()
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
        !isTestMode
            && refreshOutcomeAppliesToActiveWallet
            && !refreshState.lastRefreshFailedChains.isEmpty
            && allHeldRows.isEmpty
    }

    /// Some chains reported, some didn't — the successful rows render
    /// normally and one quiet footnote keeps the surface honest.
    private var showsPartialNetworkFootnote: Bool {
        !isTestMode
            && refreshOutcomeAppliesToActiveWallet
            && !refreshState.lastRefreshFailedChains.isEmpty
            && !allHeldRows.isEmpty
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
    @AppStorage("selectedTab") private var selectedTabRaw: String = MainTab.wallet.rawValue

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

    /// 2026-06-09 — scrubbed fiat from `BalanceHistoryChart`. Bound
    /// to the chart so the chart can publish the touched point's
    /// fiat upward during a drag; the hero amount renders this
    /// value (animated via `.contentTransition(.numericText())`)
    /// instead of the real total. `nil` when the user isn't
    /// scrubbing → the hero shows the actual `totalFiat`.
    @State private var scrubbedFiat: Decimal?

    // MARK: - Test mode (mirrors MnemonicReviewView's affordance)
    //
    // Tapping the flask in the toolbar swaps the real wallet's
    // SwiftData-backed holdings + activity for an in-memory stream
    // from `RealRPCBalanceScanner` against `TestAddresses.map` —
    // the same curated public addresses the Import → Review
    // screen uses to prove the full pipeline end-to-end on every
    // supported chain and every token in the registry. Purely a
    // developer / verifier affordance; the user's real wallet
    // rows are never mutated and the SwiftData store is never
    // touched while test mode is active.
    //
    // Send / Swap / Switch are disabled while testing — they
    // operate against the user's real wallet and have no honest
    // meaning against a public test address. Receive stays
    // enabled because it reads addresses from the active wallet
    // record (via `@AppStorage("activeWalletId")`), not from the
    // in-memory test bucket.
    //
    // **Storage (2026-06-09):** switched from `@State` to
    // `@AppStorage("isTestMode")` so the Settings → Developer →
    // Test mode toggle can flip the same flag. The toolbar flask
    // icon was removed in the same turn — the affordance now lives
    // in Settings only.
    @AppStorage("isTestMode") private var isTestMode: Bool = false
    @State private var testBalances: [SupportedChain: ChainBalance] = [:]
    @State private var testTokens: [SupportedChain: [TokenBalance]] = [:]
    /// Test-mode transaction history. Mirrors `testBalances` /
    /// `testTokens` — held in-memory only so SwiftData stays clean
    /// while the user verifies the scanner against public addresses.
    /// Populated by `runTestScan()` via the unified
    /// `RealRPCTransactionScanner`. Same scanner powers the real
    /// wallet's refresh path (which writes into `TransactionRepository`).
    @State private var testTransactions: [TransactionEvent] = []
    @State private var testScanTrigger: Int = 0

    /// In-flight test-scan task. Stored so a re-trigger cancels the
    /// previous stream before starting a new one, and so the scan
    /// stops when the view disappears — the prior untracked
    /// `Task {}` launches could race two scans into the same
    /// in-memory buckets.
    @State private var testScanTask: Task<Void, Never>?

    /// Newest-first, capped-at-10 projection of `testTransactions`.
    /// Maintained at the mutation sites (the scan loop and the
    /// enter/exit transitions) so the body never re-sorts the buffer
    /// per render.
    @State private var sortedTestActivityRows: [TransactionEvent] = []

    /// Reference-typed container for the streaming scanners. The
    /// view struct is re-initialized on every parent invalidation;
    /// holding the scanners behind `@State` keeps one stable
    /// instance per view identity instead of reconstructing the
    /// clients on every struct churn.
    ///
    /// - `balance` — shared streaming balance scanner, the same
    ///   instance shape the Mnemonic Review screen uses.
    /// - `transactions` — unified transaction-history scanner. One
    ///   instance powers both test mode (in-memory
    ///   `testTransactions`) and the real wallet's `runRefresh()`
    ///   path (writes through `TransactionRepository`). See
    ///   `RealRPCTransactionScanner` for the per-family dispatch
    ///   table.
    private final class ScannerBox {
        let balance = RealRPCBalanceScanner()
        let transactions = RealRPCTransactionScanner()
    }

    @State private var scanners = ScannerBox()

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
    @State private var recentTransactions: [TransactionRecord] = []
    @State private var allTransactions: [TransactionRecord] = []

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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listSurface
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                // 2026-06-09 — toolbar overflow menu (the 3-dots
                // ellipsis in `.topBarTrailing`). Native SwiftUI
                // `Menu` renders as iOS's standard action sheet
                // with `Toggle` for "Hide balance" (a stateful
                // switch the user can see at a glance) and a
                // `Button` for "Lock wallet" that fires
                // `AutoLockController.lockNow()`. Per Rule #19 §C
                // the toolbar item is a plain `Button` with an SF
                // Symbol label — not a `UniButton` — because
                // toolbar items are navigation affordances, not
                // commit CTAs (the rule's documented exception).
                .toolbar {
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            UniToggle(isOn: $hideBalanceOnHome) {
                                Label("Hide balance", systemImage: "eye.slash")
                            }
                            Button {
                                lockController.lockNow()
                            } label: {
                                Label("Lock wallet", systemImage: "lock")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .accessibilityLabel(Text("More options"))
                        }
                    }
                }
                .navigationDestination(for: WalletHomeDestination.self) { destination in
                    switch destination {
                    case .send:                                 SendFlowView()
                    case .swap:                                 SwapPlaceholderView()
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
                    // Seed the memoized projections before the first
                    // refresh lands so the home renders the persisted
                    // state immediately (the `@State` defaults are
                    // empty arrays).
                    rebuildFilterInputs()
                    rebuildDisplayRows()
                    rebuildTransactionRows()
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
                    //
                    // Test mode does its own scan via the Settings
                    // toggle; we guard against double-firing here.
                    guard !isTestMode else { return }
                    await runRefresh()
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
                .safeAreaInset(edge: .bottom) { testModeBanner }
                .onChange(of: testScanTrigger) { _, _ in
                    // Tracked test-scan task — cancel the in-flight
                    // stream before starting a new one so rapid
                    // re-triggers never race two scans into the same
                    // in-memory buckets.
                    testScanTask?.cancel()
                    testScanTask = Task { await runTestScan() }
                }
                .onDisappear {
                    testScanTask?.cancel()
                    testScanTask = nil
                }
                .onChange(of: filterPreferenceFingerprint) { _, _ in
                    rebuildFilterInputs()
                    rebuildFilteredRows()
                }
                .onChange(of: activeWalletIdRaw) { _, _ in
                    rebuildDisplayRows()
                    rebuildTransactionRows()
                }
                .onChange(of: currencyCode) { _, _ in
                    rebuildDisplayRows()
                }
                .onChange(of: balanceRowsRevision) { _, _ in
                    rebuildDisplayRows()
                }
                .onChange(of: transactionRowsRevision) { _, _ in
                    rebuildTransactionRows()
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
                        rebuildTransactionRows()
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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
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
                .presentationDetents([.large])
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
            .presentationDetents([.large])
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
                .presentationDetents([.large])
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
            chromeSection
            holdingsBody
            activityListSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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

    /// Holdings region — branches by test mode, then by filter
    /// view mode, then by the segmented tab (in split mode only).
    ///
    /// **Test mode** keeps the prior single-section grouped-by-chain
    /// shape — the developer playground reads as it always did and
    /// the user's filter preferences don't apply.
    ///
    /// **Production** branches on `filterViewModeRaw`:
    /// - `.split` — the original shape: a segmented Coins/Tokens
    ///   switcher in chrome, only the selected section renders below.
    /// - `.combined` — one unified section with every coin AND every
    ///   token mixed, sorted by the user's chosen key + direction.
    ///   The segmented switcher disappears (see `chromeSection`
    ///   below).
    @ViewBuilder
    private var holdingsBody: some View {
        if isTestMode {
            holdingsListSection
        } else if showsNetworkErrorState {
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
            if showsPartialNetworkFootnote {
                partialNetworkFootnoteSection
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
    /// **Test mode.** Hidden in test mode (the scanner doesn't
    /// produce transaction history; reconstructing a curve from one
    /// snapshot would be dishonest). In test mode the hero alone
    /// renders as a separate floating row (no card) so the user
    /// reads it as a developer affordance, not as their wallet.
    ///
    /// **Header row separator.** The `.listRowSeparator(.hidden)` on
    /// the hero row suppresses the divider between hero and chart —
    /// they read as one calm surface, not as two adjacent list rows.
    @ViewBuilder
    private var balanceCardSection: some View {
        if isTestMode {
            // Test mode — no card, no chart. The hero alone floats.
            Section {
                walletHomeHeaderRow
                    .disabled(true)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
        } else {
            // Production — one inset-grouped Section, default row
            // background. iOS draws the unified card.
            Section {
                walletHomeHeaderRow
                    .listRowSeparator(.hidden)
                    // 24pt above the balance hero, flush below
                    // against the delta caption (zero bottom inset
                    // — the chart row owns the gap to the pill).
                    .listRowInsets(EdgeInsets(
                        top: 24,
                        leading: UniSpacing.m,
                        bottom: 0,
                        trailing: UniSpacing.m
                    ))

                BalanceHistoryChart(
                    transactions: allTransactions,
                    currentBalances: balances.map { $0.balance },
                    priceCache: priceCacheBySymbol,
                    priceHistory: priceHistoryBySymbol,
                    currencyCode: currencyCode,
                    scrubbedFiat: $scrubbedFiat
                )
                .listRowSeparator(.hidden)
                // Caption sits flush under the hero (top: 0); 24pt
                // of breathing room at the bottom of the card
                // beneath the period pill. The sparkline curve
                // itself bleeds out horizontally to 5pt from the
                // card edge via the chart's internal negative
                // horizontal padding.
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: UniSpacing.m,
                    bottom: 24,
                    trailing: UniSpacing.m
                ))
            }
        }
    }

    /// Hero row factored out so both modes (production card, test
    /// mode floating) use the exact same instance — same parameter
    /// resolution, same disabled-when-test rule.
    private var walletHomeHeaderRow: some View {
        WalletHomeHeader(
            walletName: isTestMode
                ? String.apertureLocalized("Public test addresses")
                : (activeWallet?.name ?? String.apertureLocalized("Wallet")),
            // 2026-06-09 — when scrubbing the chart, the hero
            // renders the scrubbed point's fiat instead of the
            // wallet's actual total. The chart's own scrubbing
            // readout was removed; the hero is the single
            // source of truth for the displayed number.
            // `.contentTransition(.numericText())` inside
            // `WalletHomeHeader.balanceLabel` animates the digits.
            totalFiat: isTestMode
                ? testTotalFiat
                : (scrubbedFiat ?? totalFiat),
            currencyCode: currencyCode,
            chainCount: isTestMode ? testChainsHeldCount : chainsHeldCount,
            tokenCount: isTestMode ? testTokenRowCount : balances.count,
            totalChainsSupported: isTestMode
                ? TestAddresses.map.count
                : WalletFormatting.chainCount(activeWallet?.addresses ?? []),
            hasAnyBalance: isTestMode ? !testBalances.isEmpty : !balances.isEmpty,
            // Local OR shared — a user pull that replaced a wedged
            // pipeline keeps the header honest about the replacement
            // still running (2026-06-12).
            isRefreshing: isAnyRefreshInFlight,
            lastSyncedAt: mostRecentScanAt,
            hideBalance: hideBalanceOnHome,
            onSwitchWallet: { isShowingSwitcher = true }
        )
    }

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
                canSend: !isTestMode && activeWallet?.kind != .watchOnly,
                onSend: { navigationPath.append(WalletHomeDestination.send) },
                onReceive: { isShowingReceive = true },
                onSwap: { navigationPath.append(WalletHomeDestination.swap) }
            )
            .disabled(isTestMode)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: UniSpacing.m,
                bottom: 0,
                trailing: UniSpacing.m
            ))

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
            if !isTestMode && filterViewMode == .split && !showsNetworkErrorState {
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

    /// Native segmented picker — Coins | Tokens. Disabled in test
    /// mode (the test buckets share one Holdings section there, no
    /// reason to switch).
    private var holdingsTabPicker: some View {
        Picker("Holdings tab", selection: $selectedHoldingsTab) {
            Text("Coins").tag(HoldingsTab.coins)
            Text("Tokens").tag(HoldingsTab.tokens)
        }
        .pickerStyle(.segmented)
        .disabled(isTestMode)
        .accessibilityLabel(Text("Switch between Coins and Tokens"))
    }

    // MARK: - Holdings section (native List)

    /// Test-mode holdings section. Per `holdingsBody`'s branching,
    /// production never reaches this section — it routes through
    /// `coinsSection` / `tokensSection` / `emptyHoldingsSection`
    /// instead. Test mode keeps the original "Holdings" label +
    /// the playground-style streaming rows.
    @ViewBuilder
    private var holdingsListSection: some View {
        Section {
            testHoldingsRows
        } header: {
            Text("Holdings")
        }
    }

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
        HStack(spacing: UniSpacing.s) {
            CoinMark(chain: row.chain, tokenSymbol: row.symbol, contract: row.contract)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: row.symbol)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: row.chain.displayName)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(WalletFormatting.native(row.amount, decimals: 6))
                    .font(UniTypography.monoBody)
                    .foregroundStyle(UniColors.Text.primary)
                if let fiat = row.fiatValue, fiat > 0 {
                    Text(WalletFormatting.fiat(fiat, currencyCode: row.fiatCurrencyCode))
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .monospacedDigit()
                } else {
                    Text("Price unavailable")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
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
                title: "Retry",
                variant: .secondary,
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

    /// Partial-failure footnote — some chains reported, some didn't.
    /// The successful rows render normally above; this single quiet
    /// line keeps the surface honest without blocking anything. Pull
    /// (or the next auto-refresh) retries the failed chains.
    @ViewBuilder
    private var partialNetworkFootnoteSection: some View {
        Section {
            UniFootnote(
                text: "Some networks didn't respond — pull to retry.",
                alignment: .center,
                color: UniColors.Text.tertiary
            )
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
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
                    .foregroundStyle(UniColors.Text.primary)
                Spacer(minLength: UniSpacing.s)
            }
            .padding(.vertical, UniSpacing.xs)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Show all supported assets"))
    }

    // MARK: - Test-mode holdings + activity
    //
    // In test mode the SwiftData rows are NOT consulted — we render
    // straight from the in-memory `testBalances` + `testTokens`
    // buckets populated by the streaming scanner. The visual register
    // mirrors the Mnemonic Review screen exactly (`ReviewChainRow` +
    // `ReviewTokenRow`) so the user gets one consistent "this is the
    // test affordance" feel across both surfaces.

    /// Test-mode holdings rows. Until the streaming scanner yields
    /// the first row, a centered `ProgressView` row stands in (a
    /// single list row, separator hidden, cleared background — so it
    /// reads as a momentary state, not as data the user could act on).
    @ViewBuilder
    private var testHoldingsRows: some View {
        if testBalances.isEmpty && testTokens.isEmpty {
            VStack(spacing: UniSpacing.s) {
                ProgressView()
                UniFootnote(
                    text: "Scanning every chain against curated public addresses.",
                    alignment: .center,
                    color: UniColors.Text.tertiary
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.l)
            .listRowSeparator(.hidden)
        } else {
            // Stable identity via `chain.rawValue` — the previous
            // `.enumerated().offset` id shifted on every streaming
            // re-sort, destroying + recreating every row (and its
            // icon fetch tasks) per render.
            ForEach(sortedTestChains, id: \.rawValue) { chain in
                ReviewChainRow(
                    chain: chain,
                    address: TestAddresses.map[chain] ?? "",
                    balance: testBalances[chain]
                )
                let chainTokens = (testTokens[chain] ?? []).sorted { a, b in
                    (a.fiatBalance ?? 0) > (b.fiatBalance ?? 0)
                }
                ForEach(chainTokens) { token in
                    ReviewTokenRow(token: token)
                }
            }
        }
    }

    private var sortedTestChains: [SupportedChain] {
        // Union of chains that have either a native or token row.
        // Sort by total fiat desc — biggest holding's chain leads,
        // same convention as the real-wallet holdings list.
        let union = Set(testBalances.keys).union(testTokens.keys)
        return union.sorted { lhs, rhs in
            testTotalFiat(for: lhs) > testTotalFiat(for: rhs)
        }
    }

    private func testTotalFiat(for chain: SupportedChain) -> Decimal {
        let nativeFiat = testBalances[chain]?.fiatBalance ?? 0
        let tokenFiat = (testTokens[chain] ?? []).reduce(Decimal.zero) {
            $0 + ($1.fiatBalance ?? 0)
        }
        return nativeFiat + tokenFiat
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
    private var priceCacheBySymbol: [String: Decimal] {
        var out: [String: Decimal] = [:]
        for row in cachedPrices where row.fiat == currencyCode {
            out[row.symbol.uppercased()] = row.price
        }
        return out
    }

    /// `[symbol-uppercased: [yyyymmdd: price]]` snapshot fed to
    /// `BalanceHistoryChart`'s reconstructor. Filtered to the
    /// active fiat. Bucketing happens here — the `@Query` returns
    /// every row regardless of (symbol, fiat), and we partition by
    /// uppercased symbol. Empty until the ensure-loop's first
    /// fetch lands, after which it grows incrementally as new
    /// (symbol, fiat) pairs need historical coverage.
    private var priceHistoryBySymbol: [String: [Int: Decimal]] {
        var out: [String: [Int: Decimal]] = [:]
        for row in historicalPrices where row.fiat == currencyCode {
            out[row.symbol.uppercased(), default: [:]][row.dayKey] = row.price
        }
        return out
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

    /// Cheap SwiftData change proxies — row counts across the active
    /// wallet's addresses. Counting is O(addresses) per body pass;
    /// the expensive registry enumeration + flatMap + sort only runs
    /// when a count actually changes. Value-only updates (a refresh
    /// re-pricing existing rows) are caught by the explicit rebuild
    /// at the end of `runRefresh()`.
    private var balanceRowsRevision: Int {
        guard let wallet = activeWallet else { return 0 }
        return wallet.addresses.reduce(0) { $0 + $1.balances.count }
    }

    private var transactionRowsRevision: Int {
        guard let wallet = activeWallet else { return 0 }
        return wallet.addresses.reduce(0) { $0 + $1.transactions.count }
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
    private func rebuildDisplayRows() {
        let held = allHeldRows
        let coinRows = WalletSupportedRowBuilders.coinRows(
            heldRows: held,
            currencyCode: currencyCode
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
        let tokenRows = WalletSupportedRowBuilders.tokenRows(
            heldRows: held,
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

    /// Recent-activity section. Branches three ways like the holdings
    /// section: test mode (in-memory `testTransactions`), empty
    /// production wallet (`UniEmptyState`), and the normal recent-ten
    /// list. Each transaction row wraps `ActivityRow` in a `Button`
    /// so the row tap routes to the transaction detail.
    @ViewBuilder
    private var activityListSection: some View {
        Section {
            if isTestMode {
                if testTransactions.isEmpty {
                    testActivityEmpty
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                } else {
                    testActivityRows
                }
            } else if recentTransactions.isEmpty {
                emptyActivity
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            } else {
                productionActivityRows
            }
        } header: {
            Text("Recent activity")
        }
    }

    /// Production activity rows — each `TransactionRecord` becomes
    /// one tappable list row. The `Button` carries the navigation
    /// dispatch; the row's tap target is the row itself thanks to
    /// `.contentShape` on `ActivityRow` and `.buttonStyle(.plain)`.
    @ViewBuilder
    private var productionActivityRows: some View {
        ForEach(recentTransactions, id: \.id) { tx in
            Button {
                navigationPath.append(WalletHomeDestination.transaction(tx.id))
            } label: {
                ActivityRow(
                    chain: chainFor(tx),
                    direction: TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing,
                    amount: Decimal(string: tx.amountRaw) ?? .zero,
                    tokenSymbol: tx.tokenSymbol,
                    counterparty: tx.counterparty,
                    occurredAt: tx.occurredAt,
                    status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Test-mode activity feed. Renders the memoized
    /// `sortedTestActivityRows` projection (newest-first, capped at
    /// 10 — same cap as `recentTransactions`), maintained at the
    /// mutation sites in `runTestScan()` rather than re-sorted per
    /// body pass. Uses the same `ActivityRow` component the real
    /// wallet uses — so visual consistency between test mode and
    /// the production path is automatic.
    @ViewBuilder
    private var testActivityRows: some View {
        ForEach(sortedTestActivityRows, id: \.txHash) { event in
            ActivityRow(
                chain: event.chain,
                direction: event.direction,
                amount: event.amount,
                tokenSymbol: event.tokenSymbol,
                counterparty: event.counterparty,
                occurredAt: event.occurredAt,
                status: event.status
            )
        }
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

    /// Boundary statement at the foot of the list. Cleared row
    /// background + hidden separators so it reads as a footer, not as
    /// a list row.
    @ViewBuilder
    private var footerSection: some View {
        Section {
            UniFootnote(
                text: "No accounts. No servers. Aperture lives on your iPhone.",
                alignment: .center,
                color: UniColors.Text.tertiary
            )
            .frame(maxWidth: .infinity)
            .padding(.top, UniSpacing.l)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
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
            // signals "tap to switch." In test mode we fall back
            // to the prior text-only `.toolbarPill` because test
            // mode displays public addresses, not a user wallet —
            // no identity to render.
            //
            // **Tap** opens the full `WalletSwitcherSheet` (the
            // index of every wallet with create/import affordances
            // at the bottom). **Long-press** opens the native iOS
            // 26 Liquid Glass `contextMenu` (the Telegram /
            // Instagram fast-switch pattern). Both gestures land
            // on the same affordance because the pill IS the
            // active-wallet identity on this screen — same affordance,
            // two depths.
            if isTestMode {
                UniButton(
                    verbatim: String.apertureLocalized("Public test addresses"),
                    variant: .toolbarPill,
                    isEnabled: false
                ) {
                    isShowingSwitcher = true
                }
                .accessibilityLabel(Text("Test mode active"))
            } else {
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
                // .contextMenu removed 2026-06-09 per user direction
                // — the long-press wallet switcher lives ONLY on
                // the bottom tab bar's Wallet button (via
                // TabBarLongPressInstaller). Tap on this toolbar
                // pill still opens the switcher sheet — that's the
                // quick affordance; the tab-bar long-press is the
                // Telegram/Instagram-style switcher.
            }
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

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    /// All balances belonging to the active wallet, sorted by fiat
    /// value descending (the biggest holding first). Respects the
    /// "Hide small balances" preference — balances whose
    /// `fiatValueCached` is below the user's threshold are filtered
    /// out (returns showAll → 0 threshold → everything visible).
    private var balances: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
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

    private var totalFiat: Decimal {
        balances.reduce(Decimal.zero) { running, entry in running + entry.balance.fiatValueCached }
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

    /// Rebuild the memoized transaction projections:
    ///
    /// - `recentTransactions` — most recent ten transactions across
    ///   all the wallet's addresses, newest first.
    /// - `allTransactions` — every transaction, unsorted. Feeds the
    ///   balance-history chart's reconstructor — the prefix-10 slice
    ///   the activity section uses isn't enough for
    ///   `BalanceHistoryRange.all`. The reconstructor handles the
    ///   sort + the per-range cutoff itself.
    ///
    /// Called from `.task`, the wallet-switch / count-proxy
    /// observers, and refresh completion — never from the body, so
    /// the flatMap + sort no longer runs per render.
    private func rebuildTransactionRows() {
        guard let wallet = activeWallet else {
            recentTransactions = []
            allTransactions = []
            return
        }
        let all = wallet.addresses.flatMap { $0.transactions }
        allTransactions = all
        recentTransactions = Array(
            all.sorted { $0.occurredAt > $1.occurredAt }.prefix(10)
        )
    }

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
        if let uuid = UUID(uuidString: activeWalletIdRaw) {
            if allWallets.contains(where: { $0.id == uuid }) {
                return
            }
            // The `@Query` lags repository inserts — the import flow
            // writes `activeWalletId` only after its `@ModelActor`
            // context has saved, but the main context's merge is
            // asynchronous. Reverting to the first wallet in that
            // window hijacked the active selection away from the
            // just-imported wallet AND aimed the auto-refresh at the
            // wrong wallet (the 2026-06-12 "imported wallet shows 0
            // until relaunch" bug). Ask the store directly before
            // declaring the id stale.
            if walletExists(id: uuid) {
                return
            }
        }
        if let first = allWallets.first {
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
        let missing = symbols.subtracting(existing)
        guard !missing.isEmpty else { return }

        let service = CoinbaseHistoricalPriceService()
        let repo = HistoricalPriceRepository(modelContainer: modelContext.container)
        let fiat = currencyCode

        // Bounded concurrency — 4 simultaneous fetches keeps the
        // Coinbase Exchange API happy and the device's RPC budget
        // free for the wallet refresh.
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for symbol in missing {
                if inFlight >= 4 {
                    await group.next()
                    inFlight -= 1
                }
                inFlight += 1
                group.addTask {
                    let candles = await service.fetchDailyCloses(symbol: symbol, fiat: fiat)
                    guard !candles.isEmpty else { return }
                    let entries = candles.map {
                        (symbol: symbol, fiat: fiat, dayKey: $0.dayKey, price: $0.close)
                    }
                    do {
                        try await repo.upsertMany(entries)
                    } catch {
                        // Best-effort — surface to log, no user UI.
                    }
                }
            }
        }
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
            // A refresh can re-price existing rows without changing
            // row counts, which the count-based change proxies can't
            // see — rebuild the memoized projections explicitly now
            // that the coordinator has finished writing.
            rebuildDisplayRows()
            rebuildTransactionRows()
            // **2026-06-10 handoff signature.** Pull-to-refresh
            // complete fires the iris-settle pattern (soft tick →
            // medium tap). Per Rule #10 §I, signatures are gated
            // through `UniHapticEngine` so the AppStorage toggle
            // and Reduce Motion are both honored.
            //
            // Skipped while a replacement pipeline is still running
            // (this run was cancelled by a user pull, or superseded
            // by a wallet switch) — "settled" before the spinner
            // stops would be a lie in the hand (2026-06-12).
            if !refreshState.isRefreshing {
                UniHapticEngine.shared.play(.signature(.irisSettle))
            }
        }
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

    // MARK: - Test mode bottom banner + actions

    /// Bottom safe-area inset banner — only renders when
    /// `isTestMode` is true. Mirrors `MnemonicReviewView`'s
    /// "Exit test mode" footer so the affordance reads
    /// identically across both surfaces.
    @ViewBuilder
    private var testModeBanner: some View {
        if isTestMode {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniFootnote(
                        text: "Test mode — scanning public addresses. The Send / Swap actions are disabled while in this mode; exit to return to your wallet.",
                        alignment: .center
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    UniButton(title: "Exit test mode", variant: .secondary) {
                        exitTestMode()
                    }
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.l)
        }
    }

    /// Calm empty activity surface for test mode. Honest per
    /// Rule #2 §A.7 — the test affordance reads balances, not
    /// transaction history, so we say so plainly instead of
    /// faking a list. Uses the same `UniEmptyState` primitive as
    /// the prod empty surfaces so the test variant doesn't read
    /// as a different visual family (Rule #2 §A.5 consistency).
    private var testActivityEmpty: some View {
        UniEmptyState(
            title: "No transactions in test mode.",
            detail: "Test mode verifies balance reads only. Exit to see real activity for your wallet.",
            mark: .icon(systemName: "flask")
        )
    }

    /// Sum of native + token fiat across every chain in the test
    /// buckets. Feeds the hero number in the header so the user
    /// sees the live test total as rows stream in.
    private var testTotalFiat: Decimal {
        var total = Decimal.zero
        for (_, balance) in testBalances {
            total += balance.fiatBalance ?? 0
        }
        for (_, tokens) in testTokens {
            for token in tokens {
                total += token.fiatBalance ?? 0
            }
        }
        return total
    }

    private var testChainsHeldCount: Int {
        Set(testBalances.keys).union(testTokens.keys).count
    }

    private var testTokenRowCount: Int {
        testBalances.count + testTokens.reduce(0) { $0 + $1.value.count }
    }

    /// Flip the test toggle. Entering test mode clears any prior
    /// buckets and kicks off a stream against `TestAddresses.map`.
    /// Exiting clears the buckets so the user's real wallet
    /// reappears immediately.
    private func toggleTestMode() {
        if isTestMode {
            exitTestMode()
        } else {
            enterTestMode()
        }
    }

    private func enterTestMode() {
        testBalances = [:]
        testTokens = [:]
        testTransactions = []
        sortedTestActivityRows = []
        isTestMode = true
        testScanTrigger &+= 1
    }

    private func exitTestMode() {
        isTestMode = false
        testBalances = [:]
        testTokens = [:]
        testTransactions = []
        sortedTestActivityRows = []
    }

    /// Consume the streaming scan against `TestAddresses.map`.
    /// Mirrors `MnemonicReviewView.runScan()` — replacements per
    /// `(chain, contract)` are atomic so refreshed rows overwrite
    /// stale ones.
    ///
    /// **Transactions (2026-06-08).** In addition to the balance
    /// stream, we kick off a concurrent task that drives the
    /// unified `RealRPCTransactionScanner` against the same address
    /// map and appends events to `testTransactions` as each chain's
    /// adapter resolves. The two streams are independent — balances
    /// land via `scanners.balance`, transactions via
    /// `scanners.transactions`. Both observe `isTestMode` (and the
    /// tracked task's cancellation) so a mid-flight toggle or a
    /// re-trigger clears the buckets and stops both feeds cleanly.
    private func runTestScan() async {
        let snapshot = isTestMode
        guard snapshot else { return }
        let currency = CurrencyPreference.currency(for: currencyCode)
            ?? CurrencyPreference.all[0]

        // Transactions: run in parallel with the balance stream so
        // the user sees rows landing chain-by-chain in the activity
        // feed AT THE SAME TIME as the holdings rows fill in.
        let txTask = Task { [txScanner = scanners.transactions] in
            let txStream = txScanner.streamScan(
                addresses: TestAddresses.map,
                limit: 10
            )
            for await event in txStream {
                guard isTestMode, !Task.isCancelled else { return }
                // De-dup per (chain, hash) so repeated rescans don't
                // double-count.
                testTransactions.removeAll {
                    $0.chain == event.chain && $0.txHash == event.txHash
                }
                testTransactions.append(event)
                // Maintain the memoized newest-first projection at
                // the mutation site so the body never sorts.
                sortedTestActivityRows = Array(
                    testTransactions
                        .sorted { $0.occurredAt > $1.occurredAt }
                        .prefix(10)
                )
            }
        }

        let stream = scanners.balance.streamScan(
            addresses: TestAddresses.map,
            currency: currency
        )
        for await row in stream {
            // Bail if the user exited test mode mid-stream, or the
            // tracked task was cancelled by a re-trigger / disappear.
            guard isTestMode, !Task.isCancelled else {
                txTask.cancel()
                return
            }
            switch row {
            case .native(let chainBalance):
                testBalances[chainBalance.chain] = chainBalance
            case .token(let tokenBalance):
                var existing = testTokens[tokenBalance.chain] ?? []
                existing.removeAll { $0.contract == tokenBalance.contract }
                existing.append(tokenBalance)
                testTokens[tokenBalance.chain] = existing
            }
        }
        // The stream can also terminate because the tracked task was
        // cancelled mid-await — propagate the cancellation to the
        // transaction feed instead of awaiting it.
        if Task.isCancelled {
            txTask.cancel()
            return
        }
        // Let the transaction stream finish on its own — balance
        // stream completion shouldn't cut off the slower chain
        // adapters.
        _ = await txTask.value
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
    case send
    case swap
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
