import SwiftUI

/// Token + chain picker for one side of a swap. A native two-step
/// `NavigationStack` sheet (Rule #15): pick the **network** first, then
/// the **token** on that network. Choosing a different chain than the
/// opposite side turns the swap into a BRIDGE — the screen surfaces that.
///
/// **Real data.** The token list comes from `SwapQuoteService.tokens(for:)`
/// (Li.Fi `/tokens` for EVM, Jupiter's verified list for Solana), cached
/// by the service. Marks resolve via `CoinMark` (Trust Wallet, Rule #7);
/// the picker passes each token's contract so registry + long-tail tokens
/// both get a real mark with the honest initials-chip fallback.
///
/// **Search (Rule #14).** `.searchable` with no `placement:` — the system
/// owns it (bottom-floating Liquid Glass on iPhone). Filtering is
/// locale-aware (`localizedStandardContains`) across symbol + name +
/// address so a user can find a token by ticker, name, or contract.
struct SwapTokenPickerSheet: View {
    /// The side being picked — only affects the title ("Swap from" / "to").
    enum Side { case from, to }
    let side: Side
    /// The chains the user can swap on (EVM subset + Solana).
    let swappableChains: [SupportedChain]
    /// Holdings snapshot so the network step can show real balances + sort
    /// the chains the wallet actually holds value on to the top.
    let holdings: AssetPickerHoldings
    /// Picked `(chain, token)`. The sheet dismisses itself on selection.
    let onPick: (SwapToken) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SwapChainPickerStep(
                swappableChains: swappableChains,
                holdings: holdings,
                onPickToken: { token in
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

// MARK: - Step 1 — network picker

/// The network step: pick which chain to swap on. The native coin row sits
/// at the top of each chain so the most common pick (swap the native asset)
/// is one tap; tapping a chain pushes its token list.
private struct SwapChainPickerStep: View {
    let swappableChains: [SupportedChain]
    let holdings: AssetPickerHoldings
    /// Final token selection (bubbles up from the token step).
    let onPickToken: (SwapToken) -> Void

    @State private var searchText = ""

    private var sortedChains: [SupportedChain] {
        AssetPickerSort.natives(swappableChains, holdings: holdings)
    }

    private var filteredChains: [SupportedChain] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sortedChains }
        return sortedChains.filter { chain in
            chain.displayName.localizedStandardContains(query)
                || chain.ticker.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredChains, id: \.self) { chain in
                    NavigationLink {
                        SwapTokenListStep(chain: chain, holdings: holdings, onPickToken: onPickToken)
                    } label: {
                        chainRow(chain)
                    }
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Pick a network, then the token. Choosing a different network than the other side bridges across chains.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .searchable(text: $searchText, prompt: Text("Search networks"))
    }

    private func chainRow(_ chain: SupportedChain) -> some View {
        let totals = holdings.nativeTotals(chain: chain)
        return HStack(spacing: UniSpacing.s) {
            CoinMark(chain: chain, tokenSymbol: chain.ticker)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: chain.ticker)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            Spacer(minLength: UniSpacing.s)
            if totals.hasBalance {
                Text(verbatim: WalletFormatting.fiat(totals.fiat, currencyCode: currencyCode))
                    .font(UniTypography.footnote.monospacedDigit())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}

// MARK: - Step 2 — token list for a chain

/// The token step: list `SwapQuoteService.tokens(for:)` for the chosen
/// chain, native coin first, searchable. Loading shows the native spinner;
/// an empty result (provider down / unsupported) shows the honest empty
/// state instead of a blank pane (Rule #16).
private struct SwapTokenListStep: View {
    let chain: SupportedChain
    let holdings: AssetPickerHoldings
    let onPickToken: (SwapToken) -> Void

    @State private var tokens: [SwapToken] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private var filteredTokens: [SwapToken] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tokens }
        return tokens.filter { token in
            token.symbol.localizedStandardContains(query)
                || token.name.localizedStandardContains(query)
                || token.address.localizedStandardContains(query)
        }
    }

    var body: some View {
        Group {
            if isLoading && tokens.isEmpty {
                UniLoadingState(caption: "Loading \(chain.displayName) tokens…")
            } else if tokens.isEmpty {
                UniEmptyState(
                    title: "No tokens available",
                    detail: "Aperture couldn't load the swappable tokens for \(chain.displayName) right now. Check your connection and try again.",
                    mark: .icon(systemName: "tray")
                )
                .padding(UniSpacing.l)
            } else {
                tokenList
            }
        }
        .background(UniColors.Background.primary)
        .navigationTitle(Text(verbatim: chain.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var tokenList: some View {
        List {
            Section {
                ForEach(filteredTokens) { token in
                    Button {
                        onPickToken(token)
                    } label: {
                        tokenRow(token)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: Text("Search tokens"))
    }

    private func tokenRow(_ token: SwapToken) -> some View {
        let totals = holdings.perNetwork(symbol: token.symbol, chain: chain)
        return HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: token.chain,
                tokenSymbol: token.symbol,
                contract: token.isNative ? nil : token.address,
                customIconURL: token.logoURI
            )
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: token.symbol)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                Text(verbatim: token.name)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: UniSpacing.s)
            if totals.hasBalance {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: WalletFormatting.native(totals.native, decimals: token.decimals))
                        .font(UniTypography.footnote.monospacedDigit())
                        .foregroundStyle(UniColors.Text.secondary)
                    Text(verbatim: WalletFormatting.fiat(totals.fiat, currencyCode: currencyCode))
                        .font(UniTypography.caption1.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                }
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
        .contentShape(Rectangle())
    }

    private func load() async {
        isLoading = true
        var fetched = await SwapQuoteService.shared.tokens(for: chain)
        // Guarantee the native coin is offered even if the provider list
        // omits it, and pin it to the top.
        if let native = SwapChainMap.nativeToken(for: chain) {
            fetched.removeAll { $0.isNative }
            fetched.insert(native, at: 0)
        }
        guard !Task.isCancelled else { return }
        tokens = fetched
        isLoading = false
    }

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }
}
