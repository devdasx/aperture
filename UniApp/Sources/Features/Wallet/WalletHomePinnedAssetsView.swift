import SwiftUI
import SwiftData

/// **Pinned assets sub-screen** — the roster of assets the user has
/// pinned to the top of the wallet-home holdings list. Pushed onto
/// the filter sheet's `NavigationStack` via the "Pinned assets"
/// row.
///
/// **Design intent (Rule #2 §D.1):** show the user every pin
/// they've placed, on one screen, with a one-tap path to unpin
/// any of them. The pinning itself happens elsewhere — primarily
/// via swipe-actions on `WalletHomeHiddenAssetsView`'s rows
/// (Mail / Reminders idiom) — but this screen is where the user
/// audits and curates the pinned set.
///
/// **Honesty (Rule #2 §A.7).** When the user has nothing pinned,
/// the screen renders a calm `UniEmptyState` instead of an empty
/// list. The detail copy hints at where to pin from — the swipe
/// action on the Hidden Assets sub-screen — so the user discovers
/// the affordance without it being announced.
///
/// **Row anatomy.** 36pt asset mark + symbol + chain (or chain
/// name + ticker for coins) + a trailing pin glyph that doubles
/// as the unpin button. Tapping a row's pin clears it and the row
/// disappears; the rest reflow.
///
/// **Layout (Rule #15 §A).** Pushed sub-screen — does NOT wrap its
/// content in a `NavigationStack`. The parent sheet owns the stack
/// and the sub-screen consumes it.
struct WalletHomePinnedAssetsView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey)
    private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage(WalletHomeFilterPreferences.pinnedAssetsKey)
    private var pinnedJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON

    // MARK: - Memoized pinned rows (computed off-body)
    //
    // The roster used to construct EVERY supported coin + token row
    // per body pass just to keep the N pinned ones. The rows now
    // live in `@State`, rebuilt only when a dependency changes via
    // the keyed `.task` (pinned set, currency, active wallet) — the
    // body just renders the cached arrays. The empty/list branch
    // keys off the cheap decoded pinned set so the right branch
    // renders on the very first frame.
    @State private var pinnedCoins: [WalletCoinSupportedRow] = []
    @State private var pinnedTokens: [WalletTokenSupportedDisplayRow] = []

    var body: some View {
        Group {
            if pinnedSet.isEmpty {
                emptyState
            } else {
                pinnedList
            }
        }
        .navigationTitle(Text("Pinned assets"))
        .navigationBarTitleDisplayMode(.large)
        .uniHaptic(.selection, trigger: pinnedJSON)
        // Synchronous first fill so the rows are present on the
        // appearance frame; the keyed task owns subsequent rebuilds.
        .onAppear { rebuildRows() }
        .task(id: rowsRebuildKey) { rebuildRows() }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        List {
            Section {
                UniEmptyState(
                    title: "Nothing pinned yet.",
                    detail: "Swipe a row in Hidden assets to pin it to the top of your wallet home."
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
    }

    // MARK: - Pinned list

    @ViewBuilder
    private var pinnedList: some View {
        List {
            if !pinnedCoins.isEmpty {
                Section {
                    ForEach(pinnedCoins, id: \.chain) { row in
                        PinnedAssetRow(
                            leadingMark: AnyView(coinMark(for: row.chain)),
                            title: row.chain.displayName,
                            subtitle: row.chain.ticker,
                            unpin: { unpin(coin: row) }
                        )
                        .listRowBackground(UniColors.Background.secondary)
                    }
                } header: {
                    Text("Coins")
                }
            }
            if !pinnedTokens.isEmpty {
                Section {
                    ForEach(pinnedTokens, id: \.id) { row in
                        PinnedAssetRow(
                            leadingMark: AnyView(tokenMark(for: row)),
                            title: "\(row.symbol) — \(row.name)",
                            subtitle: row.chain.displayName,
                            unpin: { unpin(token: row) }
                        )
                        .listRowBackground(UniColors.Background.secondary)
                    }
                } header: {
                    Text("Tokens")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
    }

    // MARK: - Row builders

    @ViewBuilder
    private func coinMark(for chain: SupportedChain) -> some View {
        CoinMark(chain: chain, tokenSymbol: chain.ticker, contract: nil)
            .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private func tokenMark(for row: WalletTokenSupportedDisplayRow) -> some View {
        CoinMark(chain: row.chain, tokenSymbol: row.symbol, contract: row.contract)
            .frame(width: 36, height: 36)
    }

    // MARK: - Derived rows (the active wallet's pinned subset)

    /// Decoded pinned set. Cheap per-body read — the decode result
    /// is content-cached by `WalletHomeFilterPreferences.decode`.
    private var pinnedSet: Set<String> {
        WalletHomeFilterPreferences.decode(pinnedJSON)
    }

    /// Rebuild trigger for the memoized rows — pinned roster,
    /// display currency, or active wallet changing re-fires the
    /// keyed `.task`.
    private var rowsRebuildKey: String {
        [pinnedJSON, currencyCode, activeWalletIdRaw].joined(separator: "\u{1F}")
    }

    /// Construct the full supported-row sets once and keep only the
    /// pinned subset. Called from `.onAppear` and the keyed `.task`
    /// — never from `body`.
    private func rebuildRows() {
        let set = pinnedSet
        guard !set.isEmpty else {
            pinnedCoins = []
            pinnedTokens = []
            return
        }
        let held = heldRows
        pinnedCoins = WalletSupportedRowBuilders
            .coinRows(heldRows: held, currencyCode: currencyCode)
            .filter { set.contains(WalletHomeFilterPreferences.assetID(coin: $0)) }
        pinnedTokens = WalletSupportedRowBuilders
            .tokenRows(heldRows: held, currencyCode: currencyCode)
            .filter { set.contains(WalletHomeFilterPreferences.assetID(token: $0)) }
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

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    // MARK: - Mutations

    private func unpin(coin row: WalletCoinSupportedRow) {
        let id = WalletHomeFilterPreferences.assetID(coin: row)
        var set = pinnedSet
        set.remove(id)
        pinnedJSON = WalletHomeFilterPreferences.encode(set)
        // Prune the memoized roster in place so the row disappears
        // this frame; the keyed task rebuild confirms the state.
        pinnedCoins.removeAll { WalletHomeFilterPreferences.assetID(coin: $0) == id }
    }

    private func unpin(token row: WalletTokenSupportedDisplayRow) {
        let id = WalletHomeFilterPreferences.assetID(token: row)
        var set = pinnedSet
        set.remove(id)
        pinnedJSON = WalletHomeFilterPreferences.encode(set)
        pinnedTokens.removeAll { WalletHomeFilterPreferences.assetID(token: $0) == id }
    }
}

// MARK: - PinnedAssetRow

/// One pinned row. Leading 36pt mark, title + subtitle stack, and
/// a trailing pin-fill glyph that doubles as the unpin button.
/// Same shape as the rows in `WalletHomeHiddenAssetsView` so the
/// two sub-screens read as a family.
private struct PinnedAssetRow: View {
    let leadingMark: AnyView
    let title: String
    let subtitle: String
    let unpin: () -> Void

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            leadingMark
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: title)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: UniSpacing.s)
            Button(action: unpin) {
                Image(systemName: "pin.slash")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Unpin"))
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}
