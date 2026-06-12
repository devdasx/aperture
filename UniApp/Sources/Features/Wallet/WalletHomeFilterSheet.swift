import SwiftUI
import SwiftData

/// **The Filter & Sort sheet** for the wallet home. Single screen
/// hosting every preference that shapes how holdings render: view
/// mode (split vs combined), asset type, sort key + direction,
/// grouping, the only-with-balance toggle, the min-value threshold,
/// the networks multi-select, the two visibility editors (Hidden
/// assets, Hidden chains), and the pinned-assets roster. A
/// destructive "Reset to defaults" CTA at the bottom wipes every
/// preference this feature owns, behind a `.confirmationDialog`
/// gate so the user can pull back.
///
/// **Design intent (Rule #2 §D.1):** put one screen between the
/// user and every shape decision the wallet home can take, so they
/// pick once and the home reflects the choice everywhere — quietly
/// and immediately.
///
/// **Layout (Rule #15).** Sheet-as-screen — a `NavigationStack`
/// hosts the body so iOS owns the title chrome and the toolbar.
/// `.navigationTitle("Filter & Sort")` carries the title;
/// `.navigationBarTitleDisplayMode(.inline)` keeps the bar compact
/// at the `.large` detent (which is what nav-shaped sheets use per
/// M-008). The body is a `List(.insetGrouped)` so every section
/// reads as the same chrome the rest of the Settings family
/// presents. A leading `Cancel` lives in `.topBarLeading` —
/// **there is no `Done`** because every control writes through
/// `@AppStorage` in place, so "done" is "now." That's the honest
/// shape (Rule #2 §A.7) and the iOS-native pattern for "live
/// preferences" sheets.
///
/// **Live preview header (Rule #2 §A.2).** Sits above the three
/// sections. Says "Showing N of M assets" (or "Showing all M
/// assets" when nothing's hidden + the zero-balance filter is
/// off, or "Found N for query" when a search is active). M is the
/// total supported (coins + tokens across every registry); N is
/// the post-filter count. Recomputes on every preference change
/// because every dependency is read by the view body.
///
/// **Live propagation.** Every `@AppStorage` write here is read by
/// `WalletHomeView`'s body (also bound via `@AppStorage`), so the
/// home's holdings list updates the moment the user toggles a
/// preference here — even though this sheet is presented over the
/// home. No "save and close" round-trip.
///
/// **Rule #14 (search).** The sheet itself has no search field —
/// it's a control screen. The Hidden Assets and Networks sub-
/// screens DO carry `.searchable` (per Rule #14) for their long
/// rosters. The wallet home itself ALSO carries `.searchable`
/// (added 2026-06-09 alongside this v2 extension) — the sheet
/// reads the wallet-home's active query through `searchPreview`
/// when it composes the live preview message.
///
/// **Rule #12 §G.** The sheet's content is keyed on the direction-
/// only `sheetDirectionKey` at the call site so an LTR↔RTL flip
/// rebuilds the host while preserving the user's nav-stack
/// position inside.
struct WalletHomeFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Live preview query — when the wallet-home's search field has
    /// a value, the parent passes it through so the preview message
    /// reads "Found N for query" instead of "Showing N of M." Empty
    /// string means no search active. The sheet does NOT own the
    /// search field; it only reads its value.
    let searchPreview: String

    init(searchPreview: String = "") {
        self.searchPreview = searchPreview
    }

    @AppStorage(WalletHomeFilterPreferences.viewModeKey)
    private var viewModeRaw: String = WalletHomeFilterPreferences.defaultViewMode.rawValue
    @AppStorage(WalletHomeFilterPreferences.sortKeyKey)
    private var sortKeyRaw: String = WalletHomeFilterPreferences.defaultSortKey.rawValue
    @AppStorage(WalletHomeFilterPreferences.sortDirectionKey)
    private var sortDirectionRaw: String = WalletHomeFilterPreferences.defaultSortDirection.rawValue
    @AppStorage(WalletHomeFilterPreferences.onlyWithBalanceKey)
    private var onlyWithBalance: Bool = WalletHomeFilterPreferences.defaultOnlyWithBalance
    @AppStorage(WalletHomeFilterPreferences.hiddenAssetsKey)
    private var hiddenAssetsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    @AppStorage(WalletHomeFilterPreferences.hiddenChainsKey)
    private var hiddenChainsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    // v2 storage
    @AppStorage(WalletHomeFilterPreferences.assetTypeKey)
    private var assetTypeRaw: String = WalletHomeFilterPreferences.defaultAssetType.rawValue
    @AppStorage(WalletHomeFilterPreferences.groupByKey)
    private var groupByRaw: String = WalletHomeFilterPreferences.defaultGroupBy.rawValue
    @AppStorage(WalletHomeFilterPreferences.minFiatThresholdKey)
    private var minFiatThresholdRaw: Double = WalletHomeFilterPreferences.defaultMinFiatThreshold
    @AppStorage(WalletHomeFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    @AppStorage(WalletHomeFilterPreferences.pinnedAssetsKey)
    private var pinnedAssetsJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON

    @AppStorage(CurrencyPreference.storageKey)
    private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]

    @State private var isShowingResetConfirmation: Bool = false

    // MARK: - Memoized derived state (computed off-body)
    //
    // The live preview used to rebuild the FULL coin + token row
    // sets and run the filter pipeline inside a computed property
    // read by `body` — re-running on every body pass (and 5-7 JSON
    // decodes alongside it for the count badges). The derived
    // values now live in `@State`, recomputed only when an actual
    // dependency changes via `.task(id: previewRebuildKey)` (which
    // also debounces a live search query by task cancellation).
    @State private var previewMessage: String = ""
    @State private var hiddenAssetCount: Int = 0
    @State private var hiddenChainCount: Int = 0
    @State private var pinnedAssetCount: Int = 0
    @State private var networksReadout: String = ""

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
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: FilterDestination.self) { destination in
                switch destination {
                case .networks:      WalletHomeNetworksView()
                case .minValue:      WalletHomeMinValueView()
                case .hiddenAssets:  WalletHomeHiddenAssetsView()
                case .hiddenChains:  WalletHomeHiddenChainsView()
                case .pinnedAssets:  WalletHomePinnedAssetsView()
                }
            }
            .confirmationDialog(
                Text("Reset filter?"),
                isPresented: $isShowingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    WalletHomeFilterPreferences.resetAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every filter and sort choice. Continue?")
            }
            // Synchronous first fill so the preview row never
            // renders empty on the appearance frame; the keyed task
            // below owns every subsequent recompute.
            .onAppear { refreshDerivedState() }
            .task(id: previewRebuildKey) {
                // Debounce while a live search query is active — a
                // new keystroke changes the id, cancels this task,
                // and restarts the clock. Preference toggles (empty
                // query) recompute immediately.
                if !searchPreview.isEmpty {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                }
                refreshDerivedState()
            }
        }
    }

    // MARK: - Preview header

    /// Live-preview header. One short sentence that always tells
    /// the user how many assets are currently visible vs. how many
    /// exist. Restraint, not noise — the user reads it once per
    /// visit, sees the impact of each toggle in place.
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

    // MARK: - View section (Style + Type + Sort + Order + Group)

    /// "View" section. Style (split/combined), Type (all/coins/
    /// tokens), Sort by (5 keys), Order (asc/desc), Group (none/
    /// chain).
    @ViewBuilder
    private var viewSection: some View {
        Section {
            stylePicker
                .listRowBackground(UniColors.Background.secondary)
            assetTypePicker
                .listRowBackground(UniColors.Background.secondary)
            sortKeyPicker
                .listRowBackground(UniColors.Background.secondary)
            sortDirectionPicker
                .listRowBackground(UniColors.Background.secondary)
            groupByPicker
                .listRowBackground(UniColors.Background.secondary)
        } header: {
            Text("View")
        } footer: {
            if currentViewMode == .split {
                Text("Grouping applies in Combined view.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Split / Combined picker.
    @ViewBuilder
    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Style")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Style", selection: viewModeBinding) {
                ForEach(WalletHomeFilterPreferences.ViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: viewModeRaw)
    }

    /// All / Coins / Tokens picker.
    @ViewBuilder
    private var assetTypePicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Type")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Type", selection: assetTypeBinding) {
                ForEach(WalletHomeFilterPreferences.AssetType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: assetTypeRaw)
    }

    /// "Sort by" picker — 5 keys, segmented when room allows;
    /// segmented control with 5 short labels reads cleanly on
    /// iPhone widths.
    @ViewBuilder
    private var sortKeyPicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Sort by")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Sort by", selection: sortKeyBinding) {
                ForEach(WalletHomeFilterPreferences.SortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: sortKeyRaw)
    }

    /// Ascending / Descending picker.
    @ViewBuilder
    private var sortDirectionPicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Order")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Order", selection: sortDirectionBinding) {
                ForEach(WalletHomeFilterPreferences.SortDirection.allCases) { dir in
                    Text(dir.label).tag(dir)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniHaptic(.selection, trigger: sortDirectionRaw)
    }

    /// None / Chain picker. Disabled in `.split` view mode — the
    /// Coins/Tokens split is already a grouping there, so the
    /// picker would be a no-op. The footer below the section
    /// names this for the user.
    @ViewBuilder
    private var groupByPicker: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text("Group")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker("Group", selection: groupByBinding) {
                ForEach(WalletHomeFilterPreferences.GroupBy.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .disabled(currentViewMode == .split)
        .opacity(currentViewMode == .split ? 0.5 : 1.0)
        .uniHaptic(.selection, trigger: groupByRaw)
    }

    // MARK: - Show section (toggle + 5 nav links)

    /// "Show" section — the only-with-balance toggle, Min value
    /// link, Networks link, Hidden assets link, Hidden chains
    /// link, Pinned assets link.
    @ViewBuilder
    private var showSection: some View {
        Section {
            onlyWithBalanceToggle
                .listRowBackground(UniColors.Background.secondary)

            NavigationLink(value: FilterDestination.minValue) {
                minValueLink
            }
            .listRowBackground(UniColors.Background.secondary)

            NavigationLink(value: FilterDestination.networks) {
                networksLink
            }
            .listRowBackground(UniColors.Background.secondary)

            NavigationLink(value: FilterDestination.hiddenAssets) {
                hiddenAssetsLink
            }
            .listRowBackground(UniColors.Background.secondary)

            NavigationLink(value: FilterDestination.hiddenChains) {
                hiddenChainsLink
            }
            .listRowBackground(UniColors.Background.secondary)

            NavigationLink(value: FilterDestination.pinnedAssets) {
                pinnedAssetsLink
            }
            .listRowBackground(UniColors.Background.secondary)
        } header: {
            Text("Show")
        } footer: {
            Text("Hidden assets and chains stay in your wallet — only the wallet-home display changes. Bring them back any time.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Only with balance" toggle row.
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

    /// "Min value" link — leading dollar-sign glyph, trailing
    /// localized threshold readout.
    @ViewBuilder
    private var minValueLink: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "dollarsign")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text("Min value")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Text(verbatim: minValueReadout)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    /// "Networks" link — leading globe glyph, trailing N-of-M
    /// readout. When `selectedNetworks` is empty (the "all
    /// networks" sentinel), reads "All".
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

    /// "Hidden assets" navigation row with the count badge.
    @ViewBuilder
    private var hiddenAssetsLink: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "eye.slash")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text("Hidden assets")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            if hiddenAssetCount > 0 {
                Text(verbatim: "\(hiddenAssetCount)")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    /// "Hidden chains" navigation row with the count badge.
    @ViewBuilder
    private var hiddenChainsLink: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "network.slash")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text("Hidden chains")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            if hiddenChainCount > 0 {
                Text(verbatim: "\(hiddenChainCount)")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    /// "Pinned assets" navigation row with the count badge.
    @ViewBuilder
    private var pinnedAssetsLink: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "pin")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text("Pinned assets")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            if pinnedAssetCount > 0 {
                Text(verbatim: "\(pinnedAssetCount)")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    // MARK: - Reset section

    /// Reset to defaults. Destructive variant; tap presents the
    /// confirmation dialog above before any writes happen.
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

    // MARK: - Preview-message computation (off-body)

    /// Dependency key for the memoized derived state. Joins every
    /// persisted preference this sheet reads plus the currency, the
    /// active wallet, and the live search query — any change flips
    /// the key and re-fires the `.task(id:)` recompute. Building
    /// the joined string per body pass is trivially cheap next to
    /// the row construction it gates.
    private var previewRebuildKey: String {
        [
            viewModeRaw,
            sortKeyRaw,
            sortDirectionRaw,
            String(onlyWithBalance),
            hiddenAssetsJSON,
            hiddenChainsJSON,
            assetTypeRaw,
            groupByRaw,
            String(minFiatThresholdRaw),
            selectedNetworksJSON,
            pinnedAssetsJSON,
            currencyCode,
            activeWalletIdRaw,
            searchPreview
        ].joined(separator: "\u{1F}")
    }

    /// Recompute every memoized derived value in one pass: the live
    /// preview message (full row construction + filter pipeline),
    /// the three count badges, and the Networks readout. Runs from
    /// `.onAppear` and the keyed `.task` — never from `body`.
    private func refreshDerivedState() {
        previewMessage = computePreviewMessage()
        hiddenAssetCount = WalletHomeFilterPreferences.decode(hiddenAssetsJSON).count
        hiddenChainCount = WalletHomeFilterPreferences.decode(hiddenChainsJSON).count
        pinnedAssetCount = WalletHomeFilterPreferences.decode(pinnedAssetsJSON).count
        networksReadout = computeNetworksReadout()
    }

    /// Live preview message at the top of the sheet. Three shapes:
    ///
    /// 1. Search active — "Found N for query"
    /// 2. No filter active — "Showing all M assets"
    /// 3. Otherwise — "Showing N of M assets" (with the optional
    ///    "(zero balances hidden)" suffix when the toggle is on)
    private func computePreviewMessage() -> String {
        let inputs = currentInputs
        let coinRows = WalletSupportedRowBuilders.coinRows(
            heldRows: heldRows,
            currencyCode: currencyCode
        )
        let tokenRows = WalletSupportedRowBuilders.tokenRows(
            heldRows: heldRows,
            currencyCode: currencyCode
        )
        let totalSupported = coinRows.count + tokenRows.count
        let filteredCoins = WalletHomeFilterApply.apply(coins: coinRows, with: inputs)
        let filteredTokens = WalletHomeFilterApply.apply(tokens: tokenRows, with: inputs)
        let visible = filteredCoins.count + filteredTokens.count

        // Search-active shape wins first.
        let trimmedQuery = searchPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            return String(
                format: String(localized: "Found %lld for \"%@\""),
                Int64(visible),
                trimmedQuery
            )
        }

        let nothingHidden = (visible == totalSupported)
        let zeroBalanceHidden = inputs.onlyWithBalance

        if nothingHidden && !zeroBalanceHidden {
            return String(
                format: String(localized: "Showing all %lld assets"),
                Int64(totalSupported)
            )
        }
        if zeroBalanceHidden {
            return String(
                format: String(localized: "Showing %lld of %lld assets (zero balances hidden)"),
                Int64(visible),
                Int64(totalSupported)
            )
        }
        return String(
            format: String(localized: "Showing %lld of %lld assets"),
            Int64(visible),
            Int64(totalSupported)
        )
    }

    /// Localized readout for the Min value link's trailing slot.
    /// "Show all" when the threshold is 0; otherwise the currency-
    /// formatted threshold (e.g., "Under $10").
    private var minValueReadout: String {
        let option = WalletHomeFilterPreferences.MinFiatOption(rawValue: minFiatThresholdRaw)
        if let preset = option {
            return preset.label(currencyCode: currencyCode)
        }
        // Custom value — format and prefix.
        let value = Decimal(minFiatThresholdRaw).formatted(.currency(code: currencyCode))
        return String.apertureLocalized("Under \(value)")
    }

    /// Localized readout for the Networks link's trailing slot.
    /// "All" when the sentinel is in effect; "N of M" otherwise.
    /// Cached into the `networksReadout` `@State` by
    /// `refreshDerivedState()`.
    private func computeNetworksReadout() -> String {
        let selected = WalletHomeFilterPreferences.decode(selectedNetworksJSON)
        if selected.isEmpty {
            return String.apertureLocalized("All")
        }
        // Subtract the "none" sentinel from the count if present.
        let realCount = selected.subtracting([WalletHomeNetworksView.noneSentinel]).count
        return String(
            format: String(localized: "%lld of %lld"),
            Int64(realCount),
            Int64(SupportedChain.allCases.count)
        )
    }

    // MARK: - Bindings

    /// Bridge `String` `@AppStorage` to the typed enum picker.
    private var viewModeBinding: Binding<WalletHomeFilterPreferences.ViewMode> {
        Binding(
            get: {
                WalletHomeFilterPreferences.ViewMode(rawValue: viewModeRaw)
                    ?? WalletHomeFilterPreferences.defaultViewMode
            },
            set: { viewModeRaw = $0.rawValue }
        )
    }

    private var assetTypeBinding: Binding<WalletHomeFilterPreferences.AssetType> {
        Binding(
            get: {
                WalletHomeFilterPreferences.AssetType(rawValue: assetTypeRaw)
                    ?? WalletHomeFilterPreferences.defaultAssetType
            },
            set: { assetTypeRaw = $0.rawValue }
        )
    }

    private var sortKeyBinding: Binding<WalletHomeFilterPreferences.SortKey> {
        Binding(
            get: {
                WalletHomeFilterPreferences.SortKey(rawValue: sortKeyRaw)
                    ?? WalletHomeFilterPreferences.defaultSortKey
            },
            set: { sortKeyRaw = $0.rawValue }
        )
    }

    private var sortDirectionBinding: Binding<WalletHomeFilterPreferences.SortDirection> {
        Binding(
            get: {
                WalletHomeFilterPreferences.SortDirection(rawValue: sortDirectionRaw)
                    ?? WalletHomeFilterPreferences.defaultSortDirection
            },
            set: { sortDirectionRaw = $0.rawValue }
        )
    }

    private var groupByBinding: Binding<WalletHomeFilterPreferences.GroupBy> {
        Binding(
            get: {
                WalletHomeFilterPreferences.GroupBy(rawValue: groupByRaw)
                    ?? WalletHomeFilterPreferences.defaultGroupBy
            },
            set: { groupByRaw = $0.rawValue }
        )
    }

    // MARK: - Derived state

    private var currentViewMode: WalletHomeFilterPreferences.ViewMode {
        WalletHomeFilterPreferences.ViewMode(rawValue: viewModeRaw)
            ?? WalletHomeFilterPreferences.defaultViewMode
    }

    private var currentInputs: WalletHomeFilterApply.Inputs {
        WalletHomeFilterApply.Inputs(
            viewMode: viewModeBinding.wrappedValue,
            sortKey: sortKeyBinding.wrappedValue,
            direction: sortDirectionBinding.wrappedValue,
            onlyWithBalance: onlyWithBalance,
            hiddenAssets: WalletHomeFilterPreferences.decode(hiddenAssetsJSON),
            hiddenChains: WalletHomeFilterPreferences.decode(hiddenChainsJSON),
            assetType: assetTypeBinding.wrappedValue,
            groupBy: groupByBinding.wrappedValue,
            minFiatThreshold: Decimal(minFiatThresholdRaw),
            selectedNetworks: WalletHomeFilterPreferences.decode(selectedNetworksJSON),
            pinnedAssets: WalletHomeFilterPreferences.decode(pinnedAssetsJSON),
            searchText: searchPreview
        )
    }

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    private var heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)] {
        guard let wallet = activeWallet else { return [] }
        var result: [(SupportedChain, TokenBalanceRecord)] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for balance in address.balances where !balance.rawBalance.isEmpty {
                result.append((chain, balance))
            }
        }
        return result
    }
}

// MARK: - Filter destination

/// Navigation destinations the filter sheet pushes onto its own
/// `NavigationStack`. Five values today; future sub-screens
/// extend this enum.
enum FilterDestination: Hashable, Codable {
    case networks
    case minValue
    case hiddenAssets
    case hiddenChains
    case pinnedAssets
}
