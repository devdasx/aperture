import SwiftUI

/// Send · advanced — the network-fee sheet. Shows slow / normal / fast
/// tiers (each: the fee in native units + its fiat value + a rough time)
/// and a Custom field when the fee model allows it (`FeeQuote.isCustomAllowed`).
/// For single-tier / non-editable models (TON) it shows ONE honest fee with
/// the model's note and no edit control (Rule #2 honesty — don't imply a
/// priority market that doesn't exist).
///
/// Native sheet (Rule #15): `NavigationStack` + `navigationTitle`, Cancel
/// leading / Done trailing in the toolbar, opaque presentation background.
struct SendFeeSheet: View {
    @Bindable var model: SendComposeModel
    @Environment(\.dismiss) private var dismiss

    @State private var customByteRate = ""        // UTXO sat/vB|byte
    @State private var customMaxFeeGwei = ""       // EVM 1559 maxFee (gwei)
    @State private var customTipGwei = ""          // EVM 1559 tip (gwei)
    @State private var customGasPriceGwei = ""     // EVM legacy gasPrice (gwei)

    private var quote: FeeQuote? { model.feeQuote }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Network fee")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { applyCustomIfNeeded(); dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
    }

    @ViewBuilder
    private var content: some View {
        if let quote {
            List {
                if quote.hasSpeedTiers {
                    Section {
                        tierRow(.slow, quote: quote, label: "Slower", time: "~30+ min")
                        tierRow(.normal, quote: quote, label: "Normal", time: "~ a few min")
                        tierRow(.fast, quote: quote, label: "Faster", time: "~ next block")
                    } header: {
                        UniCaption(text: "Speed", color: UniColors.Text.tertiary)
                    }
                } else {
                    Section {
                        if let normal = quote.normal {
                            singleFeeRow(normal)
                        }
                    } header: {
                        UniCaption(text: "Network fee", color: UniColors.Text.tertiary)
                    } footer: {
                        if let note = quote.note {
                            Text(verbatim: note)
                        }
                    }
                }

                if quote.isCustomAllowed {
                    customSection(quote)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            // One `.selection` beat per tier change — fires once on the
            // List keyed to the selected tier (Custom included), replacing
            // the old per-row trigger that double-fired on tap and missed
            // Custom entirely (FIX 6 · Rule #10 §B).
            .uniHaptic(.selection, trigger: model.selectedTier)
            .onAppear { seedCustomFields(quote) }
        } else {
            unavailable
        }
    }

    // MARK: - Tier rows

    private func tierRow(_ tier: FeeTier, quote: FeeQuote, label: LocalizedStringKey, time: LocalizedStringKey) -> some View {
        let choice = quote.tiers[tier]
        return Button {
            model.selectedTier = tier
        } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: model.selectedTier == tier ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(model.selectedTier == tier ? UniColors.Icon.accent : UniColors.Icon.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(time)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
                Spacer(minLength: UniSpacing.s)
                feeColumn(choice)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(UniColors.Background.secondary)
    }

    private func singleFeeRow(_ choice: FeeChoice) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 18))
                .foregroundStyle(UniColors.Icon.secondary)
            Text("Estimated fee")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer(minLength: UniSpacing.s)
            feeColumn(choice)
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    @ViewBuilder
    private func feeColumn(_ choice: FeeChoice?) -> some View {
        if let choice {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(WalletFormatting.native(choice.estimatedTotalNative, decimals: 8)) \(model.chain.ticker)")
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                if let price = model.nativeUnitPrice, price > 0 {
                    Text(verbatim: WalletFormatting.fiat(choice.estimatedTotalNative * price, currencyCode: model.currencyCode))
                        .font(UniTypography.caption1.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        } else {
            Text("—")
                .font(UniTypography.callout)
                .foregroundStyle(UniColors.Text.tertiary)
        }
    }

    // MARK: - Custom section (fields per fee model)

    @ViewBuilder
    private func customSection(_ quote: FeeQuote) -> some View {
        Section {
            Button {
                model.selectedTier = .custom
            } label: {
                HStack {
                    Image(systemName: model.selectedTier == .custom ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(model.selectedTier == .custom ? UniColors.Icon.accent : UniColors.Icon.tertiary)
                    Text("Custom")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(UniColors.Background.secondary)

            customFields(quote)
        } header: {
            UniCaption(text: "Set your own", color: UniColors.Text.tertiary)
        } footer: {
            Text("A higher fee confirms faster. Too low and the transaction can get stuck.")
        }
    }

    @ViewBuilder
    private func customFields(_ quote: FeeQuote) -> some View {
        switch quote.feeModel {
        case .utxoByteFee, .utxoByteFeeNoWitness, .dogecoinFixedPerKB:
            customField(byteRateLabel, text: $customByteRate, suffix: byteRateSuffix)
        case .evm1559, .evm1559PlusL1Data, .zkSyncEra:
            customField("Max fee", text: $customMaxFeeGwei, suffix: "gwei")
            customField("Priority tip", text: $customTipGwei, suffix: "gwei")
        case .evmLegacy:
            customField("Gas price", text: $customGasPriceGwei, suffix: "gwei")
        default:
            // Other models expose no meaningful custom numeric lever from
            // this screen — keep the preset tiers honest.
            EmptyView()
        }
    }

    private func customField(_ label: LocalizedStringKey, text: Binding<String>, suffix: String) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(label)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer(minLength: UniSpacing.s)
            TextField("0", text: text)
                .font(UniTypography.body.monospacedDigit())
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .environment(\.layoutDirection, .leftToRight)
                .onChange(of: text.wrappedValue) { _, _ in model.selectedTier = .custom }
            Text(verbatim: suffix)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    private var unavailable: some View {
        VStack(spacing: UniSpacing.m) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UniColors.Icon.tertiary)
            UniBody(text: "The network fee isn't available right now.",
                    alignment: .center, color: UniColors.Text.secondary)
            UniButton(title: "Try again", variant: .secondary) {
                Task { await model.loadFee() }
            }
            .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(UniSpacing.l)
        .background(UniColors.Background.primary)
    }

    // MARK: - Custom resolution

    private var byteRateLabel: LocalizedStringKey {
        model.chain == .dogecoin ? "Fee rate" : "Fee rate"
    }
    private var byteRateSuffix: String {
        switch model.chain {
        case .bitcoin, .litecoin: return "sat/vB"
        case .bitcoinCash:        return "sat/byte"
        case .dogecoin:           return "koinu/byte"
        default:                  return "sat/vB"
        }
    }

    private func seedCustomFields(_ quote: FeeQuote) {
        guard let normal = quote.normal else { return }
        if customByteRate.isEmpty, let r = normal.byteFeeRate {
            customByteRate = SendComposeModel.plainString(r, decimals: 2)
        }
        if customMaxFeeGwei.isEmpty, let w = normal.maxFeePerGasWei {
            customMaxFeeGwei = SendComposeModel.plainString(ComposeDecimal.toDisplay(w, decimals: 9), decimals: 4)
        }
        if customTipGwei.isEmpty, let w = normal.maxPriorityFeePerGasWei {
            customTipGwei = SendComposeModel.plainString(ComposeDecimal.toDisplay(w, decimals: 9), decimals: 4)
        }
        if customGasPriceGwei.isEmpty, let w = normal.gasPriceWei {
            customGasPriceGwei = SendComposeModel.plainString(ComposeDecimal.toDisplay(w, decimals: 9), decimals: 4)
        }
    }

    /// Build the custom `FeeChoice` from the typed fields (only when the
    /// custom tier is selected). Starts from the normal preset so the
    /// non-edited fields (gasLimit, l1DataFeeWei, baseFeePerGasWei,
    /// gasPerPubdataLimit, …) carry over onto a `.custom`-tier choice; the
    /// edited numeric lever is applied, then the TOTALS are recomputed by
    /// the DATA LAYER (`ComposeFeeService.recomputeEVMTotals`) so estimated
    /// (base+tip) and worst (maxFee) come out distinct — never both set to
    /// the worst case (FIX 5). The UI never hand-rolls EVM arithmetic.
    private func applyCustomIfNeeded() {
        guard model.selectedTier == .custom, let quote = model.feeQuote,
              let base = quote.normal else { return }
        let dec = model.chain.nativeDecimals

        // Seed a `.custom`-tier choice carrying every per-chain field from
        // the normal preset (so gasLimit / l1 / baseFee / pubdata survive).
        var custom = FeeChoice(
            tier: .custom, feeModel: quote.feeModel,
            estimatedTotalNative: base.estimatedTotalNative,
            worstCaseTotalNative: base.worstCaseTotalNative)
        custom.byteFeeRate = base.byteFeeRate
        custom.maxFeePerGasWei = base.maxFeePerGasWei
        custom.maxPriorityFeePerGasWei = base.maxPriorityFeePerGasWei
        custom.baseFeePerGasWei = base.baseFeePerGasWei
        custom.gasPriceWei = base.gasPriceWei
        custom.gasLimit = base.gasLimit
        custom.l1DataFeeWei = base.l1DataFeeWei
        custom.gasPerPubdataLimit = base.gasPerPubdataLimit

        switch quote.feeModel {
        case .utxoByteFee, .utxoByteFeeNoWitness, .dogecoinFixedPerKB:
            guard let rate = SendComposeModel.parseAmount(customByteRate), rate > 0,
                  let normalRate = base.byteFeeRate, normalRate > 0 else { return }
            // UTXO is deterministic per rate — scale the typical estimate
            // proportionally to the rate change (estimated == worst).
            custom.byteFeeRate = rate
            let scale = rate / normalRate
            custom.setTotals(
                estimated: base.estimatedTotalNative * scale,
                worst: base.worstCaseTotalNative * scale)
        case .evm1559, .evm1559PlusL1Data, .zkSyncEra:
            guard let maxGwei = SendComposeModel.parseAmount(customMaxFeeGwei), maxGwei > 0,
                  base.gasLimit != nil else { return }
            let tipGwei = SendComposeModel.parseAmount(customTipGwei) ?? 0
            custom.maxFeePerGasWei = maxGwei * ComposeDecimal.pow10(9)
            custom.maxPriorityFeePerGasWei = tipGwei * ComposeDecimal.pow10(9)
            // baseFeePerGasWei is carried from the live quote above, so the
            // data layer computes estimated = gasLimit × (base + cappedTip)
            // [+ L1] and worst = gasLimit × maxFee [+ L1] — distinct.
            custom = ComposeFeeService.recomputeEVMTotals(custom, decimals: dec)
        case .evmLegacy:
            guard let gpGwei = SendComposeModel.parseAmount(customGasPriceGwei), gpGwei > 0,
                  base.gasLimit != nil else { return }
            custom.gasPriceWei = gpGwei * ComposeDecimal.pow10(9)
            // Legacy is deterministic (estimated == worst == gasLimit × gp).
            custom = ComposeFeeService.recomputeEVMTotals(custom, decimals: dec)
        default:
            return
        }
        model.customFee = custom
    }
}
