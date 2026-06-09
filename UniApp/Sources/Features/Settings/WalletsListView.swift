import SwiftUI
import SwiftData

/// Settings → Wallets list. Multi-wallet management surface: list
/// every persisted wallet, show kind + backup status + active marker,
/// expose drag-to-reorder, and two add-wallet entry rows. Tap a row
/// → push `WalletDetailView` for rename / view-phrase / delete.
///
/// **Per Rule #14:** native `.searchable` filter on `wallet.name` —
/// only visible when the user has > 5 wallets so the empty / small
/// list doesn't carry chrome it doesn't need.
struct WalletsListView: View {
    @Query(sort: \WalletRecord.sortOrder) private var wallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @Environment(\.modelContext) private var modelContext

    @State private var searchText: String = ""
    @State private var isShowingCreate: Bool = false
    @State private var isShowingImport: Bool = false
    @State private var createPath: NavigationPath = .init()
    @State private var importPath: NavigationPath = .init()

    private var filteredWallets: [WalletRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return wallets }
        return wallets.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            if !wallets.isEmpty {
                Section {
                    ForEach(filteredWallets) { wallet in
                        NavigationLink(value: SettingsDestination.walletDetail(wallet.id)) {
                            walletRow(wallet)
                        }
                        .listRowBackground(UniColors.Background.secondary)
                    }
                    .onMove(perform: moveWallets)
                } header: {
                    Text("Wallets")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }

            Section {
                Button {
                    isShowingCreate = true
                } label: {
                    entryRow(systemImage: "plus", title: "Create new wallet")
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)

                Button {
                    isShowingImport = true
                } label: {
                    entryRow(systemImage: "square.and.arrow.down", title: "Import existing wallet")
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Wallets"))
        .navigationBarTitleDisplayMode(.large)
        .searchableIfNeeded(text: $searchText, when: wallets.count > 5)
        .toolbar {
            if wallets.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .fullScreenCover(isPresented: $isShowingCreate, onDismiss: { createPath = .init() }) {
            RecoveryPhraseFlow(
                navigationPath: $createPath,
                onDismiss: { isShowingCreate = false },
                onUserSkippedBackup: {},
                onUserCompletedBackup: {}
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingImport, onDismiss: { importPath = .init() }) {
            ImportWalletFlow(
                navigationPath: $importPath,
                onDismiss: { isShowingImport = false },
                onCompleted: { _ in isShowingImport = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Rows

    private func walletRow(_ wallet: WalletRecord) -> some View {
        HStack(spacing: UniSpacing.s) {
            // 2026-06-09 — the wallet's customisable WalletAvatar
            // replaces the prior kind-glyph swatch. Same identity
            // surface as the tab icon, the toolbar pill, and the
            // wallet switcher.
            WalletAvatar(
                symbol: wallet.iconSymbol.isEmpty ? WalletAvatarDefaults.symbol : wallet.iconSymbol,
                colorHex: wallet.iconColorHex.isEmpty ? WalletAvatarDefaults.colorHex : wallet.iconColorHex,
                size: .row
            )

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                HStack(spacing: UniSpacing.xs) {
                    Text(wallet.name)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    if wallet.id.uuidString == activeWalletIdRaw {
                        Text("Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(UniColors.Status.successForeground)
                            .padding(.horizontal, UniSpacing.xs)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(UniColors.Status.successBackground)
                            )
                    }
                }
                Text(kindLabel(for: wallet.kind))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                if wallet.requiresBackup {
                    Text("Not backed up")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Status.warningForeground)
                }
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private func entryRow(systemImage: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.accent)
                .frame(width: 28, alignment: .center)
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, UniSpacing.xxs)
        .contentShape(Rectangle())
    }

    private func kindLabel(for kind: WalletKind) -> LocalizedStringKey {
        switch kind {
        case .created:          return "Created on this iPhone"
        case .importedMnemonic: return "Imported from recovery phrase"
        case .importedKey:      return "Imported from private key"
        case .watchOnly:        return "Watch-only"
        }
    }

    // MARK: - Reorder

    private func moveWallets(from source: IndexSet, to destination: Int) {
        var reordered = wallets
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, wallet) in reordered.enumerated() {
            wallet.sortOrder = index
            wallet.updatedAt = Date()
        }
        try? modelContext.save()
    }
}

// MARK: - Conditional searchable modifier

private extension View {
    @ViewBuilder
    func searchableIfNeeded(text: Binding<String>, when condition: Bool) -> some View {
        if condition {
            self.searchable(text: text, prompt: Text("Search wallets"))
        } else {
            self
        }
    }
}
