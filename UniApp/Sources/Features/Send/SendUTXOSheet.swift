import SwiftUI

/// Send · advanced — manual coin (UTXO) selection for the Bitcoin family.
/// Lists the real fetched UTXO set (value + confirmations), lets the user
/// multi-select, shows a running total against amount + fee, and warns when
/// the selection can't cover the send. Leaving it untouched means the
/// planner auto-selects (the default) — selecting here pins
/// `model.selectedUTXOs`.
///
/// Native sheet (Rule #15): `NavigationStack` + `navigationTitle`, Cancel /
/// Done in the toolbar, opaque background.
struct SendUTXOSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss

    /// Local working selection (UTXO id → selected). Seeded from the
    /// model's current pin, else empty (= auto-select).
    @State private var selectedIDs: Set<String> = []
    @State private var didSeed = false

    private var utxos: [SelectedUTXO] { model.availableUTXOs }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Select coins")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { apply(); dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
    }

    @ViewBuilder
    private var content: some View {
        if utxos.isEmpty {
            empty
        } else {
            List {
                Section {
                    Button {
                        selectedIDs = []
                    } label: {
                        HStack {
                            Image(systemName: selectedIDs.isEmpty ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(selectedIDs.isEmpty ? UniColors.Icon.accent : UniColors.Icon.tertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatic")
                                    .font(UniTypography.body)
                                    .foregroundStyle(UniColors.Text.primary)
                                Text("Let Aperture choose the best coins")
                                    .font(UniTypography.caption1)
                                    .foregroundStyle(UniColors.Text.tertiary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                } header: {
                    UniCaption(text: "Coin selection", color: UniColors.Text.tertiary)
                }

                Section {
                    ForEach(utxos) { utxo in
                        utxoRow(utxo)
                    }
                } header: {
                    HStack {
                        UniCaption(text: "Your coins (\(utxos.count))", color: UniColors.Text.tertiary)
                        Spacer()
                        if !selectedIDs.isEmpty {
                            Text(verbatim: runningTotalText)
                                .font(UniTypography.caption1.monospacedDigit())
                                .foregroundStyle(coversTarget ? UniColors.Text.secondary : UniColors.Status.warningForeground)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                } footer: {
                    if !selectedIDs.isEmpty && !coversTarget {
                        Text("The selected coins don't cover the amount and fee. Select more, or use Automatic.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .onAppear(perform: seed)
        }
    }

    private func utxoRow(_ utxo: SelectedUTXO) -> some View {
        let selected = selectedIDs.contains(utxo.id)
        return Button {
            if selected { selectedIDs.remove(utxo.id) } else { selectedIDs.insert(utxo.id) }
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? UniColors.Icon.accent : UniColors.Icon.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(WalletFormatting.native(displayAmount(utxo), decimals: model.chain.nativeDecimals)) \(model.chain.ticker)")
                        .font(UniTypography.body.monospacedDigit())
                        .foregroundStyle(UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                    HStack(spacing: UniSpacing.xxs) {
                        Image(systemName: utxo.confirmed ? "checkmark.seal" : "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(utxo.confirmed ? UniColors.Status.successForeground : UniColors.Status.warningForeground)
                        Text(utxo.confirmed ? "Confirmed" : "Unconfirmed")
                            .font(UniTypography.caption2)
                            .foregroundStyle(UniColors.Text.tertiary)
                        Text(verbatim: "· \(shortTxid(utxo.txid)):\(utxo.vout)")
                            .font(UniTypography.caption2.monospaced())
                            .foregroundStyle(UniColors.Text.quaternary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(UniColors.Background.secondary)
    }

    private var empty: some View {
        VStack(spacing: UniSpacing.m) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
            UniBody(text: "No spendable coins were found for this address.",
                    alignment: .center, color: UniColors.Text.secondary)
            UniButton(title: "Try again", variant: .secondary) {
                Task { await model.loadUTXOs() }
            }
            .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(UniSpacing.l)
        .background(UniColors.Background.primary)
    }

    // MARK: - Math

    private func displayAmount(_ utxo: SelectedUTXO) -> Decimal {
        ComposeDecimal.toDisplay(Decimal(utxo.valueSats), decimals: model.chain.nativeDecimals)
    }

    private var selectedTotalSats: Int64 {
        utxos.filter { selectedIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.valueSats }
    }

    private var targetSats: Int64 {
        let amount = model.totalCrypto
        let fee = model.resolvedFee?.estimatedTotalNative ?? 0
        let base = ComposeDecimal.toBaseUnits(amount + fee, decimals: model.chain.nativeDecimals)
        return NSDecimalNumber(decimal: base).int64Value
    }

    private var coversTarget: Bool { selectedTotalSats >= targetSats }

    private var runningTotalText: String {
        let total = ComposeDecimal.toDisplay(Decimal(selectedTotalSats), decimals: model.chain.nativeDecimals)
        return "\(WalletFormatting.native(total, decimals: model.chain.nativeDecimals)) \(model.chain.ticker)"
    }

    private func shortTxid(_ txid: String) -> String {
        guard txid.count > 10 else { return txid }
        return "\(txid.prefix(6))…\(txid.suffix(4))"
    }

    // MARK: - Seed / apply

    private func seed() {
        guard !didSeed else { return }
        didSeed = true
        if let pinned = model.selectedUTXOs {
            selectedIDs = Set(pinned.map { $0.id })
        }
    }

    private func apply() {
        if selectedIDs.isEmpty {
            model.selectedUTXOs = nil // auto-select
        } else {
            model.selectedUTXOs = utxos.filter { selectedIDs.contains($0.id) }
        }
    }
}
