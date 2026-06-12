import SwiftUI

/// **Advanced sheet — Bitcoin (UTXO) fee & options.**
///
/// Fee-rate presets (Economy / Fast) + a custom sat/vB slider with live
/// confirm-time, an RBF toggle, and an optional OP_RETURN message. Coin
/// control lives in its own sheet (`SendAdvancedBitcoinCoinControlSheet`)
/// opened from a row here.
///
/// **Rule #15.** A native `NavigationStack` + `.navigationTitle`. Cancel
/// leading, Done trailing. The sheet is optional — the draft already
/// carries smart defaults, so a user who never opens it still gets a sane
/// fee.
///
/// **Rule #4.** Every number here is MOCK design data (`// TODO: (T-063)`
/// real fee estimation); the slider edits real draft state so the design
/// shows the interaction, but the rate→confirm-time→fiat mapping is
/// sample.
struct SendAdvancedBitcoinSheet: View {
    @Bindable var draft: SendDraft
    let onDone: () -> Void
    let onOpenCoinControl: () -> Void
    let onOpenUTXOGuide: () -> Void
    let onOpenRBFGuide: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.m) {
                    presets
                    SendValueSlider(
                        label: "Custom fee rate",
                        value: $draft.advanced.bitcoinSatPerVByte,
                        range: 1...120,
                        unit: "sat/vB",
                        ticks: ["1", "slow", "fast", "120"],
                        valueText: { String(Int($0.rounded())) }
                    )
                    .onChange(of: draft.advanced.bitcoinSatPerVByte) { _, _ in
                        draft.feeSelection = .custom
                    }

                    SendToggleRow(
                        title: "Replace-By-Fee",
                        badge: "RBF",
                        subtitle: "Lets you bump the fee later if it's stuck.",
                        isOn: $draft.advanced.bitcoinRBFEnabled,
                        onInfo: onOpenRBFGuide
                    )

                    opReturnBox
                    coinControlRow
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(UniColors.Background.primary)
            .navigationTitle("Bitcoin fee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var presets: some View {
        VStack(spacing: UniSpacing.xs) {
            SendFeePresetRow(
                icon: "tortoise.fill",
                title: "Economy",
                subtitle: "~30–60 min",
                rate: "6 sat/vB",
                fiat: feeFiat(.economy),
                isSelected: draft.feeSelection == .economy,
                action: { draft.feeSelection = .economy }
            )
            SendFeePresetRow(
                icon: "bolt.fill",
                title: "Fast",
                subtitle: "~10 min · next block",
                rate: "21 sat/vB",
                fiat: feeFiat(.recommended),
                isSelected: draft.feeSelection == .recommended,
                action: { draft.feeSelection = .recommended }
            )
        }
    }

    private var opReturnBox: some View {
        SendInputBox(
            label: "OP_RETURN · message on-chain (optional)",
            text: $draft.advanced.bitcoinOpReturn,
            placeholder: "Add a note or data hex…",
            keyboard: .default
        )
    }

    private var coinControlRow: some View {
        Button(action: onOpenCoinControl) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous)
                            .fill(UniColors.Fill.tertiary)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("Coin control")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Choose which UTXOs to spend.")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onOpenUTXOGuide) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(UniColors.Icon.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("What's a UTXO?"))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
            .padding(UniSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func feeFiat(_ selection: SendFeeSelection) -> String {
        WalletFormatting.fiat(
            SendMockData.sampleFeeFiat(for: .bitcoin, selection: selection),
            currencyCode: activeCurrencyCode
        )
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey)
            ?? CurrencyPreference.defaultCode
    }
}
