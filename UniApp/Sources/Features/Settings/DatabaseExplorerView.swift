import SwiftData
import SwiftUI

struct DatabaseExplorerView: View {
    @Query private var wallets: [WalletRecord]
    @Query private var walletSecrets: [WalletSecretRecord]
    @Query private var walletAddresses: [WalletAddressRecord]
    @Query private var transactions: [TransactionRecord]
    @Query private var tokenBalances: [TokenBalanceRecord]
    @Query private var cachedPrices: [CachedPriceRecord]
    @Query private var biometricEnrollments: [BiometricEnrollmentRecord]
    @Query private var appMetadata: [AppMetadataRecord]
    @Query private var customTokens: [CustomTokenRecord]
    @Query private var historicalPrices: [HistoricalPriceRecord]
    @Query private var priceSnapshots: [PriceSnapshotRecord]
    @Query private var walletChartSnapshots: [WalletChartSnapshotRecord]
    @Query private var syncStatus: [SyncStatusRecord]
    @Query private var chains: [ChainRecord]
    @Query private var assets: [AssetRecord]
    @Query private var appSettings: [AppSettingsRecord]
    @Query private var marketAssets: [MarketAssetRecord]
    @Query private var marketCharts: [MarketChartCacheRecord]
    @Query private var marketWatchlist: [MarketWatchlistRecord]
    @Query private var chainStates: [ChainStateRecord]
    @Query private var chainUTXOs: [ChainUTXORecord]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatabaseSummaryCard(
                        totalRecords: totalRecords,
                        tableCount: DatabaseTable.allCases.count,
                        encryptedBlobCount: encryptedBlobCount
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                ForEach(DatabaseCategory.allCases) { category in
                    Section(category.title) {
                        ForEach(DatabaseTable.allCases.filter { $0.category == category }) { table in
                            NavigationLink(value: table) {
                                DatabaseTableRow(
                                    table: table,
                                    count: count(for: table),
                                    lastUpdated: lastUpdated(for: table)
                                )
                            }
                            .listRowBackground(UniColors.List.rowBackground)
                        }
                    }
                }

                Section {
                    Text("Private phrases and private keys are never shown here. Secret rows expose only encrypted blob metadata so you can inspect storage without leaking signing material.")
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
            .navigationDestination(for: DatabaseTable.self) { table in
                DatabaseTableView(table: table, records: records(for: table))
            }
        }
    }

    private var totalRecords: Int {
        DatabaseTable.allCases.reduce(0) { $0 + count(for: $1) }
    }

    private var encryptedBlobCount: Int {
        walletSecrets.count + chainStates.filter { $0.encryptedPrivateKey != nil }.count
    }

    private func count(for table: DatabaseTable) -> Int {
        switch table {
        case .wallets: wallets.count
        case .walletSecrets: walletSecrets.count
        case .walletAddresses: walletAddresses.count
        case .chainStates: chainStates.count
        case .chainUTXOs: chainUTXOs.count
        case .transactions: transactions.count
        case .tokenBalances: tokenBalances.count
        case .walletChartSnapshots: walletChartSnapshots.count
        case .cachedPrices: cachedPrices.count
        case .historicalPrices: historicalPrices.count
        case .priceSnapshots: priceSnapshots.count
        case .marketAssets: marketAssets.count
        case .marketCharts: marketCharts.count
        case .marketWatchlist: marketWatchlist.count
        case .chains: chains.count
        case .assets: assets.count
        case .customTokens: customTokens.count
        case .appSettings: appSettings.count
        case .appMetadata: appMetadata.count
        case .biometricEnrollments: biometricEnrollments.count
        case .syncStatus: syncStatus.count
        }
    }

    private func lastUpdated(for table: DatabaseTable) -> Date? {
        switch table {
        case .wallets: newest(wallets.map(\.updatedAt))
        case .walletSecrets: newest(walletSecrets.map(\.updatedAt))
        case .walletAddresses: newest(walletAddresses.map(\.lastScannedAt))
        case .chainStates: newest(chainStates.map(\.lastSyncedAt))
        case .chainUTXOs: newest(chainUTXOs.map(\.updatedAt))
        case .transactions: newest(transactions.map(\.occurredAt))
        case .tokenBalances: newest(tokenBalances.map(\.updatedAt))
        case .walletChartSnapshots: newest(walletChartSnapshots.map(\.capturedAt))
        case .cachedPrices: newest(cachedPrices.map(\.fetchedAt))
        case .historicalPrices: newest(historicalPrices.map(\.fetchedAt))
        case .priceSnapshots: newest(priceSnapshots.map(\.fetchedAt))
        case .marketAssets: newest(marketAssets.map(\.lastUpdatedAt))
        case .marketCharts: newest(marketCharts.map(\.updatedAt))
        case .marketWatchlist: newest(marketWatchlist.map(\.addedAt))
        case .chains: nil
        case .assets: nil
        case .customTokens: newest(customTokens.map(\.addedAt))
        case .appSettings: newest(appSettings.map(\.updatedAt))
        case .appMetadata: newest(appMetadata.map(\.lastOpenedAt))
        case .biometricEnrollments: newest(biometricEnrollments.map(\.updatedAt))
        case .syncStatus: newest(syncStatus.map(\.updatedAt))
        }
    }

    private func records(for table: DatabaseTable) -> [DatabaseRecordSnapshot] {
        switch table {
        case .wallets:
            wallets
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(wallet: $0) }
        case .walletSecrets:
            walletSecrets
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(secret: $0) }
        case .walletAddresses:
            walletAddresses
                .sorted { lhs, rhs in
                    (lhs.chainRaw, lhs.address) < (rhs.chainRaw, rhs.address)
                }
                .map { Self.snapshot(address: $0) }
        case .chainStates:
            chainStates
                .sorted { lhs, rhs in
                    (lhs.walletId.uuidString, lhs.chainRaw) < (rhs.walletId.uuidString, rhs.chainRaw)
                }
                .map { Self.snapshot(chainState: $0) }
        case .chainUTXOs:
            chainUTXOs
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(utxo: $0) }
        case .transactions:
            transactions
                .sorted { $0.occurredAt > $1.occurredAt }
                .map { Self.snapshot(transaction: $0) }
        case .tokenBalances:
            tokenBalances
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(balance: $0) }
        case .walletChartSnapshots:
            walletChartSnapshots
                .sorted { $0.capturedAt > $1.capturedAt }
                .map { Self.snapshot(walletChart: $0) }
        case .cachedPrices:
            cachedPrices
                .sorted { $0.fetchedAt > $1.fetchedAt }
                .map { Self.snapshot(cachedPrice: $0) }
        case .historicalPrices:
            historicalPrices
                .sorted { lhs, rhs in
                    if lhs.dayKey == rhs.dayKey { return lhs.symbol < rhs.symbol }
                    return lhs.dayKey > rhs.dayKey
                }
                .map { Self.snapshot(historicalPrice: $0) }
        case .priceSnapshots:
            priceSnapshots
                .sorted { $0.fetchedAt > $1.fetchedAt }
                .map { Self.snapshot(priceSnapshot: $0) }
        case .marketAssets:
            marketAssets
                .sorted { $0.rank < $1.rank }
                .map { Self.snapshot(marketAsset: $0) }
        case .marketCharts:
            marketCharts
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(marketChart: $0) }
        case .marketWatchlist:
            marketWatchlist
                .sorted { $0.addedAt > $1.addedAt }
                .map { Self.snapshot(watchlist: $0) }
        case .chains:
            chains
                .sorted { $0.sortIndex < $1.sortIndex }
                .map { Self.snapshot(chain: $0) }
        case .assets:
            assets
                .sorted { lhs, rhs in
                    (lhs.chainRaw, lhs.symbol, lhs.contract) < (rhs.chainRaw, rhs.symbol, rhs.contract)
                }
                .map { Self.snapshot(asset: $0) }
        case .customTokens:
            customTokens
                .sorted { $0.addedAt > $1.addedAt }
                .map { Self.snapshot(customToken: $0) }
        case .appSettings:
            appSettings
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(appSettings: $0) }
        case .appMetadata:
            appMetadata
                .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
                .map { Self.snapshot(appMetadata: $0) }
        case .biometricEnrollments:
            biometricEnrollments
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(biometric: $0) }
        case .syncStatus:
            syncStatus
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { Self.snapshot(syncStatus: $0) }
        }
    }

    private func newest(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }

    private func newest(_ dates: [Date]) -> Date? {
        dates.max()
    }
}

private struct DatabaseTableView: View {
    let table: DatabaseTable
    let records: [DatabaseRecordSnapshot]

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

            if filteredRecords.isEmpty {
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
                        NavigationLink(value: record) {
                            DatabaseRecordRow(record: record)
                        }
                        .listRowBackground(UniColors.List.rowBackground)
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
        .navigationDestination(for: DatabaseRecordSnapshot.self) { record in
            DatabaseRecordDetailView(record: record)
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
                            if field.isSensitive {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(UniColors.Icon.tertiary)
                                    .accessibilityLabel(Text("Encrypted"))
                            }
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

    var id: String { rawValue }

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
            ]
        )
    }

    static func snapshot(secret: WalletSecretRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "secret-\(secret.key)",
            table: .walletSecrets,
            title: secret.kindRaw,
            subtitle: secret.walletId.uuidString,
            detail: DatabaseFormat.encryptedBlob(secret.cipherData),
            badges: ["Encrypted", secret.kindRaw],
            fields: [
                .init(label: "Storage key", value: secret.key, isSensitive: true),
                .init(label: "Wallet ID", value: secret.walletId.uuidString),
                .init(label: "Kind", value: secret.kindRaw),
                .init(label: "Cipher data", value: DatabaseFormat.encryptedBlob(secret.cipherData), isSensitive: true),
                .init(label: "Created at", value: DatabaseFormat.date(secret.createdAt)),
                .init(label: "Updated at", value: DatabaseFormat.date(secret.updatedAt))
            ]
        )
    }

    static func snapshot(address: WalletAddressRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "address-\(address.id.uuidString)",
            table: .walletAddresses,
            title: address.chainRaw,
            subtitle: address.address,
            detail: address.isUsed ? "Used" : "Unused",
            badges: [
                "Wallet \(DatabaseFormat.clip(address.walletId?.uuidString, head: 8, tail: 4))",
                "\(address.transactions.count) tx",
                "\(address.balances.count) balances"
            ],
            fields: [
                .init(label: "Address ID", value: address.id.uuidString),
                .init(label: "Wallet ID", value: DatabaseFormat.uuid(address.walletId)),
                .init(label: "Chain", value: address.chainRaw),
                .init(label: "Address", value: address.address),
                .init(label: "Derivation path", value: DatabaseFormat.optional(address.derivationPath)),
                .init(label: "Used", value: DatabaseFormat.bool(address.isUsed)),
                .init(label: "Last scanned at", value: DatabaseFormat.date(address.lastScannedAt)),
                .init(label: "Transaction rows", value: DatabaseFormat.integer(address.transactions.count)),
                .init(label: "Balance rows", value: DatabaseFormat.integer(address.balances.count))
            ]
        )
    }

    static func snapshot(chainState: ChainStateRecord) -> DatabaseRecordSnapshot {
        DatabaseRecordSnapshot(
            id: "chain-state-\(chainState.id.uuidString)",
            table: .chainStates,
            title: chainState.chainRaw,
            subtitle: chainState.address,
            detail: "\(chainState.fiatCurrencyCode) \(DatabaseFormat.decimal(chainState.totalFiat))",
            badges: [
                chainState.syncStateRaw,
                chainState.encryptedPrivateKey == nil ? "No key blob" : "Encrypted key",
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
                .init(label: "Encrypted private key", value: DatabaseFormat.encryptedBlob(chainState.encryptedPrivateKey), isSensitive: true),
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
