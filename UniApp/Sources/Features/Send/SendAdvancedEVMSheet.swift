import SwiftUI

/// **Advanced sheet — EVM (EIP-1559) gas & advanced.**
///
/// Fee presets (Normal / Fast) + editable Max fee + Priority fee (gwei),
/// custom gas limit, editable nonce (replace / cancel a stuck tx), and
/// raw hex data. Shared across every EVM chain (Ethereum, Arbitrum,
/// Optimism, Base, Polygon, BNB, Avalanche, …) — the family, not the
/// chain, shapes the controls.
///
/// **Rule #15.** Native `NavigationStack` + `.navigationTitle` (the
/// chain's name). Cancel leading, Done trailing.
///
/// **Rule #4.** Numbers are MOCK design data (`// TODO: (T-063)`); the
/// fields edit real draft state so the design shows the interaction.
struct SendAdvancedEVMSheet: View {
    @Bindable var draft: SendDraft
    let chain: SupportedChain
    let onDone: () -> Void

    // Local editable bindings backed by the draft's advanced params.
    @State private var maxFeeText: String = ""
    @State private var priorityText: String = ""
    @State private var gasLimitText: String = ""
    @State private var nonceText: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.m) {
                    presets

                    HStack(spacing: UniSpacing.s) {
                        SendInputBox(label: "Max fee (gwei)", text: $maxFeeText)
                        SendInputBox(label: "Priority (gwei)", text: $priorityText)
                    }
                    HStack(spacing: UniSpacing.s) {
                        SendInputBox(label: "Gas limit", text: $gasLimitText, keyboard: .numberPad)
                        SendInputBox(label: "Nonce", text: $nonceText, placeholder: "Auto", keyboard: .numberPad)
                    }
                    SendInputBox(
                        label: "Hex data (optional)",
                        text: $draft.advanced.evmHexData,
                        placeholder: "0x…",
                        keyboard: .default
                    )

                    nonceNote
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(UniColors.Background.primary)
            .navigationTitle(Text(verbatim: "\(chain.displayName) gas"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onDone)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: commitAndDone)
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: hydrate)
        }
    }

    private var presets: some View {
        VStack(spacing: UniSpacing.xs) {
            SendFeePresetRow(
                icon: "tortoise.fill",
                title: "Normal",
                subtitle: "~30s",
                rate: "12 gwei",
                fiat: feeFiat(.economy),
                isSelected: draft.feeSelection == .economy,
                action: { selectPreset(.economy, maxFee: 16, priority: 1.0) }
            )
            SendFeePresetRow(
                icon: "bolt.fill",
                title: "Fast",
                subtitle: "~12s · next blocks",
                rate: "18 gwei",
                fiat: feeFiat(.recommended),
                isSelected: draft.feeSelection == .recommended,
                action: { selectPreset(.recommended, maxFee: 24, priority: 1.5) }
            )
        }
    }

    private var nonceNote: some View {
        Text("Leave nonce on Auto unless you're replacing a stuck transaction. A wrong nonce can make the transaction fail.")
            .font(UniTypography.caption1)
            .foregroundStyle(UniColors.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, UniSpacing.xs)
    }

    // MARK: - State

    private func hydrate() {
        maxFeeText = trimmed(draft.advanced.evmMaxFeeGwei)
        priorityText = trimmed(draft.advanced.evmPriorityFeeGwei)
        gasLimitText = String(draft.advanced.evmGasLimit)
        nonceText = draft.advanced.evmNonce.map(String.init) ?? ""
    }

    private func selectPreset(_ selection: SendFeeSelection, maxFee: Double, priority: Double) {
        draft.feeSelection = selection
        draft.advanced.evmMaxFeeGwei = maxFee
        draft.advanced.evmPriorityFeeGwei = priority
        maxFeeText = trimmed(maxFee)
        priorityText = trimmed(priority)
    }

    private func commitAndDone() {
        if let v = Double(maxFeeText) { draft.advanced.evmMaxFeeGwei = v }
        if let v = Double(priorityText) { draft.advanced.evmPriorityFeeGwei = v }
        if let v = Int(gasLimitText) { draft.advanced.evmGasLimit = v }
        draft.advanced.evmNonce = Int(nonceText)
        // If the user hand-edited the fee fields off a preset, mark custom.
        if draft.advanced.evmMaxFeeGwei != 24 && draft.advanced.evmMaxFeeGwei != 16 {
            draft.feeSelection = .custom
        }
        onDone()
    }

    // MARK: - Helpers

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func feeFiat(_ selection: SendFeeSelection) -> String {
        WalletFormatting.fiat(
            SendMockData.sampleFeeFiat(for: chain, selection: selection),
            currencyCode: activeCurrencyCode
        )
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey)
            ?? CurrencyPreference.defaultCode
    }
}
