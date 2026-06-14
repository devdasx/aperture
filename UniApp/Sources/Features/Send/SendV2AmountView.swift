import SwiftUI

/// **Send v2 · B1 — Amount (the emotional peak).** A token pill (coin tile
/// + chain badge + "USDT · Ethereum" + chevron → asset/chain picker), the
/// big SF Pro Display amount with the fiat flip, fee-aware **25 / 50 / Max**
/// chips with the fee note under them, the bare keypad, and **Review** (the
/// dark-glass primary).
///
/// **Scrolling rule (handoff):** the keypad + footer stay pinned outside
/// the scroll region; only the upper block (pill + amount + chips) scrolls
/// if it must.
///
/// **Layers (Rule #2 §B.3):** content layer — the amount + keypad on the
/// bloom. Functional layer — the token pill (glass), the flip (glass), the
/// Review (dark glass). Two glass max in any region.
struct SendV2AmountView: View {
    @Bindable var model: SendV2Model
    let onReview: () -> Void
    let onOpenAssetPicker: () -> Void

    @Environment(\.dismiss) private var dismiss
    private var draft: SendDraft { model.draft }

    /// Explicit binding into the composed `@Observable` draft's amount
    /// string. `draft` is a computed accessor (`model.draft`), so `$draft`
    /// isn't available — the draft is a reference type, so a manual
    /// `Binding` to its property is the correct bridge for the keypad.
    private var amountBinding: Binding<String> {
        Binding(get: { model.draft.amountInput }, set: { model.draft.amountInput = $0 })
    }

    var body: some View {
        ZStack {
            SendBloomBackground()

            VStack(spacing: 0) {
                SendV2NavBar(title: "Amount", onBack: { dismiss() })

                tokenPill
                    .padding(.top, UniSpacing.xs)

                Spacer(minLength: UniSpacing.m)

                SendAmountDisplay(
                    displayString: displayedAmount,
                    unit: unitLabel,
                    secondary: secondaryText,
                    isShowingFiat: draft.isShowingFiat,
                    onFlip: { draft.isShowingFiat.toggle() }
                )

                availableLine
                    .padding(.top, UniSpacing.s)

                percentChips
                    .padding(.top, UniSpacing.m)
                    .padding(.horizontal, UniSpacing.l)

                feeNote
                    .padding(.top, UniSpacing.xs)
                    .padding(.horizontal, UniSpacing.l)

                Spacer(minLength: UniSpacing.m)

                SendV2Keypad(
                    amount: amountBinding,
                    maxFractionDigits: draft.asset?.decimals ?? 8
                )
                .padding(.horizontal, UniSpacing.l)

                footer
            }
        }
        .navigationBarBackButtonHidden(true)
        // Per-keystroke `.selection` (handoff: keypad digit → tap; the
        // modifier coalesces to actual changes + respects the preference).
        .uniHaptic(.selection, trigger: draft.amountInput)
        // Clear the selected-percent highlight when the user types.
        .onChange(of: draft.amountInput) { _, _ in
            // If the typed string no longer equals a percent target, drop
            // the highlight. Cheap heuristic: any manual edit clears it.
            if model.selectedPercent != nil { model.selectedPercent = nil }
        }
        // Load REAL fee tiers (EVM gas oracle) so the fee note + fee-aware
        // Max reflect the live network fee, not a placeholder.
        .task { await model.loadFeeTiers() }
    }

    // MARK: - Token pill

    private var tokenPill: some View {
        Button(action: onOpenAssetPicker) {
            HStack(spacing: UniSpacing.s) {
                if let asset = draft.asset {
                    SendTokenTile(asset: asset, size: 30, ringColor: UniColors.Send.bloomBaseTop)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: draft.unitTicker)
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    if let network = draft.network {
                        Text(verbatim: network.displayName)
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.secondary)
            }
            .padding(.horizontal, UniSpacing.s)
            .padding(.vertical, UniSpacing.xs)
            .modifier(SendGlassSurface(cornerRadius: UniRadius.xxl, reduceTransparency: reduceTransparency))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: draft.asset)
        .accessibilityLabel(Text(verbatim: "\(draft.unitTicker) on \(draft.network?.displayName ?? "")"))
        .accessibilityHint(Text("Change asset or network"))
    }

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: - Available + percent chips

    private var availableLine: some View {
        HStack(spacing: UniSpacing.xxs) {
            Text("Available")
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
            Text(verbatim: "\(WalletFormatting.native(draft.availableBalance, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)")
                .font(UniTypography.caption1.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .combine)
    }

    private var percentChips: some View {
        HStack(spacing: UniSpacing.s) {
            ForEach([25, 50], id: \.self) { percent in
                SendChip(title: "\(percent)%", isSelected: model.selectedPercent == percent) {
                    model.applyPercent(percent)
                }
            }
            SendChip(title: "Max", isSelected: model.selectedPercent == 100) {
                model.applyPercent(100)
            }
        }
    }

    /// The fee note under the chips — fee-aware Max copy (handoff).
    @ViewBuilder
    private var feeNote: some View {
        if model.selectedPercent == 100 {
            Text(verbatim: model.maxFeeNote)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        UniButton(title: "Review", variant: .primary, isEnabled: draft.isAmountValid, action: onReview)
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
    }

    // MARK: - Derived

    private var displayedAmount: String {
        draft.amountInput.isEmpty ? "0" : draft.amountInput
    }

    private var unitLabel: String {
        draft.isShowingFiat ? activeCurrencyCode : draft.unitTicker
    }

    private var secondaryText: String {
        if draft.isShowingFiat {
            return "\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)"
        } else {
            return WalletFormatting.fiat(draft.fiatAmount, currencyCode: activeCurrencyCode)
        }
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}
