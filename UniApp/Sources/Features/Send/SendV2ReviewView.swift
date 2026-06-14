import SwiftUI

/// **Send v2 · B2 — Review + simulation.** Amount recap (big + fiat), a
/// glass detail card (**To** / **Network** / **Fee** with speed tier), then
/// the **"After this send"** simulation card — one row per balance change
/// from a real pre-flight simulation (handoff: *"not arithmetic alone"*),
/// and the **Slide to send** commit (biometric fires at completion).
///
/// **Layers (Rule #2 §B.3):** content layer — the cards on the bloom.
/// Functional layer — the slide-to-send track (its own bespoke surface).
///
/// **Honesty (Rule #2 §A.7 / Rule #16).** The simulation card shows the
/// real deltas including the fee; a simulated revert blocks the commit
/// (handoff H4). Token-send fees are shown on the native asset row.
struct SendV2ReviewView: View {
    @Bindable var model: SendV2Model
    let onEditFee: () -> Void
    let onCommit: () -> Void
    let onOpenFeeGuide: () -> Void

    private var draft: SendDraft { model.draft }

    var body: some View {
        ZStack {
            SendBloomBackground()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: UniSpacing.m) {
                        amountRecap
                        detailCard
                        simulationCard
                        if let revert = model.simulationRevert {
                            revertNotice(revert)
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
        .task {
            await model.loadFeeTiers()
            _ = await model.simulate()
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Amount recap

    private var amountRecap: some View {
        VStack(spacing: UniSpacing.xs) {
            if let asset = draft.asset {
                SendTokenTile(asset: asset, size: 52, ringColor: UniColors.Send.bloomBaseTop)
                    .padding(.bottom, UniSpacing.xxs)
            }
            Text(verbatim: "\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)")
                .font(.system(size: 34, weight: .bold))
                .monospacedDigit()
                .tracking(-0.8)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
            Text(verbatim: "≈ \(WalletFormatting.fiat(draft.fiatAmount, currencyCode: activeCurrencyCode))")
                .font(UniTypography.footnote)
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, UniSpacing.s)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Detail card

    private var detailCard: some View {
        SendGlassCard(padding: UniSpacing.m) {
            VStack(spacing: 0) {
                SendDetailRow(key: "To") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: draft.recipientDisplay)
                            .font(UniTypography.subheadlineEmphasized.monospaced())
                            .foregroundStyle(UniColors.Text.primary)
                            .environment(\.layoutDirection, .leftToRight)
                        if model.recipientState.resolved?.isFirstSend == true {
                            Text("first send")
                                .font(UniTypography.caption2.weight(.semibold))
                                .foregroundStyle(UniColors.Status.warningForeground)
                        }
                    }
                }
                UniDivider()
                SendDetailRow(key: "Network") {
                    HStack(spacing: UniSpacing.xs) {
                        networkBadge
                        Text(verbatim: draft.network?.displayName ?? "")
                            .font(UniTypography.subheadlineEmphasized)
                            .foregroundStyle(UniColors.Text.primary)
                    }
                }
                UniDivider()
                feeRow
            }
        }
    }

    private var feeRow: some View {
        HStack(spacing: UniSpacing.s) {
            Button(action: onOpenFeeGuide) {
                HStack(spacing: UniSpacing.xxs) {
                    Text("Fee")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("What's a network fee?"))

            Spacer(minLength: UniSpacing.s)

            Button(action: onEditFee) {
                HStack(spacing: UniSpacing.xs) {
                    Image(systemName: feeIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(feeColor)
                    Text(feeLabel)
                        .font(UniTypography.caption1.weight(.bold))
                        .foregroundStyle(feeColor)
                    Text(verbatim: "· \(WalletFormatting.fiat(model.networkFeeFiat, currencyCode: activeCurrencyCode))")
                        .font(UniTypography.caption1.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(UniColors.Text.primary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
                .padding(.horizontal, UniSpacing.s)
                .padding(.vertical, UniSpacing.xxs)
                .background(Capsule().fill(UniColors.Fill.tertiary))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit network fee"))
        }
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - Simulation card ("After this send")

    private var simulationCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(spacing: UniSpacing.xs) {
                SendSectionLabel(text: "After this send")
                if model.isSimulating {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            SendGlassCard(padding: UniSpacing.m) {
                if model.simulation.isEmpty {
                    HStack {
                        Text("Checking what this send will do…")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, UniSpacing.xs)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.simulation.enumerated()), id: \.element.id) { index, change in
                            balanceChangeRow(change)
                            if index < model.simulation.count - 1 { UniDivider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func balanceChangeRow(_ change: SendV2Model.BalanceChange) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(verbatim: change.assetName)
                .font(change.isFee ? UniTypography.subheadline : UniTypography.subheadlineEmphasized)
                .foregroundStyle(change.isFee ? UniColors.Text.secondary : UniColors.Text.primary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: deltaString(change))
                .font(change.isFee ? UniTypography.subheadline.monospaced() : UniTypography.subheadlineEmphasized.monospaced())
                .foregroundStyle(change.isFee ? UniColors.Text.secondary : UniColors.Send.negative)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, UniSpacing.s)
        .accessibilityElement(children: .combine)
    }

    private func deltaString(_ change: SendV2Model.BalanceChange) -> String {
        let sign = change.delta < 0 ? "−" : "+"
        let magnitude = change.delta < 0 ? -change.delta : change.delta
        return "\(sign)\(WalletFormatting.native(magnitude, decimals: change.decimals)) \(change.symbol)"
    }

    // MARK: - Revert notice (handoff H4)

    private func revertNotice(_ reason: String) -> some View {
        SendGlassCard {
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                HStack(spacing: UniSpacing.xs) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(UniColors.Send.negative)
                    Text("This send would fail")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Send.negative)
                }
                Text("You haven't paid anything — we never broadcast a transaction that will fail.")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.secondary)
                Text(verbatim: reason)
                    .font(UniTypography.caption2.monospaced())
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
    }

    // MARK: - Footer (slide to send)

    private var footer: some View {
        VStack(spacing: 0) {
            SendV2SlideToSend(onCommit: onCommit)
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.xs)
                .padding(.bottom, UniSpacing.s)
                .disabled(model.simulationRevert != nil)
                .opacity(model.simulationRevert != nil ? 0.5 : 1)
        }
    }

    // MARK: - Derived

    @ViewBuilder
    private var networkBadge: some View {
        if let chain = draft.network, let asset = chain.logoAssetName {
            Image(asset)
                .resizable().scaledToFit()
                .frame(width: 18, height: 18)
                .clipShape(Circle())
                .accessibilityHidden(true)
        }
    }

    private var feeLabel: LocalizedStringKey {
        switch model.selectedFeeTierId {
        case .slow:   return "Slow"
        case .normal: return "Normal"
        case .fast:   return "Fast"
        }
    }

    private var feeIcon: String {
        switch model.selectedFeeTierId {
        case .slow:   return "tortoise.fill"
        case .normal: return "gauge.medium"
        case .fast:   return "bolt.fill"
        }
    }

    private var feeColor: Color {
        model.selectedFeeTierId == .fast ? UniColors.Send.positive : UniColors.Text.secondary
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}
