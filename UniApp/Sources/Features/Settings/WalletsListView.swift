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
    /// Per-chain aggregate rows — summed per wallet for the row balance
    /// (2026-06-17). The same source the wallet-home hero uses, so the
    /// management list and the home agree.
    @Query private var chainStates: [ChainStateRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @Environment(\.modelContext) private var modelContext

    /// A wallet's total balance in the user's currency, summed from its
    /// per-chain aggregate rows. Zero until the wallet has been scanned.
    private func fiatBalance(for wallet: WalletRecord) -> Decimal {
        chainStates
            .filter { $0.walletId == wallet.id && $0.fiatCurrencyCode == currencyCode }
            .reduce(Decimal.zero) { $0 + $1.totalFiat }
    }

    @State private var searchText: String = ""
    @State private var isShowingCreate: Bool = false
    @State private var isShowingImport: Bool = false
    @State private var createPath: NavigationPath = .init()
    @State private var importPath: NavigationPath = .init()
    @State private var isShowingReorderError: Bool = false

    /// Rule #12 §G direction-only key for sheet content rebuild.
    /// `"ltr"` or `"rtl"`. Identical pattern to `OnboardingView`.
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

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
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingImport, onDismiss: { importPath = .init() }) {
            ImportWalletFlow(
                navigationPath: $importPath,
                onDismiss: { isShowingImport = false },
                onCompleted: { _ in isShowingImport = false }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .alert(
            Text("Couldn't save the new order"),
            isPresented: $isShowingReorderError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The wallet order couldn't be written to the local database. Try again.")
        }
    }

    // MARK: - Rows

    private func walletRow(_ wallet: WalletRecord) -> some View {
        HStack(spacing: UniSpacing.s) {
            // 2026-06-09 — gradient-disc avatar per the design
            // handoff. Reads `wallet.avatarSpec`, which hydrates the
            // persisted columns through `WalletAvatarSpec.hydrate(...)`
            // (with `auto(name)` fallback) and includes the type
            // badge derived from `wallet.kind`. Same surface as the
            // tab icon, the toolbar pill, and the wallet switcher.
            WalletAvatar(spec: wallet.avatarSpec, size: .row, walletId: wallet.id)

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
                // Balance as the subtitle — same layout as the wallet
                // switcher sheet (2026-06-19 user direction): footnote /
                // secondary / monospaced-digit / forced-LTR. The
                // "imported from…" kind subtitle was removed; it lives on
                // the wallet detail screen's Kind row.
                Text(WalletFormatting.fiat(fiatBalance(for: wallet), currencyCode: currencyCode))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
                if wallet.requiresBackup {
                    Text("Not backed up")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Status.warningForeground)
                }
            }

            Spacer(minLength: UniSpacing.s)
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

    // MARK: - Reorder

    private func moveWallets(from source: IndexSet, to destination: Int) {
        var reordered = wallets
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, wallet) in reordered.enumerated() {
            wallet.sortOrder = index
            wallet.updatedAt = Date()
        }
        do {
            try modelContext.save()
        } catch {
            isShowingReorderError = true
        }
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
