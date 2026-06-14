import SwiftUI

/// **Send v2 · C3 — Speed up / Cancel (unified bottom sheet).** For a
/// pending tx. Header *"Still pending · 4 min"* + tx summary. **Speed up —
/// replace the fee**: three presets (+10% ~3 min / +25% ~45 sec / +50% next
/// block; selected = dark glass). Card: New fee (with "was…") / Method
/// ("Replacement tx — same nonce, higher fee"; Bitcoin: "RBF bump").
/// **Speed up** (bolt) / **Cancel transaction** (ghost red), which routes
/// to the F3 cancel confirmation.
///
/// Rule #15: native `NavigationStack` + `.navigationTitle`. The seams
/// (`speedUp` / `cancel`) are stubbed (T-069); this is the design surface.
struct SendV2SpeedUpSheet: View {
    @Bindable var model: SendV2Model
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPreset: SendV2Model.SpeedUpPreset = .plus25
    @State private var showingCancelConfirm: Bool = false
    @State private var speedUpTick: Int = 0

    private var draft: SendDraft { model.draft }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.m) {
                    header
                    presetRow
                    newFeeCard
                    methodCard
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) { footer }
            .background(UniColors.Background.primary)
            .navigationTitle("Pending transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCancelConfirm) {
                SendV2CancelConfirmSheet(
                    model: model,
                    onCancelTransaction: { model.cancel(); dismiss() },
                    onKeepWaiting: { showingCancelConfirm = false }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "clock")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(UniColors.Status.warningForeground)
            VStack(alignment: .leading, spacing: 1) {
                Text("Still pending · 4 min")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: "\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker) to \(draft.recipientDisplay)")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(UniSpacing.m)
        .background(RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous).fill(UniColors.Background.secondary))
        .accessibilityElement(children: .combine)
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            SendSectionLabel(text: "Speed up — replace the fee")
            HStack(spacing: UniSpacing.s) {
                ForEach(SendV2Model.SpeedUpPreset.allCases) { preset in
                    presetChip(preset)
                }
            }
        }
    }

    @ViewBuilder
    private func presetChip(_ preset: SendV2Model.SpeedUpPreset) -> some View {
        let selected = selectedPreset == preset
        Button { selectedPreset = preset } label: {
            VStack(spacing: 2) {
                Text(preset.title)
                    .font(UniTypography.subheadlineEmphasized)
                Text(preset.eta)
                    .font(UniTypography.caption2)
            }
            .foregroundStyle(selected ? UniColors.Send.onDarkGlass : UniColors.Text.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                    .fill(selected ? UniColors.Send.darkGlass : UniColors.Background.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous))
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: selected)
    }

    private var newFeeCard: some View {
        SendGlassCard(padding: UniSpacing.m) {
            SendDetailRow(key: "New fee") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: WalletFormatting.fiat(newFeeFiat, currencyCode: activeCurrencyCode))
                        .font(UniTypography.subheadlineEmphasized.monospaced())
                        .foregroundStyle(UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(verbatim: "was \(WalletFormatting.fiat(model.networkFeeFiat, currencyCode: activeCurrencyCode))")
                        .font(UniTypography.caption2.monospaced())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }

    private var methodCard: some View {
        SendGlassCard(padding: UniSpacing.m) {
            SendDetailRow(key: "Method") {
                Text(methodText)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: UniSpacing.s) {
            UniButton(title: "Speed up", variant: .primary, systemImage: "bolt.fill") {
                speedUpTick += 1
                model.speedUp(selectedPreset)
                dismiss()
            }
            Button {
                showingCancelConfirm = true
            } label: {
                Text("Cancel transaction")
                    .font(UniTypography.buttonLabel)
                    .foregroundStyle(UniColors.Send.negative)
                    .frame(maxWidth: .infinity)
                    .frame(height: 47)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // `.warning` on cancel tap, before its confirm (handoff).
            .uniHaptic(.warning, trigger: showingCancelConfirm)
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.s)
        .background(.bar)
        // `.impactMedium` on the replacement broadcast (handoff).
        .uniHaptic(.contextualImpact(.commit), trigger: speedUpTick)
    }

    // MARK: - Derived

    private var newFeeFiat: Decimal {
        model.networkFeeFiat * selectedPreset.multiplier
    }

    private var methodText: LocalizedStringKey {
        if draft.network?.family == .bitcoin {
            return "RBF bump — replaces the original at a higher fee"
        }
        return "Replacement tx — same nonce, higher fee"
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}

// MARK: - F3 · Cancel confirmation

/// **Send v2 · F3 — Cancel confirmation (bottom sheet, warm tint).** Honest
/// copy: *"We'll broadcast a replacement that returns the funds to you. It's
/// a race — if the original confirms first, the send completes and the
/// cancel fee is still paid."* Card: Cancel fee / Chance of success.
/// **Cancel transaction** (red) / **Keep waiting** (ghost).
struct SendV2CancelConfirmSheet: View {
    @Bindable var model: SendV2Model
    let onCancelTransaction: () -> Void
    let onKeepWaiting: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmTick: Int = 0

    var body: some View {
        NavigationStack {
            ZStack {
                SendBloomBackground(danger: true)
                ScrollView {
                    VStack(spacing: UniSpacing.m) {
                        hero
                        Text("It's a race")
                            .font(UniTypography.title2)
                            .foregroundStyle(UniColors.Text.primary)
                        Text("We'll broadcast a replacement that returns the funds to you. If the original confirms first, the send completes — and the cancel fee is still paid.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        infoCard
                    }
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.s)
                    .padding(.bottom, UniSpacing.xxl)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { footer }
            }
            .navigationTitle("Cancel transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var hero: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 34))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Send.negative)
            .frame(width: 72, height: 72)
            .background(Circle().fill(UniColors.Send.negativeWash))
            .padding(.top, UniSpacing.s)
            .accessibilityHidden(true)
    }

    private var infoCard: some View {
        SendGlassCard(padding: UniSpacing.m) {
            VStack(spacing: 0) {
                SendDetailRow(key: "Cancel fee") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: WalletFormatting.fiat(model.networkFeeFiat * (Decimal(string: "1.2") ?? 1), currencyCode: activeCurrencyCode))
                            .font(UniTypography.subheadlineEmphasized.monospaced())
                            .foregroundStyle(UniColors.Text.primary)
                            .environment(\.layoutDirection, .leftToRight)
                        Text("must outbid the original")
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                }
                UniDivider()
                SendDetailRow(key: "Chance of success") {
                    HStack(spacing: UniSpacing.xxs) {
                        Circle().fill(UniColors.Send.positive).frame(width: 7, height: 7)
                        Text("High · still in mempool")
                            .font(UniTypography.subheadlineEmphasized)
                            .foregroundStyle(UniColors.Text.primary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: UniSpacing.s) {
            UniButton(title: "Cancel transaction", variant: .destructive) {
                confirmTick += 1
                onCancelTransaction()
            }
            UniButton(title: "Keep waiting", variant: .tertiary, action: onKeepWaiting)
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.top, UniSpacing.s)
        .padding(.bottom, UniSpacing.s)
        .background(.bar)
        // `.impactMedium` on the replacement broadcast (handoff).
        .uniHaptic(.contextualImpact(.commit), trigger: confirmTick)
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}
