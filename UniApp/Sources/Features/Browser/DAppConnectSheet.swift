import SwiftUI

/// Confirmation sheet for a dApp connect request — `eth_requestAccounts`,
/// Solana `connect`, or a WalletConnect `session_proposal`. Presented
/// from `BrowserHomeView` when `router.pendingRequest == .connect(...)`.
///
/// **Design intent (Rule #2 §D.1):** answer three questions for the
/// user in three glances — which dApp is asking, what they want
/// access to, and what Aperture is about to reveal — then offer
/// one Connect / one Cancel.
///
/// **Sheet shape (Rule #15).** `NavigationStack` wrapping a
/// `ScrollView`; `.large` detent only (M-005). The bottom action
/// region is a `GlassEffectContainer` of two `UniButton`s — Rule
/// #19's canonical CTA primitive.
///
/// **Honesty (Rule #16).** The Permissions section names exactly
/// what the dApp asked for; the boundary statement at the bottom
/// names the limit ("Aperture only reveals the address you
/// choose. You confirm every sign and send separately.").
struct DAppConnectSheet: View {
    let request: DAppRequestRouter.ConnectRequest
    let router: DAppRequestRouter

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    identityHero
                    addressCard
                    permissionsCard
                    boundaryStatement
                    Spacer(minLength: UniSpacing.m)
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(UniColors.Background.primary)
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        router.rejectPending()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionRegion
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var identityHero: some View {
        HStack(spacing: UniSpacing.m) {
            BrowserFaviconView(
                url: request.origin.iconURL.flatMap(URL.init(string:)),
                fallbackLetter: request.origin.title,
                size: .hero
            )

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: request.origin.title)
                    .font(UniTypography.title2)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(2)
                Text(verbatim: request.origin.host)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Address card

    @ViewBuilder
    private var addressCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "From",
                    color: UniColors.Text.tertiary
                )
                if let address = activeAddress {
                    Text(verbatim: WalletFormatting.shortAddress(address))
                        .font(UniTypography.bodyEmphasized.monospacedDigit())
                        .foregroundStyle(UniColors.Text.primary)
                } else {
                    UniBody(
                        text: "No active wallet",
                        color: UniColors.Status.warningForeground
                    )
                }
            }
        }
    }

    /// The address Aperture is about to reveal — picks the right
    /// chain family from the request's channel.
    private var activeAddress: String? {
        switch request.channel {
        case .evm:    return ActiveWalletReader.shared.currentEVMAddress()
        case .solana: return ActiveWalletReader.shared.currentSolanaAddress()
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "Permissions",
                    color: UniColors.Text.tertiary
                )
                ForEach(Array(request.permissions.enumerated()), id: \.offset) { _, permission in
                    HStack(spacing: UniSpacing.s) {
                        Image(systemName: permissionSymbol(permission))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(UniColors.Icon.primary)
                            .frame(width: 24)
                        UniBody(text: permissionLabel(permission))
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Boundary statement

    @ViewBuilder
    private var boundaryStatement: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 20)
            UniFootnote(
                text: "Aperture only reveals the address you choose. You confirm every sign and send separately.",
                color: UniColors.Text.secondary
            )
        }
    }

    // MARK: - Action region

    @ViewBuilder
    private var actionRegion: some View {
        VStack(spacing: UniSpacing.xs) {
            GlassEffectContainer(spacing: UniSpacing.s) {
                VStack(spacing: UniSpacing.s) {
                    UniButton(title: "Connect", variant: .primary) {
                        router.approveConnect(
                            host: request.origin.host,
                            channel: request.channel
                        )
                        dismiss()
                    }
                    UniButton(title: "Cancel", variant: .secondary) {
                        router.rejectPending()
                        dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.bottom, UniSpacing.xs)
        .background(
            UniColors.Background.primary
                .opacity(0.92)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Helpers

    private func permissionSymbol(_ permission: DAppRequestRouter.ConnectRequest.Permission) -> String {
        switch permission {
        case .readAddress:      return "person.crop.circle"
        case .signMessages:     return "signature"
        case .signTransactions: return "arrow.left.arrow.right"
        }
    }

    private func permissionLabel(_ permission: DAppRequestRouter.ConnectRequest.Permission) -> LocalizedStringKey {
        switch permission {
        case .readAddress:      return "Read your address"
        case .signMessages:     return "Sign messages"
        case .signTransactions: return "Sign transactions"
        }
    }
}
