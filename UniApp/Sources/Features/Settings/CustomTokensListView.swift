import SwiftUI
import SwiftData

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
    @Query(sort: [SortDescriptor(\CustomTokenRecord.symbol, order: .forward)])
    private var allTokens: [CustomTokenRecord]

    @Environment(\.modelContext) private var modelContext
    @State private var isShowingAddSheet: Bool = false
    @State private var isShowingDeleteError: Bool = false

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
            .presentationDetents([.large])
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
        VStack(spacing: UniSpacing.l) {
            Spacer()
            VStack(spacing: UniSpacing.s) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(UniColors.Icon.tertiary)
                    .accessibilityHidden(true)
                UniHeadline(text: "No custom tokens yet", alignment: .center)
                UniBody(
                    text: "Add a token by pasting its contract address. Aperture reads the rest from chain.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UniSpacing.l)
            }

            UniButton(title: "Add a token", variant: .secondary) {
                isShowingAddSheet = true
            }
            .padding(.horizontal, UniSpacing.l)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UniColors.Background.primary)
    }

    // MARK: - List

    @ViewBuilder
    private var tokenList: some View {
        List {
            ForEach(tokensByChain, id: \.chain) { group in
                Section {
                    ForEach(group.tokens) { token in
                        CustomTokenRow(token: token)
                            .listRowBackground(UniColors.Background.secondary)
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
        let container = modelContext.container
        UniHapticEngine.shared.fire(.warning)
        Task { @MainActor in
            let repo = CustomTokenRepository(modelContainer: container)
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
    let token: CustomTokenRecord

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: token.chain,
                tokenSymbol: token.symbol,
                contract: token.contract,
                customIconURL: token.iconURL
            )
            .frame(width: 36, height: 36)
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
            Spacer()
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
