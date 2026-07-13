import SwiftUI

/// **The Filter & Sort sheet** for the asset-detail screen. Single
/// screen hosting every preference that shapes the per-asset
/// transaction list and the per-network breakdown.
///
/// **Design intent (Rule #2 §D.1):** put one screen between the
/// user and every shape decision the asset detail can take. They
/// pick once; the screen reflects the choice the moment they tap.
///
/// **Layout (Rule #15).** Sheet-as-screen — a `NavigationStack` hosts
/// the body so iOS owns the title chrome and the toolbar.
/// `.navigationTitle("Filter & Sort")` carries the title;
/// `.navigationBarTitleDisplayMode(.inline)` keeps the bar compact at
/// the `.large` detent (which is what nav-shaped sheets use per
/// M-008). The body is a `List(.insetGrouped)`. A leading `Cancel`
/// lives in `.topBarLeading` — there is no `Done` because every
/// control writes through `@GRDBStorage` in place; "done" is "now".
///
/// **Live propagation.** Every `@GRDBStorage` write here is read by
/// `AssetDetailView`'s body (also bound via `@GRDBStorage`), so the
/// detail's transaction list and network breakdown update the moment
/// the user toggles a preference here.
///
/// **Rule #12 §G.** The sheet's content is keyed on the direction-only
/// `sheetDirectionKey` at the call site so an LTR↔RTL flip rebuilds
/// the host while preserving the user's nav-stack position inside.
struct AssetDetailFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The identity of the asset being viewed. Drives the Network
    /// sub-screen's "available networks" list (it's not "every chain
    /// Aperture supports" — only the networks THIS asset exists on).
    let identity: AssetIdentity
    /// The full list of networks the asset is on, from the parent
    /// view's `AssetResolution.networks`. Passed through so the
    /// network multi-select picker shows exactly the right options.
    let availableNetworks: [AssetNetworkRow]
    /// Asset-scoped transaction count for the live preview header.
    /// Pre-filter total: the "M" in "Showing N of M transactions".
    let totalTransactions: Int
    /// Post-filter count for the live preview header. Recomputed by
    /// the parent and passed in.
    let visibleTransactions: Int

    @GRDBStorage(AssetDetailFilterPreferences.sortKeyKey)
    private var sortKeyRaw: String = AssetDetailFilterPreferences.defaultSortKey.rawValue
    @GRDBStorage(AssetDetailFilterPreferences.directionKey)
    private var directionRaw: String = AssetDetailFilterPreferences.defaultDirection.rawValue
    @GRDBStorage(AssetDetailFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = AssetDetailFilterPreferences.defaultSelectedNetworksJSON
    @GRDBStorage(AssetDetailFilterPreferences.timeRangeKey)
    private var timeRangeRaw: String = AssetDetailFilterPreferences.defaultTimeRange.rawValue
    @GRDBStorage(AssetDetailFilterPreferences.hideZeroNetworksKey)
    private var hideZeroNetworks: Bool = AssetDetailFilterPreferences.defaultHideZeroNetworks

    @State private var isShowingResetConfirmation: Bool = false

    /// Decoded snapshot of `selectedNetworksJSON`. Decoding JSON per
    /// body pass (the readout row re-decoded on every render) is
    /// wasted work — decode once at init, then keep in sync via
    /// `.onChange` when this sheet or the pushed picker writes the
    /// preference.
    @State private var selectedNetworks: Set<String>

    init(
        identity: AssetIdentity,
        availableNetworks: [AssetNetworkRow],
        totalTransactions: Int,
        visibleTransactions: Int
    ) {
        self.identity = identity
        self.availableNetworks = availableNetworks
        self.totalTransactions = totalTransactions
        self.visibleTransactions = visibleTransactions
        // Seed from the same GRDB key the @GRDBStorage wraps —
        // readable here because the wrapper itself isn't available
        // until after initialization.
        _selectedNetworks = State(initialValue: AssetDetailFilterPreferences.decode(
            AppPreferenceStore.shared.string(
                AssetDetailFilterPreferences.selectedNetworksKey,
                default: AssetDetailFilterPreferences.defaultSelectedNetworksJSON
            )
        ))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                previewSection
                viewSection
                showSection
            }
            .uniListPageChrome()
            .navigationTitle(Text("Filter & Sort"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(UniColors.Button.text)
                    if hasNonDefaultFilters {
                        Button("Reset") { isShowingResetConfirmation = true }
                            .tint(UniColors.Feedback.Error.foreground)
                    }
                }
            }
            .navigationDestination(for: AssetFilterDestination.self) { destination in
                switch destination {
                case .networks:
                    AssetDetailNetworksPicker(availableNetworks: availableNetworks)
                }
            }
            .onChange(of: selectedNetworksJSON) { _, newValue in
                selectedNetworks = AssetDetailFilterPreferences.decode(newValue)
            }
            .confirmationDialog(
                Text("Reset filter?"),
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    AssetDetailFilterPreferences.resetAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every filter and sort choice for asset details. Continue?")
            }
        }
    }

    private var hasNonDefaultFilters: Bool {
        sortKeyRaw != AssetDetailFilterPreferences.defaultSortKey.rawValue
            || directionRaw != AssetDetailFilterPreferences.defaultDirection.rawValue
            || !selectedNetworks.isEmpty
            || timeRangeRaw != AssetDetailFilterPreferences.defaultTimeRange.rawValue
            || hideZeroNetworks != AssetDetailFilterPreferences.defaultHideZeroNetworks
    }

    // MARK: - Preview header

    /// Live preview message. Shows the asset-scoped totals so the
    /// user reads "Showing N of M transactions" specific to THIS
    /// asset, not the wallet-wide total.
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
            .uniListRowSurface()
        }
    }

    private var previewMessage: String {
        if visibleTransactions == totalTransactions {
            return String(
                format: String.apertureLocalized("Showing all %lld transactions"),
                Int64(totalTransactions)
            )
        }
        return String(
            format: String.apertureLocalized("Showing %lld of %lld transactions"),
            Int64(visibleTransactions),
            Int64(totalTransactions)
        )
    }

    // MARK: - View section (sort + direction + time)

    @ViewBuilder
    private var viewSection: some View {
        Section {
            sortKeyPicker
                .uniListRowSurface()
            directionPicker
                .uniListRowSurface()
            timeRangePicker
                .uniListRowSurface()
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
                ForEach(AssetDetailFilterPreferences.SortKey.allCases) { key in
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
    private var directionPicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Direction")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Direction", selection: directionBinding) {
                ForEach(AssetDetailFilterPreferences.TxDirection.allCases) { dir in
                    Text(dir.label).tag(dir)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: directionRaw)
    }

    @ViewBuilder
    private var timeRangePicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Time range")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Time range", selection: timeRangeBinding) {
                ForEach(AssetDetailFilterPreferences.TimeRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: timeRangeRaw)
    }

    // MARK: - Show section (networks + hide-zero toggle)

    @ViewBuilder
    private var showSection: some View {
        Section {
            NavigationLink(value: AssetFilterDestination.networks) {
                networksLink
            }
            .uniListRowSurface()

            hideZeroNetworksToggle
                .uniListRowSurface()
        } header: {
            Text("Show")
        } footer: {
            Text("Hidden networks stay supported — only this asset's view is affected.")
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
        .uniListRowHitTarget()
    }

    private var networksReadout: String {
        if selectedNetworks.isEmpty {
            return String.apertureLocalized("All")
        }
        return String(
            format: String.apertureLocalized("%lld of %lld"),
            Int64(selectedNetworks.count),
            Int64(availableNetworks.count)
        )
    }

    @ViewBuilder
    private var hideZeroNetworksToggle: some View {
        UniToggle(isOn: $hideZeroNetworks) {
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
        .tint(UniColors.Button.Primary.tint)
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: hideZeroNetworks)
    }

    // MARK: - Bindings

    private var sortKeyBinding: Binding<AssetDetailFilterPreferences.SortKey> {
        Binding(
            get: {
                AssetDetailFilterPreferences.SortKey(rawValue: sortKeyRaw)
                    ?? AssetDetailFilterPreferences.defaultSortKey
            },
            set: { sortKeyRaw = $0.rawValue }
        )
    }

    private var directionBinding: Binding<AssetDetailFilterPreferences.TxDirection> {
        Binding(
            get: {
                AssetDetailFilterPreferences.TxDirection(rawValue: directionRaw)
                    ?? AssetDetailFilterPreferences.defaultDirection
            },
            set: { directionRaw = $0.rawValue }
        )
    }

    private var timeRangeBinding: Binding<AssetDetailFilterPreferences.TimeRange> {
        Binding(
            get: {
                AssetDetailFilterPreferences.TimeRange(rawValue: timeRangeRaw)
                    ?? AssetDetailFilterPreferences.defaultTimeRange
            },
            set: { timeRangeRaw = $0.rawValue }
        )
    }
}

// MARK: - Networks picker sub-screen

/// Networks multi-select picker. Pushed from the filter sheet's
/// "Networks" row. List of `AssetNetworkRow`s the asset is on; tap
/// to toggle each on/off. Empty set = "all networks" (the default
/// sentinel — the user just clears their selection to see
/// everything).
private struct AssetDetailNetworksPicker: View {
    let availableNetworks: [AssetNetworkRow]
    @GRDBStorage(AssetDetailFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = AssetDetailFilterPreferences.defaultSelectedNetworksJSON

    /// Decoded selection — the per-row JSON decode (one full decode
    /// per visible row per body pass) is replaced by this single
    /// `@State` set, seeded at init and synced via `.onChange`.
    @State private var selectedNetworks: Set<String>

    init(availableNetworks: [AssetNetworkRow]) {
        self.availableNetworks = availableNetworks
        _selectedNetworks = State(initialValue: AssetDetailFilterPreferences.decode(
            AppPreferenceStore.shared.string(
                AssetDetailFilterPreferences.selectedNetworksKey,
                default: AssetDetailFilterPreferences.defaultSelectedNetworksJSON
            )
        ))
    }

    var body: some View {
        List {
            Section {
                Button {
                    selectedNetworksJSON = AssetDetailFilterPreferences.defaultSelectedNetworksJSON
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
                    .padding(.vertical, UniSpacing.xxs)
                    .uniListRowHitTarget()
                }
                .buttonStyle(.uniListRow)
                .uniListRowSurface()
            }

            Section {
                ForEach(availableNetworks, id: \.id) { row in
                    networkRow(row)
                        .uniListRowSurface()
                }
            } header: {
                Text("Networks")
            }
        }
        .uniListPageChrome()
        .navigationTitle(Text("Networks"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedNetworksJSON) { _, newValue in
            selectedNetworks = AssetDetailFilterPreferences.decode(newValue)
        }
    }

    @ViewBuilder
    private func networkRow(_ row: AssetNetworkRow) -> some View {
        Button {
            toggle(row.chain)
        } label: {
            HStack(spacing: UniSpacing.s) {
                CoinMark(chain: row.chain, tokenSymbol: row.chain.ticker)
                    .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                    .accessibilityHidden(true)
                Text(verbatim: row.chain.displayName)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                if selectedNetworks.contains(row.chain.rawValue) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(UniColors.Tint.accent)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniListRowHitTarget()
        }
        .buttonStyle(.uniListRow)
        .accessibilityLabel(Text(verbatim: String(format: String.apertureLocalized("%@ network"), row.chain.displayName)))
    }

    private func toggle(_ chain: SupportedChain) {
        var set = selectedNetworks
        if set.contains(chain.rawValue) {
            set.remove(chain.rawValue)
        } else {
            set.insert(chain.rawValue)
        }
        // Write the JSON source of truth; `.onChange` syncs the
        // decoded set (and the parent sheet's readout) from it.
        selectedNetworksJSON = AssetDetailFilterPreferences.encode(set)
    }
}

// MARK: - Destination enum

/// Navigation destinations the asset-detail filter sheet pushes
/// onto its own `NavigationStack`. One value today; future sub-
/// screens extend this enum.
enum AssetFilterDestination: Hashable, Codable {
    case networks
}
