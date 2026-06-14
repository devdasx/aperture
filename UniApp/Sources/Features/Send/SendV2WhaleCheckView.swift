import SwiftUI

/// **Send v2 · B3 — Whale check (conditional).** Shown only when the send
/// is **>50% of the asset's balance**. Neutral (NOT red — it's not an
/// error). *"That's most of your USDT"* + *"This send is 83% of your Tether
/// balance."* A card shows Sending / Remaining after, with **Yes, send it**
/// (dark glass) / **Change amount** (ghost).
///
/// **Rule #16:** restrained register, neutral status, no alarming red — the
/// user is doing something big but legitimate; the screen confirms, it
/// doesn't warn.
struct SendV2WhaleCheckView: View {
    @Bindable var model: SendV2Model
    let onConfirm: () -> Void
    let onChangeAmount: () -> Void

    @State private var appearTick: Int = 0
    private var draft: SendDraft { model.draft }

    var body: some View {
        ZStack {
            SendBloomBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: UniSpacing.m) {
                    hero
                    headline
                    summaryCard
                }
                .padding(.horizontal, UniSpacing.l)

                Spacer(minLength: 0)

                footer
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // `.warning` once, on present (handoff).
        .uniHaptic(.warning, trigger: appearTick)
        .onAppear { appearTick += 1 }
    }

    private var hero: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 34, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Text.secondary)
            .frame(width: 72, height: 72)
            .background(Circle().fill(UniColors.Fill.tertiary))
            .accessibilityHidden(true)
    }

    private var headline: some View {
        VStack(spacing: UniSpacing.xs) {
            Text(verbatim: "That's most of your \(draft.unitTicker)")
                .font(UniTypography.title2)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.center)
            Text(verbatim: "This send is \(model.sendPercentOfBalance)% of your \(assetName) balance. Double-check the amount before you continue.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryCard: some View {
        SendGlassCard(padding: UniSpacing.m) {
            VStack(spacing: 0) {
                SendDetailRow(key: "Sending") {
                    Text(verbatim: "\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)")
                        .font(UniTypography.subheadlineEmphasized.monospaced())
                        .foregroundStyle(UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                UniDivider()
                SendDetailRow(key: "Remaining after") {
                    Text(verbatim: "\(WalletFormatting.native(remaining, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)")
                        .font(UniTypography.subheadlineEmphasized.monospaced())
                        .foregroundStyle(UniColors.Text.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: UniSpacing.s) {
            UniButton(title: "Yes, send it", variant: .primary, action: onConfirm)
            UniButton(title: "Change amount", variant: .tertiary, action: onChangeAmount)
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.bottom, UniSpacing.m)
    }

    private var remaining: Decimal {
        max(0, draft.availableBalance - draft.cryptoAmount)
    }

    private var assetName: String {
        draft.asset?.displayName ?? draft.unitTicker
    }
}
