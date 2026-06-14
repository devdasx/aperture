import SwiftUI

/// **Send v2 · A2 — Resolved + first-time flag.** A typed name resolves to
/// a card: avatar, name + green **Resolved ✓** chip, full address
/// (monospace). If the wallet has **never sent to this address**, a glass
/// notice appears: *"First time sending here … For large amounts, try a
/// small test send first."* with **Send a test amount first** (glass) /
/// **Continue** (dark glass).
///
/// **Rule #16 (security surface).** This is a custody moment — it restates
/// what the user is about to do (send to this exact address), names the
/// protection (a test send proves the address before the full amount), and
/// is honest about the irreversibility of a wrong address.
struct SendV2ResolvedView: View {
    @Bindable var model: SendV2Model
    let onContinue: () -> Void
    let onTestSend: () -> Void
    let onBack: () -> Void

    private var resolved: SendV2Model.ResolvedRecipient? { model.recipientState.resolved }

    var body: some View {
        ZStack {
            SendBloomBackground()

            VStack(spacing: 0) {
                SendV2NavBar(title: "Recipient", onBack: onBack)

                ScrollView {
                    VStack(spacing: UniSpacing.m) {
                        if let resolved {
                            recipientCard(resolved)
                            if resolved.isFirstSend {
                                firstSendNotice
                            }
                        }
                    }
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.m)
                    .padding(.bottom, UniSpacing.xl)
                }
                .scrollIndicators(.hidden)

                footer
            }
        }
        .navigationBarBackButtonHidden(true)
        // `.tap` when the resolved chip appears (handoff: name resolves).
        .uniHaptic(.contextualImpact(.tap), trigger: resolved?.address ?? "")
    }

    // MARK: - Recipient card

    @ViewBuilder
    private func recipientCard(_ r: SendV2Model.ResolvedRecipient) -> some View {
        SendGlassCard(padding: UniSpacing.l) {
            VStack(spacing: UniSpacing.m) {
                avatar(r)
                VStack(spacing: UniSpacing.xs) {
                    HStack(spacing: UniSpacing.xs) {
                        Text(verbatim: r.name ?? SendDraft.shorten(r.address))
                            .font(UniTypography.title3)
                            .foregroundStyle(UniColors.Text.primary)
                        resolvedChip(ensVerified: r.ensVerified)
                    }
                    Text(verbatim: r.address)
                        .font(UniTypography.footnote.monospaced())
                        .foregroundStyle(UniColors.Text.secondary)
                        .multilineTextAlignment(.center)
                        .environment(\.layoutDirection, .leftToRight)
                        .textSelection(.enabled)
                    Text(verbatim: r.network.displayName)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func resolvedChip(ensVerified: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text(ensVerified ? "ENS ✓" : "Resolved ✓")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(UniColors.Send.positive)
        .padding(.horizontal, UniSpacing.xs)
        .padding(.vertical, 3)
        .background(Capsule().fill(UniColors.Send.positiveWash))
    }

    @ViewBuilder
    private func avatar(_ r: SendV2Model.ResolvedRecipient) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(UniColors.Send.positiveWash)
                .frame(width: 64, height: 64)
                .overlay {
                    Text(verbatim: String((r.name ?? "0x").prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(UniColors.Send.positive)
                }
            if let badge = r.network.logoAssetName {
                Image(badge)
                    .resizable().scaledToFit()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .background(Circle().fill(UniColors.Send.bloomBaseTop).frame(width: 27, height: 27))
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - First-send notice

    private var firstSendNotice: some View {
        SendGlassCard {
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                HStack(spacing: UniSpacing.xs) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 16))
                        .foregroundStyle(UniColors.Text.secondary)
                    Text("First time sending here")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer(minLength: 0)
                }
                Text("You've never sent to this address. For large amounts, try a small test send first — once it arrives, send the rest with one tap.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: UniSpacing.s) {
            if resolved?.isFirstSend == true {
                UniButton(title: "Send a test amount first", variant: .secondary, action: onTestSend)
            }
            UniButton(title: "Continue", variant: .primary, action: onContinue)
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.xs)
    }
}
