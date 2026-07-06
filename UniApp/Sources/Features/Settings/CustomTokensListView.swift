import SwiftUI

/// Settings → Wallets → <wallet> → Custom tokens. Lists every token
/// the user has added via `AddCustomTokenSheet`, sectioned by chain
/// with row-level delete affordances and a toolbar `+` to add more.
///
/// **Design intent (Rule #2 §D.1):** "what tokens have I added, and
/// can I get rid of one?" — one screen, list-format, swipe-to-delete
/// per row. The visual register matches `WalletsListView` so the user
/// reads "list of things I manage" instantly.
///
/// **Empty state (Rule #2 §A.2):** calm explanation, single CTA. No
/// marketing copy, no decorative illustration — the `info.circle`
/// glyph names the surface, the body line explains what the screen
/// does, the `UniButton(.secondary)` opens the Add sheet.
///
/// **Layers (Rule #2 §B.3):** content layer — opaque list rows on
/// `UniColors.Background.primary`. Functional layer — system nav bar
/// + toolbar `+` button.
struct CustomTokensListView: View {
    @StateObject private var databaseSnapshot = DatabaseSnapshotObservation()
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var isShowingAddSheet: Bool = false
    @State private var isShowingDeleteError: Bool = false

    private var allTokens: [CustomTokenRecord] {
        databaseSnapshot.customTokenRecords.sorted {
            $0.symbol.localizedStandardCompare($1.symbol) == .orderedAscending
        }
    }

    private var allWallets: [WalletRecord] {
        databaseSnapshot.wallets
    }

    /// Active wallet — the source of the held balances shown per token.
    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(rawID: activeWalletIdRaw, wallets: allWallets)
    }

    /// `(chainRaw)|(contract.lowercased())` → held token balance for the
    /// active wallet. Same case-insensitive key the home uses, so a custom
    /// token's pasted contract matches the scanned balance regardless of
    /// case.
    private var heldTokenIndex: [String: TokenBalanceRecord] {
        guard let wallet = activeWallet else { return [:] }
        var dict: [String: TokenBalanceRecord] = [:]
        for address in wallet.addresses {
            for balance in address.balances {
                guard let contract = balance.tokenContract, !contract.isEmpty else { continue }
                dict["\(address.chainRaw)|\(contract.lowercased())"] = balance
            }
        }
        return dict
    }

    private func heldBalance(for token: CustomTokenRecord) -> TokenBalanceRecord? {
        heldTokenIndex["\(token.chainRaw)|\(token.contract.lowercased())"]
    }

    /// Chain to pre-select when the user taps the toolbar `+`. The
    /// caller passes the wallet's currently-displayed chain so the
    /// sheet opens with one less tap.
    let initialChainForAdd: SupportedChain?

    init(initialChainForAdd: SupportedChain? = nil) {
        self.initialChainForAdd = initialChainForAdd
    }

    private var tokensByChain: [(chain: SupportedChain, tokens: [CustomTokenRecord])] {
        let grouped = Dictionary(grouping: allTokens, by: { $0.chain })
        return SupportedChain.allCases.compactMap { chain in
            guard let tokens = grouped[chain], !tokens.isEmpty else { return nil }
            return (chain: chain, tokens: tokens)
        }
    }

    var body: some View {
        Group {
            if allTokens.isEmpty {
                emptyState
            } else {
                tokenList
            }
        }
        .navigationTitle("Custom tokens")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityLabel(Text("Add a token"))
                }
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddCustomTokenSheet(
                initialChain: initialChainForAdd,
                onSaved: {}
            )
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        .alert(
            Text("Couldn't remove token"),
            isPresented: $isShowingDeleteError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The token couldn't be removed from the local database. Try again.")
        }
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyState: some View {
        List {
            Section {
                UniListEmptyState(
                    title: "No custom tokens yet.",
                    detail: "Add a token by pasting its contract address. Aperture reads the rest from chain.",
                    mark: .icon(systemName: "tag"),
                    minHeight: 320
                )
            }

            Section {
                UniButton(title: "Add a token", variant: .secondary) {
                    isShowingAddSheet = true
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: UniSpacing.m,
                    bottom: 0,
                    trailing: UniSpacing.m
                ))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
    }

    // MARK: - List

    @ViewBuilder
    private var tokenList: some View {
        List {
            ForEach(tokensByChain, id: \.chain) { group in
                Section {
                    ForEach(group.tokens) { token in
                        CustomTokenRow(
                            token: token,
                            balance: heldBalance(for: token),
                            currencyCode: currencyCode
                        )
                            .listRowBackground(UniColors.List.rowBackground)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(token)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(verbatim: group.chain.displayName)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }

            Section {
                UniFootnote(
                    text: "Aperture reads what the contract says about itself. We don't audit token contracts — verify trust before holding.",
                    color: UniColors.Text.tertiary
                )
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
    }

    // MARK: - Actions

    private func delete(_ token: CustomTokenRecord) {
        let id = token.id
        UniHapticEngine.shared.fire(.warning)
        Task { @MainActor in
            let repo = CustomTokenRepository(database: AppDatabase.shared)
            do {
                try await repo.remove(id: id)
            } catch {
                isShowingDeleteError = true
            }
        }
    }
}

// MARK: - Row

private struct CustomTokenRow: View {
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    let token: CustomTokenRecord
    /// The active wallet's held balance for this token, if any. `nil`
    /// renders a 0 placeholder so the row always carries a balance.
    let balance: TokenBalanceRecord?
    let currencyCode: String

    /// Decoded native amount (0 when unheld).
    private var amount: Decimal {
        guard let balance else { return .zero }
        return WalletFormatting.decimalAmount(rawBalance: balance.rawBalance, decimals: balance.decimals)
    }

    /// Cached fiat value, only when positive.
    private var fiatValue: Decimal? {
        guard let cached = balance?.fiatValueCached, cached > 0 else { return nil }
        return cached
    }

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: token.chain,
                tokenSymbol: token.symbol,
                contract: token.contract
            )
            .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: UniSpacing.xs) {
                    Text(verbatim: token.symbol)
                        .font(UniTypography.bodyEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                        .lineLimit(1)
                    if !token.metadataFromChain {
                        Text("User-provided")
                            .font(UniTypography.caption1)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                }
                Text(verbatim: token.name)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
                Text(verbatim: abbreviated(token.contract))
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: UniSpacing.s)

            // Balance — fiat (when priced) over native amount, same shape
            // as the main screen's token rows. Always shown, even at 0
            // (2026-06-19 user direction).
            VStack(alignment: .trailing, spacing: 2) {
                if let fiatValue {
                    Text(verbatim: WalletFormatting.fiat(fiatValue, currencyCode: balance?.fiatCurrencyCode ?? currencyCode, hidden: hideBalances))
                        .font(UniTypography.bodyEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text(verbatim: "\(WalletFormatting.native(amount, decimals: 6, hidden: hideBalances)) \(token.symbol)")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private func abbreviated(_ contract: String) -> String {
        guard contract.count > 12 else { return contract }
        let prefix = contract.prefix(6)
        let suffix = contract.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}
