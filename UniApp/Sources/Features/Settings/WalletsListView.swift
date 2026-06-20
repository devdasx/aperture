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
    /// Live per-token balances — the SAME source the wallet-home hero uses for
    /// its `liveBalanceSum`, so this list shows the same number as the home
    /// (2026-06-20 fix). The previous `ChainStateRecord` aggregate could be
    /// empty even when token balances existed, which made every wallet read
    /// JOD 0.000 here while the home showed the real total.
    @Query private var tokenBalances: [TokenBalanceRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @Environment(\.modelContext) private var modelContext

    // MARK: - Filter & Sort (2026-06-20 — replaced the Edit button)
    @AppStorage("walletsListSortKey") private var sortKeyRaw: String = WalletsListSortKey.custom.rawValue
    @AppStorage("walletsListSortAscending") private var sortAscending: Bool = true
    @AppStorage("walletsListShowCreated") private var showCreated: Bool = true
    @AppStorage("walletsListShowImportedMnemonic") private var showImportedMnemonic: Bool = true
    @AppStorage("walletsListShowImportedKey") private var showImportedKey: Bool = true
    @AppStorage("walletsListShowWatchOnly") private var showWatchOnly: Bool = true
    @AppStorage("walletsListOnlyUnbackedUp") private var onlyUnbackedUp: Bool = false
    @State private var isShowingFilter: Bool = false

    /// `true` when any non-default filter/sort is active — surfaces a dot on
    /// the filter button so the user knows the list is narrowed.
    private var isFilterActive: Bool {
        sortKeyRaw != WalletsListSortKey.custom.rawValue
            || !sortAscending
            || !showCreated || !showImportedMnemonic || !showImportedKey || !showWatchOnly
            || onlyUnbackedUp
    }

    private func kindShown(_ kind: WalletKind) -> Bool {
        switch kind {
        case .created:          return showCreated
        case .importedMnemonic: return showImportedMnemonic
        case .importedKey:      return showImportedKey
        case .watchOnly:        return showWatchOnly
        }
    }

    private func sortWallets(_ list: [WalletRecord]) -> [WalletRecord] {
        let key = WalletsListSortKey(rawValue: sortKeyRaw) ?? .custom
        let sorted: [WalletRecord]
        switch key {
        case .custom:
            sorted = list.sorted { $0.sortOrder < $1.sortOrder }
        case .name:
            sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .balance:
            sorted = list.sorted { fiatBalance(for: $0) < fiatBalance(for: $1) }
        case .dateAdded:
            sorted = list.sorted { $0.createdAt < $1.createdAt }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    /// A wallet's total balance in the user's currency, summed from its own
    /// addresses' cached token-fiat values. Zero only until the wallet has
    /// actually been scanned (no scanned tokens yet).
    private func fiatBalance(for wallet: WalletRecord) -> Decimal {
        let addressIds = Set(wallet.addresses.map(\.id))
        var total = Decimal.zero
        for balance in tokenBalances {
            guard balance.fiatCurrencyCode == currencyCode else { continue }
            guard let aid = balance.addressId, addressIds.contains(aid) else { continue }
            total += balance.fiatValueCached
        }
        return total
    }

    @State private var searchText: String = ""
    @State private var isShowingCreate: Bool = false
    @State private var isShowingImport: Bool = false
    @State private var createPath: NavigationPath = .init()
    @State private var importPath: NavigationPath = .init()
    @State private var isShowingReorderError: Bool = false

    // MARK: - Swipe-action state (2026-06-20)
    /// The wallet pending deletion — drives `WalletDeleteSheet`, which owns its
    /// own passcode/native-confirm gate.
    @State private var pendingDelete: PendingDelete?
    /// Backup-from-swipe: the target + the auth-gated phrase + the flow.
    @State private var backupTargetId: UUID?
    @State private var backupTargetName: String = ""
    @State private var backupTargetAvatar: WalletAvatarSpec?
    @State private var backupWords: [String] = []
    @State private var isShowingBackupPasscode: Bool = false
    @State private var isShowingWalletBackup: Bool = false
    /// Already-localized message for the shared error alert.
    @State private var errorAlertMessage: String?

    /// Identifiable payload for the delete confirmation sheet (a wallet row
    /// can't drive `.sheet(item:)` directly — its `id` is the SwiftData
    /// persistent id, not this UUID).
    private struct PendingDelete: Identifiable {
        let id: UUID
        let name: String
        let kind: WalletKind
        let networkCount: Int
        let hasStoredSecret: Bool
    }

    /// Rule #12 §G direction-only key for sheet content rebuild.
    /// `"ltr"` or `"rtl"`. Identical pattern to `OnboardingView`.
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    private var filteredWallets: [WalletRecord] {
        var result = wallets.filter { kindShown($0.kind) }
        if onlyUnbackedUp {
            result = result.filter { $0.requiresBackup }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedStandardContains(query) }
        }
        return sortWallets(result)
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
                        // Leading full-swipe = the primary action: make this
                        // wallet active, or — if it's already active — back it
                        // up (2026-06-20 user direction).
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if wallet.id.uuidString == activeWalletIdRaw {
                                Button { startBackup(wallet) } label: {
                                    Label("Back up", systemImage: "icloud.and.arrow.up")
                                }
                                .tint(UniColors.Tint.accent)
                            } else {
                                Button { makeActive(wallet) } label: {
                                    Label("Activate", systemImage: "checkmark.circle.fill")
                                }
                                .tint(UniColors.Status.successForeground)
                            }
                        }
                        // Trailing = the rest: refresh, back up (when not the
                        // full-swipe action), and remove.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { requestDelete(wallet) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button { refresh(wallet) } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .tint(UniColors.Icon.secondary)
                            if wallet.id.uuidString != activeWalletIdRaw {
                                Button { startBackup(wallet) } label: {
                                    Label("Back up", systemImage: "icloud.and.arrow.up")
                                }
                                .tint(UniColors.Tint.accent)
                            }
                        }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button { isShowingFilter = true } label: {
                    Image(systemName: isFilterActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease")
                }
                .accessibilityLabel(Text("Filter and sort"))
            }
        }
        .sheet(isPresented: $isShowingFilter) {
            WalletsListFilterSheet()
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
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
        // Remove (swipe) — the same self-gating delete sheet the detail screen
        // uses (passcode verify when set, native destructive confirm otherwise).
        .sheet(item: $pendingDelete) { target in
            WalletDeleteSheet(
                walletName: target.name,
                kind: target.kind,
                networkCount: target.networkCount,
                hasStoredSecret: target.hasStoredSecret,
                onAuthorized: {
                    let id = target.id
                    pendingDelete = nil
                    Task { await deleteWallet(id) }
                }
            )
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        // Back up (swipe) — passcode gate (when set) before decrypting the
        // phrase, then the same WalletBackupFlow the detail screen presents.
        .fullScreenCover(isPresented: $isShowingBackupPasscode) {
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isShowingBackupPasscode = false
                        DispatchQueue.main.async { loadAndPresentBackup() }
                    },
                    onCancel: { isShowingBackupPasscode = false },
                    allowsBiometrics: true
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingBackupPasscode = false } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Cancel"))
                    }
                }
            }
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingWalletBackup) {
            if let id = backupTargetId {
                WalletBackupFlow(
                    walletId: id,
                    walletName: backupTargetName,
                    words: backupWords,
                    avatar: backupTargetAvatar,
                    onClose: {
                        isShowingWalletBackup = false
                        backupWords = []
                    }
                )
                .uniAppEnvironment()
                .presentationBackground(UniColors.Background.primary)
            }
        }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(get: { errorAlertMessage != nil }, set: { if !$0 { errorAlertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorAlertMessage ?? ""))
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

    // MARK: - Swipe actions

    /// Make this wallet the active one (the home reads `activeWalletId`).
    private func makeActive(_ wallet: WalletRecord) {
        guard wallet.id.uuidString != activeWalletIdRaw else { return }
        activeWalletIdRaw = wallet.id.uuidString
        UniHapticEngine.shared.play(.success)
    }

    /// Real refresh of THIS wallet — balances across every chain + history,
    /// in the background, via the canonical coordinator.
    private func refresh(_ wallet: WalletRecord) {
        UniHapticEngine.shared.play(.selection)
        let container = modelContext.container
        let fiat = currencyCode
        let id = wallet.id
        Task {
            await WalletRefreshCoordinator(container: container)
                .refreshWallet(walletId: id, fiatCode: fiat)
        }
    }

    private func requestDelete(_ wallet: WalletRecord) {
        pendingDelete = PendingDelete(
            id: wallet.id,
            name: wallet.name,
            kind: wallet.kind,
            networkCount: Set(wallet.addresses.map(\.chainRaw)).count,
            hasStoredSecret: walletHasStoredSecret(wallet)
        )
    }

    @MainActor
    private func deleteWallet(_ id: UUID) async {
        let repo = WalletRepository(modelContainer: modelContext.container)
        do {
            try await repo.deleteWallet(id: id)
        } catch {
            errorAlertMessage = String.apertureLocalized("Couldn't delete this wallet from the local database. Try again.")
        }
    }

    /// Back up (swipe): gate behind the app passcode / device biometric (when
    /// present), then decrypt + present the backup flow — same security as the
    /// detail screen's Back up.
    private func startBackup(_ wallet: WalletRecord) {
        backupTargetId = wallet.id
        backupTargetName = wallet.name
        backupTargetAvatar = wallet.avatarSpec
        if PinCodeStorage.hasPin {
            isShowingBackupPasscode = true
        } else if BiometricService().isAvailable {
            Task {
                let outcome = await BiometricService().authenticate(
                    reason: LocalizedStringResource("Confirm to back up your wallet.")
                )
                if case .success = outcome { loadAndPresentBackup() }
            }
        } else {
            // Nothing on the device can gate it → proceed (matches the app-wide
            // removal of the no-lock warning).
            loadAndPresentBackup()
        }
    }

    @MainActor
    private func loadAndPresentBackup() {
        guard let id = backupTargetId else { return }
        Task { @MainActor in
            let loaded = try? await Task.detached(priority: .userInitiated) {
                try MnemonicVault.loadMnemonic(for: id)
            }.value
            guard let words = loaded ?? nil, !words.isEmpty else {
                errorAlertMessage = String.apertureLocalized("Couldn't read this wallet's phrase to back it up. Try restarting Aperture.")
                return
            }
            backupWords = words
            isShowingWalletBackup = true
        }
    }

    /// `true` iff this wallet's secret material lives in the Keychain.
    private func walletHasStoredSecret(_ wallet: WalletRecord) -> Bool {
        switch wallet.kind {
        case .importedKey:
            return MnemonicVault.hasPrivateKey(for: wallet.id)
        case .created, .importedMnemonic:
            return MnemonicVault.hasMnemonic(for: wallet.id)
        case .watchOnly:
            return false
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

// MARK: - Filter & Sort

/// How the Wallets list is ordered.
enum WalletsListSortKey: String, CaseIterable, Identifiable {
    case custom      // the user's manual / insertion order (sortOrder)
    case name
    case balance
    case dateAdded   // createdAt

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .custom:    return "Custom order"
        case .name:      return "Name"
        case .balance:   return "Balance"
        case .dateAdded: return "Date added"
        }
    }
}

/// The Wallets list **Filter & Sort** sheet (2026-06-20 — replaces the Edit
/// button). Mirrors the wallet-home filter pattern: every control is an
/// `@AppStorage` write that `WalletsListView` reads live, so "Done" is just
/// "close" — the list is already updated.
struct WalletsListFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("walletsListSortKey") private var sortKeyRaw: String = WalletsListSortKey.custom.rawValue
    @AppStorage("walletsListSortAscending") private var sortAscending: Bool = true
    @AppStorage("walletsListShowCreated") private var showCreated: Bool = true
    @AppStorage("walletsListShowImportedMnemonic") private var showImportedMnemonic: Bool = true
    @AppStorage("walletsListShowImportedKey") private var showImportedKey: Bool = true
    @AppStorage("walletsListShowWatchOnly") private var showWatchOnly: Bool = true
    @AppStorage("walletsListOnlyUnbackedUp") private var onlyUnbackedUp: Bool = false

    @State private var isShowingResetConfirm: Bool = false

    private var isCustomSort: Bool { sortKeyRaw == WalletsListSortKey.custom.rawValue }

    var body: some View {
        NavigationStack {
            List {
                sortSection
                kindSection
                backupSection
                resetSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Filter & Sort"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Text("Done").font(UniTypography.bodyEmphasized)
                    }
                }
            }
            .confirmationDialog(
                Text("Reset filters?"),
                isPresented: $isShowingResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) { resetAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every filter and sort choice.")
            }
        }
    }

    private var sortSection: some View {
        Section {
            Picker(selection: $sortKeyRaw) {
                ForEach(WalletsListSortKey.allCases) { key in
                    Text(key.label).tag(key.rawValue)
                }
            } label: {
                Text("Sort by").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .listRowBackground(UniColors.Background.secondary)

            Toggle(isOn: $sortAscending) {
                Text("Ascending order").font(UniTypography.body).foregroundStyle(isCustomSort ? UniColors.Text.disabled : UniColors.Text.primary)
            }
            .tint(UniColors.Button.primaryTint)
            .disabled(isCustomSort)
            .listRowBackground(UniColors.Background.secondary)
        } header: {
            Text("Sort").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private var kindSection: some View {
        Section {
            kindToggle("Created", isOn: $showCreated)
            kindToggle("Imported (phrase)", isOn: $showImportedMnemonic)
            kindToggle("Imported (key)", isOn: $showImportedKey)
            kindToggle("Watch-only", isOn: $showWatchOnly)
        } header: {
            Text("Show wallet types").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private var backupSection: some View {
        Section {
            Toggle(isOn: $onlyUnbackedUp) {
                Text("Only wallets that need backup").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .tint(UniColors.Button.primaryTint)
            .listRowBackground(UniColors.Background.secondary)
        } header: {
            Text("Backup").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                isShowingResetConfirm = true
            } label: {
                Text("Reset filters").font(UniTypography.body)
            }
            .listRowBackground(UniColors.Background.secondary)
        }
    }

    private func kindToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
        }
        .tint(UniColors.Button.primaryTint)
        .listRowBackground(UniColors.Background.secondary)
    }

    private func resetAll() {
        sortKeyRaw = WalletsListSortKey.custom.rawValue
        sortAscending = true
        showCreated = true
        showImportedMnemonic = true
        showImportedKey = true
        showWatchOnly = true
        onlyUnbackedUp = false
    }
}
