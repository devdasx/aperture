import SwiftUI

/// **Advanced sheet — Bitcoin coin control.**
///
/// A list of the wallet's UTXOs with checkboxes, the selected total, and
/// an "Use N inputs" apply button. Hand-picking inputs is a Bitcoin-only
/// power feature (UTXO model); EVM / account-model chains don't have it,
/// so this sheet is only ever reachable for the Bitcoin family.
///
/// **Rule #15.** Native `NavigationStack` + `.navigationTitle`. The apply
/// button is a high-stakes commit at the bottom (it changes which coins
/// fund the send), so it lives in a bottom `UniButton`, not the toolbar.
///
/// **Rule #4.** UTXOs are MOCK sample data (`// TODO: (T-063)` real UTXO
/// set from the wallet's address). The selection edits real draft state.
struct SendAdvancedBitcoinCoinControlSheet: View {
    @Bindable var draft: SendDraft
    let onApply: () -> Void
    let onCancel: () -> Void

    /// Local working copy of the selection so Cancel discards changes.
    @State private var selectedIds: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: UniSpacing.xs) {
                        ForEach(SendMockData.sampleUTXOs) { utxo in
                            utxoRow(utxo)
                        }
                        selectedTotal
                            .padding(.top, UniSpacing.xs)
                    }
                    .padding(.horizontal, UniSpacing.m)
                    .padding(.top, UniSpacing.s)
                }
                .scrollBounceBehavior(.basedOnSize)

                footer
            }
            .background(UniColors.Background.primary)
            .navigationTitle("Coin control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
            .onAppear {
                selectedIds = draft.advanced.bitcoinSelectedUTXOIds.isEmpty
                    ? SendMockData.defaultSelectedUTXOIds
                    : draft.advanced.bitcoinSelectedUTXOIds
            }
        }
    }

    // MARK: - UTXO row

    @ViewBuilder
    private func utxoRow(_ utxo: SendMockData.UTXO) -> some View {
        let isOn = selectedIds.contains(utxo.id)
        Button {
            toggle(utxo.id)
        } label: {
            HStack(spacing: UniSpacing.s) {
                checkbox(isOn: isOn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: utxo.id)
                        .font(UniTypography.caption1.monospaced())
                        .foregroundStyle(UniColors.Text.secondary)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(verbatim: "\(WalletFormatting.native(utxo.amount, decimals: 8)) BTC")
                        .font(UniTypography.subheadlineEmphasized)
                        .monospacedDigit()
                        .foregroundStyle(UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Spacer(minLength: 0)
                if let badge = SupportedChain.bitcoin.logoAssetName {
                    Image(badge)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                }
            }
            .padding(UniSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(verbatim: "\(WalletFormatting.native(utxo.amount, decimals: 8)) BTC"))
    }

    private func checkbox(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: UniRadius.xs, style: .continuous)
            .fill(isOn ? UniColors.Brand.mark : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: UniRadius.xs, style: .continuous)
                    .strokeBorder(isOn ? UniColors.Brand.mark : UniColors.Separator.regular, lineWidth: 2)
            )
            .frame(width: 22, height: 22)
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(UniColors.Icon.onTint)
                }
            }
    }

    private var selectedTotal: some View {
        HStack {
            Text("Selected")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer()
            Text(verbatim: "\(WalletFormatting.native(selectedAmount, decimals: 8)) BTC")
                .font(UniTypography.subheadlineEmphasized)
                .monospacedDigit()
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, UniSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            UniDivider()
            UniButton(
                verbatim: applyTitle,
                variant: .primary,
                isEnabled: !selectedIds.isEmpty,
                action: apply
            )
            .padding(.horizontal, UniSpacing.m)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
        .background(UniColors.Background.primary)
    }

    // MARK: - Logic

    private func toggle(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func apply() {
        draft.advanced.bitcoinSelectedUTXOIds = selectedIds
        onApply()
    }

    private var selectedAmount: Decimal {
        SendMockData.sampleUTXOs
            .filter { selectedIds.contains($0.id) }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    private var applyTitle: String {
        let count = selectedIds.count
        return count == 1 ? "Use 1 input" : "Use \(count) inputs"
    }
}
