import SwiftUI
import SwiftData

/// **Hidden assets sub-screen** — the per-asset visibility editor
/// pushed onto the filter sheet's `NavigationStack`. Lists every
/// supported coin AND every supported token across every registry;
/// each row carries a `Toggle` for "hidden". Toggling a row hidden
/// removes that asset from the wallet-home holdings list; toggling
/// it visible brings it back. The persisted set survives across
/// launches via `@AppStorage`-backed JSON (see
/// `WalletHomeFilterPreferences`).
///
/// **Pin swipe action (2026-06-09).** A leading-edge swipe on any
/// row exposes a "Pin" / "Unpin" action — the iOS-canonical
/// idiom Mail / Reminders / Photos use for "elevate this row." A
/// pinned asset stays at the top of the wallet-home holdings list
/// regardless of the sort order; unpinning it returns it to its
/// natural sort position. The pinned roster is auditable on the
/// dedicated `WalletHomePinnedAssetsView` sub-screen reachable
/// from the filter sheet.
///
/// **Why swipe and not context-menu.** The Hidden Assets screen
/// already has a per-row primary affordance: the `Toggle` for
/// hidden / visible. Stacking a context-menu on top of an
/// existing affordance reads as visual noise; a leading-edge
/// swipe is the system's native "secondary action" path and lives
/// outside the row's primary surface. The Mail account-row swipe
/// is the closest analog in Apple's own apps.
///
/// **Design intent (Rule #2 §D.1):** give the user a stable, complete
/// roster of everything Aperture supports — they pick which ones
/// participate in their home view AND which ones lead the list.
/// No fishing through the holdings list to find a row; the editor
/// IS the roster.
///
/// **Sections.**
///
/// - **Coins** — one row per `SupportedChain.allCases`.
/// - **Tokens** — one row per registry entry across every chain
///   family. Same builders the wallet home consumes
///   (`WalletSupportedRowBuilders.tokenRows`), so the editor and
///   the home see exactly the same set.
///
/// **Search (Rule #14).** `.searchable(text:)` with no `placement:`
/// override — iOS 26 picks the location. Filter uses
/// `String.localizedStandardContains(_:)` against the row's name,
/// symbol, and chain display name so a query in any script matches
/// every human-readable field on the row.
///
/// **Honesty (Rule #2 §A.7).** A row's "hidden" toggle is the row's
/// truth — when the user hides USDC on Ethereum it disappears from
/// the home list; when they unhide it, it reappears. No celebration,
/// no warning, no friction. The home view's "live preview" header
/// in the parent sheet shows the impact in real time.
///
/// **Layout (Rule #15 §A).** Pushed sub-screen — does NOT wrap its
/// content in a `NavigationStack`. The parent sheet owns the stack
/// and the sub-screen consumes it. Title via `.navigationTitle`.
struct WalletHomeHiddenAssetsView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage(WalletHomeFilterPreferences.hiddenAssetsKey)
    private var hiddenJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON
    @AppStorage(WalletHomeFilterPreferences.pinnedAssetsKey)
    private var pinnedJSON: String = WalletHomeFilterPreferences.defaultHiddenJSON

    @State private var searchText: String = ""

    // MARK: - Decoded set state (single source for the toggles)
    //
    // The hidden / pinned sets are decoded ONCE into `@State` and
    // every row binding reads + mutates the in-memory set, encoding
    // back to the JSON `@AppStorage` after each mutation. The prior
    // per-binding read-decode-mutate-encode-write round-trip decoded
    // the JSON per row per render (O(N) decodes) and raced itself —
    // two toggles landing in the same pass each re-decoded the
    // pre-mutation JSON and the second write clobbered the first.
    // Seeded in `init` from the persisted JSON so the first render
    // shows the correct toggle states; `.onChange` keeps the sets in
    // sync with external writes (e.g. the sheet's Reset).
    @State private var hiddenSet: Set<String>
    @State private var pinnedSet: Set<String>

    init() {
        let defaults = UserDefaults.standard
        let hidden = defaults.string(forKey: WalletHomeFilterPreferences.hiddenAssetsKey)
            ?? WalletHomeFilterPreferences.defaultHiddenJSON
        let pinned = defaults.string(forKey: WalletHomeFilterPreferences.pinnedAssetsKey)
            ?? WalletHomeFilterPreferences.defaultHiddenJSON
        _hiddenSet = State(initialValue: WalletHomeFilterPreferences.decode(hidden))
        _pinnedSet = State(initialValue: WalletHomeFilterPreferences.decode(pinned))
    }

    var body: some View {
        List {
            coinsSection
            tokensSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Hidden assets"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: Text("Search"))
        .uniHaptic(.selection, trigger: hiddenJSON)
        .uniHaptic(.success, trigger: pinnedJSON)
        .onChange(of: hiddenJSON) { _, newValue in
            let decoded = WalletHomeFilterPreferences.decode(newValue)
            if decoded != hiddenSet { hiddenSet = decoded }
        }
        .onChange(of: pinnedJSON) { _, newValue in
            let decoded = WalletHomeFilterPreferences.decode(newValue)
            if decoded != pinnedSet { pinnedSet = decoded }
        }
    }

    // MARK: - Sections

    /// Coins section. One row per `SupportedChain`; the leading
    /// `CoinMark` renders the native logo and the trailing `Toggle`
    /// writes through `hiddenAssets`.
    @ViewBuilder
    private var coinsSection: some View {
        let rows = filteredCoinRows
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.chain) { row in
                    AssetVisibilityRow(
                        leadingMark: AnyView(coinMark(for: row.chain)),
                        title: row.chain.displayName,
                        subtitle: row.chain.ticker,
                        isHidden: bindingForCoinHidden(row)
                    )
                    .listRowBackground(UniColors.Background.secondary)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        let pinned = isPinned(coin: row)
                        Button {
                            togglePinned(coin: row)
                        } label: {
                            Label(
                                pinned ? "Unpin" : "Pin",
                                systemImage: pinned ? "pin.slash" : "pin"
                            )
                        }
                        .tint(UniColors.Button.primaryTint)
                    }
                }
            } header: {
                Text("Coins")
            }
        }
    }

    /// Tokens section. One row per `(symbol, chain, contract)` from
    /// every curated registry. Sub-rows use the token's `CoinMark`
    /// resolution path so the brand mark is the real one when Trust
    /// Wallet provides it.
    @ViewBuilder
    private var tokensSection: some View {
        let rows = filteredTokenRows
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.id) { row in
                    AssetVisibilityRow(
                        leadingMark: AnyView(tokenMark(for: row)),
                        title: "\(row.symbol) — \(row.name)",
                        subtitle: row.chain.displayName,
                        isHidden: bindingForTokenHidden(row)
                    )
                    .listRowBackground(UniColors.Background.secondary)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        let pinned = isPinned(token: row)
                        Button {
                            togglePinned(token: row)
                        } label: {
                            Label(
                                pinned ? "Unpin" : "Pin",
                                systemImage: pinned ? "pin.slash" : "pin"
                            )
                        }
                        .tint(UniColors.Button.primaryTint)
                    }
                }
            } header: {
                Text("Tokens")
            }
        }
    }

    // MARK: - Row builders

    /// 36pt circular mark for a chain.
    @ViewBuilder
    private func coinMark(for chain: SupportedChain) -> some View {
        CoinMark(chain: chain, tokenSymbol: chain.ticker, contract: nil)
            .frame(width: 36, height: 36)
    }

    /// 36pt mark for a token, using the token's contract so Trust
    /// Wallet's `assets/<contract>/logo.png` path resolves where
    /// possible.
    @ViewBuilder
    private func tokenMark(for row: WalletTokenSupportedDisplayRow) -> some View {
        CoinMark(chain: row.chain, tokenSymbol: row.symbol, contract: row.contract)
            .frame(width: 36, height: 36)
    }

    // MARK: - Filtered rows

    private var allCoinRows: [WalletCoinSupportedRow] {
        WalletSupportedRowBuilders.coinRows(
            heldRows: heldRows,
            currencyCode: currencyCode
        )
    }

    private var allTokenRows: [WalletTokenSupportedDisplayRow] {
        WalletSupportedRowBuilders.tokenRows(
            heldRows: heldRows,
            currencyCode: currencyCode
        )
    }

    private var filteredCoinRows: [WalletCoinSupportedRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allCoinRows }
        return allCoinRows.filter { row in
            row.chain.displayName.localizedStandardContains(query)
                || row.chain.ticker.localizedStandardContains(query)
        }
    }

    private var filteredTokenRows: [WalletTokenSupportedDisplayRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allTokenRows }
        return allTokenRows.filter { row in
            row.symbol.localizedStandardContains(query)
                || row.name.localizedStandardContains(query)
                || row.chain.displayName.localizedStandardContains(query)
        }
    }

    // MARK: - Held rows (the source for the row builders)

    /// Active wallet's held balances, used by the row builders so
    /// each row carries the user's current amount even though we
    /// don't display amounts on this screen (the user is choosing
    /// visibility, not reading totals).
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

    // MARK: - Toggle bindings (hidden)

    /// `Binding<Bool>` for a coin row's "hidden" toggle. Reads and
    /// mutates the in-memory `hiddenSet` (the single source), then
    /// encodes the updated set back through `@AppStorage` — no
    /// per-row decode, no read-modify-write race between toggles.
    private func bindingForCoinHidden(_ row: WalletCoinSupportedRow) -> Binding<Bool> {
        bindingForHidden(id: WalletHomeFilterPreferences.assetID(coin: row))
    }

    private func bindingForTokenHidden(_ row: WalletTokenSupportedDisplayRow) -> Binding<Bool> {
        bindingForHidden(id: WalletHomeFilterPreferences.assetID(token: row))
    }

    private func bindingForHidden(id: String) -> Binding<Bool> {
        Binding(
            get: { hiddenSet.contains(id) },
            set: { newValue in
                if newValue { hiddenSet.insert(id) } else { hiddenSet.remove(id) }
                hiddenJSON = WalletHomeFilterPreferences.encode(hiddenSet)
            }
        )
    }

    // MARK: - Pin helpers

    private func isPinned(coin row: WalletCoinSupportedRow) -> Bool {
        pinnedSet.contains(WalletHomeFilterPreferences.assetID(coin: row))
    }

    private func isPinned(token row: WalletTokenSupportedDisplayRow) -> Bool {
        pinnedSet.contains(WalletHomeFilterPreferences.assetID(token: row))
    }

    private func togglePinned(coin row: WalletCoinSupportedRow) {
        togglePinned(id: WalletHomeFilterPreferences.assetID(coin: row))
    }

    private func togglePinned(token row: WalletTokenSupportedDisplayRow) {
        togglePinned(id: WalletHomeFilterPreferences.assetID(token: row))
    }

    private func togglePinned(id: String) {
        if pinnedSet.contains(id) { pinnedSet.remove(id) } else { pinnedSet.insert(id) }
        pinnedJSON = WalletHomeFilterPreferences.encode(pinnedSet)
    }
}

// MARK: - AssetVisibilityRow

/// One row in either Hidden Assets or Hidden Chains. A leading
/// 36pt mark, a title + subtitle stack, and a trailing `Toggle`.
/// Lifted to a small primitive so the two screens look identical
/// without duplicating the row body.
///
/// **Why `AnyView` for the leading mark.** The mark differs between
/// the two screens (coin marks vs chain marks vs token marks). The
/// row primitive shouldn't know which it's rendering; `AnyView`
/// is the standard SwiftUI escape hatch for "the caller decides the
/// leading visual." Cost is negligible for a row body that renders
/// at most ~50 times in a scrolling list.
struct AssetVisibilityRow: View {
    let leadingMark: AnyView
    let title: String
    let subtitle: String
    @Binding var isHidden: Bool

    var body: some View {
        UniToggle(isOn: $isHidden) {
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
            }
        }
        .tint(UniColors.Button.primaryTint)
        .padding(.vertical, UniSpacing.xxs)
    }
}
