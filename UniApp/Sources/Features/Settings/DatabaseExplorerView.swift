import SwiftData
import SwiftUI

struct DatabaseExplorerView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var summaries: [DatabaseTableOverview] = []
    @State private var totalRecords = 0
    @State private var encryptedBlobCount = 0
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                DatabaseSummaryCard(
                    totalRecords: totalRecords,
                    tableCount: DatabaseTable.visibleTables.count,
                    encryptedBlobCount: encryptedBlobCount
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if isLoading {
                Section {
                    HStack(spacing: UniSpacing.s) {
                        ProgressView()
                        Text("Reading database")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                    }
                    .padding(.vertical, UniSpacing.xs)
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Tint.orange)
                        .padding(.vertical, UniSpacing.xs)
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            ForEach(DatabaseCategory.allCases) { category in
                Section(category.title) {
                    ForEach(DatabaseTable.visibleTables.filter { $0.category == category }) { table in
                        NavigationLink {
                            DatabaseTableView(table: table)
                        } label: {
                            let overview = summary(for: table)
                            DatabaseTableRow(
                                table: table,
                                count: overview?.count ?? 0,
                                lastUpdated: overview?.lastUpdated
                            )
                        }
                        .listRowBackground(UniColors.List.rowBackground)
                    }
                }
            }

            Section {
                Text("Wallet-owned secrets, addresses, chain state, and UTXOs are grouped under each wallet. Plaintext secrets require passcode or Face ID when a local lock is enabled; otherwise they are shown with a safety warning.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .padding(.vertical, UniSpacing.xs)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Database"))
        .navigationBarTitleDisplayMode(.large)
        .task {
            reloadSummaries()
        }
    }

    private func summary(for table: DatabaseTable) -> DatabaseTableOverview? {
        summaries.first { $0.table == table }
    }

    @MainActor
    private func reloadSummaries() {
        isLoading = true
        loadError = nil

        let loaded = DatabaseTable.allCases.map { table in
            DatabaseTableOverview(
                table: table,
                count: count(for: table),
                lastUpdated: lastUpdated(for: table)
            )
        }
        summaries = loaded
        totalRecords = loaded.reduce(0) { $0 + $1.count }
        encryptedBlobCount = count(for: .walletSecrets) + chainStatesWithEncryptedKeysCount()
        isLoading = false
    }

    private func count(for table: DatabaseTable) -> Int {
        do {
            switch table {
            case .wallets: return try count(WalletRecord.self)
            case .walletSecrets: return try count(WalletSecretRecord.self)
            case .walletAddresses: return try count(WalletAddressRecord.self)
            case .chainStates: return try count(ChainStateRecord.self)
            case .chainUTXOs: return try count(ChainUTXORecord.self)
            case .transactions: return try count(TransactionRecord.self)
            case .tokenBalances: return try count(TokenBalanceRecord.self)
            case .walletChartSnapshots: return try count(WalletChartSnapshotRecord.self)
            case .cachedPrices: return try count(CachedPriceRecord.self)
            case .historicalPrices: return try count(HistoricalPriceRecord.self)
            case .priceSnapshots: return try count(PriceSnapshotRecord.self)
            case .marketAssets: return try count(MarketAssetRecord.self)
            case .marketCharts: return try count(MarketChartCacheRecord.self)
            case .marketWatchlist: return try count(MarketWatchlistRecord.self)
            case .chains: return try count(ChainRecord.self)
            case .assets: return try count(AssetRecord.self)
            case .customTokens: return try count(CustomTokenRecord.self)
            case .appSettings: return try count(AppSettingsRecord.self)
            case .appMetadata: return try count(AppMetadataRecord.self)
            case .biometricEnrollments: return try count(BiometricEnrollmentRecord.self)
            case .syncStatus: return try count(SyncStatusRecord.self)
            }
        } catch {
            loadError = "Some database tables could not be read."
            return 0
        }
    }

    private func count<T: PersistentModel>(_ modelType: T.Type) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<T>())
    }

    private func chainStatesWithEncryptedKeysCount() -> Int {
        let states = (try? modelContext.fetch(FetchDescriptor<ChainStateRecord>())) ?? []
        return states.filter { $0.encryptedPrivateKey != nil }.count
    }

    private func lastUpdated(for table: DatabaseTable) -> Date? {
        do {
            switch table {
            case .wallets:
                var descriptor = FetchDescriptor<WalletRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            case .walletSecrets:
                var descriptor = FetchDescriptor<WalletSecretRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            case .walletAddresses:
                return newest(try modelContext.fetch(FetchDescriptor<WalletAddressRecord>()).map(\.lastScannedAt))
            case .chainStates:
                return newest(try modelContext.fetch(FetchDescriptor<ChainStateRecord>()).map(\.lastSyncedAt))
            case .chainUTXOs:
                var descriptor = FetchDescriptor<ChainUTXORecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            case .transactions:
                var descriptor = FetchDescriptor<TransactionRecord>(sortBy: [SortDescriptor(\.occurredAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.occurredAt
            case .tokenBalances:
                var descriptor = FetchDescriptor<TokenBalanceRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            case .walletChartSnapshots:
                var descriptor = FetchDescriptor<WalletChartSnapshotRecord>(sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.capturedAt
            case .cachedPrices:
                var descriptor = FetchDescriptor<CachedPriceRecord>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.fetchedAt
            case .historicalPrices:
                var descriptor = FetchDescriptor<HistoricalPriceRecord>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.fetchedAt
            case .priceSnapshots:
                var descriptor = FetchDescriptor<PriceSnapshotRecord>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.fetchedAt
            case .marketAssets:
                var descriptor = FetchDescriptor<MarketAssetRecord>(sortBy: [SortDescriptor(\.lastUpdatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.lastUpdatedAt
            case .marketCharts:
                var descriptor = FetchDescriptor<MarketChartCacheRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            case .marketWatchlist:
                var descriptor = FetchDescriptor<MarketWatchlistRecord>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.addedAt
            case .chains, .assets:
                return nil
            case .customTokens:
                var descriptor = FetchDescriptor<CustomTokenRecord>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.addedAt
            case .appSettings:
                var descriptor = FetchDescriptor<AppSettingsRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            case .appMetadata:
                var descriptor = FetchDescriptor<AppMetadataRecord>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.lastOpenedAt
            case .biometricEnrollments:
                var descriptor = FetchDescriptor<BiometricEnrollmentRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            case .syncStatus:
                var descriptor = FetchDescriptor<SyncStatusRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                return try modelContext.fetch(descriptor).first?.updatedAt
            }
        } catch {
            loadError = "Some database metadata could not be read."
            return nil
        }
    }

    private func newest(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }
}

private struct DatabaseTableOverview: Identifiable, Hashable {
    let table: DatabaseTable
    let count: Int
    let lastUpdated: Date?

    var id: DatabaseTable { table }
}

private struct DatabaseTableView: View {
    let table: DatabaseTable

    @Environment(\.modelContext) private var modelContext
    @State private var records: [DatabaseRecordSnapshot] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredRecords: [DatabaseRecordSnapshot] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter { $0.searchableText.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        List {
            Section {
                DatabaseTableHeader(table: table, count: records.count)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if isLoading {
                Section {
                    HStack(spacing: UniSpacing.s) {
                        ProgressView()
                        Text("Loading rows")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                    }
                    .padding(.vertical, UniSpacing.xs)
                }
                .listRowBackground(UniColors.List.rowBackground)
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label("Couldn’t load table", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, UniSpacing.xl)
                    .listRowBackground(UniColors.List.rowBackground)
                }
            } else if filteredRecords.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No records", systemImage: table.systemImage)
                    } description: {
                        if searchText.isEmpty {
                            Text("This table is empty on this device.")
                        } else {
                            Text("No rows match your search.")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, UniSpacing.xl)
                    .listRowBackground(UniColors.List.rowBackground)
                }
            } else {
                Section {
                    ForEach(filteredRecords) { record in
                        if table == .wallets, let walletId = record.walletId {
                            NavigationLink {
                                DatabaseWalletDetailView(walletId: walletId)
                            } label: {
                                DatabaseRecordRow(record: record)
                            }
                            .listRowBackground(UniColors.List.rowBackground)
                        } else {
                            NavigationLink {
                                DatabaseRecordDetailView(record: record)
                            } label: {
                                DatabaseRecordRow(record: record)
                            }
                            .listRowBackground(UniColors.List.rowBackground)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text(table.title))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search rows"))
        .task(id: table) {
            loadRows()
        }
    }

    @MainActor
    private func loadRows() {
        isLoading = true
        loadError = nil

        do {
            records = try records(for: table)
        } catch {
            records = []
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    private func records(for table: DatabaseTable) throws -> [DatabaseRecordSnapshot] {
        switch table {
        case .wallets:
            return try modelContext.fetch(FetchDescriptor<WalletRecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { DatabaseExplorerView.snapshot(wallet: $0) }
        case .walletSecrets:
            return try modelContext.fetch(FetchDescriptor<WalletSecretRecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { secret in
                    DatabaseExplorerView.snapshot(
                        secret: secret,
                        plaintext: DatabaseExplorerView.plaintext(secret: secret, in: modelContext)
                    )
                }
        case .walletAddresses:
            let chainStates = try modelContext.fetch(FetchDescriptor<ChainStateRecord>())
            return try modelContext.fetch(FetchDescriptor<WalletAddressRecord>())
                .sorted { lhs, rhs in
                    (lhs.chainRaw, lhs.address) < (rhs.chainRaw, rhs.address)
                }
                .map { address in
                    DatabaseExplorerView.snapshot(
                        address: address,
                        privateKey: DatabaseExplorerView.plaintextPrivateKey(for: address, chainStates: chainStates)
                    )
                }
        case .chainStates:
            return try modelContext.fetch(FetchDescriptor<ChainStateRecord>())
                .sorted { lhs, rhs in
                    (lhs.walletId.uuidString, lhs.chainRaw) < (rhs.walletId.uuidString, rhs.chainRaw)
                }
                .map { chainState in
                    DatabaseExplorerView.snapshot(
                        chainState: chainState,
                        privateKey: DatabaseExplorerView.plaintextPrivateKey(for: chainState)
                    )
                }
        case .chainUTXOs:
            return try modelContext.fetch(FetchDescriptor<ChainUTXORecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { DatabaseExplorerView.snapshot(utxo: $0) }
        case .transactions:
            return try modelContext.fetch(FetchDescriptor<TransactionRecord>())
                .sorted { $0.occurredAt > $1.occurredAt }
                .map { DatabaseExplorerView.snapshot(transaction: $0) }
        case .tokenBalances:
            return try modelContext.fetch(FetchDescriptor<TokenBalanceRecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { DatabaseExplorerView.snapshot(balance: $0) }
        case .walletChartSnapshots:
            return try modelContext.fetch(FetchDescriptor<WalletChartSnapshotRecord>())
                .sorted { $0.capturedAt > $1.capturedAt }
                .map { DatabaseExplorerView.snapshot(walletChart: $0) }
        case .cachedPrices:
            return try modelContext.fetch(FetchDescriptor<CachedPriceRecord>())
                .sorted { $0.fetchedAt > $1.fetchedAt }
                .map { DatabaseExplorerView.snapshot(cachedPrice: $0) }
        case .historicalPrices:
            return try modelContext.fetch(FetchDescriptor<HistoricalPriceRecord>())
                .sorted { lhs, rhs in
                    if lhs.dayKey == rhs.dayKey { return lhs.symbol < rhs.symbol }
                    return lhs.dayKey > rhs.dayKey
                }
                .map { DatabaseExplorerView.snapshot(historicalPrice: $0) }
        case .priceSnapshots:
            return try modelContext.fetch(FetchDescriptor<PriceSnapshotRecord>())
                .sorted { $0.fetchedAt > $1.fetchedAt }
                .map { DatabaseExplorerView.snapshot(priceSnapshot: $0) }
        case .marketAssets:
            return try modelContext.fetch(FetchDescriptor<MarketAssetRecord>())
                .sorted { $0.rank < $1.rank }
                .map { DatabaseExplorerView.snapshot(marketAsset: $0) }
        case .marketCharts:
            return try modelContext.fetch(FetchDescriptor<MarketChartCacheRecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { DatabaseExplorerView.snapshot(marketChart: $0) }
        case .marketWatchlist:
            return try modelContext.fetch(FetchDescriptor<MarketWatchlistRecord>())
                .sorted { $0.addedAt > $1.addedAt }
                .map { DatabaseExplorerView.snapshot(watchlist: $0) }
        case .chains:
            return try modelContext.fetch(FetchDescriptor<ChainRecord>())
                .sorted { $0.sortIndex < $1.sortIndex }
                .map { DatabaseExplorerView.snapshot(chain: $0) }
        case .assets:
            return try modelContext.fetch(FetchDescriptor<AssetRecord>())
                .sorted { lhs, rhs in
                    (lhs.chainRaw, lhs.symbol, lhs.contract) < (rhs.chainRaw, rhs.symbol, rhs.contract)
                }
                .map { DatabaseExplorerView.snapshot(asset: $0) }
        case .customTokens:
            return try modelContext.fetch(FetchDescriptor<CustomTokenRecord>())
                .sorted { $0.addedAt > $1.addedAt }
                .map { DatabaseExplorerView.snapshot(customToken: $0) }
        case .appSettings:
            return try modelContext.fetch(FetchDescriptor<AppSettingsRecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { DatabaseExplorerView.snapshot(appSettings: $0) }
        case .appMetadata:
            return try modelContext.fetch(FetchDescriptor<AppMetadataRecord>())
                .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
                .map { DatabaseExplorerView.snapshot(appMetadata: $0) }
        case .biometricEnrollments:
            return try modelContext.fetch(FetchDescriptor<BiometricEnrollmentRecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { DatabaseExplorerView.snapshot(biometric: $0) }
        case .syncStatus:
            return try modelContext.fetch(FetchDescriptor<SyncStatusRecord>())
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { DatabaseExplorerView.snapshot(syncStatus: $0) }
        }
    }
}

private struct DatabaseRecordDetailView: View {
    let record: DatabaseRecordSnapshot

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    HStack(alignment: .top, spacing: UniSpacing.s) {
                        DatabaseIconTile(systemImage: record.table.systemImage, tint: record.table.tint)
                        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                            Text(verbatim: record.title)
                                .font(UniTypography.title3)
                                .foregroundStyle(UniColors.Text.primary)
                            Text(verbatim: record.subtitle)
                                .font(UniTypography.subheadline)
                                .foregroundStyle(UniColors.Text.secondary)
                        }
                    }

                    if !record.detail.isEmpty {
                        Text(verbatim: record.detail)
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, UniSpacing.xs)
            }
            .listRowBackground(UniColors.List.rowBackground)

            Section("Fields") {
                ForEach(record.fields) { field in
                    VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                        HStack(spacing: UniSpacing.xs) {
                            Text(verbatim: field.label)
                                .font(UniTypography.caption1)
                                .foregroundStyle(UniColors.Text.tertiary)
                                .textCase(.uppercase)
                        }

                        Text(verbatim: field.value)
                            .font(field.isLongValue ? UniTypography.footnote : UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, UniSpacing.xxs)
                }
            }
            .listRowBackground(UniColors.List.rowBackground)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text(record.table.title))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DatabaseWalletDetailView: View {
    let walletId: UUID

    @Environment(\.modelContext) private var modelContext
    @State private var wallet: WalletRecord?
    @State private var secrets: [WalletSecretRecord] = []
    @State private var addresses: [WalletAddressRecord] = []
    @State private var chainStates: [ChainStateRecord] = []
    @State private var utxos: [ChainUTXORecord] = []
    @State private var revealedSecrets: [String: String] = [:]
    @State private var revealedAddressPrivateKeys: [UUID: String] = [:]
    @State private var revealedChainPrivateKeys: [UUID: String] = [:]
    @State private var isLoading = true
    @State private var isShowingPinGate = false
    @State private var revealError: String?
    @State private var loadError: String?

    private var hasLocalSecretGate: Bool {
        PinCodeStorage.hasPin || PinCodePreference.isBiometricEnabled()
    }

    var body: some View {
        List {
            if let wallet {
                Section {
                    DatabaseWalletBundleCard(
                        wallet: wallet,
                        secretCount: secrets.count,
                        addressCount: addresses.count,
                        chainStateCount: chainStates.count,
                        utxoCount: utxos.count
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: UniSpacing.s) {
                        ProgressView()
                        Text("Loading wallet database")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                    }
                    .padding(.vertical, UniSpacing.xs)
                }
                .listRowBackground(UniColors.List.rowBackground)
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label("Couldn’t load wallet", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, UniSpacing.xl)
                }
                .listRowBackground(UniColors.List.rowBackground)
            } else {
                secretsSection
                childRecordsSection(
                    title: "Addresses",
                    emptyTitle: "No addresses",
                    emptySubtitle: "This wallet has no persisted address rows.",
                    records: addresses
                        .sorted { ($0.chainRaw, $0.address) < ($1.chainRaw, $1.address) }
                        .map { address in
                            DatabaseExplorerView.snapshot(
                                address: address,
                                privateKey: revealedAddressPrivateKeys[address.id]
                            )
                        }
                )
                childRecordsSection(
                    title: "Chain State",
                    emptyTitle: "No chain state",
                    emptySubtitle: "No per-chain aggregate rows are stored for this wallet yet.",
                    records: chainStates
                        .sorted { $0.chainRaw < $1.chainRaw }
                        .map { chainState in
                            DatabaseExplorerView.snapshot(
                                chainState: chainState,
                                privateKey: revealedChainPrivateKeys[chainState.id]
                            )
                        }
                )
                childRecordsSection(
                    title: "UTXOs",
                    emptyTitle: "No UTXOs",
                    emptySubtitle: "This wallet has no persisted unspent outputs.",
                    records: utxos
                        .sorted { ($0.chainRaw, $0.txid, $0.vout) < ($1.chainRaw, $1.txid, $1.vout) }
                        .map(DatabaseExplorerView.snapshot(utxo:))
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text(wallet?.name ?? "Wallet"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: walletId) { loadWalletBundle() }
        .fullScreenCover(isPresented: $isShowingPinGate) {
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isShowingPinGate = false
                        revealWalletSecrets()
                    },
                    onCancel: {
                        isShowingPinGate = false
                    },
                    onForgotPin: {
                        isShowingPinGate = false
                    },
                    allowsBiometrics: true
                )
            }
            .background(UniColors.Background.primary.ignoresSafeArea())
            .uniAppEnvironment()
        }
    }

    private var secretsSection: some View {
        Section {
            if secrets.isEmpty {
                ContentUnavailableView {
                    Label("No wallet secrets", systemImage: "key.slash")
                } description: {
                    Text("This wallet has no encrypted mnemonic or imported private-key row.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.xl)
            } else {
                HStack(alignment: .top, spacing: UniSpacing.s) {
                    Image(systemName: hasLocalSecretGate ? "lock.open" : "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(hasLocalSecretGate ? UniColors.Tint.indigo : UniColors.Tint.orange)
                        .frame(width: 30, height: 30)
                        .background((hasLocalSecretGate ? UniColors.Tint.indigo : UniColors.Tint.orange).opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                        Text("Secrets visible")
                            .font(UniTypography.bodyEmphasized)
                            .foregroundStyle(UniColors.Text.primary)
                        Text(hasLocalSecretGate ? "Database inspector shows decrypted local secret rows on this screen." : "No Aperture passcode or Face ID is enabled. Turn one on to require authentication before opening the app.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, UniSpacing.xxs)

                if let revealError {
                    Label(revealError, systemImage: "exclamationmark.triangle")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Tint.orange)
                        .padding(.vertical, UniSpacing.xxs)
                }

                ForEach(secrets.sorted { $0.kindRaw < $1.kindRaw }, id: \.key) { secret in
                    DatabaseSecretBundleRow(
                        record: DatabaseExplorerView.snapshot(secret: secret, plaintext: revealedSecrets[secret.key]),
                        revealedValue: revealedSecrets[secret.key]
                    )
                }
            }
        } header: {
            Text("Wallet Secrets")
        } footer: {
            Text("Plaintext is never stored in the inspector. This screen decrypts local encrypted SwiftData rows for viewing only.")
        }
        .listRowBackground(UniColors.List.rowBackground)
    }

    @ViewBuilder
    private func childRecordsSection(
        title: LocalizedStringKey,
        emptyTitle: LocalizedStringKey,
        emptySubtitle: LocalizedStringKey,
        records: [DatabaseRecordSnapshot]
    ) -> some View {
        Section(title) {
            if records.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "tray")
                } description: {
                    Text(emptySubtitle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.xl)
            } else {
                ForEach(records) { record in
                    NavigationLink {
                        DatabaseRecordDetailView(record: record)
                    } label: {
                        DatabaseRecordRow(record: record)
                    }
                }
            }
        }
        .listRowBackground(UniColors.List.rowBackground)
    }

    @MainActor
    private func loadWalletBundle() {
        isLoading = true
        loadError = nil
        revealedSecrets = [:]
        revealedAddressPrivateKeys = [:]
        revealedChainPrivateKeys = [:]
        revealError = nil

        do {
            let ownerId = walletId
            let optionalOwnerId = Optional(walletId)
            var walletDescriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == ownerId }
            )
            walletDescriptor.fetchLimit = 1
            wallet = try modelContext.fetch(walletDescriptor).first
            secrets = try modelContext.fetch(
                FetchDescriptor<WalletSecretRecord>(
                    predicate: #Predicate { $0.walletId == ownerId }
                )
            )
            addresses = try modelContext.fetch(
                FetchDescriptor<WalletAddressRecord>(
                    predicate: #Predicate { $0.walletId == optionalOwnerId }
                )
            )
            chainStates = try modelContext.fetch(
                FetchDescriptor<ChainStateRecord>(
                    predicate: #Predicate { $0.walletId == ownerId }
                )
            )
            utxos = try modelContext.fetch(
                FetchDescriptor<ChainUTXORecord>(
                    predicate: #Predicate { $0.walletId == ownerId }
                )
            )
            revealWalletSecrets()
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    private func beginSecretReveal() {
        revealError = nil
        if !revealedSecrets.isEmpty || !revealedAddressPrivateKeys.isEmpty || !revealedChainPrivateKeys.isEmpty {
            revealedSecrets = [:]
            revealedAddressPrivateKeys = [:]
            revealedChainPrivateKeys = [:]
            return
        }
        guard hasLocalSecretGate else {
            revealWalletSecrets()
            return
        }
        isShowingPinGate = true
    }

    @MainActor
    private func revealWalletSecrets() {
        var unlocked: [String: String] = [:]
        var unlockedChainKeys: [UUID: String] = [:]
        var unlockedAddressKeys: [UUID: String] = [:]
        do {
            for secret in secrets {
                guard let kind = WalletSecretKind(rawValue: secret.kindRaw) else { continue }
                switch kind {
                case .mnemonic:
                    let words = try WalletSecretPersistence.loadMnemonic(for: secret.walletId, in: modelContext) ?? []
                    if !words.isEmpty {
                        unlocked[secret.key] = words.joined(separator: " ")
                    }
                case .privateKey:
                    if let key = try WalletSecretPersistence.loadPrivateKey(for: secret.walletId, in: modelContext),
                       !key.isEmpty {
                        unlocked[secret.key] = key
                    }
                }
            }
            for chainState in chainStates {
                if let key = DatabaseExplorerView.plaintextPrivateKey(for: chainState) {
                    unlockedChainKeys[chainState.id] = key
                }
            }
            for address in addresses {
                if let key = DatabaseExplorerView.plaintextPrivateKey(for: address, chainStates: chainStates) {
                    unlockedAddressKeys[address.id] = key
                }
            }
            revealedSecrets = unlocked
            revealedChainPrivateKeys = unlockedChainKeys
            revealedAddressPrivateKeys = unlockedAddressKeys

            let expectedSecretCount = secrets.count
            let expectedChainKeyCount = chainStates.filter { $0.encryptedPrivateKey != nil }.count
            let missingSecrets = expectedSecretCount > 0 && unlocked.count < expectedSecretCount
            let missingChainKeys = expectedChainKeyCount > 0 && unlockedChainKeys.count < expectedChainKeyCount
            revealError = (missingSecrets || missingChainKeys) ? "Some encrypted database secrets could not be opened on this iPhone." : nil
        } catch {
            revealedSecrets = [:]
            revealedChainPrivateKeys = [:]
            revealedAddressPrivateKeys = [:]
            revealError = "Couldn’t decrypt wallet secrets on this device."
        }
    }
}

private struct DatabaseWalletBundleCard: View {
    let wallet: WalletRecord
    let secretCount: Int
    let addressCount: Int
    let chainStateCount: Int
    let utxoCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                DatabaseIconTile(systemImage: "wallet.pass", tint: UniColors.Tint.indigo, size: 48)
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: wallet.name)
                        .font(UniTypography.title3)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(verbatim: wallet.id.uuidString)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .textSelection(.enabled)
                    Text(verbatim: wallet.kindRaw)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: UniSpacing.s), count: 2), spacing: UniSpacing.s) {
                DatabaseMetricTile(title: "Secrets", value: "\(secretCount)")
                DatabaseMetricTile(title: "Addresses", value: "\(addressCount)")
                DatabaseMetricTile(title: "Chains", value: "\(chainStateCount)")
                DatabaseMetricTile(title: "UTXOs", value: "\(utxoCount)")
            }
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DatabaseSecretBundleRow: View {
    let record: DatabaseRecordSnapshot
    let revealedValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            DatabaseRecordRow(record: record)

            if let revealedValue {
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text("Plaintext")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .textCase(.uppercase)
                    Text(verbatim: revealedValue)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(UniColors.Text.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(UniSpacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UniColors.Card.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}

private struct DatabaseSummaryCard: View {
    let totalRecords: Int
    let tableCount: Int
    let encryptedBlobCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                DatabaseIconTile(systemImage: "cylinder.split.1x2", tint: UniColors.Tint.indigo)
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text("Local database")
                        .font(UniTypography.title3)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Read-only view of SwiftData records stored on this device.")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }

            HStack(spacing: UniSpacing.s) {
                DatabaseMetricTile(title: "Records", value: Self.countString(totalRecords))
                DatabaseMetricTile(title: "Tables", value: "\(tableCount)")
                DatabaseMetricTile(title: "Encrypted", value: "\(encryptedBlobCount)")
            }
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private static func countString(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }
}

private struct DatabaseMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            Text(verbatim: title)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
            Text(verbatim: value)
                .font(UniTypography.bodyEmphasized.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UniSpacing.s)
        .background(UniColors.Card.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DatabaseTableHeader: View {
    let table: DatabaseTable
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            DatabaseIconTile(systemImage: table.systemImage, tint: table.tint, size: 48)
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(table.title)
                    .font(UniTypography.title2)
                    .foregroundStyle(UniColors.Text.primary)
                Text(table.subtitle)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                Text(verbatim: "\(count.formatted(.number.grouping(.automatic))) rows")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UniSpacing.m)
        .background(UniColors.Card.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DatabaseTableRow: View {
    let table: DatabaseTable
    let count: Int
    let lastUpdated: Date?

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            DatabaseIconTile(systemImage: table.systemImage, tint: table.tint)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(table.title)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text(table.subtitle)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: UniSpacing.s)

            VStack(alignment: .trailing, spacing: UniSpacing.xxs) {
                Text(verbatim: count.formatted(.number.grouping(.automatic)))
                    .font(UniTypography.bodyEmphasized.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: lastUpdated.map(DatabaseFormat.shortDate) ?? "Static")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}

private struct DatabaseRecordRow: View {
    let record: DatabaseRecordSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: record.title)
                        .font(UniTypography.bodyEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                        .lineLimit(1)
                    Text(verbatim: record.subtitle)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: UniSpacing.s)
                if !record.detail.isEmpty {
                    Text(verbatim: record.detail)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .lineLimit(1)
                }
            }

            if !record.badges.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: UniSpacing.xs) {
                        ForEach(record.badges, id: \.self) { badge in
                            Text(verbatim: badge)
                                .font(UniTypography.caption1)
                                .foregroundStyle(UniColors.Text.secondary)
                                .padding(.horizontal, UniSpacing.xs)
                                .padding(.vertical, UniSpacing.xxs)
                                .background(UniColors.Fill.tertiary, in: Capsule())
                        }
                    }
                }
                .scrollDisabled(record.badges.count < 4)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}

private struct DatabaseIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.opacity(0.15))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.72)
                    .padding(size * 0.18)
            }
            .accessibilityHidden(true)
    }
}

private enum DatabaseCategory: String, CaseIterable, Identifiable {
    case walletCore
    case activity
    case markets
    case catalog

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .walletCore: "Wallets & Keys"
        case .activity: "Balances & Activity"
        case .markets: "Markets & Prices"
        case .catalog: "Catalog & App State"
        }
    }
}

private enum DatabaseTable: String, CaseIterable, Identifiable, Hashable {
    case wallets
    case walletSecrets
    case walletAddresses
    case chainStates
    case chainUTXOs
    case transactions
    case tokenBalances
    case walletChartSnapshots
    case cachedPrices
    case historicalPrices
    case priceSnapshots
    case marketAssets
    case marketCharts
    case marketWatchlist
    case chains
    case assets
    case customTokens
    case appSettings
    case appMetadata
    case biometricEnrollments
    case syncStatus

    static var visibleTables: [DatabaseTable] {
        allCases.filter { !$0.isWalletOwnedChildTable }
    }

    var id: String { rawValue }

    private var isWalletOwnedChildTable: Bool {
        switch self {
        case .walletSecrets, .walletAddresses, .chainStates, .chainUTXOs:
            true
        default:
            false
        }
    }

    var category: DatabaseCategory {
        switch self {
        case .wallets, .walletSecrets, .walletAddresses, .chainStates, .chainUTXOs:
            .walletCore
        case .transactions, .tokenBalances, .walletChartSnapshots:
            .activity
        case .cachedPrices, .historicalPrices, .priceSnapshots, .marketAssets, .marketCharts, .marketWatchlist:
            .markets
        case .chains, .assets, .customTokens, .appSettings, .appMetadata, .biometricEnrollments, .syncStatus:
            .catalog
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .wallets: "Wallets"
        case .walletSecrets: "Wallet Secrets"
        case .walletAddresses: "Addresses"
        case .chainStates: "Chain State"
        case .chainUTXOs: "UTXOs"
        case .transactions: "Transactions"
        case .tokenBalances: "Token Balances"
        case .walletChartSnapshots: "Wallet Chart Snapshots"
        case .cachedPrices: "Cached Prices"
        case .historicalPrices: "Historical Prices"
        case .priceSnapshots: "Price Snapshots"
        case .marketAssets: "Market Assets"
        case .marketCharts: "Market Charts"
        case .marketWatchlist: "Market Watchlist"
        case .chains: "Chains"
        case .assets: "Assets"
        case .customTokens: "Custom Tokens"
        case .appSettings: "App Settings"
        case .appMetadata: "App Metadata"
        case .biometricEnrollments: "Biometric Enrollment"
        case .syncStatus: "Sync Status"
        }
    }

    var subtitle: String {
        switch self {
        case .wallets: "Wallet profiles, ordering, backup flags, and avatars"
        case .walletSecrets: "Encrypted phrase and private-key blobs"
        case .walletAddresses: "Wallet-chain addresses and derivation paths"
        case .chainStates: "Per-wallet chain aggregates and encrypted chain keys"
        case .chainUTXOs: "Persisted unspent outputs for UTXO chains"
        case .transactions: "On-chain transaction rows and statuses"
        case .tokenBalances: "Latest native and token balances"
        case .walletChartSnapshots: "Captured portfolio value observations"
        case .cachedPrices: "Latest spot-price cache"
        case .historicalPrices: "Daily historical closes"
        case .priceSnapshots: "Append-only live price observations"
        case .marketAssets: "Markets tab asset cache"
        case .marketCharts: "Markets chart sample cache"
        case .marketWatchlist: "Watched market symbols"
        case .chains: "Seeded supported-chain catalog"
        case .assets: "Seeded supported-token catalog"
        case .customTokens: "User-added contract and mint metadata"
        case .appSettings: "Synced app preference row"
        case .appMetadata: "Launch and migration metadata"
        case .biometricEnrollments: "Opaque biometric domain-state snapshots"
        case .syncStatus: "Freshness ledger for background jobs"
        }
    }

    var systemImage: String {
        switch self {
        case .wallets: "wallet.pass"
        case .walletSecrets: "key"
        case .walletAddresses: "number.square"
        case .chainStates: "link"
        case .chainUTXOs: "cube.transparent"
        case .transactions: "arrow.left.arrow.right"
        case .tokenBalances: "scalemass"
        case .walletChartSnapshots: "chart.line.uptrend.xyaxis"
        case .cachedPrices: "dollarsign.circle"
        case .historicalPrices: "calendar"
        case .priceSnapshots: "waveform.path.ecg"
        case .marketAssets: "chart.bar"
        case .marketCharts: "chart.xyaxis.line"
        case .marketWatchlist: "star"
        case .chains: "network"
        case .assets: "circle.grid.3x3"
        case .customTokens: "tag"
        case .appSettings: "slider.horizontal.3"
        case .appMetadata: "info.circle"
        case .biometricEnrollments: "faceid"
        case .syncStatus: "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch category {
        case .walletCore: UniColors.Tint.indigo
        case .activity: UniColors.Tint.green
        case .markets: UniColors.Tint.blue
        case .catalog: UniColors.Tint.orange
        }
    }
}

private struct DatabaseRecordSnapshot: Identifiable, Hashable {
    let id: String
    let table: DatabaseTable
    let title: String
    let subtitle: String
    let detail: String
    let badges: [String]
    let fields: [DatabaseField]
    var walletId: UUID? = nil

    var searchableText: String {
        ([title, subtitle, detail] + badges + fields.flatMap { [$0.label, $0.value] })
            .joined(separator: " ")
    }
}

private struct DatabaseField: Identifiable, Hashable {
    let label: String
    let value: String
    var isSensitive: Bool = false

    var id: String { label }

    var isLongValue: Bool {
        value.count > 64 || value.contains("\n")
    }
}

private enum DatabaseFormat {
    static func bool(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    static func optional(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Not set" }
        return value
    }

    static func uuid(_ value: UUID?) -> String {
        value?.uuidString ?? "Not set"
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "Not set" }
        return value.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().second())
    }

    static func shortDate(_ value: Date) -> String {
        value.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func decimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return value.formatted(.number.precision(.fractionLength(0...8)).grouping(.automatic))
    }

    static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func integer(_ value: Int64?) -> String {
        guard let value else { return "Not set" }
        return value.formatted(.number.grouping(.automatic))
    }

    static func clip(_ value: String?, head: Int = 12, tail: Int = 8) -> String {
        guard let value, !value.isEmpty else { return "Not set" }
        guard value.count > head + tail + 3 else { return value }
        return "\(value.prefix(head))...\(value.suffix(tail))"
    }

    static func encryptedBlob(_ data: Data?) -> String {
        guard let data else { return "Not stored" }
        return "Encrypted blob, \(data.count.formatted(.number.grouping(.automatic))) bytes"
    }

    static func dataBlob(_ data: Data?) -> String {
        guard let data else { return "Not set" }
        return "\(data.count.formatted(.number.grouping(.automatic))) bytes"
    }

    static func hex(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    static func textBlob(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Not set" }
        return "\(value.count.formatted(.number.grouping(.automatic))) characters"
    }

    static func jsonSamples(_ value: String) -> String {
        let count = MarketPoint.codec.decode(value).count
        return "\(count.formatted(.number.grouping(.automatic))) samples"
    }
}

private extension DatabaseExplorerView {
    static func plaintext(secret: WalletSecretRecord, in context: ModelContext) -> String? {
        guard let kind = WalletSecretKind(rawValue: secret.kindRaw) else { return nil }
        switch kind {
        case .mnemonic:
            guard let words = try? WalletSecretPersistence.loadMnemonic(for: secret.walletId, in: context),
                  !words.isEmpty else {
                return nil
            }
            return words.joined(separator: " ")
        case .privateKey:
            guard let key = try? WalletSecretPersistence.loadPrivateKey(for: secret.walletId, in: context),
                  !key.isEmpty else {
                return nil
            }
            return key
        }
    }

    static func plaintextPrivateKey(for chainState: ChainStateRecord) -> String? {
        guard chainState.keyEncryptionScheme == ChainKeyVault.scheme,
              let blob = chainState.encryptedPrivateKey,
              let keyData = try? ChainKeyVault.open(blob) else {
            return nil
        }
        return DatabaseFormat.hex(keyData)
    }

    static func plaintextPrivateKey(
        for address: WalletAddressRecord,
        chainStates: [ChainStateRecord]
    ) -> String? {
        guard let walletId = address.walletId else { return nil }
        let exact = chainStates.first {
            $0.walletId == walletId
                && $0.chainRaw == address.chainRaw
                && $0.address == address.address
        }
        let equivalent = exact ?? chainStates.first {
            $0.walletId == walletId
                && $0.chainRaw == address.chainRaw
                && $0.address.caseInsensitiveCompare(address.address) == .orderedSame
        }
        let chainOnly = equivalent ?? chainStates.first {
            $0.walletId == walletId && $0.chainRaw == address.chainRaw
        }
        guard let chainState = chainOnly else { return nil }
        return plaintextPrivateKey(for: chainState)
    }

    static func snapshot(wallet: WalletRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "wallet-\(wallet.id.uuidString)",
            table: .wallets,
            title: wallet.name,
            subtitle: wallet.id.uuidString,
            detail: wallet.kindRaw,
            badges: [
                wallet.requiresBackup ? "Needs backup" : "Backed up",
                wallet.isHidden ? "Hidden" : "Visible",
                "\(wallet.addresses.count) addresses"
            ],
            fields: [
                .init(label: "Wallet ID", value: wallet.id.uuidString),
                .init(label: "Name", value: wallet.name),
                .init(label: "Kind", value: wallet.kindRaw),
                .init(label: "Mnemonic word count", value: wallet.mnemonicWordCount.map(String.init) ?? "Not set"),
                .init(label: "Has BIP-39 passphrase", value: DatabaseFormat.bool(wallet.hasPassphrase)),
                .init(label: "Color tag", value: wallet.colorTag),
                .init(label: "Legacy icon symbol", value: wallet.iconSymbol),
                .init(label: "Legacy icon color", value: wallet.iconColorHex),
                .init(label: "Avatar gradient", value: wallet.avatarGradient),
                .init(label: "Avatar symbol type", value: wallet.avatarSymbolType),
                .init(label: "Avatar glyph", value: DatabaseFormat.optional(wallet.avatarGlyph)),
                .init(label: "Avatar monogram", value: DatabaseFormat.optional(wallet.avatarMonogram)),
                .init(label: "Avatar custom SVG", value: DatabaseFormat.textBlob(wallet.avatarCustomSvg)),
                .init(label: "Avatar custom tint", value: DatabaseFormat.optional(wallet.avatarCustomTint)),
                .init(label: "Avatar badge", value: DatabaseFormat.optional(wallet.avatarBadge)),
                .init(label: "Sort order", value: DatabaseFormat.integer(wallet.sortOrder)),
                .init(label: "Hidden", value: DatabaseFormat.bool(wallet.isHidden)),
                .init(label: "Requires backup", value: DatabaseFormat.bool(wallet.requiresBackup)),
                .init(label: "Manual backup completed", value: DatabaseFormat.bool(wallet.manualBackupCompleted ?? false)),
                .init(label: "Created at", value: DatabaseFormat.date(wallet.createdAt)),
                .init(label: "Updated at", value: DatabaseFormat.date(wallet.updatedAt)),
                .init(label: "Address rows", value: DatabaseFormat.integer(wallet.addresses.count))
            ],
            walletId: wallet.id
        )
    }

    static func snapshot(secret: WalletSecretRecord, plaintext: String? = nil) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "secret-\(secret.key)",
            table: .walletSecrets,
            title: secret.kindRaw,
            subtitle: secret.walletId.uuidString,
            detail: plaintext.map { DatabaseFormat.clip($0, head: 24, tail: 18) } ?? DatabaseFormat.encryptedBlob(secret.cipherData),
            badges: [plaintext == nil ? "Encrypted" : "Plaintext available", secret.kindRaw],
            fields: [
                .init(label: "Storage key", value: secret.key),
                .init(label: "Wallet ID", value: secret.walletId.uuidString),
                .init(label: "Kind", value: secret.kindRaw),
                .init(label: "Plaintext", value: plaintext ?? "Not available on this iPhone"),
                .init(label: "Cipher data", value: DatabaseFormat.encryptedBlob(secret.cipherData)),
                .init(label: "Created at", value: DatabaseFormat.date(secret.createdAt)),
                .init(label: "Updated at", value: DatabaseFormat.date(secret.updatedAt))
            ]
        )
    }

    static func snapshot(address: WalletAddressRecord, privateKey: String? = nil) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "address-\(address.id.uuidString)",
            table: .walletAddresses,
            title: address.chainRaw,
            subtitle: address.address,
            detail: address.isUsed ? "Used" : "Unused",
            badges: [
                "Wallet \(DatabaseFormat.clip(address.walletId?.uuidString, head: 8, tail: 4))",
                privateKey == nil ? "No private key" : "Private key",
                "\(address.transactions.count) tx",
                "\(address.balances.count) balances"
            ],
            fields: [
                .init(label: "Address ID", value: address.id.uuidString),
                .init(label: "Wallet ID", value: DatabaseFormat.uuid(address.walletId)),
                .init(label: "Chain", value: address.chainRaw),
                .init(label: "Address", value: address.address),
                .init(label: "Private key", value: privateKey ?? "Not available on this iPhone"),
                .init(label: "Derivation path", value: DatabaseFormat.optional(address.derivationPath)),
                .init(label: "Used", value: DatabaseFormat.bool(address.isUsed)),
                .init(label: "Last scanned at", value: DatabaseFormat.date(address.lastScannedAt)),
                .init(label: "Transaction rows", value: DatabaseFormat.integer(address.transactions.count)),
                .init(label: "Balance rows", value: DatabaseFormat.integer(address.balances.count))
            ]
        )
    }

    static func snapshot(chainState: ChainStateRecord, privateKey: String? = nil) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "chain-state-\(chainState.id.uuidString)",
            table: .chainStates,
            title: chainState.chainRaw,
            subtitle: chainState.address,
            detail: "\(chainState.fiatCurrencyCode) \(DatabaseFormat.decimal(chainState.totalFiat))",
            badges: [
                chainState.syncStateRaw,
                privateKey == nil ? "No private key" : "Private key",
                "\(chainState.txTotalCount) tx"
            ],
            fields: [
                .init(label: "Row ID", value: chainState.id.uuidString),
                .init(label: "Wallet ID", value: chainState.walletId.uuidString),
                .init(label: "Chain", value: chainState.chainRaw),
                .init(label: "Address", value: chainState.address),
                .init(label: "Derivation path", value: DatabaseFormat.optional(chainState.derivationPath)),
                .init(label: "Native balance", value: chainState.nativeBalanceRaw),
                .init(label: "Native decimals", value: DatabaseFormat.integer(chainState.nativeDecimals)),
                .init(label: "Native fiat", value: DatabaseFormat.decimal(chainState.nativeFiat)),
                .init(label: "Total fiat", value: DatabaseFormat.decimal(chainState.totalFiat)),
                .init(label: "Token count", value: DatabaseFormat.integer(chainState.tokenCount)),
                .init(label: "Fiat currency", value: chainState.fiatCurrencyCode),
                .init(label: "Sent count", value: DatabaseFormat.integer(chainState.txSentCount)),
                .init(label: "Received count", value: DatabaseFormat.integer(chainState.txReceivedCount)),
                .init(label: "Self-transfer count", value: DatabaseFormat.integer(chainState.txSelfTransferCount)),
                .init(label: "Bridge count", value: DatabaseFormat.integer(chainState.txBridgeCount)),
                .init(label: "Failed count", value: DatabaseFormat.integer(chainState.txFailedCount)),
                .init(label: "Pending count", value: DatabaseFormat.integer(chainState.txPendingCount)),
                .init(label: "Total tx count", value: DatabaseFormat.integer(chainState.txTotalCount)),
                .init(label: "UTXO count", value: DatabaseFormat.integer(chainState.utxoCount)),
                .init(label: "UTXO total raw", value: chainState.utxoTotalRaw),
                .init(label: "Used", value: DatabaseFormat.bool(chainState.isUsed)),
                .init(label: "Last synced at", value: DatabaseFormat.date(chainState.lastSyncedAt)),
                .init(label: "Sync state", value: chainState.syncStateRaw),
                .init(label: "Private key", value: privateKey ?? "Not available on this iPhone"),
                .init(label: "Encrypted private key bytes", value: DatabaseFormat.encryptedBlob(chainState.encryptedPrivateKey)),
                .init(label: "Key encryption scheme", value: DatabaseFormat.optional(chainState.keyEncryptionScheme))
            ]
        )
    }

    static func snapshot(utxo: ChainUTXORecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "utxo-\(utxo.id.uuidString)",
            table: .chainUTXOs,
            title: "\(utxo.chainRaw) #\(utxo.vout)",
            subtitle: utxo.txid,
            detail: utxo.valueSatsRaw,
            badges: [utxo.confirmed ? "Confirmed" : "Pending", DatabaseFormat.clip(utxo.walletId.uuidString, head: 8, tail: 4)],
            fields: [
                .init(label: "Row ID", value: utxo.id.uuidString),
                .init(label: "Wallet ID", value: utxo.walletId.uuidString),
                .init(label: "Chain", value: utxo.chainRaw),
                .init(label: "Address", value: utxo.address),
                .init(label: "Transaction ID", value: utxo.txid),
                .init(label: "Vout", value: DatabaseFormat.integer(utxo.vout)),
                .init(label: "Value sats raw", value: utxo.valueSatsRaw),
                .init(label: "Script hex", value: DatabaseFormat.clip(utxo.scriptHex, head: 24, tail: 16)),
                .init(label: "Confirmed", value: DatabaseFormat.bool(utxo.confirmed)),
                .init(label: "Updated at", value: DatabaseFormat.date(utxo.updatedAt))
            ]
        )
    }

    static func snapshot(transaction: TransactionRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "transaction-\(transaction.id.uuidString)",
            table: .transactions,
            title: "\(transaction.directionRaw) \(transaction.tokenSymbol)",
            subtitle: transaction.txHash,
            detail: transaction.statusRaw,
            badges: [
                transaction.kindRaw ?? "transfer",
                transaction.amountRaw,
                transaction.address?.chainRaw ?? "Unknown chain"
            ],
            fields: [
                .init(label: "Transaction row ID", value: transaction.id.uuidString),
                .init(label: "Address ID", value: DatabaseFormat.uuid(transaction.addressId)),
                .init(label: "Address chain", value: transaction.address?.chainRaw ?? "Not set"),
                .init(label: "Hash", value: transaction.txHash),
                .init(label: "Direction", value: transaction.directionRaw),
                .init(label: "Kind", value: DatabaseFormat.optional(transaction.kindRaw)),
                .init(label: "Amount", value: transaction.amountRaw),
                .init(label: "Token symbol", value: transaction.tokenSymbol),
                .init(label: "Token contract", value: DatabaseFormat.optional(transaction.tokenContract)),
                .init(label: "Block number", value: DatabaseFormat.integer(transaction.blockNumber)),
                .init(label: "Occurred at", value: DatabaseFormat.date(transaction.occurredAt)),
                .init(label: "Status", value: transaction.statusRaw),
                .init(label: "Counterparty", value: DatabaseFormat.optional(transaction.counterparty)),
                .init(label: "Fee", value: DatabaseFormat.optional(transaction.feeRaw))
            ]
        )
    }

    static func snapshot(balance: TokenBalanceRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "balance-\(balance.id.uuidString)",
            table: .tokenBalances,
            title: balance.tokenSymbol,
            subtitle: balance.tokenContract ?? "Native coin",
            detail: "\(balance.fiatCurrencyCode) \(DatabaseFormat.decimal(balance.fiatValueCached))",
            badges: [balance.rawBalance, "\(balance.decimals) decimals"],
            fields: [
                .init(label: "Balance row ID", value: balance.id.uuidString),
                .init(label: "Address ID", value: DatabaseFormat.uuid(balance.addressId)),
                .init(label: "Address chain", value: balance.address?.chainRaw ?? "Not set"),
                .init(label: "Token symbol", value: balance.tokenSymbol),
                .init(label: "Token contract", value: DatabaseFormat.optional(balance.tokenContract)),
                .init(label: "Decimals", value: DatabaseFormat.integer(balance.decimals)),
                .init(label: "Raw balance", value: balance.rawBalance),
                .init(label: "Fiat value cached", value: DatabaseFormat.decimal(balance.fiatValueCached)),
                .init(label: "Fiat currency", value: balance.fiatCurrencyCode),
                .init(label: "Updated at", value: DatabaseFormat.date(balance.updatedAt))
            ]
        )
    }

    static func snapshot(walletChart: WalletChartSnapshotRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "wallet-chart-\(walletChart.id.uuidString)",
            table: .walletChartSnapshots,
            title: "\(walletChart.currencyCode) \(DatabaseFormat.decimal(walletChart.fiatValue))",
            subtitle: walletChart.walletId.uuidString,
            detail: DatabaseFormat.date(walletChart.capturedAt),
            badges: ["Day \(walletChart.dayKey)"],
            fields: [
                .init(label: "Snapshot ID", value: walletChart.id.uuidString),
                .init(label: "Wallet ID", value: walletChart.walletId.uuidString),
                .init(label: "Currency", value: walletChart.currencyCode),
                .init(label: "Fiat value", value: DatabaseFormat.decimal(walletChart.fiatValue)),
                .init(label: "Captured at", value: DatabaseFormat.date(walletChart.capturedAt)),
                .init(label: "Day key", value: DatabaseFormat.integer(walletChart.dayKey))
            ]
        )
    }

    static func snapshot(cachedPrice: CachedPriceRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "cached-price-\(cachedPrice.key)",
            table: .cachedPrices,
            title: cachedPrice.key,
            subtitle: "\(cachedPrice.symbol) in \(cachedPrice.fiat)",
            detail: DatabaseFormat.decimal(cachedPrice.price),
            badges: [cachedPrice.source, DatabaseFormat.date(cachedPrice.fetchedAt)],
            fields: [
                .init(label: "Key", value: cachedPrice.key),
                .init(label: "Symbol", value: cachedPrice.symbol),
                .init(label: "Fiat", value: cachedPrice.fiat),
                .init(label: "Price", value: DatabaseFormat.decimal(cachedPrice.price)),
                .init(label: "Fetched at", value: DatabaseFormat.date(cachedPrice.fetchedAt)),
                .init(label: "Source", value: cachedPrice.source)
            ]
        )
    }

    static func snapshot(historicalPrice: HistoricalPriceRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "historical-price-\(historicalPrice.key)",
            table: .historicalPrices,
            title: historicalPrice.key,
            subtitle: "\(historicalPrice.symbol) in \(historicalPrice.fiat)",
            detail: DatabaseFormat.decimal(historicalPrice.price),
            badges: ["Day \(historicalPrice.dayKey)", DatabaseFormat.date(historicalPrice.fetchedAt)],
            fields: [
                .init(label: "Key", value: historicalPrice.key),
                .init(label: "Symbol", value: historicalPrice.symbol),
                .init(label: "Fiat", value: historicalPrice.fiat),
                .init(label: "Day key", value: DatabaseFormat.integer(historicalPrice.dayKey)),
                .init(label: "Price", value: DatabaseFormat.decimal(historicalPrice.price)),
                .init(label: "Fetched at", value: DatabaseFormat.date(historicalPrice.fetchedAt))
            ]
        )
    }

    static func snapshot(priceSnapshot: PriceSnapshotRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "price-snapshot-\(priceSnapshot.id.uuidString)",
            table: .priceSnapshots,
            title: "\(priceSnapshot.symbol)-\(priceSnapshot.currencyCode)",
            subtitle: priceSnapshot.source,
            detail: DatabaseFormat.decimal(priceSnapshot.price),
            badges: ["Day \(priceSnapshot.dayKey)", DatabaseFormat.date(priceSnapshot.fetchedAt)],
            fields: [
                .init(label: "Snapshot ID", value: priceSnapshot.id.uuidString),
                .init(label: "Symbol", value: priceSnapshot.symbol),
                .init(label: "Currency", value: priceSnapshot.currencyCode),
                .init(label: "Price", value: DatabaseFormat.decimal(priceSnapshot.price)),
                .init(label: "Fetched at", value: DatabaseFormat.date(priceSnapshot.fetchedAt)),
                .init(label: "Source", value: priceSnapshot.source),
                .init(label: "Day key", value: DatabaseFormat.integer(priceSnapshot.dayKey))
            ]
        )
    }

    static func snapshot(marketAsset: MarketAssetRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "market-asset-\(marketAsset.symbol)",
            table: .marketAssets,
            title: marketAsset.name,
            subtitle: marketAsset.symbol,
            detail: "\(marketAsset.currencyCode) \(DatabaseFormat.number(marketAsset.price))",
            badges: ["Rank \(marketAsset.rank)", marketAsset.source, "\(DatabaseFormat.number(marketAsset.priceChange24hPercent))%"],
            fields: [
                .init(label: "Symbol", value: marketAsset.symbol),
                .init(label: "Name", value: marketAsset.name),
                .init(label: "Provider ID", value: marketAsset.providerId),
                .init(label: "Rank", value: DatabaseFormat.integer(marketAsset.rank)),
                .init(label: "Price", value: DatabaseFormat.number(marketAsset.price)),
                .init(label: "Currency", value: marketAsset.currencyCode),
                .init(label: "24h change percent", value: DatabaseFormat.number(marketAsset.priceChange24hPercent)),
                .init(label: "24h change amount", value: DatabaseFormat.number(marketAsset.priceChange24hAmount)),
                .init(label: "Market cap", value: DatabaseFormat.number(marketAsset.marketCap)),
                .init(label: "24h volume", value: DatabaseFormat.number(marketAsset.volume24h)),
                .init(label: "Circulating supply", value: DatabaseFormat.number(marketAsset.circulatingSupply)),
                .init(label: "All-time high", value: DatabaseFormat.number(marketAsset.ath)),
                .init(label: "24h high", value: DatabaseFormat.number(marketAsset.high24h)),
                .init(label: "24h low", value: DatabaseFormat.number(marketAsset.low24h)),
                .init(label: "About", value: DatabaseFormat.textBlob(marketAsset.about)),
                .init(label: "Sparkline", value: DatabaseFormat.jsonSamples(marketAsset.sparklineJSON)),
                .init(label: "Source", value: marketAsset.source),
                .init(label: "Last updated at", value: DatabaseFormat.date(marketAsset.lastUpdatedAt))
            ]
        )
    }

    static func snapshot(marketChart: MarketChartCacheRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "market-chart-\(marketChart.cacheKey)",
            table: .marketCharts,
            title: marketChart.cacheKey,
            subtitle: "\(marketChart.symbol) \(marketChart.rangeRaw) \(marketChart.currencyCode)",
            detail: DatabaseFormat.jsonSamples(marketChart.samplesJSON),
            badges: [marketChart.source, DatabaseFormat.date(marketChart.updatedAt)],
            fields: [
                .init(label: "Cache key", value: marketChart.cacheKey),
                .init(label: "Symbol", value: marketChart.symbol),
                .init(label: "Range", value: marketChart.rangeRaw),
                .init(label: "Currency", value: marketChart.currencyCode),
                .init(label: "Samples", value: DatabaseFormat.jsonSamples(marketChart.samplesJSON)),
                .init(label: "Source", value: marketChart.source),
                .init(label: "Updated at", value: DatabaseFormat.date(marketChart.updatedAt))
            ]
        )
    }

    static func snapshot(watchlist: MarketWatchlistRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "market-watchlist-\(watchlist.symbol)",
            table: .marketWatchlist,
            title: watchlist.symbol,
            subtitle: "Watchlist symbol",
            detail: DatabaseFormat.date(watchlist.addedAt),
            badges: [],
            fields: [
                .init(label: "Symbol", value: watchlist.symbol),
                .init(label: "Added at", value: DatabaseFormat.date(watchlist.addedAt))
            ]
        )
    }

    static func snapshot(chain: ChainRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "chain-\(chain.chainRaw)",
            table: .chains,
            title: chain.displayName,
            subtitle: chain.chainRaw,
            detail: chain.ticker,
            badges: ["Sort \(chain.sortIndex)"],
            fields: [
                .init(label: "Chain raw", value: chain.chainRaw),
                .init(label: "Ticker", value: chain.ticker),
                .init(label: "Display name", value: chain.displayName),
                .init(label: "Sort index", value: DatabaseFormat.integer(chain.sortIndex))
            ]
        )
    }

    static func snapshot(asset: AssetRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "asset-\(asset.catalogId)",
            table: .assets,
            title: asset.name,
            subtitle: asset.symbol,
            detail: asset.chainRaw,
            badges: [asset.decimals.formatted() + " decimals", DatabaseFormat.clip(asset.contract, head: 8, tail: 6)],
            fields: [
                .init(label: "Catalog ID", value: asset.catalogId),
                .init(label: "Chain", value: asset.chainRaw),
                .init(label: "Symbol", value: asset.symbol),
                .init(label: "Name", value: asset.name),
                .init(label: "Contract", value: asset.contract),
                .init(label: "Decimals", value: DatabaseFormat.integer(asset.decimals))
            ]
        )
    }

    static func snapshot(customToken: CustomTokenRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "custom-token-\(customToken.id.uuidString)",
            table: .customTokens,
            title: customToken.name,
            subtitle: customToken.symbol,
            detail: customToken.chainRaw,
            badges: [
                customToken.metadataFromChain ? "Chain metadata" : "User metadata",
                customToken.hasKnownChain ? "Known chain" : "Unknown chain"
            ],
            fields: [
                .init(label: "Token ID", value: customToken.id.uuidString),
                .init(label: "Chain", value: customToken.chainRaw),
                .init(label: "Contract", value: customToken.contract),
                .init(label: "Symbol", value: customToken.symbol),
                .init(label: "Name", value: customToken.name),
                .init(label: "Decimals", value: DatabaseFormat.integer(customToken.decimals)),
                .init(label: "Icon URL", value: DatabaseFormat.optional(customToken.iconURL)),
                .init(label: "Added at", value: DatabaseFormat.date(customToken.addedAt)),
                .init(label: "Metadata from chain", value: DatabaseFormat.bool(customToken.metadataFromChain)),
                .init(label: "Dedup key", value: customToken.dedupKey),
                .init(label: "Has known chain", value: DatabaseFormat.bool(customToken.hasKnownChain))
            ]
        )
    }

    static func snapshot(appSettings: AppSettingsRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "app-settings-\(appSettings.id)",
            table: .appSettings,
            title: "App Settings",
            subtitle: appSettings.id,
            detail: DatabaseFormat.date(appSettings.updatedAt),
            badges: [appSettings.currencyPreference, appSettings.languagePreference, "Tab \(appSettings.selectedTab)"],
            fields: [
                .init(label: "ID", value: appSettings.id),
                .init(label: "Theme preference", value: appSettings.themePreference),
                .init(label: "Language preference", value: appSettings.languagePreference),
                .init(label: "PIN enabled", value: DatabaseFormat.bool(appSettings.pinEnabled)),
                .init(label: "Biometric enabled", value: DatabaseFormat.bool(appSettings.biometricEnabled)),
                .init(label: "Auto-lock seconds", value: DatabaseFormat.integer(appSettings.autoLockSeconds)),
                .init(label: "Currency preference", value: appSettings.currencyPreference),
                .init(label: "Haptic feedback", value: DatabaseFormat.bool(appSettings.hapticFeedbackEnabled)),
                .init(label: "Background balance refresh", value: DatabaseFormat.bool(appSettings.backgroundBalanceRefresh)),
                .init(label: "Wallet-home balance range", value: appSettings.walletHomeBalanceHistoryRange),
                .init(label: "Selected tab", value: DatabaseFormat.integer(appSettings.selectedTab)),
                .init(label: "Active wallet ID", value: DatabaseFormat.optional(appSettings.activeWalletId)),
                .init(label: "Settings deep link", value: DatabaseFormat.optional(appSettings.settingsDeepLink)),
                .init(label: "Has unbacked-up wallet", value: DatabaseFormat.bool(appSettings.hasUnbackedupWallet)),
                .init(label: "Hide import-key warning", value: DatabaseFormat.bool(appSettings.hideImportKeyWarning)),
                .init(label: "Updated at", value: DatabaseFormat.date(appSettings.updatedAt))
            ]
        )
    }

    static func snapshot(appMetadata: AppMetadataRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "app-metadata-\(appMetadata.id.uuidString)",
            table: .appMetadata,
            title: "App Metadata",
            subtitle: appMetadata.id.uuidString,
            detail: "Schema \(appMetadata.schemaVersion)",
            badges: [appMetadata.requiresBiometricReenrollment ? "Re-enrollment needed" : "Biometrics current"],
            fields: [
                .init(label: "ID", value: appMetadata.id.uuidString),
                .init(label: "Schema version", value: DatabaseFormat.integer(appMetadata.schemaVersion)),
                .init(label: "First launch at", value: DatabaseFormat.date(appMetadata.firstLaunchAt)),
                .init(label: "Last opened at", value: DatabaseFormat.date(appMetadata.lastOpenedAt)),
                .init(label: "Requires biometric re-enrollment", value: DatabaseFormat.bool(appMetadata.requiresBiometricReenrollment))
            ]
        )
    }

    static func snapshot(biometric: BiometricEnrollmentRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "biometric-\(biometric.id.uuidString)",
            table: .biometricEnrollments,
            title: "Biometric Snapshot",
            subtitle: biometric.id.uuidString,
            detail: DatabaseFormat.dataBlob(biometric.domainStateSnapshot),
            badges: [],
            fields: [
                .init(label: "ID", value: biometric.id.uuidString),
                .init(label: "Domain state snapshot", value: DatabaseFormat.dataBlob(biometric.domainStateSnapshot), isSensitive: true),
                .init(label: "Updated at", value: DatabaseFormat.date(biometric.updatedAt))
            ]
        )
    }

    static func snapshot(syncStatus: SyncStatusRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "sync-status-\(syncStatus.key)",
            table: .syncStatus,
            title: syncStatus.domainRaw,
            subtitle: syncStatus.scopeId,
            detail: syncStatus.isSyncing ? "Syncing" : "Idle",
            badges: [syncStatus.lastErrorMessage == nil ? "No error" : "Has error"],
            fields: [
                .init(label: "Key", value: syncStatus.key),
                .init(label: "Domain", value: syncStatus.domainRaw),
                .init(label: "Scope ID", value: syncStatus.scopeId),
                .init(label: "Last synced at", value: DatabaseFormat.date(syncStatus.lastSyncedAt)),
                .init(label: "Last attempt at", value: DatabaseFormat.date(syncStatus.lastAttemptAt)),
                .init(label: "Is syncing", value: DatabaseFormat.bool(syncStatus.isSyncing)),
                .init(label: "Last error", value: DatabaseFormat.optional(syncStatus.lastErrorMessage)),
                .init(label: "Updated at", value: DatabaseFormat.date(syncStatus.updatedAt))
            ]
        )
    }
}
