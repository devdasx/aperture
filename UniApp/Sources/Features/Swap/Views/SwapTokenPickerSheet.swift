import SwiftUI
import SwiftData

/// Token + chain picker for one side of a swap. **Mirrors the Receive
/// picker 100%** (Rule #2 — one pattern everywhere): asset-first → network.
/// Step 1 lists the app's curated assets + the user's custom tokens
/// (`SwapAsset.natives` / `SwapAsset.tokens`), restricted to the chains the
/// active wallet has an address on ∩ `SwapChainMap.swappableChains`. Native
/// rows pick directly (the network IS the chain); token rows push Step 2 — a
/// per-token network picker — so the handed-back `SwapToken` carries that
/// network's real contract + decimals (quote-valid).
///
/// **Provider search fallback (the new behavior).** When the search query is
/// non-empty, the curated list still filters locally AND, in parallel and
/// debounced (~400ms, off-main per Rule #28), the providers are queried via
/// `SwapQuoteService.searchTokens`. Provider hits that aren't already curated
/// render under a third "Search results" section and behave identically.
///
/// **Data layer (Rule #27).** Owns its own `@Query` for `AssetRecord` +
/// `CustomTokenRecord` + `WalletRecord`, exactly like `ReceiveAssetListView`
/// / `ReceiveView`, so the universe comes from the local store — never the
/// raw provider list. Marks resolve via `CoinMark` (Trust Wallet, Rule #7);
/// the honest initials chip is the only fallback. Search uses `.searchable`
/// with no `placement:` (Rule #14). Sheet is a native `NavigationStack` with
/// `.navigationTitle` (Rule #15). Every handed-back `SwapToken` comes from
/// `asset.swapToken(for:)` — never hand-built.
struct SwapTokenPickerSheet: View {
    /// The side being picked — only affects the title ("Swap from" / "to").
    enum Side { case from, to }
    let side: Side
    /// Holdings snapshot so rows show real balances + drive the high→low sort,
    /// identical to the Receive/Send pickers.
    let holdings: AssetPickerHoldings
    /// Picked `(chain, token)`. The sheet dismisses itself on selection.
    let onPick: (SwapToken) -> Void

    @Environment(\.dismiss) private var dismiss

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }

    var body: some View {
        NavigationStack {
            SwapAssetListStep(
                holdings: holdings,
                currencyCode: currencyCode,
                onPick: { token in
                    onPick(token)
                    dismiss()
                }
            )
            .navigationTitle(side == .from ? "Swap from" : "Swap to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Step 1 — asset list (mirrors ReceiveAssetListView)

/// Step 1: the asset list. "Native coins" + "Tokens" sections from the
/// curated catalog + custom tokens (swappable ∩ wallet-available), plus a
/// "Search results" section fed by the provider fallback while searching.
/// Native rows pick directly; token rows push the network step.
private struct SwapAssetListStep: View {
    let holdings: AssetPickerHoldings
    let currencyCode: String
    let onPick: (SwapToken) -> Void

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @Query(sort: [SortDescriptor(\CustomTokenRecord.symbol, order: .forward)])
    private var customTokenRecords: [CustomTokenRecord]
    @Query private var assetRecords: [AssetRecord]

    @State private var sortedNatives: [SwapAsset] = []
    @State private var sortedTokens: [SwapAsset] = []
    @State private var searchText: String = ""

    /// Provider-fallback results, folded into `SwapAsset` rows, minus
    /// anything already present in the curated universe. Rebuilt on each
    /// debounced query change via `.task(id: searchText)`.
    @State private var providerResults: [SwapAsset] = []
    @State private var isSearchingProvider: Bool = false

    private var rowsKey: String {
        "\(availableChains.map(\.rawValue).joined(separator: ","))|\(customTokenRecords.count)|\(assetRecords.count)|\(holdings.fingerprint)"
    }

    var body: some View {
        List {
            if availableChains.isEmpty {
                emptySection
            } else {
                let natives = filteredNatives
                let tokens = filteredTokens
                let provider = providerOnlyResults
                if natives.isEmpty && tokens.isEmpty && provider.isEmpty {
                    noResultsSection
                } else {
                    if !natives.isEmpty { nativeSection(natives) }
                    if !tokens.isEmpty { tokenSection(tokens) }
                    if !provider.isEmpty { providerSection(provider) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .searchable(text: $searchText, prompt: Text("Search"))
        .task(id: rowsKey) {
            let tokens = SwapAsset.tokens(
                availableChains: Set(availableChains),
                customTokens: customTokenRecords.map { CustomTokenSnapshot(from: $0) },
                catalogAssets: AssetCatalog.assets(from: assetRecords)
            )
            sortedTokens = AssetPickerSort.tokens(tokens, holdings: holdings)
            sortedNatives = AssetPickerSort.natives(
                SwapAsset.natives(availableChains: Set(availableChains)).chains(),
                holdings: holdings
            ).map { SwapAsset.native($0) }
        }
        .task(id: searchText) {
            await runProviderSearch()
        }
    }

    // MARK: - Provider fallback

    /// Debounced provider search. Fires only for a non-empty trimmed query;
    /// cancels/replaces automatically when the query changes (`.task(id:)`).
    /// Off-main (Rule #28); folds the flat result via
    /// `SwapAsset.fromProviderTokens`.
    private func runProviderSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            providerResults = []
            isSearchingProvider = false
            return
        }
        // Show the searching state immediately and drop the PREVIOUS query's
        // rows now — so there's no flash of "No token found" during the
        // debounce and no stale results from the prior query lingering.
        providerResults = []
        isSearchingProvider = true
        // Debounce — let the user keep typing without firing a request per
        // keystroke. A query change cancels this task before the sleep ends.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }

        let chains = availableChains
        let found = await SwapQuoteService.shared.searchTokens(query: query, chains: chains)
        guard !Task.isCancelled else { return }
        providerResults = SwapAsset.fromProviderTokens(found)
        isSearchingProvider = false
    }

    // MARK: - Filtering

    private var filteredNatives: [SwapAsset] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedNatives }
        return sortedNatives.filter { asset in
            guard case let .native(chain) = asset else { return false }
            return chain.displayName.localizedStandardContains(q)
                || chain.ticker.localizedStandardContains(q)
        }
    }

    private var filteredTokens: [SwapAsset] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedTokens }
        return sortedTokens.filter { asset in
            guard case let .token(symbol, name, _) = asset else { return false }
            return name.localizedStandardContains(q) || symbol.localizedStandardContains(q)
        }
    }

    /// Provider hits, minus the (symbol/coin, chain) pairs the curated
    /// universe ALREADY covers — at NETWORK granularity, not symbol. So a
    /// provider hit for a token we curate on some chains still surfaces its
    /// NEW chains (the whole point of the fallback): e.g. curated USDC on
    /// Ethereum/Base + a provider USDC on Solana yields a "Search results"
    /// USDC row carrying only Solana. A native coin we already list is
    /// dropped; a token whose every network is already curated is dropped.
    private var providerOnlyResults: [SwapAsset] {
        guard !providerResults.isEmpty else { return [] }

        // Coverage keys: "native.<chain>" for native rows, "<symbol>.<chain>"
        // for each network of a curated token row.
        var covered = Set<String>()
        for asset in sortedNatives {
            if case let .native(chain) = asset { covered.insert("native.\(chain.rawValue)") }
        }
        for asset in sortedTokens {
            if case let .token(symbol, _, networks) = asset {
                for network in networks { covered.insert("\(symbol).\(network.chain.rawValue)") }
            }
        }

        var residual: [SwapAsset] = []
        for asset in providerResults {
            switch asset {
            case let .native(chain):
                if !covered.contains("native.\(chain.rawValue)") { residual.append(asset) }
            case let .token(symbol, name, networks):
                let newNetworks = networks.filter { !covered.contains("\(symbol).\($0.chain.rawValue)") }
                if !newNetworks.isEmpty {
                    residual.append(.token(symbol: symbol, name: name, networks: newNetworks))
                }
            }
        }
        return residual
    }

    // MARK: - Sections

    @ViewBuilder
    private func nativeSection(_ assets: [SwapAsset]) -> some View {
        Section {
            ForEach(assets) { asset in
                if case let .native(chain) = asset {
                    nativeRow(asset, chain: chain)
                }
            }
        } header: {
            UniCaption(text: "Native coins", color: UniColors.Text.tertiary)
        }
    }

    @ViewBuilder
    private func tokenSection(_ tokens: [SwapAsset]) -> some View {
        Section {
            ForEach(tokens) { asset in
                tokenRow(asset)
            }
        } header: {
            UniCaption(text: "Tokens", color: UniColors.Text.tertiary)
        }
    }

    /// Provider results — a third section appearing only while searching.
    /// Native hits pick directly; token hits push the network step. An
    /// inline spinner shows while the provider request is in flight.
    @ViewBuilder
    private func providerSection(_ assets: [SwapAsset]) -> some View {
        Section {
            ForEach(assets) { asset in
                switch asset {
                case let .native(chain):
                    nativeRow(asset, chain: chain)
                case .token:
                    tokenRow(asset)
                }
            }
        } header: {
            HStack(spacing: UniSpacing.xs) {
                UniCaption(text: "Search results", color: UniColors.Text.tertiary)
                if isSearchingProvider {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Rows (reuse AssetPickerAssetRow — Receive/Send shared row)

    @ViewBuilder
    private func nativeRow(_ asset: SwapAsset, chain: SupportedChain) -> some View {
        Button {
            if let token = asset.swapToken(for: chain) { onPick(token) }
        } label: {
            AssetPickerAssetRow(
                fullName: chain.displayName,
                ticker: chain.ticker,
                logoChain: chain,
                logoContract: nil,
                totals: holdings.nativeTotals(chain: chain),
                currencyCode: currencyCode
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(UniColors.Background.secondary)
    }

    @ViewBuilder
    private func tokenRow(_ asset: SwapAsset) -> some View {
        if case let .token(symbol, name, _) = asset {
            NavigationLink {
                SwapNetworkPickerStep(
                    asset: asset,
                    holdings: holdings,
                    currencyCode: currencyCode,
                    onPick: onPick
                )
            } label: {
                AssetPickerAssetRow(
                    fullName: name,
                    ticker: symbol,
                    logoChain: asset.canonicalChainForLogo,
                    logoContract: asset.canonicalContract,
                    totals: holdings.aggregate(symbol: symbol),
                    currencyCode: currencyCode
                )
            }
            .listRowBackground(UniColors.Background.secondary)
        }
    }

    // MARK: - Empty / no-results

    @ViewBuilder
    private var noResultsSection: some View {
        Section {
            VStack(spacing: UniSpacing.s) {
                if isSearchingProvider {
                    ProgressView()
                    UniBody(
                        text: "Searching…",
                        alignment: .center,
                        color: UniColors.Text.secondary
                    )
                } else {
                    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    UniBody(
                        text: q.isEmpty ? "No swappable assets." : "No token found for “\(q)”.",
                        alignment: .center,
                        color: UniColors.Text.secondary
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xl)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var emptySection: some View {
        Section {
            VStack(spacing: UniSpacing.s) {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(UniColors.Icon.tertiary)
                UniBody(
                    text: "No swappable networks for this wallet yet.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                UniFootnote(
                    text: "Receive crypto on a network Aperture can swap on to get started.",
                    alignment: .center,
                    color: UniColors.Text.tertiary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, UniSpacing.xxl)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Derived universe (wallet chains ∩ swappable)

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    /// Chains the active wallet has a derived (non-empty) address on,
    /// intersected with the swappable set, in canonical order. Mirrors
    /// `ReceiveView.availableChains`, then `.filter(SwapChainMap.isSwappable)`.
    private var availableChains: [SupportedChain] {
        guard let wallet = activeWallet else { return [] }
        let chains: [SupportedChain] = wallet.addresses.compactMap { record in
            guard !record.address.isEmpty else { return nil }
            return SupportedChain(rawValue: record.chainRaw)
        }
        let set = Set(chains)
        return SupportedChain.allCases.filter { set.contains($0) && SwapChainMap.isSwappable($0) }
    }
}

// MARK: - Step 2 — network picker (mirrors ReceiveNetworkPickerView)

/// Step 2: the per-token network picker. Lists `asset.chains` (the token's
/// swappable networks) using the shared `AssetPickerNetworkRow`, sorted by
/// per-network balance high→low. Tapping a network resolves the quote-valid
/// `SwapToken` via `asset.swapToken(for:)` and picks it. Searchable by
/// network name (Rule #14); title "Choose network for <SYMBOL>".
private struct SwapNetworkPickerStep: View {
    let asset: SwapAsset
    let holdings: AssetPickerHoldings
    let currencyCode: String
    let onPick: (SwapToken) -> Void

    @State private var searchText: String = ""

    private var symbol: String {
        if case let .token(symbol, _, _) = asset { return symbol }
        return ""
    }

    private var sortedChains: [SupportedChain] {
        AssetPickerSort.networks(asset.chains, symbol: symbol, holdings: holdings)
    }

    private var filteredChains: [SupportedChain] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sortedChains }
        return sortedChains.filter {
            $0.displayName.localizedStandardContains(q) || $0.ticker.localizedStandardContains(q)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredChains, id: \.self) { chain in
                    Button {
                        if let token = asset.swapToken(for: chain) { onPick(token) }
                    } label: {
                        AssetPickerNetworkRow(
                            chain: chain,
                            subtitle: "Swap on this network",
                            totals: holdings.perNetwork(symbol: symbol, chain: chain),
                            currencyCode: currencyCode
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                    .accessibilityLabel(Text(verbatim: chain.displayName))
                    .accessibilityHint(Text("Swap \(symbol) on this network"))
                }
            } footer: {
                UniFootnote(
                    text: "Picking a different network than the other side bridges across chains.",
                    color: UniColors.Text.tertiary
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, UniSpacing.xs)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .searchable(text: $searchText, prompt: Text("Search"))
        .navigationTitle(Text("Choose network for \(symbol)"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Small helper

private extension Array where Element == SwapAsset {
    /// Collapse `.native` rows back to their chains (the sort helper works
    /// on `[SupportedChain]`).
    func chains() -> [SupportedChain] {
        compactMap { if case let .native(chain) = $0 { return chain } else { return nil } }
    }
}
