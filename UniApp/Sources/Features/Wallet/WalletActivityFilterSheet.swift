import SwiftUI

/// **The Filter & Sort sheet** for the wallet-wide Activity screen.
/// One screen hosting every preference that shapes the cross-asset,
/// cross-network transaction list: sort, direction, status, time range
/// (presets + a custom from/to window), network multi-select, asset
/// multi-select, and a fiat amount range.
///
/// **Design intent (Rule #2 §D.1):** one screen between the user and
/// every shape decision the Activity list can take. They pick once; the
/// list reflects the choice the moment they tap — every control writes
/// through `@AppStorage`, which the Activity view also reads, so there
/// is no "Apply" button. "Done" is "now."
///
/// **Layout (Rule #15).** Sheet-as-screen — a `NavigationStack` hosts a
/// `List(.insetGrouped)`. `.navigationTitle("Filter & Sort")`,
/// `.inline` title (the nav-shaped `.large` detent per M-008). A
/// leading `Cancel` dismisses; sub-screens (Networks, Assets) push onto
/// this stack.
///
/// **Rule #12 §G.** Keyed on the call site's `sheetDirectionKey` so an
/// LTR↔RTL flip rebuilds the host while preserving nav position.
struct WalletActivityFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Distinct chains present in the (dust-gated) feed — the network
    /// multi-select shows exactly these, not "every chain Aperture
    /// supports."
    let availableNetworks: [SupportedChain]
    /// Distinct token symbols present in the feed (display casing),
    /// sorted — the asset multi-select options.
    let availableSymbols: [String]
    /// The active display-currency code, shown beside the amount fields.
    let currencyCode: String
    /// Pre-filter total — the "M" in "Showing N of M transactions"
    /// (the dust-gated wallet feed count).
    let totalTransactions: Int
    /// Post-filter count — the "N". Recomputed by the parent.
    let visibleTransactions: Int

    @AppStorage(WalletActivityFilterPreferences.sortKeyKey)
    private var sortKeyRaw: String = WalletActivityFilterPreferences.defaultSortKey.rawValue
    @AppStorage(WalletActivityFilterPreferences.directionKey)
    private var directionRaw: String = WalletActivityFilterPreferences.defaultDirection.rawValue
    @AppStorage(WalletActivityFilterPreferences.statusKey)
    private var statusRaw: String = WalletActivityFilterPreferences.defaultStatus.rawValue
    @AppStorage(WalletActivityFilterPreferences.kindKey)
    private var kindRaw: String = WalletActivityFilterPreferences.defaultKind.rawValue
    @AppStorage(WalletActivityFilterPreferences.assetClassKey)
    private var assetClassRaw: String = WalletActivityFilterPreferences.defaultAssetClass.rawValue
    @AppStorage(WalletActivityFilterPreferences.timeRangeKey)
    private var timeRangeRaw: String = WalletActivityFilterPreferences.defaultTimeRange.rawValue
    @AppStorage(WalletActivityFilterPreferences.customStartKey)
    private var customStart: Double = WalletActivityFilterPreferences.defaultCustomDate
    @AppStorage(WalletActivityFilterPreferences.customEndKey)
    private var customEnd: Double = WalletActivityFilterPreferences.defaultCustomDate
    @AppStorage(WalletActivityFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON
    @AppStorage(WalletActivityFilterPreferences.selectedSymbolsKey)
    private var selectedSymbolsJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON
    @AppStorage(WalletActivityFilterPreferences.minFiatKey)
    private var minFiat: String = WalletActivityFilterPreferences.defaultAmount
    @AppStorage(WalletActivityFilterPreferences.maxFiatKey)
    private var maxFiat: String = WalletActivityFilterPreferences.defaultAmount

    @State private var isShowingResetConfirmation: Bool = false

    /// Decoded selections, seeded at init and kept in sync via
    /// `.onChange` — avoids re-decoding the JSON on every render (the
    /// readout rows would otherwise decode per body pass).
    @State private var selectedNetworks: Set<String>
    @State private var selectedSymbols: Set<String>

    init(
        availableNetworks: [SupportedChain],
        availableSymbols: [String],
        currencyCode: String,
        totalTransactions: Int,
        visibleTransactions: Int
    ) {
        self.availableNetworks = availableNetworks
        self.availableSymbols = availableSymbols
        self.currencyCode = currencyCode
        self.totalTransactions = totalTransactions
        self.visibleTransactions = visibleTransactions
        _selectedNetworks = State(initialValue: WalletActivityFilterPreferences.decode(
            UserDefaults.standard.string(forKey: WalletActivityFilterPreferences.selectedNetworksKey)
                ?? WalletActivityFilterPreferences.defaultSelectedJSON
        ))
        _selectedSymbols = State(initialValue: WalletActivityFilterPreferences.decode(
            UserDefaults.standard.string(forKey: WalletActivityFilterPreferences.selectedSymbolsKey)
                ?? WalletActivityFilterPreferences.defaultSelectedJSON
        ))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                previewSection
                sortSection
                filterSection
                timeSection
                showSection
                amountSection
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
            .navigationDestination(for: WalletActivityFilterDestination.self) { destination in
                switch destination {
                case .networks:
                    WalletActivityNetworksPicker(availableNetworks: availableNetworks)
                case .assets:
                    WalletActivityAssetsPicker(availableSymbols: availableSymbols)
                }
            }
            .onChange(of: selectedNetworksJSON) { _, newValue in
                selectedNetworks = WalletActivityFilterPreferences.decode(newValue)
            }
            .onChange(of: selectedSymbolsJSON) { _, newValue in
                selectedSymbols = WalletActivityFilterPreferences.decode(newValue)
            }
            .onChange(of: timeRangeRaw) { _, newValue in
                // Switching to the custom window with no dates yet seeds
                // a sensible 30-day window so the date pickers show real
                // bounds the user can adjust, not a phantom "today."
                if newValue == WalletActivityFilterPreferences.TimeRange.custom.rawValue {
                    seedCustomWindowIfNeeded()
                }
            }
            .confirmationDialog(
                Text("Reset filter?"),
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    WalletActivityFilterPreferences.resetAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every Activity filter and sort choice. Continue?")
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
            .listRowBackground(UniColors.List.rowBackground)
        }
    }

    private var previewMessage: String {
        if visibleTransactions == totalTransactions {
            return String(
                format: String(localized: "Showing all %lld transactions"),
                Int64(totalTransactions)
            )
        }
        return String(
            format: String(localized: "Showing %lld of %lld transactions"),
            Int64(visibleTransactions),
            Int64(totalTransactions)
        )
    }

    // MARK: - Sort

    @ViewBuilder
    private var sortSection: some View {
        Section {
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text("Sort by")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Picker("Sort by", selection: sortKeyBinding) {
                    ForEach(WalletActivityFilterPreferences.SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniHaptic(.selection, trigger: sortKeyRaw)
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Sort")
        }
    }

    // MARK: - Filter (direction + status)

    @ViewBuilder
    private var filterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text("Direction")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Picker("Direction", selection: directionBinding) {
                    ForEach(WalletActivityFilterPreferences.TxDirection.allCases) { dir in
                        Text(dir.label).tag(dir)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniHaptic(.selection, trigger: directionRaw)
            .listRowBackground(UniColors.List.rowBackground)

            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text("Kind")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Picker("Kind", selection: kindBinding) {
                    ForEach(WalletActivityFilterPreferences.TxKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniHaptic(.selection, trigger: kindRaw)
            .listRowBackground(UniColors.List.rowBackground)

            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text("Status")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Picker("Status", selection: statusBinding) {
                    ForEach(WalletActivityFilterPreferences.TxStatus.allCases) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniHaptic(.selection, trigger: statusRaw)
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Filter")
        }
    }

    // MARK: - Time

    @ViewBuilder
    private var timeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text("Time range")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Picker("Time range", selection: timeRangeBinding) {
                    ForEach(WalletActivityFilterPreferences.TimeRange.allCases) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniHaptic(.selection, trigger: timeRangeRaw)
            .listRowBackground(UniColors.List.rowBackground)

            if timeRangeBinding.wrappedValue == .custom {
                DatePicker(
                    selection: customStartBinding,
                    in: ...customEndBinding.wrappedValue,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text("From")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                }
                .tint(UniColors.Tint.accent)
                .listRowBackground(UniColors.List.rowBackground)

                DatePicker(
                    selection: customEndBinding,
                    in: customStartBinding.wrappedValue...,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text("To")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                }
                .tint(UniColors.Tint.accent)
                .listRowBackground(UniColors.List.rowBackground)
            }
        } header: {
            Text("When")
        }
    }

    // MARK: - Show (networks + assets)

    @ViewBuilder
    private var showSection: some View {
        Section {
            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text("Asset type")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Picker("Asset type", selection: assetClassBinding) {
                    ForEach(WalletActivityFilterPreferences.AssetClass.allCases) { assetClass in
                        Text(assetClass.label).tag(assetClass)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniHaptic(.selection, trigger: assetClassRaw)
            .listRowBackground(UniColors.List.rowBackground)

            NavigationLink(value: WalletActivityFilterDestination.networks) {
                multiSelectLink(
                    systemImage: "globe",
                    title: "Networks",
                    readout: readout(selected: selectedNetworks.count, total: availableNetworks.count)
                )
            }
            .listRowBackground(UniColors.List.rowBackground)

            NavigationLink(value: WalletActivityFilterDestination.assets) {
                multiSelectLink(
                    systemImage: "bitcoinsign.circle",
                    title: "Assets",
                    readout: readout(selected: selectedSymbols.count, total: availableSymbols.count)
                )
            }
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Show")
        }
    }

    @ViewBuilder
    private func multiSelectLink(
        systemImage: String,
        title: LocalizedStringKey,
        readout: String
    ) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Text(verbatim: readout)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private func readout(selected: Int, total: Int) -> String {
        if selected == 0 {
            return String.apertureLocalized("All")
        }
        return String(
            format: String(localized: "%lld of %lld"),
            Int64(selected),
            Int64(total)
        )
    }

    // MARK: - Amount range

    @ViewBuilder
    private var amountSection: some View {
        Section {
            amountField(placeholder: "Minimum", text: $minFiat)
                .listRowBackground(UniColors.List.rowBackground)
            amountField(placeholder: "Maximum", text: $maxFiat)
                .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Amount")
        } footer: {
            Text("Filters by each transaction's value in \(currencyCode). Transactions with no known price are hidden while an amount filter is set.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func amountField(placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(verbatim: currencyCode)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(minWidth: 40, alignment: .leading)
                .monospacedDigit()
            UniTextField(
                placeholder: placeholder,
                text: text,
                fill: Color.clear,
                verticalPadding: UniSpacing.xs,
                showsChrome: false,
                keyboardType: .decimalPad
            )
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    // MARK: - Reset

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

    // MARK: - Custom window seeding

    /// Seed a 30-day window when the user first switches to `.custom`
    /// and no dates are stored, so the pickers show real, adjustable
    /// bounds rather than an implicit "today".
    private func seedCustomWindowIfNeeded() {
        guard customStart == 0, customEnd == 0 else { return }
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        customStart = start.timeIntervalSince1970
        customEnd = now.timeIntervalSince1970
    }

    // MARK: - Bindings

    private var sortKeyBinding: Binding<WalletActivityFilterPreferences.SortKey> {
        Binding(
            get: {
                WalletActivityFilterPreferences.SortKey(rawValue: sortKeyRaw)
                    ?? WalletActivityFilterPreferences.defaultSortKey
            },
            set: { sortKeyRaw = $0.rawValue }
        )
    }

    private var directionBinding: Binding<WalletActivityFilterPreferences.TxDirection> {
        Binding(
            get: {
                WalletActivityFilterPreferences.TxDirection(rawValue: directionRaw)
                    ?? WalletActivityFilterPreferences.defaultDirection
            },
            set: { directionRaw = $0.rawValue }
        )
    }

    private var statusBinding: Binding<WalletActivityFilterPreferences.TxStatus> {
        Binding(
            get: {
                WalletActivityFilterPreferences.TxStatus(rawValue: statusRaw)
                    ?? WalletActivityFilterPreferences.defaultStatus
            },
            set: { statusRaw = $0.rawValue }
        )
    }

    private var kindBinding: Binding<WalletActivityFilterPreferences.TxKind> {
        Binding(
            get: {
                WalletActivityFilterPreferences.TxKind(rawValue: kindRaw)
                    ?? WalletActivityFilterPreferences.defaultKind
            },
            set: { kindRaw = $0.rawValue }
        )
    }

    private var assetClassBinding: Binding<WalletActivityFilterPreferences.AssetClass> {
        Binding(
            get: {
                WalletActivityFilterPreferences.AssetClass(rawValue: assetClassRaw)
                    ?? WalletActivityFilterPreferences.defaultAssetClass
            },
            set: { assetClassRaw = $0.rawValue }
        )
    }

    private var timeRangeBinding: Binding<WalletActivityFilterPreferences.TimeRange> {
        Binding(
            get: {
                WalletActivityFilterPreferences.TimeRange(rawValue: timeRangeRaw)
                    ?? WalletActivityFilterPreferences.defaultTimeRange
            },
            set: { timeRangeRaw = $0.rawValue }
        )
    }

    /// Custom-start picker bound to the stored epoch. Keeps the selected
    /// date + time exact so Activity and PDF exports share the same window.
    private var customStartBinding: Binding<Date> {
        Binding(
            get: {
                customStart > 0
                    ? Date(timeIntervalSince1970: customStart)
                    : Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            },
            set: {
                let end = customEndBinding.wrappedValue
                customStart = min($0, end).timeIntervalSince1970
            }
        )
    }

    /// Custom-end picker bound to the stored epoch. Keeps the selected
    /// date + time exact so Activity and PDF exports share the same window.
    private var customEndBinding: Binding<Date> {
        Binding(
            get: {
                customEnd > 0
                    ? Date(timeIntervalSince1970: customEnd)
                    : Date()
            },
            set: {
                let start = customStartBinding.wrappedValue
                customEnd = max($0, start).timeIntervalSince1970
            }
        )
    }
}

// MARK: - Networks picker sub-screen

/// Network multi-select pushed from the filter sheet. Tap to toggle;
/// empty selection = "all networks" (the default sentinel).
private struct WalletActivityNetworksPicker: View {
    let availableNetworks: [SupportedChain]
    @AppStorage(WalletActivityFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON

    @State private var selectedNetworks: Set<String>

    init(availableNetworks: [SupportedChain]) {
        self.availableNetworks = availableNetworks
        _selectedNetworks = State(initialValue: WalletActivityFilterPreferences.decode(
            UserDefaults.standard.string(forKey: WalletActivityFilterPreferences.selectedNetworksKey)
                ?? WalletActivityFilterPreferences.defaultSelectedJSON
        ))
    }

    var body: some View {
        List {
            Section {
                Button {
                    selectedNetworksJSON = WalletActivityFilterPreferences.defaultSelectedJSON
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
                .listRowBackground(UniColors.List.rowBackground)
            }

            Section {
                ForEach(availableNetworks, id: \.rawValue) { chain in
                    networkRow(chain)
                        .listRowBackground(UniColors.List.rowBackground)
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
            selectedNetworks = WalletActivityFilterPreferences.decode(newValue)
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
        selectedNetworksJSON = WalletActivityFilterPreferences.encode(set)
    }
}

// MARK: - Assets picker sub-screen

/// Asset (token-symbol) multi-select pushed from the filter sheet. Tap
/// to toggle; empty selection = "all assets". Symbols are stored
/// UPPERCASED (the apply step compares uppercased) but shown in their
/// display casing.
private struct WalletActivityAssetsPicker: View {
    let availableSymbols: [String]
    @AppStorage(WalletActivityFilterPreferences.selectedSymbolsKey)
    private var selectedSymbolsJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON

    @State private var selectedSymbols: Set<String>

    init(availableSymbols: [String]) {
        self.availableSymbols = availableSymbols
        _selectedSymbols = State(initialValue: WalletActivityFilterPreferences.decode(
            UserDefaults.standard.string(forKey: WalletActivityFilterPreferences.selectedSymbolsKey)
                ?? WalletActivityFilterPreferences.defaultSelectedJSON
        ))
    }

    var body: some View {
        List {
            Section {
                Button {
                    selectedSymbolsJSON = WalletActivityFilterPreferences.defaultSelectedJSON
                } label: {
                    HStack {
                        Text("All assets")
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        if selectedSymbols.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(UniColors.Tint.accent)
                        }
                    }
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            Section {
                ForEach(availableSymbols, id: \.self) { symbol in
                    symbolRow(symbol)
                        .listRowBackground(UniColors.List.rowBackground)
                }
            } header: {
                Text("Assets")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Assets"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedSymbolsJSON) { _, newValue in
            selectedSymbols = WalletActivityFilterPreferences.decode(newValue)
        }
    }

    @ViewBuilder
    private func symbolRow(_ symbol: String) -> some View {
        Button {
            toggle(symbol)
        } label: {
            HStack(spacing: UniSpacing.s) {
                Text(verbatim: symbol)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                if selectedSymbols.contains(symbol.uppercased()) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(UniColors.Tint.accent)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
        }
        .accessibilityLabel(Text(verbatim: symbol))
    }

    private func toggle(_ symbol: String) {
        let key = symbol.uppercased()
        var set = selectedSymbols
        if set.contains(key) {
            set.remove(key)
        } else {
            set.insert(key)
        }
        selectedSymbolsJSON = WalletActivityFilterPreferences.encode(set)
    }
}

// MARK: - Destination enum

/// Navigation destinations the Activity filter sheet pushes onto its
/// own `NavigationStack`.
enum WalletActivityFilterDestination: Hashable, Codable {
    case networks
    case assets
}
