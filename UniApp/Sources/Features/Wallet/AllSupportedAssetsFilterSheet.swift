import SwiftUI

/// **The Filter & Sort sheet** for the "All supported assets" screen.
/// One screen hosting every preference that shapes the discovery list:
/// how it's sorted, which kind of asset shows, which networks, and
/// whether to hide everything the wallet doesn't hold.
///
/// **Design intent (Rule #2 §D.1):** the same contract every Aperture
/// filter follows — one screen between the user and every shape
/// decision; pick once, the list reflects it the instant they tap.
///
/// **Layout (Rule #15).** Sheet-as-screen — a `NavigationStack` hosts a
/// `List(.insetGrouped)` so iOS owns the title chrome and toolbar.
/// `.navigationTitle("Filter & Sort")`, `.inline` mode. A leading
/// `Cancel` lives in `.topBarLeading`; there is no `Done` because every
/// control writes through `@AppStorage` in place.
///
/// **Live propagation.** Each `@AppStorage` write here is read by
/// `AllSupportedAssetsView`'s body (also bound via `@AppStorage`), so the
/// list re-sorts / re-filters the moment the user toggles a preference.
struct AllSupportedAssetsFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Pre-filter total asset count for the live preview header — the
    /// "M" in "Showing N of M assets".
    let totalAssets: Int
    /// Post-filter count for the live preview header.
    let visibleAssets: Int

    @AppStorage(AllSupportedFilterPreferences.sortKeyKey)
    private var sortKeyRaw: String = AllSupportedFilterPreferences.defaultSortKey.rawValue
    @AppStorage(AllSupportedFilterPreferences.assetTypeKey)
    private var assetTypeRaw: String = AllSupportedFilterPreferences.defaultAssetType.rawValue
    @AppStorage(AllSupportedFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = AllSupportedFilterPreferences.defaultSelectedNetworksJSON
    @AppStorage(AllSupportedFilterPreferences.onlyWithBalanceKey)
    private var onlyWithBalance: Bool = AllSupportedFilterPreferences.defaultOnlyWithBalance

    @State private var isShowingResetConfirmation: Bool = false

    /// Decoded snapshot of `selectedNetworksJSON` — decoded once at init,
    /// kept in sync via `.onChange` when this sheet or the pushed picker
    /// writes the preference (avoids a JSON decode per body pass).
    @State private var selectedNetworks: Set<String>

    init(totalAssets: Int, visibleAssets: Int) {
        self.totalAssets = totalAssets
        self.visibleAssets = visibleAssets
        _selectedNetworks = State(initialValue: AllSupportedFilterPreferences.decode(
            UserDefaults.standard.string(forKey: AllSupportedFilterPreferences.selectedNetworksKey)
                ?? AllSupportedFilterPreferences.defaultSelectedNetworksJSON
        ))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                previewSection
                viewSection
                showSection
                resetSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Filter & Sort"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(UniColors.Button.text)
                }
            }
            .navigationDestination(for: AllSupportedFilterDestination.self) { destination in
                switch destination {
                case .networks:
                    AllSupportedNetworksPicker()
                }
            }
            .onChange(of: selectedNetworksJSON) { _, newValue in
                selectedNetworks = AllSupportedFilterPreferences.decode(newValue)
            }
            .confirmationDialog(
                Text("Reset filter?"),
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    AllSupportedFilterPreferences.resetAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every filter and sort choice for the supported-assets list. Continue?")
            }
        }
    }

    // MARK: - Preview header

    @ViewBuilder
    private var previewSection: some View {
        Section {
            HStack(alignment: .center, spacing: UniSpacing.s) {
                Image(systemName: "eye")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                Text(verbatim: previewMessage)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, UniSpacing.xxs)
            .listRowBackground(UniColors.Background.secondary)
        }
    }

    private var previewMessage: String {
        if visibleAssets == totalAssets {
            return String(
                format: String(localized: "Showing all %lld assets"),
                Int64(totalAssets)
            )
        }
        return String(
            format: String(localized: "Showing %lld of %lld assets"),
            Int64(visibleAssets),
            Int64(totalAssets)
        )
    }

    // MARK: - View section (sort + asset type)

    @ViewBuilder
    private var viewSection: some View {
        Section {
            sortKeyPicker
                .listRowBackground(UniColors.Background.secondary)
            assetTypePicker
                .listRowBackground(UniColors.Background.secondary)
        } header: {
            Text("View")
        }
    }

    @ViewBuilder
    private var sortKeyPicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Sort by")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Sort by", selection: sortKeyBinding) {
                ForEach(AllSupportedFilterPreferences.SortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: sortKeyRaw)
    }

    @ViewBuilder
    private var assetTypePicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Assets")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Assets", selection: assetTypeBinding) {
                ForEach(AllSupportedFilterPreferences.AssetType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: assetTypeRaw)
    }

    // MARK: - Show section (networks + only-with-balance toggle)

    @ViewBuilder
    private var showSection: some View {
        Section {
            NavigationLink(value: AllSupportedFilterDestination.networks) {
                networksLink
            }
            .listRowBackground(UniColors.Background.secondary)

            onlyWithBalanceToggle
                .listRowBackground(UniColors.Background.secondary)
        } header: {
            Text("Show")
        } footer: {
            Text("Hidden networks stay supported — only this list's view is affected.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var networksLink: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text("Networks")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Text(verbatim: networksReadout)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private var networksReadout: String {
        if selectedNetworks.isEmpty {
            return String.apertureLocalized("All")
        }
        return String(
            format: String(localized: "%lld of %lld"),
            Int64(selectedNetworks.count),
            Int64(SupportedChain.allCases.count)
        )
    }

    @ViewBuilder
    private var onlyWithBalanceToggle: some View {
        UniToggle(isOn: $onlyWithBalance) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "scalemass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                Text("Only with balance")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .tint(UniColors.Button.primaryTint)
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: onlyWithBalance)
    }

    // MARK: - Reset section

    @ViewBuilder
    private var resetSection: some View {
        Section {
            UniButton(title: "Reset to defaults", variant: .destructive) {
                isShowingResetConfirmation = true
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: UniSpacing.s,
                leading: UniSpacing.m,
                bottom: UniSpacing.s,
                trailing: UniSpacing.m
            ))
        }
    }

    // MARK: - Bindings

    private var sortKeyBinding: Binding<AllSupportedFilterPreferences.SortKey> {
        Binding(
            get: {
                AllSupportedFilterPreferences.SortKey(rawValue: sortKeyRaw)
                    ?? AllSupportedFilterPreferences.defaultSortKey
            },
            set: { sortKeyRaw = $0.rawValue }
        )
    }

    private var assetTypeBinding: Binding<AllSupportedFilterPreferences.AssetType> {
        Binding(
            get: {
                AllSupportedFilterPreferences.AssetType(rawValue: assetTypeRaw)
                    ?? AllSupportedFilterPreferences.defaultAssetType
            },
            set: { assetTypeRaw = $0.rawValue }
        )
    }
}

// MARK: - Networks picker sub-screen

/// Networks multi-select picker. Pushed from the filter sheet's
/// "Networks" row. Lists every `SupportedChain`; tap to toggle each
/// on/off. Empty set = "all networks" (the default sentinel — the user
/// clears their selection to see everything).
private struct AllSupportedNetworksPicker: View {
    @AppStorage(AllSupportedFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = AllSupportedFilterPreferences.defaultSelectedNetworksJSON

    @State private var selectedNetworks: Set<String>

    init() {
        _selectedNetworks = State(initialValue: AllSupportedFilterPreferences.decode(
            UserDefaults.standard.string(forKey: AllSupportedFilterPreferences.selectedNetworksKey)
                ?? AllSupportedFilterPreferences.defaultSelectedNetworksJSON
        ))
    }

    var body: some View {
        List {
            Section {
                Button {
                    selectedNetworksJSON = AllSupportedFilterPreferences.defaultSelectedNetworksJSON
                } label: {
                    HStack {
                        Text("All networks")
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        if selectedNetworks.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(UniColors.Tint.accent)
                        }
                    }
                }
                .listRowBackground(UniColors.Background.secondary)
            }

            Section {
                ForEach(SupportedChain.allCases, id: \.self) { chain in
                    networkRow(chain)
                        .listRowBackground(UniColors.Background.secondary)
                }
            } header: {
                Text("Networks")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Networks"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedNetworksJSON) { _, newValue in
            selectedNetworks = AllSupportedFilterPreferences.decode(newValue)
        }
    }

    @ViewBuilder
    private func networkRow(_ chain: SupportedChain) -> some View {
        Button {
            toggle(chain)
        } label: {
            HStack(spacing: UniSpacing.s) {
                CoinMark(chain: chain, tokenSymbol: chain.ticker)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(verbatim: chain.displayName)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                if selectedNetworks.contains(chain.rawValue) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(UniColors.Tint.accent)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .accessibilityLabel(Text("\(chain.displayName) network"))
    }

    private func toggle(_ chain: SupportedChain) {
        var set = selectedNetworks
        if set.contains(chain.rawValue) {
            set.remove(chain.rawValue)
        } else {
            set.insert(chain.rawValue)
        }
        selectedNetworksJSON = AllSupportedFilterPreferences.encode(set)
    }
}

// MARK: - Destination enum

/// Navigation destinations the all-supported-assets filter sheet pushes
/// onto its own `NavigationStack`.
enum AllSupportedFilterDestination: Hashable, Codable {
    case networks
}
