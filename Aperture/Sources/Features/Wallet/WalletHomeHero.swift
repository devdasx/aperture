import SwiftUI
import UIKit
import GRDB
import Lottie

// MARK: - In-hero pull metrics (shared by production + lab)

/// Resistance-limited pull for the balance-card refresh slot.
/// Raw scroll rubber-band can grow without bound; **display** pull uses a
/// tanh curve that gets progressively harder and asymptotes at `maxStretch`.
enum WalletHomePullMetrics {
    /// Balance pager page height (pt).
    static let balancePageHeight: CGFloat = 200
    /// Maximum in-card stretch (pt) — refresh chrome is fully visible here.
    static let maxStretch: CGFloat = 80
    /// Display pull at which refresh is armed (slot fully shown).
    static let armThreshold: CGFloat = 64
    /// Hide the mark below this display pull (dead zone).
    static let revealThreshold: CGFloat = 14
    /// Raw scroll pull considered “finger up / at rest”.
    static let releaseRaw: CGFloat = 10
    /// Spring used when the card settles after release (native feel).
    static let settleSpring: Animation = .spring(response: 0.38, dampingFraction: 0.86)
    /// Wait for settle spring before starting network refresh (ms).
    static let settleDurationMs: UInt64 = 420
    /// Lottie display size on the balance card (product: slightly smaller
    /// than the original 40×40 so pull-to-refresh stays calm).
    static let markSize: CGFloat = 32
    /// Strip height while loading / success — equals mark size so the mark
    /// does not re-center when the pull stretch collapses to the hold.
    static let holdHeight: CGFloat = 32

    /// Map unbounded raw rubber-band → resisted display pull in `0…maxStretch`.
    static func resisted(raw: CGFloat) -> CGFloat {
        guard raw > 0 else { return 0 }
        let limit = maxStretch
        // Nearly linear at first, then hardens toward the cap (harder to stretch).
        return limit * CGFloat(tanh(Double(raw) / Double(limit * 0.85)))
    }
}

// MARK: - Hero pager (swipe wallets + UIPageControl + action row)

/// Production wallet-home hero: solid identity colour card, paged balances,
/// native page dots, Receive / Send / Scan / Hide at 52pt height.
///
/// **Pager stability:** horizontal `scrollPosition` is owned as **local**
/// `@State` so parent rebuilds (active-wallet refresh) cannot yank the page
/// back to a previous wallet. Settled page is pushed to `selectedWalletId`.
struct WalletHomeHeroPager: View {
    let wallets: [WalletRecord]
    @Binding var selectedWalletId: UUID?
    let currencyCode: String
    /// Watch-only wallets cannot send.
    var canSend: Bool = true
    let onReceive: () -> Void
    let onSend: () -> Void
    let onScan: () -> Void
    /// Resisted pull distance — grows the in-card mark strip (moves with hero).
    var pullDistance: CGFloat = 0
    /// Lottie phase from the parent PTR state machine.
    var markRefreshPhase: WalletHomeMarkRefreshPhase = .idle
    /// Called when success frames finish — parent dismisses the strip.
    var onMarkRefreshSuccessFinished: (() -> Void)? = nil
    /// Settled fractional page index for the parent app bar (idle only).
    var onSwipeProgressChange: ((CGFloat) -> Void)? = nil

    @GRDBStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var isHidden: Bool = false
    /// Shared identity chrome — also drives hero fill so icon-picker
    /// colour writes paint the balance card immediately (not only after
    /// the next pager gesture).
    @ObservedObject private var swipeChrome = WalletHomeSwipeChrome.shared
    /// iPad / regular width uses a neutral page surface (no identity wash).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesIdentitySurface: Bool {
        horizontalSizeClass != .regular
    }
    /// Per-page balance snapshots (from `WalletHomeHeroPage`) — drives the
    /// shared balance surface + action-row empty chrome.
    @State private var balanceByWalletId: [UUID: WalletHomeHeroBalanceReport] = [:]
    /// Action-row empty flag with **explicit** animation (pager progress itself
    /// is written under `disablesAnimations`, which killed content transitions).
    @State private var actionRowEmpty: Bool = true
    /// Nearer wallet whose balance is shown on the shared surface. Updates
    /// with the same snappy family as Send/Receive (not a hard page slide).
    @State private var displayedBalanceWalletId: UUID?

    /// Pull / hold strip for mark-refresh Lottie — height follows parent
    /// `pullDistance` / phase; always part of the identity card surface.
    @ViewBuilder
    private var inCardMarkStrip: some View {
        let resolvedPhase: WalletHomeMarkRefreshPhase = {
            if markRefreshPhase != .idle { return markRefreshPhase }
            if pullDistance >= WalletHomePullMetrics.revealThreshold {
                let span = max(
                    1,
                    WalletHomePullMetrics.armThreshold - WalletHomePullMetrics.revealThreshold
                )
                let p = min(
                    1,
                    max(0, (pullDistance - WalletHomePullMetrics.revealThreshold) / span)
                )
                return .pulling(progress: p)
            }
            return .idle
        }()
        if resolvedPhase != .idle {
            WalletHomePullRefreshOverlay(
                pullDistance: pullDistance,
                phase: resolvedPhase,
                onSuccessFinished: onMarkRefreshSuccessFinished
            )
        }
    }
    /// Fractional page index `0…count-1` while swiping — local only.
    @State private var pageSwipeProgress: CGFloat = 0
    /// Local scroll target — must not be the parent binding (rebuild races).
    @State private var pagerScrollId: UUID?
    /// True while the user is actively dragging the wallet pager.
    @State private var isPagingHorizontally: Bool = false

    private var selectedWallet: WalletRecord? {
        if let id = selectedWalletId {
            return wallets.first(where: { $0.id == id }) ?? wallets.first
        }
        return wallets.first
    }

    /// Spec used for chrome contrast mid-swipe (nearest page after halfway).
    private var avatarSpec: WalletAvatarSpec {
        swipeChrome.nearerSpec
    }

    /// On identity surfaces: same ink/cloud as the avatar iris. On iPad
    /// (neutral page): standard text tokens — no light-on-pink contrast.
    private var fg: Color {
        usesIdentitySurface
            ? UniColors.WalletAvatar.contentPrimary(for: avatarSpec)
            : UniColors.Text.primary
    }

    private var fgSecondary: Color {
        usesIdentitySurface
            ? UniColors.WalletAvatar.contentSecondary(for: avatarSpec)
            : UniColors.Text.secondary
    }

    private var chipFill: Color {
        usesIdentitySurface
            ? UniColors.WalletAvatar.contentChipFill(for: avatarSpec)
            : UniColors.Fill.tertiary
    }


    /// True when the settled (selected) wallet has no balance — legacy
    /// action-row branch only.
    private var isSelectedWalletEmpty: Bool {
        guard let id = selectedWalletId else { return true }
        return balanceByWalletId[id]?.isEmpty ?? true
    }

    /// Nearer page’s empty state (half-swipe), same timing as the app-bar name.
    private func isNearerWalletEmpty(at progress: CGFloat) -> Bool {
        guard let id = nearerWalletId(at: progress) else { return true }
        return balanceByWalletId[id]?.isEmpty ?? true
    }

    /// Wallet whose balance should paint on the shared surface (halfway rule —
    /// identical to action-row empty + app-bar name).
    private func nearerWalletId(at progress: CGFloat) -> UUID? {
        guard !wallets.isEmpty else { return nil }
        let maxIndex = wallets.count - 1
        let idx = min(max(Int(progress.rounded()), 0), maxIndex)
        return wallets[idx].id
    }

    private var displayedBalanceReport: WalletHomeHeroBalanceReport? {
        guard let id = displayedBalanceWalletId else { return nil }
        return balanceByWalletId[id]
    }

    /// From/to avatar specs + blend `t` for the current fractional page.
    private var swipePair: (from: WalletAvatarSpec, to: WalletAvatarSpec, t: CGFloat) {
        Self.swipePair(wallets: wallets, progress: pageSwipeProgress)
    }

    static func swipePair(
        wallets: [WalletRecord],
        progress: CGFloat
    ) -> (from: WalletAvatarSpec, to: WalletAvatarSpec, t: CGFloat) {
        let fallback = WalletAvatarSpec.auto(name: "Wallet")
        guard !wallets.isEmpty else { return (fallback, fallback, 0) }
        let maxIndex = CGFloat(wallets.count - 1)
        let p = min(maxIndex, max(0, progress))
        let i = Int(floor(p))
        let t = p - CGFloat(i)
        let from = wallets[min(max(i, 0), wallets.count - 1)].avatarSpec
        let toIndex = min(i + 1, wallets.count - 1)
        let to = wallets[toIndex].avatarSpec
        return (from, to, t)
    }

    private var pageIndexBinding: Binding<Int> {
        Binding(
            get: {
                guard let id = pagerScrollId ?? selectedWalletId,
                      let idx = wallets.firstIndex(where: { $0.id == id })
                else { return 0 }
                return idx
            },
            set: { newIndex in
                guard wallets.indices.contains(newIndex) else { return }
                let id = wallets[newIndex].id
                pagerScrollId = id
                selectedWalletId = id
                pageSwipeProgress = CGFloat(newIndex)
                onSwipeProgressChange?(CGFloat(newIndex))
            }
        )
    }

    var body: some View {
        // ONE solid identity fill for the whole card (no gradient — avoids
        // mid-card bands when chrome + pager layers meet).
        //
        // Mark strip is **inside** this hero (scroll content), not a
        // screen-fixed overlay. A fixed overlay stayed at the top of the
        // ZStack while the card rubber-banded, so on finger-up the mark
        // jumped relative to the balance UI. Anchored to the card it
        // travels with overscroll and stays put through hold → success.
        VStack(spacing: 0) {
            inCardMarkStrip

            if wallets.isEmpty {
                emptyHero
            } else {
                // Shared balance surface (morphs like Send/Receive) + invisible
                // horizontal pager for the swipe gesture / selection.
                ZStack {
                    sharedBalanceSurface
                        .frame(maxWidth: .infinity)
                        .frame(height: WalletHomePullMetrics.balancePageHeight)
                        .allowsHitTesting(false)

                    // Horizontal paging via ScrollView — not TabView(.page).
                    // Pages are transparent observers; the painted balance
                    // lives in `sharedBalanceSurface` so wallet switches
                    // cross-fade / numeric-morph instead of hard-sliding.
                    ScrollView(.horizontal, showsIndicators: false) {
                        // HStack (not Lazy) — few wallets; LazyHStack + scrollPosition
                        // recycled pages and jumped back to wallet 1 after swipes.
                        HStack(spacing: 0) {
                            ForEach(wallets) { wallet in
                                WalletHomeHeroPage(
                                    walletId: wallet.id,
                                    walletName: wallet.name,
                                    avatarSpec: wallet.avatarSpec,
                                    currencyCode: currencyCode
                                )
                                .containerRelativeFrame(.horizontal)
                                .frame(height: WalletHomePullMetrics.balancePageHeight)
                                .id(wallet.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    // One wallet per gesture — long/fast swipes must not
                    // fling across 4–5 pages (`.always` allowed multi-page).
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollPosition(id: $pagerScrollId)
                    .frame(height: WalletHomePullMetrics.balancePageHeight)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        let width = geometry.containerSize.width
                        guard width > 1 else { return pageSwipeProgress }
                        return (geometry.contentOffset.x + geometry.contentInsets.leading) / width
                    } action: { _, newProgress in
                        handleHorizontalPageProgress(newProgress)
                    }
                    .onScrollPhaseChange { _, newPhase in
                        isPagingHorizontally = (newPhase == .interacting || newPhase == .decelerating)
                        if newPhase == .idle {
                            commitSelectionFromProgress()
                        }
                    }
                    .onChange(of: pagerScrollId) { _, newId in
                        // View-aligned settle can update scroll id before phase idle.
                        guard let newId, !isPagingHorizontally else { return }
                        if selectedWalletId != newId {
                            selectedWalletId = newId
                        }
                    }
                }

                heroActionRow
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.xs)
                    .padding(.bottom, wallets.count > 1 ? 0 : UniSpacing.s)

                // Page dots sit under the action row — extra top inset so the
                // Receive/Send row breathes above the indicators.
                if wallets.count > 1 {
                    WalletHomePageControl(
                        currentPage: pageIndexBinding,
                        numberOfPages: wallets.count,
                        currentColor: fg,
                        inactiveColor: fg.opacity(0.35)
                    )
                    .padding(.top, UniSpacing.m)
                    .padding(.bottom, UniSpacing.s)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background { heroBackground }
        .onPreferenceChange(WalletHomePageBalanceKey.self) { map in
            balanceByWalletId = map
            // Balance data may land after the page — animate chrome + surface.
            syncActionRowEmpty(animated: true)
            syncDisplayedBalanceWallet(animated: true)
        }
        .onAppear {
            seedPagerFromSelection(force: true, animateActionRow: false, animated: false)
        }
        .onChange(of: selectedWalletId) { _, newId in
            // External selection only (switcher / parent / create-import).
            // Never while the user is paging with a finger.
            guard !isPagingHorizontally else { return }
            guard let newId else { return }
            if pagerScrollId != newId {
                seedPagerFromSelection(
                    force: true,
                    animateActionRow: true,
                    animated: false
                )
            }
        }
        .onChange(of: wallets.map(\.id)) { _, newIds in
            guard !isPagingHorizontally else { return }
            // Follow parent selection when a new wallet joins the pager.
            if let target = selectedWalletId, newIds.contains(target) {
                if pagerScrollId != target {
                    seedPagerFromSelection(
                        force: true,
                        animateActionRow: true,
                        animated: false
                    )
                }
                return
            }
            if let id = pagerScrollId, newIds.contains(id) {
                return
            }
            seedPagerFromSelection(force: true, animateActionRow: false, animated: false)
        }
        // Icon picker writes a new gradient without changing wallet ids —
        // re-publish chrome so the balance card tracks GRDB once it lands.
        .onChange(of: walletIdentityFingerprint) { _, _ in
            guard !isPagingHorizontally else { return }
            WalletHomeSwipeChrome.shared.publish(
                progress: pageSwipeProgress,
                wallets: wallets
            )
        }
    }

    /// Gradient / custom hex fingerprint per wallet — identity-only (not name).
    private var walletIdentityFingerprint: String {
        wallets.map {
            let custom = $0.avatarSpec.customColorHex ?? ""
            return "\($0.id.uuidString):\($0.avatarSpec.gradient.rawValue):\(custom)"
        }
        .joined(separator: "|")
    }

    // MARK: - Shared balance surface (morphs with nearer wallet)

    /// Balance / empty copy for the nearer wallet. Same snappy + content
    /// transitions as the action row — wallet switches animate in place
    /// instead of only sliding a page under the chrome.
    @ViewBuilder
    private var sharedBalanceSurface: some View {
        let report = displayedBalanceReport
        let empty = report?.isEmpty ?? true
        let totalFiat = report?.totalFiat ?? .zero
        let lastUpdated = report?.lastUpdated

        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Group {
                if empty {
                    sharedEmptyBalanceBody
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            )
                        )
                } else {
                    VStack(spacing: 6) {
                        sharedBalanceBlock(totalFiat: totalFiat)
                        if let lastUpdated {
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                HStack(spacing: 4) {
                                    Text(verbatim: WalletHomeHeroPage.updatedCaption(lastUpdated))
                                        .font(UniTypography.caption2)
                                        .foregroundStyle(fgSecondary)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(fgSecondary)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))
                        )
                    )
                }
            }
            // No `.id(wallet)` — keep Text identity so `.numericText()` can
            // morph amounts across wallets (same idea as Send/Receive labels).
            .padding(.horizontal, UniSpacing.l)

            Spacer(minLength: 0)
        }
        // Same family as Send/Receive empty ↔ funded morph.
        .animation(.snappy(duration: 0.28), value: empty)
        .animation(.snappy(duration: 0.28), value: displayedBalanceWalletId)
        .animation(.snappy(duration: 0.28), value: totalFiat)
        .animation(.snappy(duration: 0.34), value: isHidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sharedBalanceAccessibilityLabel(empty: empty, totalFiat: totalFiat))
    }

    private var sharedEmptyBalanceBody: some View {
        VStack(spacing: UniSpacing.xs) {
            // Same content ink/cloud as balance text (`fg` / `fgSecondary`) so
            // the dashed mark tracks the wallet colour surface — never a
            // fixed grey that washes out on cyan / rose / etc.
            Image("MarkEmptyDashed")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(fgSecondary)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

            Text("No balance yet")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(fg)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your balance appears here once this wallet receives crypto on-chain.")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(fgSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func sharedBalanceBlock(totalFiat: Decimal) -> some View {
        ZStack {
            sharedComposedBalance(totalFiat: totalFiat)
                .opacity(isHidden ? 0 : 1)
                .scaleEffect(isHidden ? 0.94 : 1)
                .blur(radius: isHidden ? 4 : 0)
                .accessibilityHidden(isHidden)

            Text(verbatim: WalletFormatting.hiddenAmount)
                .font(WalletHomeHeroMetrics.balanceIntegerFont)
                .foregroundStyle(fg)
                .monospacedDigit()
                .tracking(2)
                .opacity(isHidden ? 1 : 0)
                .scaleEffect(isHidden ? 1 : 0.94)
                .blur(radius: isHidden ? 0 : 4)
                .accessibilityHidden(!isHidden)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func sharedComposedBalance(totalFiat: Decimal) -> some View {
        let parts = WalletFormatting.fiatParts(totalFiat, currencyCode: currencyCode)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if parts.currencyLeads, !parts.currency.isEmpty {
                Text(verbatim: parts.currency)
                    .font(WalletHomeHeroMetrics.balanceCurrencyFont)
                    .foregroundStyle(fgSecondary)
                    .contentTransition(.opacity)
                Text(verbatim: " ")
                    .font(WalletHomeHeroMetrics.balanceCurrencyFont)
            }
            Text(verbatim: parts.integer)
                .font(WalletHomeHeroMetrics.balanceIntegerFont)
                .foregroundStyle(fg)
                .contentTransition(.numericText())
            if let fraction = parts.fraction, !fraction.isEmpty {
                Text(verbatim: fraction)
                    .font(WalletHomeHeroMetrics.balanceFractionFont)
                    .foregroundStyle(fg.opacity(0.55))
                    .contentTransition(.numericText())
            }
            if !parts.currencyLeads, !parts.currency.isEmpty {
                Text(verbatim: " ")
                    .font(WalletHomeHeroMetrics.balanceCurrencyFont)
                Text(verbatim: parts.currency)
                    .font(WalletHomeHeroMetrics.balanceCurrencyFont)
                    .foregroundStyle(fgSecondary)
                    .contentTransition(.opacity)
            }
        }
    }

    private func sharedBalanceAccessibilityLabel(empty: Bool, totalFiat: Decimal) -> Text {
        if empty {
            return Text("Total balance empty. Receive funds to get started.")
        }
        if isHidden {
            return Text("Total balance hidden")
        }
        let value = WalletFormatting.fiat(totalFiat, currencyCode: currencyCode)
        return Text(verbatim: String(format: String.apertureLocalized("Total balance %@"), value))
    }

    private var emptyHero: some View {
        Text("No wallets yet.")
            .font(UniTypography.body)
            .foregroundStyle(fgSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xxl)
    }

    /// Flip to `false` to restore the pre-transition action row (branching
    /// if/else, instant swap). Design preserved in `heroActionRowLegacy`.
    private static let useDynamicHeroActionTransitions = true

    /// Funded: Receive + Send + Scan + Hide.
    /// Empty: wide **Add funds** (+), Send, Scan — hide fades out.
    @ViewBuilder
    private var heroActionRow: some View {
        if Self.useDynamicHeroActionTransitions {
            heroActionRowDynamic
        } else {
            heroActionRowLegacy
        }
    }

    /// Current shipping design (static swap). Kept verbatim for easy rollback.
    @ViewBuilder
    private var heroActionRowLegacy: some View {
        HStack(spacing: UniSpacing.s) {
            if isSelectedWalletEmpty {
                heroTextButton(
                    title: String.apertureLocalized("Add funds"),
                    systemImage: "plus",
                    isEnabled: true,
                    expands: true,
                    action: onReceive
                )
                // Compact but not hug-only — min width so “Send” isn’t a sliver
                // next to the wide Add funds control.
                heroTextButton(
                    title: String.apertureLocalized("Send"),
                    systemImage: "arrow.up.right",
                    isEnabled: canSend,
                    expands: false,
                    minWidth: 108,
                    action: onSend
                )
                heroIconButton(
                    systemImage: "qrcode.viewfinder",
                    accessibilityLabel: String.apertureLocalized("Scan"),
                    action: onScan
                )
            } else {
                heroTextButton(
                    title: String.apertureLocalized("Receive"),
                    systemImage: "arrow.down.left",
                    isEnabled: true,
                    expands: true,
                    action: onReceive
                )
                heroTextButton(
                    title: String.apertureLocalized("Send"),
                    systemImage: "arrow.up.right",
                    isEnabled: canSend,
                    expands: true,
                    action: onSend
                )
                HStack(spacing: UniSpacing.xs) {
                    heroIconButton(
                        systemImage: "qrcode.viewfinder",
                        accessibilityLabel: String.apertureLocalized("Scan"),
                        action: onScan
                    )
                    heroIconButton(
                        systemImage: isHidden ? "eye.slash" : "eye",
                        accessibilityLabel: String.apertureLocalized(
                            isHidden ? "Show balance" : "Hide balance"
                        ),
                        action: toggleHidden
                    )
                }
            }
        }
    }

    /// One stable row: primary title/icon cross-fade; eye fades (no layout pop).
    /// Uses `actionRowEmpty` (animated) — not raw progress under disablesAnimations.
    private var heroActionRowDynamic: some View {
        let empty = actionRowEmpty
        let primaryTitle = empty
            ? String.apertureLocalized("Add funds")
            : String.apertureLocalized("Receive")
        let primarySymbol = empty ? "plus" : "arrow.down.left"
        return HStack(spacing: UniSpacing.s) {
            heroTextButton(
                title: primaryTitle,
                systemImage: primarySymbol,
                isEnabled: true,
                expands: true,
                action: onReceive
            )

            heroTextButton(
                title: String.apertureLocalized("Send"),
                systemImage: "arrow.up.right",
                isEnabled: canSend,
                expands: !empty,
                minWidth: empty ? 108 : nil,
                action: onSend
            )

            HStack(spacing: UniSpacing.xs) {
                heroIconButton(
                    systemImage: "qrcode.viewfinder",
                    accessibilityLabel: String.apertureLocalized("Scan"),
                    action: onScan
                )

                // No reserved empty slot — when empty the eye is removed so
                // Add funds can grow (legacy layout). Fade on insert/remove.
                if !empty {
                    heroIconButton(
                        systemImage: isHidden ? "eye.slash" : "eye",
                        accessibilityLabel: String.apertureLocalized(
                            isHidden ? "Show balance" : "Hide balance"
                        ),
                        action: toggleHidden
                    )
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.86)),
                            removal: .opacity.combined(with: .scale(scale: 0.86))
                        )
                    )
                }
            }
        }
        // Same snappy family as the app-bar wallet name.
        .animation(.snappy(duration: 0.28), value: empty)
    }

    /// Sync action-row empty chrome. Call with `animated: true` when the
    /// nearer wallet’s empty state flips (page swipe / preference update).
    private func syncActionRowEmpty(animated: Bool) {
        let next = isNearerWalletEmpty(at: pageSwipeProgress)
        guard next != actionRowEmpty else { return }
        if animated {
            withAnimation(.snappy(duration: 0.28)) {
                actionRowEmpty = next
            }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                actionRowEmpty = next
            }
        }
    }

    /// Sync the shared balance surface to the nearer wallet. Explicit
    /// animation — pager progress writes use `disablesAnimations`, which
    /// would otherwise kill content transitions (same fix as the action row).
    private func syncDisplayedBalanceWallet(animated: Bool) {
        let next = nearerWalletId(at: pageSwipeProgress)
        guard next != displayedBalanceWalletId else { return }
        if animated {
            withAnimation(.snappy(duration: 0.28)) {
                displayedBalanceWalletId = next
            }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) {
                displayedBalanceWalletId = next
            }
        }
    }

    /// Cross-fade between neighbouring wallet solid identity colours while swiping.
    /// Reads from `WalletHomeSwipeChrome` so a live icon-colour write updates
    /// the full balance card without requiring a re-swipe.
    /// iPad: neutral page background (no coloured hero wash).
    @ViewBuilder
    private var heroBackground: some View {
        if usesIdentitySurface {
            swipeChrome.blendedIdentityColor
        } else {
            UniColors.Background.primary
        }
    }

    private func handleHorizontalPageProgress(_ raw: CGFloat) {
        guard !wallets.isEmpty else { return }
        let maxIndex = CGFloat(wallets.count - 1)
        let p = min(maxIndex, max(0, raw))
        // Sub-point updates keep the **local** fade smooth. Parent `@State`
        // is not updated here (that re-rendered home and snapped the pager).
        // Live app-bar colour goes through `WalletHomeSwipeChrome` instead.
        guard abs(p - pageSwipeProgress) >= 0.002 else { return }
        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            pageSwipeProgress = p
        }
        WalletHomeSwipeChrome.shared.publish(progress: p, wallets: wallets)
        // Chrome + shared balance animate outside the silent progress write.
        syncActionRowEmpty(animated: true)
        syncDisplayedBalanceWallet(animated: true)
    }

    /// Snap selection to the nearest page when horizontal scroll idles.
    private func commitSelectionFromProgress() {
        guard !wallets.isEmpty else { return }
        let maxIndex = wallets.count - 1
        let idx = Int(pageSwipeProgress.rounded())
        let clamped = min(max(idx, 0), maxIndex)
        let id = wallets[clamped].id
        let settled = CGFloat(clamped)

        var txn = Transaction()
        txn.disablesAnimations = true
        withTransaction(txn) {
            pagerScrollId = id
            pageSwipeProgress = settled
            if selectedWalletId != id {
                selectedWalletId = id
            }
        }
        WalletHomeSwipeChrome.shared.publish(progress: settled, wallets: wallets)
        onSwipeProgressChange?(settled)
        syncActionRowEmpty(animated: true)
        syncDisplayedBalanceWallet(animated: true)
    }

    /// Align local pager to parent / switcher selection.
    /// - Parameter animated: scroll the balance card like a finger swipe
    ///   (create/import/switcher). User drags always use live scroll.
    private func seedPagerFromSelection(
        force: Bool,
        animateActionRow: Bool = true,
        animated: Bool = false
    ) {
        guard !wallets.isEmpty else {
            pagerScrollId = nil
            pageSwipeProgress = 0
            onSwipeProgressChange?(0)
            syncActionRowEmpty(animated: false)
            syncDisplayedBalanceWallet(animated: false)
            return
        }
        let id = selectedWalletId ?? wallets.first?.id
        guard let id,
              let i = wallets.firstIndex(where: { $0.id == id })
        else { return }
        let idx = CGFloat(i)
        guard force || pagerScrollId != id || abs(idx - pageSwipeProgress) >= 0.02 else {
            syncActionRowEmpty(animated: animateActionRow)
            syncDisplayedBalanceWallet(animated: animateActionRow)
            return
        }
        let apply = {
            pagerScrollId = id
            pageSwipeProgress = idx
        }
        if animated, wallets.count > 1 {
            withAnimation(.snappy(duration: 0.38)) { apply() }
        } else {
            var txn = Transaction()
            txn.disablesAnimations = true
            withTransaction(txn) { apply() }
        }
        WalletHomeSwipeChrome.shared.publish(progress: idx, wallets: wallets)
        onSwipeProgressChange?(idx)
        syncActionRowEmpty(animated: animateActionRow)
        syncDisplayedBalanceWallet(animated: animateActionRow)
    }

    private func heroIconButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(fg)
                .frame(width: 52, height: 52)
                .background(Circle().fill(chipFill))
                .contentShape(Circle())
        }
        // Custom expand + bounce + shimmer (no system Liquid Glass).
        .buttonStyle(.uniInteractivePressCircle)
        .controlSize(.regular)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private func heroTextButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        expands: Bool = true,
        minWidth: CGFloat? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: systemImage == "plus" ? .semibold : .regular))
                    .contentTransition(.symbolEffect(.replace))
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(fg.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 16)
            .frame(minWidth: minWidth)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(height: 52)
            .background(Capsule(style: .continuous).fill(chipFill))
            .contentShape(Capsule(style: .continuous))
            .animation(.snappy(duration: 0.28), value: title)
            .animation(.snappy(duration: 0.28), value: systemImage)
        }
        // Custom expand + bounce + shimmer; commit beat (Add funds / Send).
        .buttonStyle(.uniInteractivePressCommit)
        .controlSize(.regular)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(verbatim: title))
    }

    private func toggleHidden() {
        // Drive native text content transitions on the hero balance.
        withAnimation(.snappy(duration: 0.34)) {
            isHidden = !isHidden
        }
        UniHapticEngine.shared.play(.toggle)
    }
}

// MARK: - Mark refresh (mark-refresh-kit Lottie)

/// Playback phases from `Aperture/Resources/Motion/mark-refresh-kit/README.md`.
///
/// 1. **Pull** — scrub frames `0…66` (wind-up + spin-up) with finger
/// 2. **Loading** — loop frames `66…124` until data is ready
/// 3. **Success** — play frames `124…210` once (aperture close → green → check)
enum WalletHomeMarkRefreshPhase: Equatable {
    case idle
    /// 0…1 maps to Lottie frames 0…66.
    case pulling(progress: CGFloat)
    case loading
    case success
}

/// In-card mark strip — Lottie from `mark-refresh-kit`.
/// Sits at the **top of the balance hero** so it moves with rubber-band
/// and never jumps when the finger lifts. Variant by surface contrast.
struct WalletHomePullRefreshOverlay: View {
    var pullDistance: CGFloat
    var phase: WalletHomeMarkRefreshPhase
    var onSuccessFinished: (() -> Void)? = nil

    @ObservedObject private var chrome = WalletHomeSwipeChrome.shared
    @Environment(\.apertureAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Strip height: pull stretch, or hold height while loading/success.
    private var slotHeight: CGFloat {
        switch phase {
        case .idle:
            return 0
        case .pulling:
            guard pullDistance >= WalletHomePullMetrics.revealThreshold else { return 0 }
            return min(pullDistance, WalletHomePullMetrics.maxStretch)
        case .loading, .success:
            return WalletHomePullMetrics.holdHeight
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var animationName: String {
        // iPad: neutral page surface → always dark-on-light mark.
        if horizontalSizeClass == .regular {
            return "mark-refresh-light"
        }
        // Do: pick by surface contrast (README §8).
        if chrome.prefersLightForeground {
            // Light ink on dark card — white or midnight mark.
            switch appearance {
            case .midnight: return "mark-refresh-midnight"
            default: return "mark-refresh-dark"
            }
        }
        return "mark-refresh-light"
    }

    var body: some View {
        let h = slotHeight
        if h > 0 {
            // **Bottom-align** the mark in the stretch strip.
            // Centering inside a growing/shrinking strip was the jump:
            // pull h≈80 → center at y=40; hold h=40 → center at y=20
            // (mark leapt up 20pt on finger-up). Bottom-pinned, the mark
            // stays glued just above the balance content for every frame.
            ZStack(alignment: .bottom) {
                MarkRefreshLottieView(
                    animationName: animationName,
                    phase: phase,
                    reduceMotion: reduceMotion,
                    onSuccessFinished: onSuccessFinished
                )
                .frame(
                    width: WalletHomePullMetrics.markSize,
                    height: WalletHomePullMetrics.markSize
                )
                .clipped()
            }
            .frame(maxWidth: .infinity)
            .frame(height: h, alignment: .bottom)
            .opacity(phaseOpacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityLabelKey))
        }
    }

    private var phaseOpacity: Double {
        switch phase {
        case .pulling(let p):
            return max(0.45, min(1, Double(p) * 1.2 + 0.35))
        case .loading, .success:
            return 1
        case .idle:
            return 0
        }
    }

    private var accessibilityLabelKey: LocalizedStringKey {
        switch phase {
        case .loading, .success: return "Refreshing"
        default: return "Pull to refresh"
        }
    }
}

// MARK: - Lottie host (mark-refresh-kit)

/// Host that **forces** display size to `WalletHomePullMetrics.markSize`.
/// The kit JSON is authored at 70×70; without an explicit container +
/// `sizeThatFits`, `LottieAnimationView` keeps a 70pt intrinsic size and
/// ignores the SwiftUI `.frame(width:height:)` — looking larger than 40.
private struct MarkRefreshLottieView: UIViewRepresentable {
    var animationName: String
    var phase: WalletHomeMarkRefreshPhase
    var reduceMotion: Bool
    var onSuccessFinished: (() -> Void)?

    private var displaySize: CGFloat { WalletHomePullMetrics.markSize }

    final class Coordinator {
        var loadedName: String?
        var lastPhase: WalletHomeMarkRefreshPhase = .idle
        var successCompletion: (() -> Void)?
        weak var animationView: LottieAnimationView?
    }

    /// Container so Auto Layout pins Lottie to the SwiftUI-proposed bounds.
    final class HostView: UIView {
        let animationView = LottieAnimationView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            animationView.contentMode = .scaleAspectFit
            animationView.backgroundBehavior = .pauseAndRestore
            animationView.loopMode = .playOnce
            animationView.animationSpeed = 1
            animationView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(animationView)
            NSLayoutConstraint.activate([
                animationView.leadingAnchor.constraint(equalTo: leadingAnchor),
                animationView.trailingAnchor.constraint(equalTo: trailingAnchor),
                animationView.topAnchor.constraint(equalTo: topAnchor),
                animationView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize {
            CGSize(
                width: WalletHomePullMetrics.markSize,
                height: WalletHomePullMetrics.markSize
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let host = HostView()
        context.coordinator.animationView = host.animationView
        return host
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: HostView,
        context: Context
    ) -> CGSize? {
        // Always 40×40 — never fall back to the JSON’s 70×70 intrinsic.
        CGSize(width: displaySize, height: displaySize)
    }

    func updateUIView(_ host: HostView, context: Context) {
        let view = host.animationView
        let coord = context.coordinator
        coord.animationView = view
        coord.successCompletion = onSuccessFinished
        host.invalidateIntrinsicContentSize()

        if coord.loadedName != animationName {
            view.animation = LottieAnimation.named(animationName)
            coord.loadedName = animationName
            coord.lastPhase = .idle
        }
        guard view.animation != nil else { return }

        // Reduce motion: frame 0 while loading, final frame on success (README §8).
        if reduceMotion {
            view.stop()
            switch phase {
            case .success:
                view.currentFrame = 210
                if coord.lastPhase != .success {
                    coord.lastPhase = .success
                    DispatchQueue.main.async { coord.successCompletion?() }
                }
            case .loading, .pulling:
                view.currentFrame = 0
                coord.lastPhase = phase
            case .idle:
                view.currentFrame = 0
                coord.lastPhase = .idle
            }
            return
        }

        switch phase {
        case .idle:
            view.stop()
            view.currentFrame = 0
            coord.lastPhase = .idle

        case .pulling(let progress):
            // Scrub wind-up + spin-up (frames 0…66).
            let p = min(1, max(0, progress))
            view.stop()
            view.currentFrame = AnimationFrameTime(p * 66)
            coord.lastPhase = .pulling(progress: p)

        case .loading:
            if case .loading = coord.lastPhase, view.isAnimationPlaying {
                break
            }
            // Enter loop: if we just finished pull at ~66, jump into seamless loop.
            // If cold-start, play 0→66 once then loop 66→124 (README §5).
            let enterFromPull: Bool = {
                if case .pulling(let p) = coord.lastPhase { return p >= 0.85 }
                return false
            }()
            coord.lastPhase = .loading
            if enterFromPull {
                view.play(fromFrame: 66, toFrame: 124, loopMode: .loop)
            } else {
                view.play(fromFrame: 0, toFrame: 66, loopMode: .playOnce) { finished in
                    guard finished else { return }
                    // Only continue if still loading.
                    guard case .loading = coord.lastPhase else { return }
                    view.play(fromFrame: 66, toFrame: 124, loopMode: .loop)
                }
            }

        case .success:
            if case .success = coord.lastPhase { break }
            coord.lastPhase = .success
            view.play(fromFrame: 124, toFrame: 210, loopMode: .playOnce) { finished in
                guard finished else { return }
                DispatchQueue.main.async { coord.successCompletion?() }
            }
        }
    }
}

// MARK: - Hero metrics (shared by pager surface + page observers)

enum WalletHomeHeroMetrics {
    static let balanceIntegerFont = Font.system(size: 64, weight: .bold, design: .default).monospacedDigit()
    static let balanceFractionFont = Font.system(size: 36, weight: .bold, design: .default).monospacedDigit()
    static let balanceCurrencyFont = Font.system(size: 36, weight: .semibold, design: .default).monospacedDigit()
}

// MARK: - One wallet page (balance observer)

/// Transparent pager page: observes GRDB for this wallet and publishes a
/// balance snapshot. The painted balance lives on the parent’s shared
/// surface so switches morph like Send/Receive instead of only sliding.
struct WalletHomeHeroPage: View {
    let walletId: UUID
    let walletName: String
    let avatarSpec: WalletAvatarSpec
    let currencyCode: String

    @StateObject private var cardObservation = WalletBalanceCardObservation()

    private var cardScopeKey: String {
        "\(walletId.uuidString)|\(currencyCode.uppercased())"
    }

    private var totalFiat: Decimal {
        WalletHeroFiat.total(
            walletId: walletId,
            displayCurrencyCode: currencyCode,
            portfolioSummaries: cardObservation.portfolioSummaries.map {
                WalletHeroFiat.Summary(
                    walletId: $0.walletId,
                    currencyCode: $0.currencyCode,
                    totalFiat: $0.totalFiat
                )
            },
            chainStates: cardObservation.chainStates.map {
                WalletHeroFiat.ChainTotal(
                    walletId: $0.walletId,
                    fiatCurrencyCode: $0.fiatCurrencyCode,
                    totalFiat: $0.totalFiat
                )
            }
        )
    }

    private var lastUpdated: Date? {
        let scope = walletId.uuidString
        let domains: Set<String> = [
            SyncDomain.balances.rawValue,
            SyncDomain.transactions.rawValue
        ]
        return cardObservation.syncStatuses
            .filter { $0.scopeId == scope && domains.contains($0.domainRaw) }
            .compactMap(\.lastSyncedAt)
            .max()
    }

    private var report: WalletHomeHeroBalanceReport {
        WalletHomeHeroBalanceReport(
            walletId: walletId,
            totalFiat: totalFiat,
            lastUpdated: lastUpdated
        )
    }

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .preference(key: WalletHomePageBalanceKey.self, value: [walletId: report])
            .accessibilityHidden(true)
            .task(id: cardScopeKey) {
                cardObservation.setScope(walletId: walletId, currencyCode: currencyCode)
            }
    }

    static func updatedCaption(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = ApertureLocalization.currentLocale
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return String(format: String.apertureLocalized("Updated %@"), relative)
    }
}

// MARK: - Balance snapshot preference (shared surface + action chrome)

struct WalletHomeHeroBalanceReport: Equatable {
    let walletId: UUID
    let totalFiat: Decimal
    let lastUpdated: Date?

    var isEmpty: Bool { totalFiat <= 0 }
}

/// Publishes each paged wallet’s live fiat total so the parent can paint
/// one shared, animated balance surface (and drive action-row empty).
private struct WalletHomePageBalanceKey: PreferenceKey {
    static let defaultValue: [UUID: WalletHomeHeroBalanceReport] = [:]
    static func reduce(
        value: inout [UUID: WalletHomeHeroBalanceReport],
        nextValue: () -> [UUID: WalletHomeHeroBalanceReport]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Page indicators (system-style capsule)

/// Wallet pager dots in the system style: **round** inactive, **wide capsule**
/// active, with a snappy width morph when the page changes.
///
/// `UIPageControl` + `preferredCurrentPageIndicatorImage` squashes non-square
/// images into a broken square (see the tiny white square bug). SwiftUI
/// `Capsule` indicators match Apple’s Photos / Onboarding look and animate
/// cleanly.
struct WalletHomePageControl: View {
    @Binding var currentPage: Int
    var numberOfPages: Int
    var currentColor: Color
    var inactiveColor: Color

    private let inactiveSize: CGFloat = 7
    private let activeWidth: CGFloat = 18
    private let activeHeight: CGFloat = 7
    private let spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<numberOfPages, id: \.self) { index in
                let isActive = index == currentPage
                Capsule(style: .continuous)
                    .fill(isActive ? currentColor : inactiveColor)
                    .frame(
                        width: isActive ? activeWidth : inactiveSize,
                        height: activeHeight
                    )
                    .accessibilityHidden(true)
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.28)) {
                            currentPage = index
                        }
                    }
            }
        }
        .frame(height: activeHeight + 8)
        .animation(.snappy(duration: 0.28), value: currentPage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Wallet pages"))
        .accessibilityValue(Text(verbatim: String(
            format: String.apertureLocalized("Page %lld of %lld"),
            Int64(currentPage + 1),
            Int64(max(numberOfPages, 1))
        )))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                if currentPage < numberOfPages - 1 {
                    currentPage += 1
                }
            case .decrement:
                if currentPage > 0 {
                    currentPage -= 1
                }
            @unknown default:
                break
            }
        }
    }
}
