import SwiftUI

/// The hero card at the top of the wallet-home scroll: the active
/// wallet's name (tappable pill that opens the switcher sheet), the
/// total fiat balance in `heroBalance` type, and a small roll-up of
/// chain and token counts.
///
/// **Design intent (one sentence per Rule #2 §D.1):** show the user
/// the calm, undeniable truth of what they own — large, monospaced,
/// surrounded by space, with the active wallet's identity always
/// visible.
///
/// **What got stripped:** sparklines, "+2.3% today" badges, gradient
/// blobs behind the number. The total fiat IS the hero; ornament
/// around it is decoration. When real on-chain data lands we may add
/// a calm time-range selector beneath the number; today, the surface
/// has nothing to be ornamental about.
struct WalletHomeHeader: View {
    let walletName: String
    let totalFiat: Decimal
    let currencyCode: String
    /// Chains the wallet currently *holds* a non-zero balance on.
    /// Drives the held-rollup line when there's at least one balance.
    let chainCount: Int
    /// Distinct non-zero token rows across the active wallet.
    let tokenCount: Int
    /// Total chains the wallet has addresses derived for (a fresh
    /// HD wallet has all 24 supported chains here). Used as the
    /// fallback "26 chains supported" line when `hasAnyBalance` is
    /// false — calmer than rendering "0 chains · 0 tokens" while the
    /// scanner is still working / the wallet is empty.
    let totalChainsSupported: Int
    /// `true` when at least one balance row is non-zero. Drives the
    /// rollup-line branch: held-rollup vs. supported-fallback.
    let hasAnyBalance: Bool
    /// `true` while the refresh coordinator is fetching balances and
    /// prices. Surfaces a subtle "Refreshing…" footer so the user
    /// understands why the number might be a beat behind reality.
    let isRefreshing: Bool
    /// Last successful refresh, or `nil` if never refreshed. When
    /// `nil` and not currently refreshing, no footer is rendered (the
    /// number stands on its own).
    let lastSyncedAt: Date?
    /// When `true`, render the balance as `••••` until tapped. Toggled
    /// from Settings → Preferences → Hide balance on home (shoulder
    /// surfing protection).
    let hideBalance: Bool
    let onSwitchWallet: () -> Void
    /// Chart-scrub channel (2026-06-13 perf fix). While the user drags
    /// the sparkline, the hero shows the touched point's value instead
    /// of the wallet's resting total. Reading `scrubModel?.fiat` HERE
    /// (inside this view's body) means a scrub frame invalidates ONLY
    /// this header, not the whole `WalletHomeView` body — which used to
    /// rebuild the price dictionaries and re-sort balances 60×/sec.
    /// `nil` (default) → no scrub wiring (test mode).
    var scrubModel: ChartScrubModel? = nil

    @State private var isRevealingHiddenBalance: Bool = false

    var body: some View {
        VStack(spacing: UniSpacing.s) {
            // Switcher pill moved to the nav-bar `.principal` slot
            // 2026-06-07 per user direction — matches Apple's own
            // Mail / Notes pattern where the account / folder picker
            // is the nav-bar title. WalletHomeView owns the toolbar
            // item now and the body skips straight to the balance
            // hero.

            balanceLabel

            // rollupLine ("1 chain · 1 token" / "26 chains
            // supported" / "Refreshing…" / "Last synced X ago")
            // removed 2026-06-09 per user direction. Balance card
            // now hosts only the hero number — the chart sitting
            // below tells the rest of the story.
        }
        .frame(maxWidth: .infinity)
        // Vertical padding removed 2026-06-09 — the balance hero
        // sits flush at the top of the card and flush against the
        // chart's delta caption below. The List's own row insets
        // contribute the only remaining breathing room.
        .onChange(of: hideBalance) { _, newValue in
            // When the user turns "Hide balance" OFF, drop the
            // transient tap-to-reveal flag so the next time hiding
            // is enabled the balance starts masked instead of
            // inheriting a stale reveal.
            if !newValue { isRevealingHiddenBalance = false }
        }
    }

    @ViewBuilder
    private var balanceLabel: some View {
        let visible = !hideBalance || isRevealingHiddenBalance
        // Scrubbed value (if dragging) else the resting total. The read
        // of `scrubModel?.fiat` is what scopes scrub re-renders to this
        // header alone (2026-06-13 perf fix).
        let effectiveFiat = scrubModel?.fiat ?? totalFiat
        let display = visible
            ? WalletFormatting.fiat(effectiveFiat, currencyCode: currencyCode)
            : "••••••"
        Button {
            guard hideBalance else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isRevealingHiddenBalance.toggle()
            }
        } label: {
            Text(display)
                .font(UniTypography.heroBalance)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                // **2026-06-12 — countUp haptic REMOVED.** The
                // 2026-06-10 handoff bound `.uniHaptic(.countUp,
                // trigger: display)` here, ticking whenever the hero
                // string changed. That trigger is NOT touch-gated:
                // background balance scans (balance-first yields,
                // price re-yields, per-chain retries) re-render the
                // hero every few seconds while the user does nothing,
                // and the wallet home stays mounted behind the tab
                // bar — so the whole app buzzed at idle (user report
                // 2026-06-12: "it's doing haptic feedbacks without
                // me touching anything every few seconds"). Haptics
                // acknowledge the user's own actions (Rule #2
                // restraint); passive data updates are not the
                // user's hand. Scrubbing already has its own
                // dedicated scrub-tick haptics in the chart.
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            visible
                ? Text("Total balance \(WalletFormatting.fiat(totalFiat, currencyCode: currencyCode))")
                : Text("Balance hidden, tap to reveal")
        )
    }

    /// Legacy pill — the wallet switcher was moved to the nav-bar
    /// `.principal` slot 2026-06-07 (see comment at the top of `body`).
    /// Kept as a fallback / preview-only surface; routed through
    /// `UniButton(.toolbarPill)` per Rule #19 so any future revival
    /// inherits the unified hit-test contract and the variant haptic.
    private var walletSwitcherPill: some View {
        UniButton(
            verbatim: walletName,
            variant: .toolbarPill,
            action: onSwitchWallet
        )
        .accessibilityLabel(Text("Switch wallet, currently \(walletName)"))
    }

    @ViewBuilder
    private var rollupLine: some View {
        // Refreshing + "Last synced X ago" rows removed on
        // 2026-06-09 user direction — the balance card is now a
        // calm hero, not a status dashboard. The data still
        // refreshes silently on appear + pull-to-refresh; the
        // user just doesn't see the metadata row.
        if hasAnyBalance {
            // Inflection markup `^[...](inflect: true)` is resolved by
            // SwiftUI's `LocalizedStringKey` initializer at render
            // time via Foundation morphology. Passing the same markup
            // through `String(localized:)` (the previous shape) only
            // resolves it when the catalog table is registered with
            // the morphology engine — when it isn't, the literal `^[]`
            // shows through (the bug visible in 2026-06-06
            // Thuglife/iPhone-17-Pro-Max screenshots). Letting `Text`
            // own the LocalizedStringKey directly is the iOS-26-native
            // path and resolves correctly with no catalog plumbing.
            HStack(spacing: 0) {
                Text("^[\(chainCount) chain](inflect: true)")
                Text(verbatim: " · ")
                Text("^[\(tokenCount) token](inflect: true)")
            }
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Text.tertiary)
        } else if totalChainsSupported > 0 {
            // Fresh wallet, no balances scanned yet. "26 chains
            // supported" reads as calm capability rather than
            // "0 chains · 0 tokens" which reads as failure.
            Text("^[\(totalChainsSupported) chain](inflect: true) supported")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }
}
