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
    @State private var isTestMode: Bool = false
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
            scrollSurface
                .background(UniColors.Background.primary.ignoresSafeArea())
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(for: WalletHomeDestination.self) { destination in
                    switch destination {
                    case .send:                    SendPlaceholderView()
                    case .swap:                    SwapPlaceholderView()
                    case .transaction(let id):     TransactionDetailView(transactionId: id)
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

    private var scrollSurface: some View {
        ScrollView {
            VStack(spacing: UniSpacing.l) {
                WalletHomeHeader(
                    walletName: isTestMode
                        ? String.apertureLocalized("Public test addresses")
                        : (activeWallet?.name ?? String.apertureLocalized("Wallet")),
                    totalFiat: isTestMode ? testTotalFiat : totalFiat,
                    currencyCode: currencyCode,
                    // Chains held (non-zero balance) — falls back to
                    // total supported addresses on a fresh wallet so
                    // the user sees "26 chains supported" rather than
                    // an honest-but-noisy "0 chains · 0 tokens".
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
                .disabled(isTestMode)

                banners

                WalletActionRegion(
                    canSend: !isTestMode && activeWallet?.kind != .watchOnly,
                    onSend: { navigationPath.append(WalletHomeDestination.send) },
                    onReceive: { isShowingReceive = true },
                    onSwap: { navigationPath.append(WalletHomeDestination.swap) }
                )
                .padding(.horizontal, UniSpacing.l)
                .disabled(isTestMode)

                holdingsSection

                activitySection

                footer
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.xxl)
        }
        .scrollIndicators(.hidden)
    }

    /// Wallet-home banner cluster.
    ///
    /// The `BackupRequiredBanner` was REMOVED from the wallet home on
    /// 2026-06-07 per direct user direction:
    ///
    /// > "remove this 'Save your recovery phrase' from the main screen
    /// > at all, and instead in the wallet management screen, show
    /// > modern warning that says he should do a backup to his wallet,
    /// > and when it done, it should be marked as Done."
    ///
    /// **Why the move.** The wallet home is the daily-driver surface;
    /// the user is here to read the calm truth of what they own
    /// (balances, holdings, activity). A persistent backup nag on every
    /// open pulled attention away from that truth and read as
    /// alarm-class chrome — even though backup is a *responsibility*,
    /// not a *danger* (Rule #2 §A.7 / Rule #16 §B). The backup state
    /// now lives where the user goes to *think about this specific
    /// wallet*: Settings → Wallets → [wallet]. There it is calm,
    /// monochrome, and transitions to a Done state the moment the
    /// user confirms.
    ///
    /// `BiometricReenrollmentBanner` remains here because it names a
    /// *different* class of event: an iOS-level enrollment change
    /// happened OUTSIDE Aperture, and the user needs to re-authorize
    /// to restore biometric unlock. That's an event-driven prompt, not
    /// a setup-time decision the user can navigate to.
    @ViewBuilder
    private var banners: some View {
        if requiresBiometricReenrollment {
            BiometricReenrollmentBanner()
        }
    }

    private var holdingsSection: some View {
        sectionFrame(title: "Holdings") {
            if isTestMode {
                testHoldingsContent
            } else if balances.isEmpty {
                emptyHoldings
            } else {
                holdingsList
            }
        }
    }

    // MARK: - Test-mode holdings + activity
    //
    // In test mode the SwiftData rows are NOT consulted — we render
    // straight from the in-memory `testBalances` + `testTokens`
    // buckets populated by the streaming scanner. The visual
    // register mirrors the Mnemonic Review screen exactly
    // (`ReviewChainRow` + `ReviewTokenRow`) so the user gets one
    // consistent "this is the test affordance" feel across both
    // surfaces.
    @ViewBuilder
    private var testHoldingsContent: some View {
        if testBalances.isEmpty && testTokens.isEmpty {
            // Streaming hasn't yielded a row yet — quiet progress
            // surface inside the card so the layout doesn't jump
            // as rows arrive.
            VStack(spacing: UniSpacing.s) {
                ProgressView()
                UniFootnote(
                    text: "Scanning every chain against curated public addresses.",
                    alignment: .center,
                    color: UniColors.Text.tertiary
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xl)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Material.card)
            )
        } else {
            testHoldingsList
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

    private var testHoldingsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(sortedTestChains.enumerated()), id: \.offset) { idx, chain in
                ReviewChainRow(
                    chain: chain,
                    address: TestAddresses.map[chain] ?? "",
                    balance: testBalances[chain]
                )
                let chainTokens = (testTokens[chain] ?? []).sorted { a, b in
                    (a.fiatBalance ?? 0) > (b.fiatBalance ?? 0)
                }
                if !chainTokens.isEmpty {
                    ForEach(chainTokens) { token in
                        ReviewTokenRow(token: token)
                    }
                }
                if idx < sortedTestChains.count - 1 {
                    UniDivider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Material.card)
        )
    }

    /// Groups balances by chain (chain native first per group, tokens
    /// follow) and renders one card. Within a group, the native row
    /// has the full chain logo + ticker; tokens render as quieter
    /// indented rows under the native (matches the `ReviewTokenRow`
    /// treeline pattern from the Import → Review screen, so the same
    /// parent/child cue propagates across the app).
    @ViewBuilder
    private var holdingsList: some View {
        let groups = groupedBalances
        LazyVStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIdx, group in
                // Native chain row first.
                AssetRow(
                    chain: group.chain,
                    tokenSymbol: group.native.tokenSymbol,
                    nativeAmount: WalletFormatting.decimalAmount(
                        rawBalance: group.native.rawBalance,
                        decimals: group.native.decimals
                    ),
                    // **Display decimals come from the chain, not the
                    // stored field.** The native-balance upsert path
                    // in `WalletRefreshCoordinator` writes `decimals:
                    // 0` because the scanner already divides
                    // (`summary.nativeBalance` is in chain units, not
                    // wei/sats). Reading `group.native.decimals` here
                    // would give 0 and the `0...0` fractional-length
                    // range in `WalletFormatting.native` would round
                    // a non-zero balance like 0.012345 ETH to "0".
                    // The chain's `nativeDecimals` is the honest
                    // source of truth — capped at 8 so the row stays
                    // legible (ETH/NEAR don't need 18/24 digits on
                    // the home; Send/Receive use full precision).
                    nativeDecimals: min(group.chain.nativeDecimals, 8),
                    fiatValue: group.native.fiatValueCached > 0 ? group.native.fiatValueCached : nil,
                    fiatCurrencyCode: group.native.fiatCurrencyCode
                )
                .padding(.horizontal, UniSpacing.m)
                // Token sub-rows, indented under the native.
                ForEach(Array(group.tokens.enumerated()), id: \.offset) { _, token in
                    UniDivider().padding(.leading, UniSpacing.m + 32 + UniSpacing.s)
                    HoldingsTokenRow(
                        chain: group.chain,
                        balance: token
                    )
                    .padding(.horizontal, UniSpacing.m)
                }
                if groupIdx < groups.count - 1 {
                    UniDivider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Material.card)
        )
    }

    /// One chain's holdings, sorted by per-group fiat desc and chain-
    /// group fiat desc at the outer level. The native balance is the
    /// row that carries the chain logo; `tokens` is the optional list
    /// of token sub-rows (empty for chains where the user only holds
    /// the native coin).
    private struct ChainHoldingsGroup {
        let chain: SupportedChain
        let native: TokenBalanceRecord
        let tokens: [TokenBalanceRecord]
        var totalFiat: Decimal {
            tokens.reduce(native.fiatValueCached) { $0 + $1.fiatValueCached }
        }
    }

    private var groupedBalances: [ChainHoldingsGroup] {
        // Re-use the filter from `balances` (which already applies
        // `hideSmallBalances` + non-zero raw). Bucket by chain.
        var buckets: [SupportedChain: [TokenBalanceRecord]] = [:]
        for entry in balances {
            buckets[entry.chain, default: []].append(entry.balance)
        }
        let groups: [ChainHoldingsGroup] = buckets.compactMap { chain, rows in
            // Native row = the one whose tokenSymbol matches the chain
            // ticker AND tokenContract is nil. If a chain hasn't had
            // its native scanned but has tokens, synthesize a zero
            // native placeholder so the user still sees the chain
            // grouping cleanly.
            let native = rows.first { $0.tokenContract == nil && $0.tokenSymbol == chain.ticker }
            let tokens = rows.filter { $0.tokenContract != nil || $0.tokenSymbol != chain.ticker }
            guard let nativeRow = native else {
                // No native row but tokens exist — promote the first
                // token to lead-row position so the group still renders.
                guard let lead = tokens.first else { return nil }
                let rest = Array(tokens.dropFirst())
                return ChainHoldingsGroup(chain: chain, native: lead, tokens: rest)
            }
            // Sort tokens by fiat desc within the group.
            let sortedTokens = tokens.sorted { $0.fiatValueCached > $1.fiatValueCached }
            return ChainHoldingsGroup(chain: chain, native: nativeRow, tokens: sortedTokens)
        }
        // Sort groups by group totalFiat desc — the biggest holding's
        // chain leads.
        return groups.sorted { $0.totalFiat > $1.totalFiat }
    }

    /// **Holdings empty state.** Redesigned 2026-06-07 against the
    /// monochrome brand correction: the iris watermark anchors the
    /// surface as Aperture's, the splash-family elliptical lift
    /// threads visually back to the launch screen the user just saw,
    /// and the copy names what holdings ARE plus how the user moves
    /// from absence to presence. No CTA inside the empty surface —
    /// the `WalletActionRegion` glass triplet directly above carries
    /// Receive, and the user-direction 2026-06-07 removed the prior
    /// CTA explicitly.
    ///
    /// The empty state composes the canonical `UniEmptyState`
    /// primitive so siblings (this + `emptyActivity` + future
    /// neutral empty states) share one visual register.
    private var emptyHoldings: some View {
        UniEmptyState(
            title: "Your holdings will appear here.",
            detail: "Receive crypto to any of your addresses and it'll show up the moment it lands on-chain."
        )
    }

    private var activitySection: some View {
        sectionFrame(title: "Recent activity") {
            if isTestMode {
                if testTransactions.isEmpty {
                    testActivityEmpty
                } else {
                    testActivityList
                }
            } else if recentTransactions.isEmpty {
                emptyActivity
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(recentTransactions.enumerated()), id: \.offset) { idx, tx in
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
                            .padding(.horizontal, UniSpacing.m)
                        }
                        .buttonStyle(.plain)
                        if idx < recentTransactions.count - 1 {
                            UniDivider().padding(.leading, UniSpacing.m + 36 + UniSpacing.s)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                        .fill(UniColors.Material.card)
                )
            }
        }
    }

    /// Test-mode activity feed. Renders the in-memory
    /// `testTransactions` buffer (populated by the unified
    /// `RealRPCTransactionScanner`) using the same `ActivityRow`
    /// component the real wallet uses — so visual consistency
    /// between test mode and the production path is automatic.
    /// Rows are sorted newest-first and capped at 10 (same cap as
    /// `recentTransactions`).
    private var testActivityList: some View {
        let sorted = testTransactions
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(10)
        return LazyVStack(spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.offset) { idx, event in
                ActivityRow(
                    chain: event.chain,
                    direction: event.direction,
                    amount: event.amount,
                    tokenSymbol: event.tokenSymbol,
                    counterparty: event.counterparty,
                    occurredAt: event.occurredAt,
                    status: event.status
                )
                .padding(.horizontal, UniSpacing.m)
                if idx < sorted.count - 1 {
                    UniDivider().padding(.leading, UniSpacing.m + 36 + UniSpacing.s)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Material.card)
        )
    }

    /// **Activity empty state.** Sibling to `emptyHoldings` — same
    /// iris watermark, same elliptical lift, same copy register.
    /// The two empty surfaces sit in the same scroll; reading them
    /// as a pair (Holdings empty / Activity empty) confirms the
    /// wallet is alive and waiting rather than broken or stuck.
    private var emptyActivity: some View {
        UniEmptyState(
            title: "No activity yet.",
            detail: "Transactions appear here as they confirm on-chain."
        )
    }

    private var footer: some View {
        UniFootnote(
            text: "No accounts. No servers. Aperture lives on your iPhone.",
            alignment: .center,
            color: UniColors.Text.tertiary
        )
        .padding(.top, UniSpacing.l)
    }

    private func sectionFrame<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text(title)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .textCase(.uppercase)
                .tracking(0.6)
                .padding(.leading, UniSpacing.xs)
            content()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .regular))
            }
            .accessibilityLabel(Text("Settings"))
        }

        // Wallet switcher in the nav-bar title slot (`.principal`).
        //
        // Per Rule #19, the pill goes through `UniButton(.toolbarPill)`
        // — the canonical Liquid Glass capsule for nav-bar slots. The
        // variant carries:
        //
        // 1. **The 17pt font + 13pt chevron** — the rhythm the toolbar's
        //    auto-glass icon envelope expects (this had to be
        //    rediscovered through five takes; recorded in SHIPPED.md).
        // 2. **`.controlSize(.large)`** — lifts the capsule into the
        //    same vertical envelope as the auto-glass icons sitting
        //    next to it (WWDC25 session 323, "Glassifying toolbars in
        //    SwiftUI": *the controlSize modifier "can be applied to a
        //    single control or across an entire set of controls" and
        //    is the canonical mechanism for matching heights across
        //    button styles in a toolbar*).
        // 3. **`.contentShape(Capsule())`** on the label — fixes the
        //    2026-06-08 hit-test bug where taps in the painted glass
        //    capsule but outside the text's intrinsic bounds fell
        //    through (only the text glyphs were tappable, even though
        //    the glass extended further). SwiftUI Button hit-tests the
        //    content's frame, not the layout-modifier frame; the
        //    contentShape brings the tap region back in line with the
        //    visible material.
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
        // Test affordance — mirrors the MnemonicReviewView toolbar
        // shipped 2026-06-06. Bare `flask.fill` SF Symbol per
        // M-002 / M-003 (no `.circle` chrome, no `.buttonStyle(.glass)`
        // — toolbar items inherit the nav bar's Liquid Glass).
        // `.uniHaptic(.selection)` per Rule #10 §A — toggling test
        // mode is a calm picker-class state change, not a commit.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                toggleTestMode()
            } label: {
                Image(systemName: "flask.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        isTestMode
                            ? UniColors.Tint.accent
                            : UniColors.Icon.secondary
                    )
            }
            .accessibilityLabel(Text("Test against public addresses"))
            .uniHaptic(.selection, trigger: isTestMode)
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

// MARK: - Destinations

enum WalletHomeDestination: Hashable, Codable {
    case send
    case swap
    case transaction(UUID)
}
