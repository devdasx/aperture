import SwiftUI
import SwiftData

// MARK: - RootGate

/// App-launch routing gate. Reads the wallet count reactively via
/// `@Query`; routes to `WalletHomeView` if the user has at least one
/// wallet, otherwise to `OnboardingView`. When the create/import
/// flows insert a `WalletRecord`, the gate flips automatically — no
/// explicit navigation needed from those flows.
///
/// **Splash → onboarding shared element (2026-06-07).** `AppRoot`
/// (in `UniAppApp.swift`) wraps the gate so it can thread the
/// `@Namespace logoNamespace` + `AppPhase` machine into onboarding —
/// onboarding consumes both to attach `matchedGeometryEffect` to its
/// welcome-slide logo and to drive the staggered chrome fade-in.
/// The wallet-home branch ignores both: the shared-element transition
/// only applies to first-launch onboarding, not to returning users.
struct RootGate: View {
    let logoNamespace: Namespace.ID
    let phase: AppPhase

    @Query private var wallets: [WalletRecord]

    var body: some View {
        if wallets.isEmpty {
            OnboardingView(logoNamespace: logoNamespace, phase: phase)
        } else {
            WalletHomeView()
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
    @Query private var metadataRows: [AppMetadataRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var hideBalanceOnHome: Bool = false
    @AppStorage(HideBalancesPreference.thresholdKey) private var hideSmallThreshold: Double = HideBalancesPreference.defaultThreshold
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

    @State private var isShowingSettings: Bool = false
    @State private var isShowingSwitcher: Bool = false
    @State private var isShowingCreate: Bool = false
    @State private var isShowingImport: Bool = false
    /// Receive v2 (2026-06-06) — the Receive surface is a sheet, not
    /// a push. Owned here on the parent so its path can be reset on
    /// dismiss per Rule #12 §G.
    @State private var isShowingReceive: Bool = false
    @State private var receivePath: NavigationPath = NavigationPath()
    @State private var navigationPath: NavigationPath = NavigationPath()
    @State private var createPath: NavigationPath = NavigationPath()
    @State private var importPath: NavigationPath = NavigationPath()
    @State private var settingsPath: NavigationPath = NavigationPath()
    @State private var isRefreshing: Bool = false

    /// Active tab for the holdings region. Per the 2026-06-09 user
    /// direction, the home no longer shows Coins AND Tokens as
    /// stacked List sections — a native segmented switcher sits
    /// under the action region and the user picks which collection
    /// to view. Defaults to `.coins` because that's the broader
    /// vocabulary (every chain has one); Tokens is the deeper dive.
    @State private var selectedHoldingsTab: HoldingsTab = .coins

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

    /// Shared streaming scanner — the same instance shape the
    /// Mnemonic Review screen uses. Holding it as a `let` on the
    /// view keeps the per-test rescan stream backed by one client.
    private let testScanner = RealRPCBalanceScanner()

    /// Unified transaction-history scanner. One instance powers both
    /// test mode (in-memory `testTransactions`) and the real
    /// wallet's `runRefresh()` path (writes through
    /// `TransactionRepository`). See `RealRPCTransactionScanner` for
    /// the per-family dispatch table.
    private let txScanner = RealRPCTransactionScanner()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listSurface
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(for: WalletHomeDestination.self) { destination in
                    switch destination {
                    case .send:                    SendPlaceholderView()
                    case .swap:                    SwapPlaceholderView()
                    case .transaction(let id):     TransactionDetailView(transactionId: id)
                    case .allSupported:            AllSupportedAssetsView()
                    }
                }
                .refreshable { await runRefresh() }
                .task {
                    ensureActiveWalletSet()
                    // Auto-refresh on appear so the wallet shows live
                    // balances + transaction history without forcing
                    // the user to pull-to-refresh on every open. Runs
                    // once per view lifecycle (`.task` semantics) so
                    // it doesn't thrash the RPC providers on every
                    // re-render. The refresh is silent unless it
                    // produces a change — the user sees the
                    // `mostRecentScanAt` footer tick over honestly.
                    //
                    // Test mode does its own scan via the toolbar
                    // toggle; we guard against double-firing here.
                    guard !isTestMode else { return }
                    await runRefresh()
                }
                .safeAreaInset(edge: .bottom) { testModeBanner }
                .onChange(of: testScanTrigger) { _, _ in
                    Task { await runTestScan() }
                }
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: { settingsPath = NavigationPath() }) {
            // Match the OnboardingView Settings sheet pattern exactly:
            // `.large` detent only (sheet opens fully so navigation
            // into child pickers has room to render the new title +
            // back chevron without competing with the parent's sheet
            // grabber), `.id(sheetDirectionKey)` for the Rule #12 §G
            // direction-only rebuild, `.uniAppEnvironment()` so
            // theme/locale propagate into the sheet's scope (the
            // `.sheet`/`.fullScreenCover` content gets its own
            // environment scope per the iOS 26 SwiftUI contract),
            // opaque background so children that don't carry their
            // own `.scrollContentBackground(.hidden)` still read
            // cleanly.
            SettingsView(navigationPath: $settingsPath)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .presentationDetents([.large])
                .presentationBackground(UniColors.Background.primary)
        }
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
        .sheet(isPresented: $isShowingSwitcher) {
            WalletSwitcherSheet(
                onSelect: {
                    // Selection writes activeWalletIdRaw in the sheet
                    // itself; here we just acknowledge with a haptic.
                },
                onCreateNew: {
                    isShowingSwitcher = false
                    DispatchQueue.main.async { isShowingCreate = true }
                },
                onImport: {
                    isShowingSwitcher = false
                    DispatchQueue.main.async { isShowingImport = true }
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
    /// to ride `.safeAreaInset(edge: .bottom)` on the body.
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
    }

    /// Holdings region — branches by mode and by what's held.
    /// Test mode keeps the prior single-section grouped-by-chain
    /// shape (the playground reads as it always did). Production
    /// branches three ways: empty (single `UniEmptyState` section),
    /// only-coins (one Coins section), only-tokens (one Tokens
    /// section), or both (Coins then Tokens). Each held section
    /// caps at 10 rows + optional "Show all" row.
    @ViewBuilder
    private var holdingsBody: some View {
        if isTestMode {
            holdingsListSection
        } else {
            // Per 2026-06-09 direction the home no longer stacks
            // Coins and Tokens — the user picks one via the
            // segmented picker in chrome and only that section
            // renders. Switching tabs is a `withAnimation`
            // crossfade for the row content.
            switch selectedHoldingsTab {
            case .coins:  coinsSection
            case .tokens: tokensSection
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
                    .listRowInsets(EdgeInsets(
                        top: UniSpacing.l,
                        leading: UniSpacing.l,
                        bottom: UniSpacing.xs,
                        trailing: UniSpacing.l
                    ))

                BalanceHistoryChart(
                    transactions: allTransactions,
                    currentBalances: balances.map { $0.balance },
                    currencyCode: currencyCode
                )
                .listRowSeparator(.hidden)
                // 2026-06-09 follow-on: row insets back to the
                // normal `UniSpacing.l` so the delta caption + pill
                // align with everything else in the card. The
                // sparkline curve itself uses negative horizontal
                // padding inside the chart component to bleed out
                // to 5pt from the card edge — only the curve gets
                // the full-bleed treatment, not the surrounding
                // chrome.
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: UniSpacing.l,
                    bottom: UniSpacing.s,
                    trailing: UniSpacing.l
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
            totalFiat: isTestMode ? testTotalFiat : totalFiat,
            currencyCode: currencyCode,
            chainCount: isTestMode ? testChainsHeldCount : chainsHeldCount,
            tokenCount: isTestMode ? testTokenRowCount : balances.count,
            totalChainsSupported: isTestMode
                ? TestAddresses.map.count
                : WalletFormatting.chainCount(activeWallet?.addresses ?? []),
            hasAnyBalance: isTestMode ? !testBalances.isEmpty : !balances.isEmpty,
            isRefreshing: isRefreshing,
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
            if requiresBiometricReenrollment {
                BiometricReenrollmentBanner()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: UniSpacing.l,
                        bottom: 0,
                        trailing: UniSpacing.l
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
                leading: UniSpacing.l,
                bottom: 0,
                trailing: UniSpacing.l
            ))

            // Coins ↔ Tokens segmented switcher. Native iOS
            // `.pickerStyle(.segmented)` — the same control iOS
            // Settings uses for its "Display & Brightness" Light /
            // Dark toggle. Swipe / tap to change the active tab;
            // `holdingsBody` renders the matching section.
            holdingsTabPicker
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                // Tightened vertical padding per 2026-06-09 user
                // direction so the picker sits closer to the action
                // region above and the section below.
                .listRowInsets(EdgeInsets(
                    top: UniSpacing.xxs,
                    leading: UniSpacing.l,
                    bottom: UniSpacing.xxs,
                    trailing: UniSpacing.l
                ))
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
        // Use `coinDisplayRows` (every supported chain, held-first
        // sort) — not `coinHoldings` (held only). Per the user's
        // 2026-06-08 direction the home screen now shows all
        // supported coins; zero-balance rows render honestly.
        let rows = coinDisplayRows
        let displayed = Array(rows.prefix(holdingsDisplayCap))
        let hasMore = rows.count > holdingsDisplayCap

        Section {
            ForEach(Array(displayed.enumerated()), id: \.offset) { _, row in
                AssetRow(
                    chain: row.chain,
                    tokenSymbol: row.chain.ticker,
                    nativeAmount: row.amount,
                    nativeDecimals: min(row.chain.nativeDecimals, 8),
                    fiatValue: row.fiatValue,
                    fiatCurrencyCode: row.fiatCurrencyCode
                )
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
        // Use `tokenDisplayRows` (every supported token across every
        // registry, held-first sort). The display row carries
        // (symbol, name, amount, fiat) — zero-balance rows render
        // honestly per Rule #16.
        let rows = tokenDisplayRows
        let displayed = Array(rows.prefix(holdingsDisplayCap))
        let hasMore = rows.count > holdingsDisplayCap

        Section {
            ForEach(displayed, id: \.id) { row in
                supportedTokenRow(row)
            }
            if hasMore { showAllRow }
        }
        // Header omitted — see the coinsSection note above.
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
            CoinMark(chain: row.chain, tokenSymbol: row.symbol)
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
            ForEach(Array(sortedTestChains.enumerated()), id: \.offset) { _, chain in
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

    /// Coins rows — every `SupportedChain.allCases`, held coins first
    /// (fiat desc), then unheld in canonical chain order. The home
    /// screen takes the first 10; the "Show all" destination shows
    /// the rest.
    var coinDisplayRows: [WalletCoinSupportedRow] {
        let rows = WalletSupportedRowBuilders.coinRows(
            heldRows: allHeldRows,
            currencyCode: currencyCode
        )
        return rows.sorted { a, b in
            if a.isHeld != b.isHeld { return a.isHeld }
            if a.isHeld {
                let aFiat = a.fiatValue ?? .zero
                let bFiat = b.fiatValue ?? .zero
                if aFiat != bFiat { return aFiat > bFiat }
            }
            return a.chain.displayName.localizedStandardCompare(b.chain.displayName) == .orderedAscending
        }
    }

    /// Tokens rows — every supported token across all registries,
    /// held first (fiat desc), then unheld alphabetically by
    /// `(symbol, chain)`.
    var tokenDisplayRows: [WalletTokenSupportedDisplayRow] {
        let rows = WalletSupportedRowBuilders.tokenRows(
            heldRows: allHeldRows,
            currencyCode: currencyCode
        )
        return rows.sorted { a, b in
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

    /// Test-mode activity feed. Renders the in-memory
    /// `testTransactions` buffer (populated by the unified
    /// `RealRPCTransactionScanner`) using the same `ActivityRow`
    /// component the real wallet uses — so visual consistency
    /// between test mode and the production path is automatic. Rows
    /// are sorted newest-first and capped at 10 (same cap as
    /// `recentTransactions`).
    @ViewBuilder
    private var testActivityRows: some View {
        let sorted = Array(
            testTransactions
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(10)
        )
        ForEach(Array(sorted.enumerated()), id: \.offset) { _, event in
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
        // 2026-06-09 layout reversion: gear in `.topBarLeading`,
        // wallet pill back in `.principal` (centered nav-bar title
        // slot), test flask REMOVED entirely. The flask affordance
        // moved to Settings → Developer → "Test against public
        // addresses" — `isTestMode` is now `@AppStorage` so both
        // surfaces read/write the same flag. Net effect on the
        // toolbar: two items (gear left, pill center), nothing
        // trailing.
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .regular))
            }
            .accessibilityLabel(Text("Settings"))
        }

        ToolbarItem(placement: .principal) {
            UniButton(
                verbatim: isTestMode
                    ? String.apertureLocalized("Public test addresses")
                    : (activeWallet?.name ?? String.apertureLocalized("Wallet")),
                variant: .toolbarPill,
                isEnabled: !isTestMode
            ) {
                isShowingSwitcher = true
            }
            .accessibilityLabel(Text("Switch wallet, currently \(activeWallet?.name ?? "")"))
        }
    }

    // MARK: - Derived state

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

    /// Most recent ten transactions across all the wallet's addresses,
    /// newest first.
    private var recentTransactions: [TransactionRecord] {
        guard let wallet = activeWallet else { return [] }
        let all = wallet.addresses.flatMap { $0.transactions }
        return all
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(10)
            .map { $0 }
    }

    /// All transactions across the active wallet's addresses,
    /// unsorted. Feeds the balance-history chart's reconstructor —
    /// the prefix-10 slice the activity section uses isn't enough
    /// for `BalanceHistoryRange.all`. The reconstructor handles the
    /// sort + the per-range cutoff itself.
    private var allTransactions: [TransactionRecord] {
        guard let wallet = activeWallet else { return [] }
        return wallet.addresses.flatMap { $0.transactions }
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
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           allWallets.contains(where: { $0.id == uuid }) {
            return
        }
        if let first = allWallets.first {
            activeWalletIdRaw = first.id.uuidString
        }
    }

    // MARK: - Refresh

    private func runRefresh() async {
        guard let walletId = activeWallet?.id else { return }
        await MainActor.run { isRefreshing = true }
        let coordinator = WalletRefreshCoordinator(container: modelContext.container)
        await coordinator.refreshWallet(walletId: walletId, fiatCode: currencyCode)
        await MainActor.run { isRefreshing = false }
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
        isTestMode = true
        testScanTrigger &+= 1
    }

    private func exitTestMode() {
        isTestMode = false
        testBalances = [:]
        testTokens = [:]
        testTransactions = []
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
    /// land via `testScanner`, transactions via `txScanner`. Both
    /// observe `isTestMode` so a mid-flight toggle clears the
    /// buckets and stops both feeds cleanly.
    private func runTestScan() async {
        let snapshot = isTestMode
        guard snapshot else { return }
        let currency = CurrencyPreference.currency(for: currencyCode)
            ?? CurrencyPreference.all[0]

        // Transactions: run in parallel with the balance stream so
        // the user sees rows landing chain-by-chain in the activity
        // feed AT THE SAME TIME as the holdings rows fill in.
        let txTask = Task { [txScanner] in
            let txStream = txScanner.streamScan(
                addresses: TestAddresses.map,
                limit: 10
            )
            for await event in txStream {
                guard isTestMode else { return }
                // De-dup per (chain, hash) so repeated rescans don't
                // double-count.
                testTransactions.removeAll {
                    $0.chain == event.chain && $0.txHash == event.txHash
                }
                testTransactions.append(event)
            }
        }

        let stream = testScanner.streamScan(
            addresses: TestAddresses.map,
            currency: currency
        )
        for await row in stream {
            // Bail if the user exited test mode mid-stream.
            guard isTestMode else {
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
}
