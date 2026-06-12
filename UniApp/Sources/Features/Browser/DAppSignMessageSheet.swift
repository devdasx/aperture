import SwiftUI

/// Confirmation sheet for a `personal_sign` / `eth_sign` / Solana
/// `signMessage` request. Presented from `BrowserHomeView` when
/// `router.pendingRequest == .signMessage(...)`.
///
/// **Design intent (Rule #2 §D.1):** show the user exactly what
/// they are about to sign, in the most legible form available
/// (UTF-8 when printable, raw hex when not), and remind them once
/// that signing proves control of the address.
///
/// **Sheet shape (Rule #15).** `NavigationStack` + `ScrollView`
/// (the message may be long). `.large` detent only.
///
/// **Honesty (Rule #16).** The message body lives inside a
/// monospaced `UniCard`. We don't decode for the user beyond
/// UTF-8; we don't simulate or paraphrase. If a dApp encodes a
/// SIWE login challenge, that's the literal text the user
/// reads — same as Apple's mail-signing dialogs.
struct DAppSignMessageSheet: View {
    let request: DAppRequestRouter.SignMessageRequest
    let router: DAppRequestRouter

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    identityHero
                    messageCard
                    warningStatement
                    Spacer(minLength: UniSpacing.m)
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(UniColors.Background.primary)
            .navigationTitle("Sign message")
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

    // MARK: - Sections

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

    @ViewBuilder
    private var messageCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                UniCaption(
                    text: "Message",
                    color: UniColors.Text.tertiary
                )
                Text(verbatim: request.messagePreview.isEmpty ? request.rawHex : request.messagePreview)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var warningStatement: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Status.warningForeground)
                .frame(width: 20)
            UniFootnote(
                text: "Signing this message proves you control this address. Only sign messages from dApps you trust.",
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
                    UniButton(title: "Sign", variant: .primary) {
                        if request.chain.family == .evm {
                            Task {
                                do {
                                    let signature = try await EVMDAppSigner.signPersonalMessage(
                                        messageHex: request.rawHex
                                    )
                                    router.approveSign(signedHex: signature)
                                } catch {
                                    router.failPending(EVMDAppSigner.requestError(for: error))
                                }
                                dismiss()
                            }
                        } else {
                            // Solana message signing isn't wired yet —
                            // honest 4200 rejection, never a fake
                            // signature.
                            router.failPending(DAppRequestError(
                                code: 4200,
                                message: "Aperture can't sign this request yet"
                            ))
                            dismiss()
                        }
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
}
