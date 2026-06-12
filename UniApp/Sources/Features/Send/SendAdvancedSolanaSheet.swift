import SwiftUI

/// **Advanced sheet — Solana priority fee.**
///
/// The priority fee = compute-unit price in micro-lamports, with presets
/// (None / Recommended) + a slider, and the base fee shown. A tiny tip
/// helps the transfer land during congestion; the compute-unit limit is
/// set automatically (the toggle row names that).
///
/// **Rule #15.** Native `NavigationStack` + `.navigationTitle`. Cancel
/// leading, Done trailing.
///
/// **Rule #4.** Numbers are MOCK design data (`// TODO: (T-063)`); the
/// controls edit real draft state.
struct SendAdvancedSolanaSheet: View {
    @Bindable var draft: SendDraft
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: UniSpacing.m) {
                    presets
                    SendValueSlider(
                        label: "Compute unit price",
                        value: $draft.advanced.solanaComputeUnitPriceMicroLamports,
                        range: 0...500_000,
                        unit: "µlamports",
                        ticks: ["0", "low", "high", "max"],
                        valueText: { formatMicroLamports($0) }
                    )
                    .onChange(of: draft.advanced.solanaComputeUnitPriceMicroLamports) { _, _ in
                        draft.feeSelection = .custom
                    }

                    SendToggleRow(
                        title: "Priority fee",
                        badge: "CU",
                        subtitle: "Sets the compute-unit limit automatically.",
                        isOn: $draft.advanced.solanaPriorityFeeEnabled
                    )

                    baseFeeNote
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(UniColors.Background.primary)
            .navigationTitle("Priority fee")
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
                title: "None",
                subtitle: "Base fee only",
                rate: "0",
                fiat: "~0.000005 SOL",
                isSelected: draft.feeSelection == .economy,
                action: {
                    draft.feeSelection = .economy
                    draft.advanced.solanaComputeUnitPriceMicroLamports = 0
                }
            )
            SendFeePresetRow(
                icon: "bolt.fill",
                title: "Recommended",
                subtitle: "Lands fast",
                rate: "50k µ◎",
                fiat: "~0.0002 SOL",
                isSelected: draft.feeSelection == .recommended,
                action: {
                    draft.feeSelection = .recommended
                    draft.advanced.solanaComputeUnitPriceMicroLamports = 50_000
                }
            )
        }
    }

    private var baseFeeNote: some View {
        Text("Every Solana transaction pays a small fixed base fee. The priority fee is an optional tip on top — it only matters when the network is busy.")
            .font(UniTypography.caption1)
            .foregroundStyle(UniColors.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, UniSpacing.xs)
    }

    /// Render the µlamport value compactly ("50k" past 1,000).
    private func formatMicroLamports(_ value: Double) -> String {
        let v = value.rounded()
        if v >= 1_000 {
            let k = v / 1_000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return String(Int(v))
    }
}
