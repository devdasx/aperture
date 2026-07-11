import SwiftUI

/// Settings → Wallets list. Multi-wallet management surface: list
/// every persisted wallet, show kind + backup status + active marker,
/// expose drag-to-reorder, and two add-wallet entry rows. Tap a row
/// → push `WalletDetailView` for rename / view-phrase / delete.
///
/// **Per Rule #14:** native `.searchable` filter on `wallet.name` —
/// only visible when the user has > 5 wallets so the empty / small
/// list doesn't carry chrome it doesn't need.
struct WalletsListView: View {
    @Environment(\.balancePrivacyEnabled) private var hideBalances
    @StateObject private var databaseSnapshot = DatabaseSnapshotObservation()
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @GRDBStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

    private var wallets: [WalletRecord] {
        databaseSnapshot.wallets.sorted {
            if $0.sortOrder == $1.sortOrder { return $0.createdAt < $1.createdAt }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private var tokenBalances: [TokenBalanceRecord] {
        databaseSnapshot.balances
    }

    // MARK: - Filter & Sort (2026-06-20 — replaced the Edit button)
    @GRDBStorage("walletsListSortKey") private var sortKeyRaw: String = WalletsListSortKey.custom.rawValue
    @GRDBStorage("walletsListSortAscending") private var sortAscending: Bool = true
    @GRDBStorage("walletsListShowCreated") private var showCreated: Bool = true
    @GRDBStorage("walletsListShowImportedMnemonic") private var showImportedMnemonic: Bool = true
    @GRDBStorage("walletsListShowImportedKey") private var showImportedKey: Bool = true
    @GRDBStorage("walletsListShowWatchOnly") private var showWatchOnly: Bool = true
    @GRDBStorage("walletsListActiveScope") private var activeScopeRaw: String = WalletsListActiveScope.all.rawValue
    @GRDBStorage("walletsListVisibilityScope") private var visibilityScopeRaw: String = WalletsListVisibilityScope.all.rawValue
    @GRDBStorage("walletsListBackupScope") private var backupScopeRaw: String = WalletsListBackupScope.all.rawValue
    @GRDBStorage("walletsListOnlyUnbackedUp") private var legacyOnlyUnbackedUp: Bool = false
    @GRDBStorage("walletsListBalanceScope") private var balanceScopeRaw: String = WalletsListBalanceScope.all.rawValue
    @GRDBStorage("walletsListMinFiat") private var minFiatRaw: String = ""
    @GRDBStorage("walletsListMaxFiat") private var maxFiatRaw: String = ""
    @GRDBStorage("walletsListNetworkScope") private var networkScopeRaw: String = WalletsListNetworkScope.all.rawValue
    @GRDBStorage("walletsListSelectedNetworks") private var selectedNetworksJSON: String = WalletsListFilterSupport.defaultSelectedJSON
    @GRDBStorage("walletsListSecretScope") private var secretScopeRaw: String = WalletsListSecretScope.all.rawValue
    @GRDBStorage("walletsListOnlyPassphrase") private var onlyPassphrase: Bool = false
    @GRDBStorage("walletsListDateRange") private var dateRangeRaw: String = WalletsListDateRange.all.rawValue
    @State private var isShowingFilter: Bool = false

    /// `true` when any non-default filter/sort is active — surfaces a dot on
    /// the filter button so the user knows the list is narrowed.
    private var isFilterActive: Bool {
        sortKeyRaw != WalletsListSortKey.custom.rawValue
            || !sortAscending
            || !showCreated || !showImportedMnemonic || !showImportedKey || !showWatchOnly
            || activeScopeRaw != WalletsListActiveScope.all.rawValue
            || visibilityScopeRaw != WalletsListVisibilityScope.all.rawValue
            || backupScopeRaw != WalletsListBackupScope.all.rawValue
            || legacyOnlyUnbackedUp
            || balanceScopeRaw != WalletsListBalanceScope.all.rawValue
            || !minFiatRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !maxFiatRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || networkScopeRaw != WalletsListNetworkScope.all.rawValue
            || !WalletsListFilterSupport.decode(selectedNetworksJSON).isEmpty
            || secretScopeRaw != WalletsListSecretScope.all.rawValue
            || onlyPassphrase
            || dateRangeRaw != WalletsListDateRange.all.rawValue
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
        case .dateUpdated:
            sorted = list.sorted { $0.updatedAt < $1.updatedAt }
        case .walletType:
            sorted = list.sorted { lhs, rhs in
                if lhs.kindRaw == rhs.kindRaw {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.kindRaw < rhs.kindRaw
            }
        case .networks:
            sorted = list.sorted { networkCount(for: $0) < networkCount(for: $1) }
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

    private func networkCount(for wallet: WalletRecord) -> Int {
        Set(wallet.addresses.map(\.chainRaw)).count
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
        var result = wallets.filter { kindShown($0.kind) }

        result = result.filter { wallet in
            matchesActiveScope(wallet)
                && matchesVisibilityScope(wallet)
                && matchesBackupScope(wallet)
                && matchesBalanceScope(wallet)
                && matchesNetworkScope(wallet)
                && matchesSecretScope(wallet)
                && matchesDateRange(wallet)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedStandardContains(query) }
        }
        return sortWallets(result)
    }

    private func matchesActiveScope(_ wallet: WalletRecord) -> Bool {
        let scope = WalletsListActiveScope(rawValue: activeScopeRaw) ?? .all
        let isActive = wallet.id.uuidString == activeWalletIdRaw
        switch scope {
        case .all:      return true
        case .active:   return isActive
        case .inactive: return !isActive
        }
    }

    private func matchesVisibilityScope(_ wallet: WalletRecord) -> Bool {
        let scope = WalletsListVisibilityScope(rawValue: visibilityScopeRaw) ?? .all
        switch scope {
        case .all:     return true
        case .visible: return !wallet.isHidden
        case .hidden:  return wallet.isHidden
        }
    }

    private func matchesBackupScope(_ wallet: WalletRecord) -> Bool {
        let scope = legacyOnlyUnbackedUp
            ? WalletsListBackupScope.needsBackup
            : (WalletsListBackupScope(rawValue: backupScopeRaw) ?? .all)
        switch scope {
        case .all:
            return true
        case .needsBackup:
            return wallet.requiresBackup
        case .backedUp:
            return !wallet.requiresBackup
        case .manualBackup:
            return wallet.manualBackupCompleted == true
        }
    }

    private func matchesBalanceScope(_ wallet: WalletRecord) -> Bool {
        let balance = fiatBalance(for: wallet)
        let scope = WalletsListBalanceScope(rawValue: balanceScopeRaw) ?? .all
        switch scope {
        case .all:
            break
        case .withBalance:
            guard balance > 0 else { return false }
        case .empty:
            guard balance == 0 else { return false }
        }
        if let minimum = Self.parseFiatAmount(minFiatRaw), balance < minimum {
            return false
        }
        if let maximum = Self.parseFiatAmount(maxFiatRaw), balance > maximum {
            return false
        }
        return true
    }

    private func matchesNetworkScope(_ wallet: WalletRecord) -> Bool {
        let walletNetworks = Set(wallet.addresses.map(\.chainRaw))
        let scope = WalletsListNetworkScope(rawValue: networkScopeRaw) ?? .all
        switch scope {
        case .all:
            break
        case .singleNetwork:
            guard walletNetworks.count == 1 else { return false }
        case .multiNetwork:
            guard walletNetworks.count > 1 else { return false }
        }

        let selectedNetworks = WalletsListFilterSupport.decode(selectedNetworksJSON)
        guard !selectedNetworks.isEmpty else { return true }
        return !selectedNetworks.isDisjoint(with: walletNetworks)
    }

    private func matchesSecretScope(_ wallet: WalletRecord) -> Bool {
        if onlyPassphrase, !wallet.hasPassphrase {
            return false
        }

        let scope = WalletsListSecretScope(rawValue: secretScopeRaw) ?? .all
        switch scope {
        case .all:
            return true
        case .canSign:
            return walletHasStoredSecret(wallet)
        case .noSigningKey:
            return !walletHasStoredSecret(wallet)
        }
    }

    private func matchesDateRange(_ wallet: WalletRecord) -> Bool {
        let range = WalletsListDateRange(rawValue: dateRangeRaw) ?? .all
        guard let cutoff = range.cutoff(from: Date()) else { return true }
        return wallet.createdAt >= cutoff
    }

    private static func parseFiatAmount(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Decimal(string: trimmed) { return value }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        List {
            if wallets.isEmpty {
                Section {
                    UniListEmptyState(
                        title: "No wallets yet.",
                        detail: "Create a new wallet or import an existing one to start using Aperture.",
                        mark: .icon(systemName: "wallet.pass"),
                        minHeight: 300
                    )
                }
            } else if filteredWallets.isEmpty {
                Section {
                    UniListEmptyState(
                        title: "No wallets match the filter.",
                        detail: walletsEmptyDetail,
                        mark: .icon(systemName: "line.3.horizontal.decrease"),
                        minHeight: 300
                    )
                }
            } else {
                Section {
                    ForEach(filteredWallets) { wallet in
                        NavigationLink(value: SettingsDestination.walletDetail(wallet.id)) {
                            walletRow(wallet)
                        }
                        .listRowBackground(UniColors.List.rowBackground)
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
                .buttonStyle(.uniListRow)
                .listRowBackground(UniColors.List.rowBackground)

                Button {
                    isShowingImport = true
                } label: {
                    entryRow(systemImage: "square.and.arrow.down", title: "Import existing wallet")
                }
                .buttonStyle(.uniListRow)
                .listRowBackground(UniColors.List.rowBackground)
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
                .apertureEnvironment()
                .uniSheetDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingCreate, onDismiss: { createPath = .init() }) {
            RecoveryPhraseFlow(
                navigationPath: $createPath,
                onDismiss: { isShowingCreate = false },
                onUserContinuedWithoutVerifiedBackup: {}
            )
            .id(sheetDirectionKey)
            .apertureEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingImport, onDismiss: { importPath = .init() }) {
            ImportWalletFlow(
                navigationPath: $importPath,
                onDismiss: { isShowingImport = false },
                onCompleted: { _ in isShowingImport = false }
            )
            .id(sheetDirectionKey)
            .apertureEnvironment()
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

    private var walletsEmptyDetail: LocalizedStringKey {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return "Try a different wallet name, address, or network."
        }
        return "Adjust Filter & Sort to bring hidden wallets back into view."
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
                            .foregroundStyle(UniColors.Feedback.Success.foreground)
                            .padding(.horizontal, UniSpacing.xs)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(UniColors.Feedback.Success.background)
                            )
                    }
                }
                // Balance as the subtitle — same layout as the wallet
                // switcher sheet (2026-06-19 user direction): footnote /
                // secondary / monospaced-digit / forced-LTR. The
                // "imported from…" kind subtitle was removed; it lives on
                // the wallet detail screen's Kind row.
                Text(WalletFormatting.fiat(fiatBalance(for: wallet), currencyCode: currencyCode, hidden: hideBalances))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
                if wallet.requiresBackup {
                    Text("Not backed up")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Feedback.Warning.foreground)
                }
            }

            Spacer(minLength: UniSpacing.s)
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniListRowHitTarget()
    }

    private func entryRow(systemImage: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.s) {
            SettingsIconTile(
                systemImage: systemImage,
                tint: .blue,
                compactTint: UniColors.Icon.accent
            )
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, UniSpacing.xxs)
        .uniListRowHitTarget()
    }

    // MARK: - Secret filters

    /// `true` iff this wallet's secret material lives in GRDB.
    private func walletHasStoredSecret(_ wallet: WalletRecord) -> Bool {
        switch wallet.kind {
        case .importedKey:
            return hasStoredSecret(kind: .privateKey, for: wallet.id)
        case .created, .importedMnemonic:
            return hasStoredSecret(kind: .mnemonic, for: wallet.id)
        case .watchOnly:
            return false
        }
    }

    private func hasStoredSecret(kind: WalletSecretKind, for walletId: UUID) -> Bool {
        switch kind {
        case .seed:
            return WalletSecretPersistence.hasSecret(kind: .seed, for: walletId, database: AppDatabase.shared)
        case .mnemonic:
            if let words = try? WalletSecretPersistence.loadMnemonic(for: walletId, database: AppDatabase.shared),
               !words.isEmpty {
                return true
            }
            return false
        case .privateKey:
            if let key = try? WalletSecretPersistence.loadPrivateKey(for: walletId, database: AppDatabase.shared),
               !key.isEmpty {
                return true
            }
            return false
        }
    }

    // MARK: - Reorder

    private func moveWallets(from source: IndexSet, to destination: Int) {
        var reordered = wallets
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            try WalletRepository(database: AppDatabase.shared).updateSortOrders(reordered.map(\.id))
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
    case dateUpdated
    case walletType
    case networks

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .custom:    return "Custom order"
        case .name:      return "Name"
        case .balance:   return "Balance"
        case .dateAdded: return "Date added"
        case .dateUpdated: return "Last updated"
        case .walletType:  return "Wallet type"
        case .networks:    return "Networks"
        }
    }
}

enum WalletsListActiveScope: String, CaseIterable, Identifiable {
    case all
    case active
    case inactive

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all:      return "All"
        case .active:   return "Active"
        case .inactive: return "Inactive"
        }
    }
}

enum WalletsListVisibilityScope: String, CaseIterable, Identifiable {
    case all
    case visible
    case hidden

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all:     return "All"
        case .visible: return "Visible"
        case .hidden:  return "Hidden"
        }
    }
}

enum WalletsListBackupScope: String, CaseIterable, Identifiable {
    case all
    case needsBackup
    case backedUp
    case manualBackup

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all:          return "All"
        case .needsBackup:  return "Needs backup"
        case .backedUp:     return "Backed up"
        case .manualBackup: return "Manual backup done"
        }
    }
}

enum WalletsListBalanceScope: String, CaseIterable, Identifiable {
    case all
    case withBalance
    case empty

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all:         return "All"
        case .withBalance: return "With balance"
        case .empty:       return "Empty"
        }
    }
}

enum WalletsListNetworkScope: String, CaseIterable, Identifiable {
    case all
    case singleNetwork
    case multiNetwork

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all:           return "All"
        case .singleNetwork: return "Single network"
        case .multiNetwork:  return "Multi-network"
        }
    }
}

enum WalletsListSecretScope: String, CaseIterable, Identifiable {
    case all
    case canSign
    case noSigningKey

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all:          return "All"
        case .canSign:      return "Can sign"
        case .noSigningKey: return "No signing key"
        }
    }
}

enum WalletsListDateRange: String, CaseIterable, Identifiable {
    case all
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .all:   return "All"
        case .day:   return "24h"
        case .week:  return "7d"
        case .month: return "30d"
        case .year:  return "1y"
        }
    }

    func cutoff(from reference: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .all:
            return nil
        case .day:
            return calendar.date(byAdding: .day, value: -1, to: reference)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: reference)
        case .month:
            return calendar.date(byAdding: .day, value: -30, to: reference)
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: reference)
        }
    }
}

enum WalletsListFilterSupport {
    static let defaultSelectedJSON = "[]"

    static func decode(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }

    static func encode(_ set: Set<String>) -> String {
        let sorted = Array(set).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8)
        else { return defaultSelectedJSON }
        return json
    }
}

/// The Wallets list **Filter & Sort** sheet (2026-06-20 — replaces the Edit
/// button). Mirrors the wallet-home filter pattern: every control is an
/// `@GRDBStorage` write that `WalletsListView` reads live, so "Done" is just
/// "close" — the list is already updated.
struct WalletsListFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @GRDBStorage("walletsListSortKey") private var sortKeyRaw: String = WalletsListSortKey.custom.rawValue
    @GRDBStorage("walletsListSortAscending") private var sortAscending: Bool = true
    @GRDBStorage("walletsListShowCreated") private var showCreated: Bool = true
    @GRDBStorage("walletsListShowImportedMnemonic") private var showImportedMnemonic: Bool = true
    @GRDBStorage("walletsListShowImportedKey") private var showImportedKey: Bool = true
    @GRDBStorage("walletsListShowWatchOnly") private var showWatchOnly: Bool = true
    @GRDBStorage("walletsListActiveScope") private var activeScopeRaw: String = WalletsListActiveScope.all.rawValue
    @GRDBStorage("walletsListVisibilityScope") private var visibilityScopeRaw: String = WalletsListVisibilityScope.all.rawValue
    @GRDBStorage("walletsListBackupScope") private var backupScopeRaw: String = WalletsListBackupScope.all.rawValue
    @GRDBStorage("walletsListOnlyUnbackedUp") private var legacyOnlyUnbackedUp: Bool = false
    @GRDBStorage("walletsListBalanceScope") private var balanceScopeRaw: String = WalletsListBalanceScope.all.rawValue
    @GRDBStorage("walletsListMinFiat") private var minFiatRaw: String = ""
    @GRDBStorage("walletsListMaxFiat") private var maxFiatRaw: String = ""
    @GRDBStorage("walletsListNetworkScope") private var networkScopeRaw: String = WalletsListNetworkScope.all.rawValue
    @GRDBStorage("walletsListSelectedNetworks") private var selectedNetworksJSON: String = WalletsListFilterSupport.defaultSelectedJSON
    @GRDBStorage("walletsListSecretScope") private var secretScopeRaw: String = WalletsListSecretScope.all.rawValue
    @GRDBStorage("walletsListOnlyPassphrase") private var onlyPassphrase: Bool = false
    @GRDBStorage("walletsListDateRange") private var dateRangeRaw: String = WalletsListDateRange.all.rawValue
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var isShowingResetConfirm: Bool = false

    private var isCustomSort: Bool { sortKeyRaw == WalletsListSortKey.custom.rawValue }
    private var selectedNetworkCount: Int { WalletsListFilterSupport.decode(selectedNetworksJSON).count }
    private var availableNetworkCount: Int { SupportedChain.allCases.count }

    var body: some View {
        NavigationStack {
            List {
                sortSection
                statusSection
                kindSection
                holdingsSection
                networksSection
                securitySection
                dateSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Filter & Sort"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasNonDefaultFilters {
                        Button("Reset") { isShowingResetConfirm = true }
                            .tint(UniColors.Feedback.Error.foreground)
                    }
                }
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
            .onAppear(perform: migrateLegacyBackupFilter)
        }
    }

    private var hasNonDefaultFilters: Bool {
        sortKeyRaw != WalletsListSortKey.custom.rawValue
            || sortAscending != true
            || showCreated != true
            || showImportedMnemonic != true
            || showImportedKey != true
            || showWatchOnly != true
            || activeScopeRaw != WalletsListActiveScope.all.rawValue
            || visibilityScopeRaw != WalletsListVisibilityScope.all.rawValue
            || backupScopeRaw != WalletsListBackupScope.all.rawValue
            || legacyOnlyUnbackedUp != false
            || balanceScopeRaw != WalletsListBalanceScope.all.rawValue
            || minFiatRaw != ""
            || maxFiatRaw != ""
            || networkScopeRaw != WalletsListNetworkScope.all.rawValue
            || !WalletsListFilterSupport.decode(selectedNetworksJSON).isEmpty
            || secretScopeRaw != WalletsListSecretScope.all.rawValue
            || onlyPassphrase != false
            || dateRangeRaw != WalletsListDateRange.all.rawValue
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
            .listRowBackground(UniColors.List.rowBackground)

            Toggle(isOn: $sortAscending) {
                Text("Ascending order").font(UniTypography.body).foregroundStyle(isCustomSort ? UniColors.Text.disabled : UniColors.Text.primary)
            }
            .tint(UniColors.Button.Primary.tint)
            .disabled(isCustomSort)
            .listRowBackground(UniColors.List.rowBackground)
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

    private var statusSection: some View {
        Section {
            Picker(selection: $activeScopeRaw) {
                ForEach(WalletsListActiveScope.allCases) { scope in
                    Text(scope.label).tag(scope.rawValue)
                }
            } label: {
                Text("Active state").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .listRowBackground(UniColors.List.rowBackground)

            Picker(selection: $visibilityScopeRaw) {
                ForEach(WalletsListVisibilityScope.allCases) { scope in
                    Text(scope.label).tag(scope.rawValue)
                }
            } label: {
                Text("Visibility").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Status").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private var holdingsSection: some View {
        Section {
            Picker(selection: $balanceScopeRaw) {
                ForEach(WalletsListBalanceScope.allCases) { scope in
                    Text(scope.label).tag(scope.rawValue)
                }
            } label: {
                Text("Balance").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .listRowBackground(UniColors.List.rowBackground)

            amountField(placeholder: "Minimum", text: $minFiatRaw)
                .listRowBackground(UniColors.List.rowBackground)

            amountField(placeholder: "Maximum", text: $maxFiatRaw)
                .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Holdings").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        } footer: {
            Text("Balance filters use cached wallet totals in \(currencyCode).")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var networksSection: some View {
        Section {
            Picker(selection: $networkScopeRaw) {
                ForEach(WalletsListNetworkScope.allCases) { scope in
                    Text(scope.label).tag(scope.rawValue)
                }
            } label: {
                Text("Coverage").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .listRowBackground(UniColors.List.rowBackground)

            NavigationLink {
                WalletsListNetworkFilterView(selectedNetworksJSON: $selectedNetworksJSON)
            } label: {
                filterLink(
                    systemImage: "globe",
                    title: "Networks",
                    readout: networkReadout
                )
            }
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Networks").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private var securitySection: some View {
        Section {
            Picker(selection: $backupScopeRaw) {
                ForEach(WalletsListBackupScope.allCases) { scope in
                    Text(scope.label).tag(scope.rawValue)
                }
            } label: {
                Text("Backup").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .onChange(of: backupScopeRaw) { _, _ in legacyOnlyUnbackedUp = false }
            .listRowBackground(UniColors.List.rowBackground)

            Picker(selection: $secretScopeRaw) {
                ForEach(WalletsListSecretScope.allCases) { scope in
                    Text(scope.label).tag(scope.rawValue)
                }
            } label: {
                Text("Signing key").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .listRowBackground(UniColors.List.rowBackground)

            Toggle(isOn: $onlyPassphrase) {
                Text("Only wallets with passphrase").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .tint(UniColors.Button.Primary.tint)
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Security").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private var dateSection: some View {
        Section {
            Picker(selection: $dateRangeRaw) {
                ForEach(WalletsListDateRange.allCases) { range in
                    Text(range.label).tag(range.rawValue)
                }
            } label: {
                Text("Date added").font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            }
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Added").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        }
    }

    private func kindToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
        }
        .tint(UniColors.Button.Primary.tint)
        .listRowBackground(UniColors.List.rowBackground)
    }

    private var networkReadout: String {
        guard selectedNetworkCount > 0 else {
            return String.apertureLocalized("All")
        }
        return String(
            format: String.apertureLocalized("%lld of %lld"),
            Int64(selectedNetworkCount),
            Int64(availableNetworkCount)
        )
    }

    private func filterLink(
        systemImage: String,
        title: LocalizedStringKey,
        readout: String
    ) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Text(verbatim: readout)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private func amountField(placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(verbatim: currencyCode)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(minWidth: 40, alignment: .leading)
                .monospacedDigit()
            UniTextField(
                placeholder: placeholder,
                text: text,
                fill: Color.clear,
                verticalPadding: UniSpacing.xs,
                showsChrome: false,
                keyboardType: .decimalPad
            )
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private func migrateLegacyBackupFilter() {
        guard legacyOnlyUnbackedUp else { return }
        backupScopeRaw = WalletsListBackupScope.needsBackup.rawValue
        legacyOnlyUnbackedUp = false
    }

    private func resetAll() {
        sortKeyRaw = WalletsListSortKey.custom.rawValue
        sortAscending = true
        showCreated = true
        showImportedMnemonic = true
        showImportedKey = true
        showWatchOnly = true
        activeScopeRaw = WalletsListActiveScope.all.rawValue
        visibilityScopeRaw = WalletsListVisibilityScope.all.rawValue
        backupScopeRaw = WalletsListBackupScope.all.rawValue
        legacyOnlyUnbackedUp = false
        balanceScopeRaw = WalletsListBalanceScope.all.rawValue
        minFiatRaw = ""
        maxFiatRaw = ""
        networkScopeRaw = WalletsListNetworkScope.all.rawValue
        selectedNetworksJSON = WalletsListFilterSupport.defaultSelectedJSON
        secretScopeRaw = WalletsListSecretScope.all.rawValue
        onlyPassphrase = false
        dateRangeRaw = WalletsListDateRange.all.rawValue
    }
}

private struct WalletsListNetworkFilterView: View {
    @Binding var selectedNetworksJSON: String
    @State private var searchText: String = ""

    private var selectedNetworks: Set<String> {
        WalletsListFilterSupport.decode(selectedNetworksJSON)
    }

    private var chains: [SupportedChain] {
        let sorted = SupportedChain.allCases.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayName.localizedStandardContains(query)
                || $0.ticker.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    selectedNetworksJSON = WalletsListFilterSupport.defaultSelectedJSON
                } label: {
                    HStack(spacing: UniSpacing.s) {
                        Image(systemName: "circle.grid.2x2")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(UniColors.Icon.secondary)
                            .frame(width: 28, alignment: .center)
                        Text("All networks")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        if selectedNetworks.isEmpty {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(UniColors.Tint.accent)
                        }
                    }
                    .padding(.vertical, UniSpacing.xxs)
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            Section {
                ForEach(chains, id: \.rawValue) { chain in
                    networkRow(chain)
                        .listRowBackground(UniColors.List.rowBackground)
                }
            } header: {
                Text("Networks")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Networks"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("Search networks"))
    }

    private func networkRow(_ chain: SupportedChain) -> some View {
        Button {
            toggle(chain)
        } label: {
            HStack(spacing: UniSpacing.s) {
                CoinMark(chain: chain, tokenSymbol: chain.ticker)
                    .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: chain.displayName)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(verbatim: chain.ticker)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.secondary)
                }

                Spacer()

                if selectedNetworks.contains(chain.rawValue) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(UniColors.Tint.accent)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
            .uniListRowHitTarget()
        }
        .buttonStyle(.uniListRow)
        .accessibilityLabel(Text("\(chain.displayName) network"))
    }

    private func toggle(_ chain: SupportedChain) {
        var set = selectedNetworks
        if set.contains(chain.rawValue) {
            set.remove(chain.rawValue)
        } else {
            set.insert(chain.rawValue)
        }
        selectedNetworksJSON = WalletsListFilterSupport.encode(set)
    }
}
