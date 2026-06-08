import SwiftUI
import SwiftData

/// Step 3 of the Receive sheet — the QR card + address + share +
/// chain-mismatch warning, composed for one specific (chain, optional
/// token) pair. Reused from both the native-row direct path (Step 1
/// → Step 3) and the token route (Step 1 → Step 2 → Step 3).
///
/// **Why factor this out of the v1 root.** The QR card, the address
/// row, and the chain-mismatch footer are the parts of the v1 Receive
/// screen that earned their place — they're per Rule #2 / #16 / #18.
/// The v2 redesign replaces the chain-chip picker at the top with
/// the asset list + network picker steps; this view is what the user
/// reaches at the end of either route.
///
/// **Layers (Rule #2 §B.3):** content layer — white QR card on opaque
/// surface + opaque address row + opaque warning footer. Functional
/// layer — system nav bar (parent NavigationStack), Liquid Glass
/// share button.
struct ReceiveQRDetailView: View {
    let chain: SupportedChain
    /// `nil` when the user landed here from a native-asset tap;
    /// non-nil when they landed via the network picker for a token.
    let tokenSymbol: String?
    let address: String

    @State private var justCopiedAt: Date?
    @State private var isShowingGuide: Bool = false

    /// What the user is receiving, in the toolbar title. Native →
    /// chain name; token → "USDC".
    private var navigationTitleText: String {
        if let tokenSymbol {
            return tokenSymbol
        }
        return chain.displayName
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UniSpacing.l) {
                ReceiveQRCard(
                    chain: chain,
                    tokenSymbol: tokenSymbol,
                    address: address
                )
                ReceiveAddressRow(
                    address: address,
                    justCopiedAt: $justCopiedAt
                )
                shareButton
                ReceiveChainMismatchFooter(
                    chain: chain,
                    tokenSymbol: tokenSymbol,
                    onInfoTapped: { isShowingGuide = true }
                )
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text(verbatim: navigationTitleText))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isShowingGuide) {
            ReceiveGuideSheet(
                chain: chain,
                tokenSymbol: tokenSymbol,
                onDismiss: { isShowingGuide = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var shareButton: some View {
        // System ShareLink — opens the OS share sheet with the address.
        // No third-party share UI (Rule #3).
        //
        // **Not wrapped in `UniButton`** by design. Rule #19 reserves
        // `UniButton` for generic action buttons; `ShareLink` is a
        // system-blessed control that owns the share-sheet presentation
        // contract and cannot be expressed as an `action: () -> Void`.
        // To satisfy Rule #19's hit-test invariant, we apply the same
        // `.contentShape(Capsule())` + 47pt frame + `.glassProminent`
        // styling that `UniButton(.primary)` uses internally — so the
        // visual identity AND the hit-test region match the canonical
        // primary CTA exactly.
        ShareLink(
            item: address,
            subject: Text(verbatim: shareSubject),
            message: Text(verbatim: "")
        ) {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                Text("Share")
                    .font(UniTypography.buttonLabel)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 47)
            .contentShape(Capsule())
        }
        .buttonStyle(.glassProminent)
        .tint(UniColors.Button.primaryTint)
        .accessibilityLabel(Text("Share address"))
    }

    /// Subject for the OS share sheet. Names the asset and the chain
    /// so a paste into a message thread is self-describing.
    private var shareSubject: String {
        if let tokenSymbol {
            return "\(tokenSymbol) on \(chain.displayName) — receive address"
        }
        return "\(chain.displayName) — receive address"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingGuide = true
            } label: {
                // Bare `info.circle` per M-002/M-003 — toolbar icons
                // inherit nav-bar tinting; no extra chrome wrapper.
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .regular))
            }
            .accessibilityLabel(Text("What's a receive address?"))
        }
    }
}
