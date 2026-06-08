import SwiftUI

// MARK: - TestScreenView

/// **Design playground.** A faithful copy of the wallet-home surface
/// (`WalletHomeView`) with mock data and inert actions, used by the
/// designer + user to evaluate design experiments before promoting
/// them to the real wallet screen.
///
/// **Design intent (one sentence, Rule #2 §D.1):** show the user a
/// believable copy of the wallet-home screen — hero balance, glass
/// action triplet, holdings, activity — so they can judge design
/// changes against the real visual register, with a single calm
/// "Test Screen" badge that makes the playground identity unambiguous.
///
/// **Why a copy, not a fork.** The wallet home reads from SwiftData,
/// the active-wallet bootstrap, the refresh coordinator, the test-mode
/// scanner, the receive sheet, etc. This screen reaches none of that —
/// it's a pure SwiftUI surface composed from the design system and
/// statically-defined placeholder data (`PlaygroundBalance`,
/// `PlaygroundTransaction`). The actions exist as `UniButton` /
/// glass-prominent affordances so the haptics fire and the buttons
/// read as live, but their callbacks are no-ops — this is a playground,
/// not a flow.
///
/// **Layers (Rule #2 §B.3, same as WalletHomeView):**
/// - Content layer (opaque): "Test Screen" badge, hero balance,
///   holdings card, activity card, footer.
/// - Functional layer (Liquid Glass): system nav bar + the
///   `WalletActionRegion` glass triplet (used as-is — same component
///   as the real wallet home).
///
/// **What to expect in this file:** the file is composition, not
/// invention. Every visual primitive is a `UniColors` / `UniTypography`
/// / `UniSpacing` / `UniRadius` token reference, or a component from
/// `DesignSystem/Components/` (`UniBody`, `UniFootnote`, `UniDivider`,
/// `UniEmptyState`), or a wallet-home primitive
/// (`WalletHomeHeader`, `WalletActionRegion`, `AssetRow`, `ActivityRow`).
/// If the user mutates this screen and likes what they see, the
/// mutation can be promoted to the real wallet by copy-paste plus the
/// usual SwiftData wiring — no design ambiguity because the screen
/// already reads in the production register.
struct TestScreenView: View {

    // MARK: - Playground data

    /// One playground holding — a chain + a balance + a fiat
    /// equivalent. Drives a single `AssetRow` in the holdings card.
    /// Mirrors the shape of `TokenBalanceRecord` (chain, native
    /// amount, decimals, fiat value) but is a plain value type so
    /// the playground has zero database surface.
    private struct PlaygroundBalance: Identifiable {
        let id = UUID()
        let chain: SupportedChain
        let tokenSymbol: String
        let nativeAmount: Decimal
        let decimals: Int
        let fiatValue: Decimal
    }

    /// One playground transaction — a chain + direction + amount +
    /// counterparty + occurredAt + status. Drives a single
    /// `ActivityRow`. Mirrors the shape of `TransactionEvent` for
    /// visual fidelity. The `chain` tells the row which bundled
    /// coin mark to render as the leading visual.
    private struct PlaygroundTransaction: Identifiable {
        let id = UUID()
        let chain: SupportedChain
        let direction: TransactionDirection
        let amount: Decimal
        let tokenSymbol: String
        let counterparty: String
        let occurredAt: Date
        let status: TransactionStatus
    }

    /// Three believable holdings — Bitcoin, Ethereum, Solana. Picked
    /// to feel like a calm modest portfolio rather than a marketing
    /// number. Fiat values use whole-dollar-class numbers (`$24,318`,
    /// `$8,742`, `$1,205`) so the hero balance lands as a recognizable
    /// round-class total ($34,265 with these rows) — easier to scan
    /// in the playground than fractional cents.
    private static let playgroundBalances: [PlaygroundBalance] = [
        PlaygroundBalance(
            chain: .bitcoin,
            tokenSymbol: "BTC",
            nativeAmount: Decimal(string: "0.32500000")!,
            decimals: 8,
            fiatValue: Decimal(24318)
        ),
        PlaygroundBalance(
            chain: .ethereum,
            tokenSymbol: "ETH",
            nativeAmount: Decimal(string: "2.41")!,
            decimals: 6,
            fiatValue: Decimal(8742)
        ),
        PlaygroundBalance(
            chain: .solana,
            tokenSymbol: "SOL",
            nativeAmount: Decimal(string: "6.18")!,
            decimals: 4,
            fiatValue: Decimal(1205)
        )
    ]

    /// Three believable transactions — one incoming confirmed, one
    /// outgoing confirmed, one pending. Dates land at "2h ago",
    /// "yesterday", "4d ago" through `WalletFormatting.relativeTime`.
    private static let playgroundTransactions: [PlaygroundTransaction] = [
        PlaygroundTransaction(
            chain: .bitcoin,
            direction: .incoming,
            amount: Decimal(string: "0.05")!,
            tokenSymbol: "BTC",
            counterparty: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
            occurredAt: Date().addingTimeInterval(-2 * 60 * 60),
            status: .confirmed
        ),
        PlaygroundTransaction(
            chain: .ethereum,
            direction: .outgoing,
            amount: Decimal(string: "0.18")!,
            tokenSymbol: "ETH",
            counterparty: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
            occurredAt: Date().addingTimeInterval(-26 * 60 * 60),
            status: .confirmed
        ),
        PlaygroundTransaction(
            chain: .solana,
            direction: .outgoing,
            amount: Decimal(string: "1.2")!,
            tokenSymbol: "SOL",
            counterparty: "Acg7p5tQfZuTQDvCgEjCQJ6gXhE2yqYJzVMa9YgN8gQk",
            occurredAt: Date().addingTimeInterval(-4 * 24 * 60 * 60),
            status: .pending
        )
    ]

    /// Sum of every playground holding's fiat value. The hero number.
    private var playgroundTotalFiat: Decimal {
        Self.playgroundBalances.reduce(Decimal.zero) { $0 + $1.fiatValue }
    }

    /// Reasonable display currency for the playground. We don't read
    /// `@AppStorage(CurrencyPreference.storageKey)` here — the
    /// playground is intentionally locale-stable so the design holds
    /// up the same way every time the user opens it. `"USD"` is the
    /// project's default per `CurrencyPreference.defaultCode`.
    private var playgroundCurrencyCode: String { "USD" }

    // MARK: - Body

    var body: some View {
        scrollSurface
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Test Screen"))
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Layout

    /// The scroll surface. Same composition as `WalletHomeView`:
    /// header → action triplet → holdings → activity → footer. No
    /// banners, no test-mode toggle, no refreshable — this is a
    /// playground, not a live data surface.
    private var scrollSurface: some View {
        ScrollView {
            VStack(spacing: UniSpacing.l) {
                playgroundBadge

                WalletHomeHeader(
                    walletName: String.apertureLocalized("Playground wallet"),
                    totalFiat: playgroundTotalFiat,
                    currencyCode: playgroundCurrencyCode,
                    chainCount: Self.playgroundBalances.count,
                    tokenCount: Self.playgroundBalances.count,
                    totalChainsSupported: SupportedChain.allCases.count,
                    hasAnyBalance: true,
                    isRefreshing: false,
                    lastSyncedAt: Date().addingTimeInterval(-30),
                    hideBalance: false,
                    onSwitchWallet: {
                        // Switcher is a no-op in the playground. The
                        // pill is rendered by `WalletHomeHeader` only
                        // when the wallet-home toolbar is absent;
                        // here the toolbar carries the nav-bar title
                        // so the pill body is unused. Keep the
                        // closure so the header signature is honored.
                    }
                )

                WalletActionRegion(
                    canSend: true,
                    onSend: {
                        // Inert. Same component as the real wallet so
                        // the haptic + glass material read identically.
                    },
                    onReceive: {
                        // Inert.
                    },
                    onSwap: {
                        // Inert.
                    }
                )
                .padding(.horizontal, UniSpacing.l)

                holdingsSection

                activitySection

                footer
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.xxl)
        }
        .scrollIndicators(.hidden)
    }

    /// **Playground identity badge.** A single restrained row near the
    /// top of the scroll that names the surface as the test screen
    /// without alarming the user (Rule #16 §B). Brand-mark monochrome
    /// (not status warning orange) — the user is not in danger; they
    /// are simply not in their real wallet. SF Symbol `flask` echoes
    /// the test-affordance flask on `WalletHomeView`'s toolbar so the
    /// two test surfaces read as siblings.
    private var playgroundBadge: some View {
        HStack(spacing: UniSpacing.xs) {
            Image(systemName: "flask")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Icon.secondary)
                .accessibilityHidden(true)
            Text("Test Screen — design playground")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, UniSpacing.s)
        .padding(.vertical, UniSpacing.xxs)
        .background(
            Capsule(style: .continuous)
                .fill(UniColors.Material.card)
        )
        .frame(maxWidth: .infinity)
    }

    /// Holdings section — same chrome as the wallet home
    /// (`sectionFrame(title:)` equivalent + a `Material.card` rounded
    /// surface holding `AssetRow` rows + `UniDivider` separators).
    private var holdingsSection: some View {
        sectionFrame(title: "Holdings") {
            VStack(spacing: 0) {
                ForEach(Array(Self.playgroundBalances.enumerated()), id: \.element.id) { idx, balance in
                    AssetRow(
                        chain: balance.chain,
                        tokenSymbol: balance.tokenSymbol,
                        nativeAmount: balance.nativeAmount,
                        nativeDecimals: min(balance.decimals, 8),
                        fiatValue: balance.fiatValue,
                        fiatCurrencyCode: playgroundCurrencyCode
                    )
                    .padding(.horizontal, UniSpacing.m)
                    if idx < Self.playgroundBalances.count - 1 {
                        UniDivider().padding(.leading, UniSpacing.m + 32 + UniSpacing.s)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Material.card)
            )
        }
    }

    /// Activity section — same chrome as wallet home. Rows are
    /// `Button { } label: { ActivityRow(...) }` so the buttonStyle
    /// gives the tap target, but the action closure is a no-op (the
    /// playground does not route to a transaction detail).
    private var activitySection: some View {
        sectionFrame(title: "Recent activity") {
            VStack(spacing: 0) {
                ForEach(Array(Self.playgroundTransactions.enumerated()), id: \.element.id) { idx, tx in
                    Button {
                        // Inert. Real wallet home pushes
                        // `WalletHomeDestination.transaction(id)`; the
                        // playground stays put.
                    } label: {
                        ActivityRow(
                            chain: tx.chain,
                            direction: tx.direction,
                            amount: tx.amount,
                            tokenSymbol: tx.tokenSymbol,
                            counterparty: tx.counterparty,
                            occurredAt: tx.occurredAt,
                            status: tx.status
                        )
                        .padding(.horizontal, UniSpacing.m)
                    }
                    .buttonStyle(.plain)
                    if idx < Self.playgroundTransactions.count - 1 {
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

    /// Footer — same boundary statement as the real wallet home.
    /// Calmly restates the no-server property even though the
    /// playground does not touch any server. Keeps the visual
    /// register identical.
    private var footer: some View {
        UniFootnote(
            text: "No accounts. No servers. Aperture lives on your iPhone.",
            alignment: .center,
            color: UniColors.Text.tertiary
        )
        .padding(.top, UniSpacing.l)
    }

    /// Section frame — verbatim copy of `WalletHomeView.sectionFrame`
    /// so the small-caps title rhythm matches the real wallet home.
    /// Lives here as a local helper rather than being lifted to a
    /// component because (a) the wallet home's version is also a
    /// local helper, and (b) factoring it out now would change two
    /// surfaces' visual contract from one — premature.
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
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        TestScreenView()
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        TestScreenView()
    }
    .preferredColorScheme(.dark)
}
