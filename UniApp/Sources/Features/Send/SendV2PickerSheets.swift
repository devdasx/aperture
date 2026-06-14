import SwiftUI

// MARK: - E1 · Asset & chain picker
//
/// **Send v2 · E1 — Asset & chain picker (bottom sheet).** Opened by the
/// token pill. Native `.searchable` (Rule #14 — no placement override),
/// chain filter chips (All / per-chain), then token rows (coin tile + chain
/// badge, name, network, balance + fiat). Footnote: *"Only assets the
/// recipient's network can receive are shown"* — recipient-aware.
///
/// Rule #15: native `NavigationStack` + `.navigationTitle`. Rule #14:
/// `.searchable` filters with `localizedStandardContains`.
struct SendV2AssetChainPickerSheet: View {
    @Bindable var model: SendV2Model
    let availableChains: [SupportedChain]
    let onSelect: (SendAsset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var chainFilter: SupportedChain?

    private var draft: SendDraft { model.draft }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    chainFilterRow
                        .listRowInsets(EdgeInsets(top: UniSpacing.xs, leading: UniSpacing.m, bottom: UniSpacing.xs, trailing: UniSpacing.m))
                        .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(filteredAssets) { asset in
                        Button { onSelect(asset) } label: {
                            assetRow(asset)
                        }
                        .buttonStyle(.plain)
                        .uniHaptic(.selection, trigger: asset.id)
                    }
                } footer: {
                    Text("Only assets the recipient's network can receive are shown.")
                        .font(UniTypography.caption2)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .searchable(text: $searchText, prompt: Text("Search assets"))
            .navigationTitle("Send asset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Chain filter chips

    private var chainFilterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: UniSpacing.xs) {
                filterChip(title: "All", chain: nil)
                ForEach(availableChains, id: \.self) { chain in
                    filterChip(title: LocalizedStringKey(chain.displayName), chain: chain)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func filterChip(title: LocalizedStringKey, chain: SupportedChain?) -> some View {
        let selected = chainFilter == chain
        Button { chainFilter = chain } label: {
            Text(title)
                .font(UniTypography.subheadlineEmphasized)
                .foregroundStyle(selected ? UniColors.Send.onDarkGlass : UniColors.Text.primary)
                .padding(.horizontal, UniSpacing.m)
                .frame(height: 36)
                .background(
                    Capsule().fill(selected ? UniColors.Send.darkGlass : UniColors.Fill.tertiary)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: selected)
    }

    // MARK: - Asset row

    @ViewBuilder
    private func assetRow(_ asset: SendAsset) -> some View {
        HStack(spacing: UniSpacing.s) {
            SendTokenTile(asset: asset, size: 40, ringColor: UniColors.Background.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: asset.unitTicker)
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: asset.network.displayName)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: WalletFormatting.native(balance(for: asset), decimals: asset.decimals))
                    .font(UniTypography.subheadlineEmphasized.monospaced())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                if draft.asset == asset {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UniColors.Send.positive)
                }
            }
        }
        .padding(.vertical, UniSpacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(asset.unitTicker) on \(asset.network.displayName)"))
    }

    // MARK: - Derived

    private var allAssets: [SendAsset] {
        SendAsset.sendable(availableChains: Set(availableChains))
    }

    private var filteredAssets: [SendAsset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allAssets.filter { asset in
            (chainFilter == nil || asset.network == chainFilter)
            && (query.isEmpty
                || asset.unitTicker.localizedStandardContains(query)
                || asset.displayName.localizedStandardContains(query)
                || asset.network.displayName.localizedStandardContains(query))
        }
    }

    private func balance(for asset: SendAsset) -> Decimal {
        draft.heldAssets.first {
            $0.network == asset.network && $0.symbol.uppercased() == asset.unitTicker.uppercased()
        }?.amount ?? 0
    }
}

// MARK: - E3 · Fee speed sheet

/// **Send v2 · E3 — Fee speed (bottom sheet).** Three stacked options
/// (Slow / Normal / Fast) each with crypto + fiat (selected = dark glass).
/// An **Advanced · gas, nonce, hex data** row links to the per-network
/// power sheets. **Apply** returns to Review re-simulated.
///
/// Rule #15: native `NavigationStack` + `.navigationTitle`. The advanced
/// row only appears for chains that have an advanced power sheet.
struct SendV2FeeSpeedSheet: View {
    @Bindable var model: SendV2Model
    let onAdvanced: () -> Void
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var applyTick: Int = 0

    private var draft: SendDraft { model.draft }

    var body: some View {
        NavigationStack {
            VStack(spacing: UniSpacing.m) {
                VStack(spacing: UniSpacing.xs) {
                    ForEach(model.feeTiers) { tier in
                        feeRow(tier)
                    }
                }
                .padding(.horizontal, UniSpacing.l)

                if SendAdvancedParams.hasAdvancedSheet(for: draft.network) {
                    advancedRow
                        .padding(.horizontal, UniSpacing.l)
                }

                Spacer(minLength: 0)

                UniButton(title: "Apply", variant: .primary) {
                    applyTick += 1
                    onApply()
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.xs)
            }
            .padding(.top, UniSpacing.m)
            .background(UniColors.Background.primary)
            .navigationTitle("Network fee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            // `.impactLight` on apply (handoff).
            .uniHaptic(.contextualImpact(.whisper), trigger: applyTick)
        }
    }

    @ViewBuilder
    private func feeRow(_ tier: SendV2Model.FeeTier) -> some View {
        let selected = model.selectedFeeTierId == tier.speed
        Button { model.selectedFeeTierId = tier.speed } label: {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: icon(for: tier.speed))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? UniColors.Send.onDarkGlass : UniColors.Icon.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.title)
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(selected ? UniColors.Send.onDarkGlass : UniColors.Text.primary)
                    Text(verbatim: etaText(tier.etaSeconds))
                        .font(UniTypography.caption2)
                        .foregroundStyle(selected ? UniColors.Send.onDarkGlass.opacity(0.7) : UniColors.Text.tertiary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: WalletFormatting.fiat(tier.feeFiat, currencyCode: activeCurrencyCode))
                        .font(UniTypography.subheadlineEmphasized.monospaced())
                        .foregroundStyle(selected ? UniColors.Send.onDarkGlass : UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                    Text(verbatim: "\(WalletFormatting.native(tier.feeNative, decimals: draft.network?.nativeDecimals ?? 8)) \(draft.network?.ticker ?? "")")
                        .font(UniTypography.caption2.monospaced())
                        .foregroundStyle(selected ? UniColors.Send.onDarkGlass.opacity(0.7) : UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .padding(UniSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                    .fill(selected ? UniColors.Send.darkGlass : UniColors.Background.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous))
        }
        .buttonStyle(.plain)
        .uniHaptic(.selection, trigger: selected)
        .accessibilityElement(children: .combine)
    }

    private var advancedRow: some View {
        Button(action: onAdvanced) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Advanced")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Gas, nonce, hex data")
                        .font(UniTypography.caption2)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
            .padding(UniSpacing.m)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.l, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func icon(for speed: SendV2Model.FeeTier.Speed) -> String {
        switch speed {
        case .slow:   return "tortoise.fill"
        case .normal: return "gauge.medium"
        case .fast:   return "bolt.fill"
        }
    }

    private func etaText(_ seconds: Int) -> String {
        if seconds >= 60 { return "~\(seconds / 60) min" }
        return "~\(seconds) sec"
    }

    private var activeCurrencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}
