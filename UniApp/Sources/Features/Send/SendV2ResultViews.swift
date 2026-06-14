import SwiftUI

// MARK: - C1 Sending
//
/// **Send v2 · C1 — Sending.** Centered spinning iris (the brand loading
/// motion), *"Sending…"*, *"Broadcasting to Ethereum. You can leave — we'll
/// notify you."*, and a thin progress bar. Non-blocking: the copy tells the
/// user they may leave. On the bloom (calmer than v1's full-dark scaffold —
/// the handoff C1 is a light surface; the dark moment is the v1 carry-over,
/// kept for the terminal Failed state only).
///
/// **Reduce Motion:** the iris spinner becomes a static iris + bar
/// (handoff).
struct SendV2SendingView: View {
    @Bindable var model: SendV2Model

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0
    @State private var startTick: Int = 0

    private var networkName: String { model.draft.network?.displayName ?? "" }

    var body: some View {
        ZStack {
            SendBloomBackground()

            VStack(spacing: UniSpacing.l) {
                Spacer(minLength: 0)

                ApertureIrisView(ringColor: UniColors.Brand.mark)
                    .frame(width: 76, height: 76)
                    .rotationEffect(.degrees(reduceMotion ? 0 : spin))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1.05).repeatForever(autoreverses: false)) {
                            spin = 360
                        }
                    }
                    .accessibilityHidden(true)

                VStack(spacing: UniSpacing.xs) {
                    Text("Sending…")
                        .font(UniTypography.title2)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(verbatim: "Broadcasting to \(networkName). You can leave — we'll notify you.")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                progressBar
                    .padding(.horizontal, UniSpacing.xxl)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, UniSpacing.l)
        }
        .navigationBarBackButtonHidden(true)
        // `.impactLight` when broadcast starts (handoff).
        .uniHaptic(.contextualImpact(.whisper), trigger: startTick)
        .onAppear { startTick += 1 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Sending"))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(UniColors.Fill.tertiary)
                Capsule()
                    .fill(UniColors.Brand.mark)
                    .frame(width: proxy.size.width * progressFraction)
                    .animation(.easeInOut(duration: 0.6), value: model.lifecycle)
            }
        }
        .frame(height: 4)
    }

    private var progressFraction: CGFloat {
        switch model.lifecycle {
        case .idle, .broadcasting: return 0.25
        case .unconfirmed:         return 0.55
        case .confirming:          return 0.8
        case .confirmed:           return 1
        default:                   return 0.5
        }
    }
}

// MARK: - C2 Sent receipt

/// **Send v2 · C2 — Sent receipt.** Green check hero, *"120.50 USDT sent"*,
/// *"to rami.eth · date"*, a glass card (Network / Fee paid / Transaction
/// hash), two glass chips (**Share receipt** / **Explorer**), and **Done**
/// (dark glass). On the bloom.
///
/// **Rule #16:** restates the recipient and anchors to the on-device truth
/// ("confirming on-chain — we'll notify you"). `.success` fires when the
/// check draws.
struct SendV2SentView: View {
    @Bindable var model: SendV2Model
    let amountText: String
    let recipientDisplay: String
    let onDone: () -> Void
    let onShareReceipt: () -> Void
    let onViewExplorer: () -> Void

    @State private var successTick: Int = 0
    private var draft: SendDraft { model.draft }

    var body: some View {
        ZStack {
            SendBloomBackground()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: UniSpacing.m) {
                        Spacer(minLength: UniSpacing.xl)
                        heroCheck
                        Text(verbatim: "\(amountText) sent")
                            .font(.system(size: 30, weight: .bold))
                            .monospacedDigit()
                            .tracking(-0.6)
                            .foregroundStyle(UniColors.Text.primary)
                            .environment(\.layoutDirection, .leftToRight)
                        Text(verbatim: "to \(recipientDisplay) · confirming on-chain now")
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                        receiptCard
                            .padding(.top, UniSpacing.s)
                        actionChips
                    }
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.bottom, UniSpacing.xl)
                }
                .scrollIndicators(.hidden)

                footer
            }
        }
        .navigationBarBackButtonHidden(true)
        // `.success` when the check finishes drawing (handoff).
        .uniHaptic(.success, trigger: successTick)
        .onAppear { successTick += 1 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(amountText) sent to \(recipientDisplay)"))
    }

    private var heroCheck: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 64, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Send.positive)
            .symbolEffect(.bounce, options: .nonRepeating)
            .accessibilityHidden(true)
    }

    private var receiptCard: some View {
        SendGlassCard(padding: UniSpacing.m) {
            VStack(spacing: 0) {
                SendDetailRow(key: "Network") {
                    HStack(spacing: UniSpacing.xs) {
                        if let chain = draft.network, let asset = chain.logoAssetName {
                            Image(asset).resizable().scaledToFit().frame(width: 18, height: 18).clipShape(Circle())
                        }
                        Text(verbatim: draft.network?.displayName ?? "")
                            .font(UniTypography.subheadlineEmphasized)
                            .foregroundStyle(UniColors.Text.primary)
                    }
                }
                UniDivider()
                SendDetailRow(key: "Fee paid") {
                    Text(verbatim: WalletFormatting.fiat(model.networkFeeFiat, currencyCode: activeCurrencyCode))
                        .font(UniTypography.subheadlineEmphasized.monospaced())
                        .foregroundStyle(UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                UniDivider()
                SendDetailRow(key: "Transaction") {
                    Text(verbatim: SendDraft.shorten(model.transactionHash, prefix: 8, suffix: 6))
                        .font(UniTypography.caption1.monospaced())
                        .foregroundStyle(UniColors.Text.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }

    private var actionChips: some View {
        HStack(spacing: UniSpacing.s) {
            SendChip(title: "Share receipt", systemImage: "square.and.arrow.up", action: onShareReceipt)
            SendChip(title: "Explorer", systemImage: "safari", action: onViewExplorer)
        }
    }

    private var footer: some View {
        UniButton(title: "Done", variant: .primary, action: onDone)
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}
