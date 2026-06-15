import SwiftUI

// MARK: - SwapReviewSummary

/// The assembled, honest review of a swap/bridge — what the user is about
/// to do, restated at the moment of commitment. `Hashable` + `Codable` so
/// it rides the sheet's `NavigationPath` across Rule #12 §G direction
/// rebuilds (the same contract as `SendDraft`).
///
/// It carries the live `SwapQuote` verbatim (which itself holds the EVM /
/// Solana execute seam — `evmTx` / `solanaTx`), so the NEXT increment's
/// execute turn can sign + broadcast straight from this summary without
/// re-quoting. This turn it is display-only.
struct SwapReviewSummary: Hashable, Codable {
    let quote: SwapQuote
    /// The human from-amount the user entered (chain units).
    let fromAmount: Decimal
    /// Slippage tolerance used for this quote (bps).
    let slippageBps: Int

    var isCrossChain: Bool { quote.fromToken.chain != quote.toToken.chain }
}

// MARK: - SwapReviewView

/// Swap · Review — the honest summary boundary. Restates the from/to assets
/// and amounts, the route, the fees, the time, and the minimum received,
/// then states plainly that **signing + broadcast is the next increment**.
/// It NEVER fabricates a swap, a hash, or a "Swapped!" success — exactly as
/// the Send flow was staged before its signing engine landed.
///
/// **Honesty (Rule #16 / Rule #2 §A.7).** The CTA does not say "Swap now"
/// or "Confirm" — that would imply an action the app can't yet take. It
/// says "Done" and the body names the boundary, so the user is never misled
/// about what just happened (nothing was sent).
struct SwapReviewView: View {
    let summary: SwapReviewSummary
    let currencyCode: String
    /// Dismisses the whole Swap sheet.
    let onClose: () -> Void

    private var quote: SwapQuote { summary.quote }

    var body: some View {
        ScrollView {
            VStack(spacing: UniSpacing.l) {
                assetsCard
                SwapQuotePanel(
                    quote: quote,
                    isCrossChain: summary.isCrossChain,
                    currencyCode: currencyCode
                )
                boundaryNote
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.xxxl + UniSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .safeAreaInset(edge: .bottom) { doneBar }
        .navigationTitle(summary.isCrossChain ? "Review bridge" : "Review swap")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Assets card (from → to)

    private var assetsCard: some View {
        UniCard {
            VStack(spacing: UniSpacing.s) {
                assetRow(
                    label: "You pay",
                    token: quote.fromToken,
                    amount: summary.fromAmount,
                    emphasized: true
                )
                HStack {
                    Image(systemName: summary.isCrossChain ? "arrow.left.arrow.right" : "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.secondary)
                    Spacer()
                }
                .padding(.leading, UniSpacing.xs)
                assetRow(
                    label: "You receive (estimated)",
                    token: quote.toToken,
                    amount: quote.toAmount,
                    emphasized: true
                )
            }
        }
    }

    private func assetRow(label: LocalizedStringKey, token: SwapToken, amount: Decimal, emphasized: Bool) -> some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: token.chain,
                tokenSymbol: token.symbol,
                contract: token.isNative ? nil : token.address,
                customIconURL: token.logoURI
            )
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: token.chain.displayName)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer(minLength: UniSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: WalletFormatting.native(amount, decimals: token.decimals))
                    .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: token.symbol)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    // MARK: - Honest boundary note

    private var boundaryNote: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "hammer")
                .font(.system(size: 15))
                .foregroundStyle(UniColors.Icon.secondary)
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text("Signing is coming next")
                    .font(UniTypography.footnote.weight(.semibold))
                    .foregroundStyle(UniColors.Text.primary)
                Text("This is a real, live quote — but Aperture doesn't sign and broadcast swaps yet. Nothing has been sent. On-device signing + broadcast lands in the next update, the same way sending did.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UniSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Fill.quaternary)
        )
    }

    // MARK: - Done CTA (honest — not "Swap")

    private var doneBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(
                title: "Done",
                variant: .primary,
                action: onClose
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }
}
