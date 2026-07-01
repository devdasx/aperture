import SwiftUI
import SwiftData

/// **"View all" destination** behind the wallet-home "Recent activity"
/// header's `View all` link. Lists EVERY transaction across EVERY
/// address of the active wallet — newest first — without the five-row
/// cap the home surfaces.
///
/// **Design intent (Rule #2 §D.1):** when the user wants their whole
/// history, give them the same rows they already recognize from the
/// home — the same `ActivityRow` — unbounded and in time order. No new
/// visual vocabulary; the screen is "the home's activity list, longer."
/// This mirrors `AssetActivityView` (the per-asset "View all") so the
/// two histories read as one family.
///
/// **Scope.** This is the wallet-wide counterpart to
/// `AssetActivityView`. That screen is asset-scoped — it carries an
/// `AssetIdentity`, resolves asset networks, and presents an
/// asset-coupled filter sheet. None of that generalizes to "all
/// assets" without rewriting the filter plumbing, so this view ships
/// the clean wallet-wide form: every transaction, sorted, no filter.
/// The core ask — "see ALL transactions" — is met in full. A future
/// turn can add a sort/direction filter here if the user asks for it.
///
/// **Layout (Rule #15 — pushed-screen contract).** Inherits the
/// wallet-home's `NavigationStack`. Title via `.navigationTitle` so
/// the system handles scroll compression natively. Native
/// `List(.insetGrouped)`; rows route to the shared
/// `WalletHomeDestination.transaction(_:)` detail.
///
/// **Wallet truth (matches `WalletHomeView`).** The active wallet is
/// resolved the same hardened store-truth way the home does — the
/// `@Query`-backed `allWallets` lags repository inserts/switches, so a
/// freshly-switched or freshly-imported wallet would otherwise show
/// the *previous* wallet's history for one merge window. Asking the
/// store directly (`modelContext.fetch`) closes that gap, so this
/// screen never shows the wrong wallet's transactions.
struct WalletActivityView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    /// Top-level transaction feed, newest-first at the STORE level (no
    /// per-render sort). The same hardened pattern `WalletHomeView` uses:
    /// filter this by the active wallet's address-id set in ONE in-memory
    /// pass (`addressId` is a stored column — no relationship faulting),
    /// instead of `wallet.addresses.flatMap { $0.transactions }` (which
    /// faults every address's transaction relationship) gated by the
    /// O(all-tx) `WalletDataFingerprint.make` key recomputed every body
    /// pass (2026-06-14 Activity-lag fix).
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse)
    private var allTransactionRecords: [TransactionRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    // Local-currency activity amounts (2026-06-18): spot prices feed
    // `priceMap` (symbol → unit price in `currencyCode`).
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @Query private var cachedPrices: [CachedPriceRecord]

    private var priceMap: [String: Decimal] {
        ActivityFiat.priceMap(cachedPrices, currency: currencyCode)
    }

    // MARK: - Filter & search preferences (Part 2, 2026-06-19)

    @AppStorage(WalletActivityFilterPreferences.sortKeyKey)
    private var sortKeyRaw: String = WalletActivityFilterPreferences.defaultSortKey.rawValue
    @AppStorage(WalletActivityFilterPreferences.directionKey)
    private var directionRaw: String = WalletActivityFilterPreferences.defaultDirection.rawValue
    @AppStorage(WalletActivityFilterPreferences.statusKey)
    private var statusRaw: String = WalletActivityFilterPreferences.defaultStatus.rawValue
    @AppStorage(WalletActivityFilterPreferences.kindKey)
    private var kindRaw: String = WalletActivityFilterPreferences.defaultKind.rawValue
    @AppStorage(WalletActivityFilterPreferences.assetClassKey)
    private var assetClassRaw: String = WalletActivityFilterPreferences.defaultAssetClass.rawValue
    @AppStorage(WalletActivityFilterPreferences.selectedNetworksKey)
    private var selectedNetworksJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON
    @AppStorage(WalletActivityFilterPreferences.selectedSymbolsKey)
    private var selectedSymbolsJSON: String = WalletActivityFilterPreferences.defaultSelectedJSON
    @AppStorage(WalletActivityFilterPreferences.timeRangeKey)
    private var timeRangeRaw: String = WalletActivityFilterPreferences.defaultTimeRange.rawValue
    @AppStorage(WalletActivityFilterPreferences.customStartKey)
    private var customStart: Double = WalletActivityFilterPreferences.defaultCustomDate
    @AppStorage(WalletActivityFilterPreferences.customEndKey)
    private var customEnd: Double = WalletActivityFilterPreferences.defaultCustomDate
    @AppStorage(WalletActivityFilterPreferences.minFiatKey)
    private var minFiat: String = WalletActivityFilterPreferences.defaultAmount
    @AppStorage(WalletActivityFilterPreferences.maxFiatKey)
    private var maxFiat: String = WalletActivityFilterPreferences.defaultAmount

    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    @State private var isShowingFilter: Bool = false
    @State private var searchText: String = ""

    // MARK: - PDF export (Part 3, 2026-06-19)

    @Environment(\.displayScale) private var displayScale
    @State private var isGeneratingPDF: Bool = false
    @State private var exportedPDF: ExportedActivityPDF?
    @State private var exportFailed: Bool = false
    @State private var isShowingExportOptions: Bool = false

    /// Memoized newest-first feed. Rebuilt only when the feed key
    /// changes (wallet switch or a tx count change) — not per body pass.
    @State private var sortedTransactions: [TransactionRecord] = []

    /// USD unit prices for the feed's symbols, used ONLY for the $0.01-USD
    /// dust gate (see `ActivityFiat.usdPriceMap`). Loaded async after each
    /// rebuild; until it arrives every row shows (we never hide what we
    /// can't yet measure in dollars). Mutating it re-renders, which
    /// re-applies `displayedTransactions`.
    @State private var usdPrices: [String: Decimal] = [:]

    /// Cheap rebuild key — O(1). Replaces the O(all-tx) data fingerprint.
    /// Wallet switch changes `activeWalletIdRaw`; a new/removed tx changes
    /// the @Query count. A status change (pending→confirmed, same count)
    /// doesn't re-key, but the rows read `tx.statusRaw` live off the
    /// shared SwiftData reference, so status still updates without a
    /// feed rebuild.
    private var feedKey: String {
        "\(activeWalletIdRaw)|\(allTransactionRecords.count)"
    }

    /// The honest base feed — the wallet's transactions with sub-$0.01-USD
    /// dust removed (2026-06-19 user direction). This is the "M" in the
    /// preview's "Showing N of M": dust is never part of what the user can
    /// see, so it isn't part of the total either. A leg with no known USD
    /// price is kept (honesty over a guessed hide).
    private var dustFreeTransactions: [TransactionRecord] {
        sortedTransactions.filter { tx in
            !ActivityFiat.isDust(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, usdMap: usdPrices)
        }
    }

    /// The rows actually shown — the dust-free base run through the user's
    /// filter + sort + search (Part 2). Fiat for amount-range filtering and
    /// value sorts is resolved in the active display currency via
    /// `priceMap`, matching the amounts the rows display.
    private var displayedTransactions: [TransactionRecord] {
        transactions(for: filterInputs)
    }

    private func transactions(for inputs: WalletActivityFilterInputs) -> [TransactionRecord] {
        WalletActivityFilterApply.apply(
            transactions: dustFreeTransactions,
            with: inputs,
            fiatValue: { ActivityFiat.value(amountRaw: $0.amountRaw, symbol: $0.tokenSymbol, map: priceMap) }
        )
    }

    /// Decoded snapshot of the persisted filter preferences plus the
    /// transient search text — the single input to `WalletActivityFilterApply`.
    private var filterInputs: WalletActivityFilterInputs {
        let isCustom = timeRangeRaw == WalletActivityFilterPreferences.TimeRange.custom.rawValue
        return WalletActivityFilterInputs(
            sortKey: WalletActivityFilterPreferences.SortKey(rawValue: sortKeyRaw)
                ?? WalletActivityFilterPreferences.defaultSortKey,
            direction: WalletActivityFilterPreferences.TxDirection(rawValue: directionRaw)
                ?? WalletActivityFilterPreferences.defaultDirection,
            status: WalletActivityFilterPreferences.TxStatus(rawValue: statusRaw)
                ?? WalletActivityFilterPreferences.defaultStatus,
            kind: WalletActivityFilterPreferences.TxKind(rawValue: kindRaw)
                ?? WalletActivityFilterPreferences.defaultKind,
            assetClass: WalletActivityFilterPreferences.AssetClass(rawValue: assetClassRaw)
                ?? WalletActivityFilterPreferences.defaultAssetClass,
            selectedNetworks: WalletActivityFilterPreferences.decode(selectedNetworksJSON),
            selectedSymbols: WalletActivityFilterPreferences.decode(selectedSymbolsJSON),
            timeRange: WalletActivityFilterPreferences.TimeRange(rawValue: timeRangeRaw)
                ?? WalletActivityFilterPreferences.defaultTimeRange,
            customStart: (isCustom && customStart > 0) ? Date(timeIntervalSince1970: customStart) : nil,
            customEnd: (isCustom && customEnd > 0) ? Date(timeIntervalSince1970: customEnd) : nil,
            minFiat: Self.parseAmount(minFiat),
            maxFiat: Self.parseAmount(maxFiat),
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    /// Parse a user-entered amount string to `Decimal`. Empty → nil.
    /// Accepts both `.` and `,` as the decimal separator so a decimal-pad
    /// entry in any locale parses.
    private static func parseAmount(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Decimal(string: trimmed) { return value }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Distinct chains present in the dust-free feed — the network
    /// multi-select's options (not "every chain Aperture supports").
    private var availableNetworks: [SupportedChain] {
        var seen = Set<String>()
        var result: [SupportedChain] = []
        for tx in dustFreeTransactions {
            guard let raw = tx.address?.chainRaw, !seen.contains(raw),
                  let chain = SupportedChain(rawValue: raw) else { continue }
            seen.insert(raw)
            result.append(chain)
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    /// Distinct token symbols present in the dust-free feed — the asset
    /// multi-select's options, in display casing, sorted.
    private var availableSymbols: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tx in dustFreeTransactions {
            let key = tx.tokenSymbol.uppercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(tx.tokenSymbol)
        }
        return result.sorted { $0.uppercased() < $1.uppercased() }
    }

    /// `true` when any filter, sort, or search is narrowing the list —
    /// drives the toolbar button's active dot.
    private var isFilterActive: Bool {
        WalletActivityFilterPreferences.isActive(
            sortKeyRaw: sortKeyRaw,
            directionRaw: directionRaw,
            statusRaw: statusRaw,
            kindRaw: kindRaw,
            assetClassRaw: assetClassRaw,
            selectedNetworksJSON: selectedNetworksJSON,
            selectedSymbolsJSON: selectedSymbolsJSON,
            timeRangeRaw: timeRangeRaw,
            minFiat: minFiat,
            maxFiat: maxFiat
        ) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if displayedTransactions.isEmpty {
                emptyStateScreen
            } else {
                activityList
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text("Search address, asset, or hash")
        )
        .toolbar {
            if !dustFreeTransactions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingExportOptions = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityLabel(Text("Export PDF"))
                    }
                    .tint(UniColors.Icon.accent)
                    .disabled(isGeneratingPDF)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingFilter = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "slider.horizontal.3")
                        if isFilterActive {
                            Circle()
                                .fill(UniColors.Tint.accent)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -3)
                        }
                    }
                    .accessibilityLabel(Text("Filter and sort"))
                }
                .tint(UniColors.Icon.accent)
            }
        }
        .sheet(isPresented: $isShowingFilter) {
            WalletActivityFilterSheet(
                availableNetworks: availableNetworks,
                availableSymbols: availableSymbols,
                currencyCode: currencyCode,
                totalTransactions: dustFreeTransactions.count,
                visibleTransactions: displayedTransactions.count
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingExportOptions) {
            ActivityPDFExportSheet(
                availableNetworks: availableNetworks,
                availableSymbols: availableSymbols,
                currencyCode: currencyCode,
                totalTransactions: dustFreeTransactions.count,
                initialInputs: filterInputs,
                visibleTransactions: { inputs in
                    transactions(for: inputs).count
                },
                onExport: { inputs in
                    exportPDF(using: inputs)
                }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(item: $exportedPDF) { pdf in
            ActivityPDFShareSheet(url: pdf.url)
        }
        .overlay {
            if isGeneratingPDF {
                pdfGeneratingOverlay
            }
        }
        .alert("Couldn't create the PDF.", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong preparing the export. Please try again.")
        }
        .task(id: feedKey) {
            rebuild()
            await loadDustPrices()
        }
    }

    private var activityList: some View {
        List {
            Section {
                ForEach(displayedTransactions, id: \.id) { tx in
                    if let chain = chainFor(tx) {
                        NavigationLink(value: WalletHomeDestination.transaction(tx.id)) {
                            activityRow(tx, chain: chain)
                        }
                    } else {
                        // The parent address record is missing or
                        // carries an unrecognized chain — render the
                        // row plain, with NO NavigationLink, so the
                        // user is never routed against wrong-chain
                        // data. (Same guard `AssetActivityView`
                        // uses — a silent `.ethereum` fallback once
                        // showed users the wrong chain's detail.)
                        activityRow(tx, chain: .ethereum)
                    }
                }
            } header: {
                Text(headerLabel(visible: displayedTransactions.count, total: dustFreeTransactions.count))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Native progress overlay shown while the PDF document renders.
    private var pdfGeneratingOverlay: some View {
        ZStack {
            UniColors.Background.primary.opacity(0.6).ignoresSafeArea()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(UniColors.Tint.accent)
        }
        .transition(.opacity)
    }

    // MARK: - Empty state

    /// Empty state — two registers. When the dust-free feed itself is
    /// empty, the wallet genuinely has no activity. When it has activity
    /// but the user's filter/search excludes all of it, say so and point
    /// them at the filter, mirroring `AssetActivityView`.
    private var emptyStateScreen: some View {
        List {
            Section {
                emptyState
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        let hasActivity = !dustFreeTransactions.isEmpty
        return UniListEmptyState(
            title: hasActivity ? "No activity matches the filter." : "No activity yet.",
            detail: hasActivity
                ? "Adjust the filter or search to see more of your activity."
                : "Transactions appear here as they confirm on-chain.",
            mark: hasActivity ? .icon(systemName: "line.3.horizontal.decrease") : .iris,
            minHeight: 360
        )
    }

    // MARK: - Header

    /// "All N transactions" when nothing is narrowing the list, else
    /// the honest "Showing N of M transactions".
    private func headerLabel(visible: Int, total: Int) -> String {
        if visible == total {
            return String(
                format: String(localized: "All %lld transactions"),
                Int64(total)
            )
        }
        return String(
            format: String(localized: "Showing %lld of %lld transactions"),
            Int64(visible),
            Int64(total)
        )
    }

    // MARK: - Feed

    /// Resolve + flatten + sort once. Newest-first across every
    /// address of the active wallet, reflecting the full history the DB
    /// holds (the adapters paginate to 1,000 txs/chain).
    private func rebuild() {
        guard let wallet = activeWallet else {
            sortedTransactions = []
            return
        }
        let ids = Set(wallet.addresses.map { $0.id })
        guard !ids.isEmpty else {
            sortedTransactions = []
            return
        }
        // One in-memory pass over the store-sorted feed (newest-first
        // already), filtering on the stored `addressId` column — no
        // relationship faulting, no per-render sort.
        sortedTransactions = allTransactionRecords.filter { tx in
            guard let aid = tx.addressId else { return false }
            return ids.contains(aid)
        }
    }

    /// Resolve USD unit prices for the feed's distinct symbols so the
    /// $0.01-USD dust gate can run. Cheap after the first call (the engine
    /// caches), and cancellation-safe — a wallet switch re-keys the task,
    /// cancelling this before it writes a stale wallet's prices.
    private func loadDustPrices() async {
        let symbols = sortedTransactions.map(\.tokenSymbol)
        let map = await ActivityFiat.usdPriceMap(symbols: symbols)
        guard !Task.isCancelled else { return }
        usdPrices = map
    }

    // MARK: - Wallet plumbing (store-truth, matches WalletHomeView)

    /// Active wallet resolved with the same hardened precedence the
    /// wallet-home uses: stored id → `@Query` match → direct store
    /// fetch (covers the `@Query` merge lag). An explicit missing id
    /// returns nil instead of showing a different wallet's rows.
    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(
            rawID: activeWalletIdRaw,
            wallets: allWallets,
            modelContext: modelContext
        )
    }

    private func walletExists(id: UUID) -> Bool {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Resolves the chain a `TransactionRecord` belongs to. Returns
    /// `nil` when the parent address record is missing or carries an
    /// unrecognized chain — callers must NOT route such a row anywhere
    /// (no silent `.ethereum` fallback for navigation; that showed
    /// users wrong-chain data).
    private func chainFor(_ tx: TransactionRecord) -> SupportedChain? {
        guard let raw = tx.address?.chainRaw,
              let chain = SupportedChain(rawValue: raw) else { return nil }
        return chain
    }

    /// Shared row label for both the navigable and the plain
    /// (unresolvable-chain) activity entries — the same `ActivityRow`
    /// the wallet-home and `AssetActivityView` use.
    private func activityRow(_ tx: TransactionRecord, chain: SupportedChain) -> ActivityRow {
        ActivityRow(
            chain: chain,
            direction: TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing,
            amount: Decimal(string: tx.amountRaw) ?? .zero,
            tokenSymbol: tx.tokenSymbol,
            counterparty: tx.counterparty,
            occurredAt: tx.occurredAt,
            status: TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed,
            kind: tx.kind,
            fiatValue: ActivityFiat.value(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, map: priceMap),
            fiatCurrencyCode: currencyCode,
            tokenContract: tx.tokenContract,
            txHash: tx.txHash
        )
    }

    // MARK: - PDF export (Part 3)

    /// Snapshot the currently-shown rows + a localized document model on
    /// the main actor, then render + write the PDF off the hot path and
    /// present the system share sheet. The user drives every share
    /// destination — the app only produces a local file.
    private func exportPDF(using inputs: WalletActivityFilterInputs) {
        let exportTransactions = transactions(for: inputs)
        guard !exportTransactions.isEmpty, !isGeneratingPDF else { return }
        let rows = pdfRows(for: exportTransactions)
        let document = pdfDocument(rows: rows, inputs: inputs)
        let fileName = pdfFileName()
        let scale = displayScale
        isGeneratingPDF = true
        Task {
            let url = await ActivityPDFExporter.makeFile(
                rows: rows,
                document: document,
                fileName: fileName,
                displayScale: scale
            )
            isGeneratingPDF = false
            if let url {
                exportedPDF = ExportedActivityPDF(url: url)
            } else {
                exportFailed = true
            }
        }
    }

    /// Build the value-typed PDF rows from the displayed transactions —
    /// amounts and fiat formatted exactly as the on-screen rows show them
    /// (signed native amount; unsigned fiat value, the colour + type carry
    /// direction).
    private func pdfRows(for transactions: [TransactionRecord]) -> [ActivityPDFRow] {
        let map = priceMap
        return transactions.map { tx in
            let direction = TransactionDirection(rawValue: tx.directionRaw) ?? .outgoing
            let amount = Decimal(string: tx.amountRaw) ?? .zero
            let fiat = ActivityFiat.value(amountRaw: tx.amountRaw, symbol: tx.tokenSymbol, map: map)
            let sign: String
            switch direction {
            case .incoming: sign = "+"
            case .outgoing: sign = "−"
            case .internal: sign = ""
            }
            let status = TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed
            return ActivityPDFRow(
                occurredAt: tx.occurredAt,
                dateText: Self.statementDateFormatter.string(from: tx.occurredAt),
                timeText: Self.statementTimeFormatter.string(from: tx.occurredAt),
                assetSymbol: tx.tokenSymbol,
                networkName: chainFor(tx)?.displayName ?? "-",
                chain: chainFor(tx) ?? .ethereum,
                tokenContract: tx.tokenContract,
                typeText: pdfTypeLabel(direction),
                transferType: pdfTransferType(direction),
                amountText: "\(sign)\(WalletFormatting.native(amount, decimals: 6))",
                unitText: tx.tokenSymbol,
                fiatText: fiat.map { WalletFormatting.fiat($0, currencyCode: currencyCode) } ?? "—",
                fiatValue: fiat,
                statusText: pdfStatusLabel(status),
                status: pdfStatusKind(status)
            )
        }
    }

    /// The localized document metadata + column labels.
    private func pdfDocument(rows: [ActivityPDFRow], inputs: WalletActivityFilterInputs) -> ActivityPDFDocument {
        let isRTL = LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft
        let rowCount = rows.count
        let received = rows
            .filter { $0.transferType == .received }
            .reduce(Decimal.zero) { $0 + ($1.fiatValue ?? .zero) }
        let sent = rows
            .filter { $0.transferType == .sent }
            .reduce(Decimal.zero) { $0 + ($1.fiatValue ?? .zero) }
        let net = received - sent
        let failedCount = rows.filter { $0.status == .failed }.count
        let confirmedCount = rows.filter { $0.status == .confirmed }.count
        let internalCount = rows.filter { $0.transferType == .internalTransfer }.count
        let assets = Set(rows.map {
            "\($0.chain.rawValue)|\($0.assetSymbol.uppercased())|\($0.tokenContract?.lowercased() ?? "")"
        })
        let chainCounts = Dictionary(grouping: rows, by: \.chain)
            .map { ActivityPDFChainSummary(chain: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.chain.displayName < $1.chain.displayName
            }
        let periodText: String
        if let first = rows.map(\.occurredAt).min(), let last = rows.map(\.occurredAt).max() {
            periodText = "\(Self.statementDateFormatter.string(from: first)) — \(Self.statementDateFormatter.string(from: last))"
        } else {
            periodText = Self.statementDateFormatter.string(from: Date())
        }
        return ActivityPDFDocument(
            appName: "Aperture",
            title: String(localized: "Activity Statement"),
            walletName: activeWallet?.name ?? String(localized: "Wallet"),
            generatedText: Self.statementGeneratedFormatter.string(from: Date()),
            transactionCount: rowCount,
            assetCount: assets.count,
            confirmedCount: confirmedCount,
            failedCount: failedCount,
            internalCount: internalCount,
            receivedFiatText: WalletFormatting.fiat(received, currencyCode: currencyCode),
            sentFiatText: WalletFormatting.fiat(sent, currencyCode: currencyCode),
            netFiatText: "\(net >= .zero ? "+" : "−")\(WalletFormatting.fiat(Self.abs(net), currencyCode: currencyCode))",
            netIsPositive: net >= .zero,
            periodText: periodText,
            chainSummaries: chainCounts,
            downloadCaption: String(localized: "Get Aperture"),
            appStoreURLText: ApertureWeb.appStoreDisplay,
            footerSiteText: "aperturex.io",
            pageLabelFormat: String(localized: "Page %1$lld of %2$lld"),
            emptyText: String(localized: "No transactions to show."),
            legalTitle: String(localized: "About this statement"),
            legalText: String(localized: "This statement was generated by Aperture from on-chain data for the wallet shown above. Fiat values are estimates at the time of each transaction and are for reference only. Aperture is a self-custodial wallet — your keys never leave your device. This document is informational and is not tax or financial advice."),
            isRTL: isRTL
        )
    }

    /// Localized one-line descriptions of each active filter, for the PDF
    /// header band. Empty when nothing is narrowing the list.
    private func pdfFilterLines(_ inputs: WalletActivityFilterInputs) -> [String] {
        var lines: [String] = []

        switch inputs.sortKey {
        case .newest: break
        case .oldest:
            lines.append(String(format: String(localized: "Sort: %@"), String(localized: "Oldest first")))
        case .largest:
            lines.append(String(format: String(localized: "Sort: %@"), String(localized: "Largest first")))
        case .smallest:
            lines.append(String(format: String(localized: "Sort: %@"), String(localized: "Smallest first")))
        }

        switch inputs.direction {
        case .all: break
        case .incoming:
            lines.append(String(format: String(localized: "Direction: %@"), String(localized: "Received")))
        case .outgoing:
            lines.append(String(format: String(localized: "Direction: %@"), String(localized: "Sent")))
        case .internal:
            lines.append(String(format: String(localized: "Direction: %@"), String(localized: "Internal")))
        }

        switch inputs.status {
        case .all: break
        case .confirmed:
            lines.append(String(format: String(localized: "Status: %@"), String(localized: "Confirmed")))
        case .pending:
            lines.append(String(format: String(localized: "Status: %@"), String(localized: "Pending")))
        case .failed:
            lines.append(String(format: String(localized: "Status: %@"), String(localized: "Failed")))
        }

        switch inputs.kind {
        case .all: break
        case .transfer:
            lines.append(String(format: String(localized: "Kind: %@"), String(localized: "Transfers")))
        case .selfTransfer:
            lines.append(String(format: String(localized: "Kind: %@"), String(localized: "Self transfers")))
        case .bridge:
            lines.append(String(format: String(localized: "Kind: %@"), String(localized: "Bridge")))
        }

        switch inputs.assetClass {
        case .all: break
        case .coins:
            lines.append(String(format: String(localized: "Asset type: %@"), String(localized: "Coins")))
        case .tokens:
            lines.append(String(format: String(localized: "Asset type: %@"), String(localized: "Tokens")))
        }

        if !inputs.selectedNetworks.isEmpty {
            let names = inputs.selectedNetworks
                .compactMap { SupportedChain(rawValue: $0)?.displayName }
                .sorted()
                .joined(separator: ", ")
            if !names.isEmpty {
                lines.append(String(format: String(localized: "Networks: %@"), names))
            }
        }

        if !inputs.selectedSymbols.isEmpty {
            let names = inputs.selectedSymbols.sorted().joined(separator: ", ")
            lines.append(String(format: String(localized: "Assets: %@"), names))
        }

        if inputs.timeRange != .all {
            lines.append(String(format: String(localized: "Period: %@"), pdfPeriodText(inputs)))
        }

        if let amountText = pdfAmountText(inputs) {
            lines.append(String(format: String(localized: "Amount: %@"), amountText))
        }

        let query = inputs.searchText
        if !query.isEmpty {
            lines.append(String(format: String(localized: "Search: %@"), query))
        }

        return lines
    }

    private func pdfPeriodText(_ inputs: WalletActivityFilterInputs) -> String {
        switch inputs.timeRange {
        case .day:   return String(localized: "Last 24 hours")
        case .week:  return String(localized: "Last 7 days")
        case .month: return String(localized: "Last 30 days")
        case .year:  return String(localized: "Last year")
        case .all:   return String(localized: "All time")
        case .custom:
            let from = inputs.customStart.map { Self.rowDateFormatter.string(from: $0) }
            let to = inputs.customEnd.map { Self.rowDateFormatter.string(from: $0) }
            switch (from, to) {
            case let (f?, t?): return "\(f) – \(t)"
            case let (f?, nil): return String(format: String(localized: "From %@"), f)
            case let (nil, t?): return String(format: String(localized: "Until %@"), t)
            case (nil, nil): return String(localized: "Custom")
            }
        }
    }

    private func pdfAmountText(_ inputs: WalletActivityFilterInputs) -> String? {
        let min = inputs.minFiat.map { WalletFormatting.fiat($0, currencyCode: currencyCode) }
        let max = inputs.maxFiat.map { WalletFormatting.fiat($0, currencyCode: currencyCode) }
        switch (min, max) {
        case let (lo?, hi?): return "\(lo) – \(hi)"
        case let (lo?, nil): return "≥ \(lo)"
        case let (nil, hi?): return "≤ \(hi)"
        case (nil, nil): return nil
        }
    }

    private func pdfTypeLabel(_ direction: TransactionDirection) -> String {
        switch direction {
        case .incoming: return String(localized: "Received")
        case .outgoing: return String(localized: "Sent")
        case .internal: return String(localized: "Internal")
        }
    }

    private func pdfTransferType(_ direction: TransactionDirection) -> ActivityPDFRow.TransferType {
        switch direction {
        case .incoming: return .received
        case .outgoing: return .sent
        case .internal: return .internalTransfer
        }
    }

    private func pdfStatusLabel(_ status: TransactionStatus) -> String {
        switch status {
        case .confirmed: return String(localized: "Confirmed")
        case .pending:   return String(localized: "Pending")
        case .failed:    return String(localized: "Canceled")
        }
    }

    private func pdfStatusKind(_ status: TransactionStatus) -> ActivityPDFRow.Status {
        switch status {
        case .confirmed: return .confirmed
        case .pending:   return .pending
        case .failed:    return .failed
        }
    }

    private func pdfFileName() -> String {
        let date = Self.fileDateFormatter.string(from: Date())
        let wallet = activeWallet?.name ?? "Wallet"
        return "Aperture Activity - \(wallet) - \(date).pdf"
    }

    private static func abs(_ value: Decimal) -> Decimal {
        value < .zero ? -value : value
    }

    /// Pixel-match statement date: `13 Jun 2026`.
    private static let statementDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// Pixel-match statement time: `14:22`.
    private static let statementTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Pixel-match generated timestamp: `29 June 2026 at 15:34`.
    private static let statementGeneratedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMMM yyyy 'at' HH:mm"
        return f
    }()

    /// Compact per-row date+time, in the user's locale.
    private static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Long "generated on" timestamp for the header.
    private static let generatedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// `yyyy-MM-dd` for the export filename (stable, sortable).
    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - PDF Export Options

private struct ActivityPDFExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let availableNetworks: [SupportedChain]
    let availableSymbols: [String]
    let currencyCode: String
    let totalTransactions: Int
    let initialInputs: WalletActivityFilterInputs
    let visibleTransactions: (WalletActivityFilterInputs) -> Int
    let onExport: (WalletActivityFilterInputs) -> Void

    @State private var sortKey: WalletActivityFilterPreferences.SortKey
    @State private var direction: WalletActivityFilterPreferences.TxDirection
    @State private var status: WalletActivityFilterPreferences.TxStatus
    @State private var kind: WalletActivityFilterPreferences.TxKind
    @State private var assetClass: WalletActivityFilterPreferences.AssetClass
    @State private var selectedNetworks: Set<String>
    @State private var selectedSymbols: Set<String>
    @State private var timeRange: WalletActivityFilterPreferences.TimeRange
    @State private var customStart: Date
    @State private var customEnd: Date
    @State private var minFiat: String
    @State private var maxFiat: String
    @State private var searchText: String

    init(
        availableNetworks: [SupportedChain],
        availableSymbols: [String],
        currencyCode: String,
        totalTransactions: Int,
        initialInputs: WalletActivityFilterInputs,
        visibleTransactions: @escaping (WalletActivityFilterInputs) -> Int,
        onExport: @escaping (WalletActivityFilterInputs) -> Void
    ) {
        self.availableNetworks = availableNetworks
        self.availableSymbols = availableSymbols
        self.currencyCode = currencyCode
        self.totalTransactions = totalTransactions
        self.initialInputs = initialInputs
        self.visibleTransactions = visibleTransactions
        self.onExport = onExport

        let now = Date()
        let seededStart = initialInputs.customStart
            ?? Calendar.current.date(byAdding: .day, value: -30, to: now)
            ?? now
        let seededEnd = initialInputs.customEnd ?? now

        _sortKey = State(initialValue: initialInputs.sortKey)
        _direction = State(initialValue: initialInputs.direction)
        _status = State(initialValue: initialInputs.status)
        _kind = State(initialValue: initialInputs.kind)
        _assetClass = State(initialValue: initialInputs.assetClass)
        _selectedNetworks = State(initialValue: initialInputs.selectedNetworks)
        _selectedSymbols = State(initialValue: initialInputs.selectedSymbols)
        _timeRange = State(initialValue: initialInputs.timeRange)
        _customStart = State(initialValue: seededStart)
        _customEnd = State(initialValue: seededEnd)
        _minFiat = State(initialValue: Self.amountString(initialInputs.minFiat))
        _maxFiat = State(initialValue: Self.amountString(initialInputs.maxFiat))
        _searchText = State(initialValue: initialInputs.searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                previewSection
                scopeSection
                sortSection
                transactionSection
                showSection
                dateSection
                amountSection
                searchSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Export PDF"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(UniColors.Button.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") {
                        onExport(inputs)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .tint(UniColors.Button.text)
                    .disabled(visibleCount <= 0)
                }
            }
            .navigationDestination(for: ActivityPDFExportDestination.self) { destination in
                switch destination {
                case .networks:
                    ActivityPDFExportNetworksPicker(
                        availableNetworks: availableNetworks,
                        selectedNetworks: $selectedNetworks
                    )
                case .assets:
                    ActivityPDFExportAssetsPicker(
                        availableSymbols: availableSymbols,
                        selectedSymbols: $selectedSymbols
                    )
                }
            }
            .onChange(of: timeRange) { _, newValue in
                if newValue == .custom {
                    seedCustomWindowIfNeeded()
                }
            }
        }
    }

    private var inputs: WalletActivityFilterInputs {
        WalletActivityFilterInputs(
            sortKey: sortKey,
            direction: direction,
            status: status,
            kind: kind,
            assetClass: assetClass,
            selectedNetworks: selectedNetworks,
            selectedSymbols: selectedSymbols,
            timeRange: timeRange,
            customStart: timeRange == .custom ? customStart : nil,
            customEnd: timeRange == .custom ? customEnd : nil,
            minFiat: Self.parseAmount(minFiat),
            maxFiat: Self.parseAmount(maxFiat),
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private var visibleCount: Int {
        visibleTransactions(inputs)
    }

    private var previewText: String {
        if visibleCount == totalTransactions {
            return String(
                format: String(localized: "Exporting all %lld transactions"),
                Int64(totalTransactions)
            )
        }
        return String(
            format: String(localized: "Exporting %lld of %lld transactions"),
            Int64(visibleCount),
            Int64(totalTransactions)
        )
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            HStack(spacing: UniSpacing.s) {
                Image("LogoCircle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(verbatim: previewText)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Aperture Activity Statement")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
            .listRowBackground(UniColors.List.rowBackground)
        }
    }

    @ViewBuilder
    private var scopeSection: some View {
        Section {
            Button {
                apply(initialInputs)
            } label: {
                actionRow(
                    systemImage: "slider.horizontal.3",
                    title: "Current view",
                    readout: currentViewReadout
                )
            }
            .listRowBackground(UniColors.List.rowBackground)

            Button {
                apply(Self.defaultInputs())
            } label: {
                actionRow(
                    systemImage: "tray.full",
                    title: "All activity",
                    readout: allActivityReadout
                )
            }
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Scope")
        }
    }

    private var currentViewReadout: String {
        let count = visibleTransactions(initialInputs)
        return String(format: String(localized: "%lld rows"), Int64(count))
    }

    private var allActivityReadout: String {
        String(format: String(localized: "%lld rows"), Int64(totalTransactions))
    }

    @ViewBuilder
    private var sortSection: some View {
        Section {
            pickerBlock(title: "Sort by", selection: $sortKey) {
                ForEach(WalletActivityFilterPreferences.SortKey.allCases) { key in
                    Text(key.label).tag(key)
                }
            }
        } header: {
            Text("Sort")
        }
    }

    @ViewBuilder
    private var transactionSection: some View {
        Section {
            pickerBlock(title: "Direction", selection: $direction) {
                ForEach(WalletActivityFilterPreferences.TxDirection.allCases) { direction in
                    Text(direction.label).tag(direction)
                }
            }
            pickerBlock(title: "Kind", selection: $kind) {
                ForEach(WalletActivityFilterPreferences.TxKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            pickerBlock(title: "Status", selection: $status) {
                ForEach(WalletActivityFilterPreferences.TxStatus.allCases) { status in
                    Text(status.label).tag(status)
                }
            }
        } header: {
            Text("Transactions")
        }
    }

    @ViewBuilder
    private var showSection: some View {
        Section {
            pickerBlock(title: "Asset type", selection: $assetClass) {
                ForEach(WalletActivityFilterPreferences.AssetClass.allCases) { assetClass in
                    Text(assetClass.label).tag(assetClass)
                }
            }

            NavigationLink(value: ActivityPDFExportDestination.networks) {
                multiSelectLink(
                    systemImage: "network",
                    title: "Chains",
                    readout: readout(selected: selectedNetworks.count, total: availableNetworks.count)
                )
            }
            .listRowBackground(UniColors.List.rowBackground)

            NavigationLink(value: ActivityPDFExportDestination.assets) {
                multiSelectLink(
                    systemImage: "circle.hexagongrid",
                    title: "Coins & tokens",
                    readout: readout(selected: selectedSymbols.count, total: availableSymbols.count)
                )
            }
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Assets")
        }
    }

    @ViewBuilder
    private var dateSection: some View {
        Section {
            pickerBlock(title: "Date range", selection: $timeRange) {
                ForEach(WalletActivityFilterPreferences.TimeRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }

            if timeRange == .custom {
                DatePicker(
                    selection: customStartBinding,
                    in: ...customEnd,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text("From")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                }
                .tint(UniColors.Tint.accent)
                .listRowBackground(UniColors.List.rowBackground)

                DatePicker(
                    selection: customEndBinding,
                    in: customStart...,
                    displayedComponents: [.date, .hourAndMinute]
                ) {
                    Text("To")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                }
                .tint(UniColors.Tint.accent)
                .listRowBackground(UniColors.List.rowBackground)
            }
        } header: {
            Text("Date & Time")
        }
    }

    @ViewBuilder
    private var amountSection: some View {
        Section {
            amountField(placeholder: "Minimum", text: $minFiat)
                .listRowBackground(UniColors.List.rowBackground)
            amountField(placeholder: "Maximum", text: $maxFiat)
                .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Amount")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section {
            UniTextField(
                placeholder: "Address, asset, or hash",
                text: $searchText,
                fill: Color.clear,
                verticalPadding: UniSpacing.xs,
                showsChrome: false
            )
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Search")
        }
    }

    @ViewBuilder
    private func pickerBlock<Value: Hashable>(
        title: LocalizedStringKey,
        selection: Binding<Value>,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text(title)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
            Picker(title, selection: selection) {
                content()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.List.rowBackground)
    }

    @ViewBuilder
    private func multiSelectLink(
        systemImage: String,
        title: LocalizedStringKey,
        readout: String
    ) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
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

    @ViewBuilder
    private func actionRow(
        systemImage: String,
        title: LocalizedStringKey,
        readout: String
    ) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
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

    @ViewBuilder
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

    private var customStartBinding: Binding<Date> {
        Binding(
            get: { customStart },
            set: { customStart = min($0, customEnd) }
        )
    }

    private var customEndBinding: Binding<Date> {
        Binding(
            get: { customEnd },
            set: { customEnd = max($0, customStart) }
        )
    }

    private func readout(selected: Int, total: Int) -> String {
        if selected == 0 {
            return String.apertureLocalized("All")
        }
        return String(
            format: String(localized: "%lld of %lld"),
            Int64(selected),
            Int64(total)
        )
    }

    private func apply(_ inputs: WalletActivityFilterInputs) {
        sortKey = inputs.sortKey
        direction = inputs.direction
        status = inputs.status
        kind = inputs.kind
        assetClass = inputs.assetClass
        selectedNetworks = inputs.selectedNetworks
        selectedSymbols = inputs.selectedSymbols
        timeRange = inputs.timeRange
        if let start = inputs.customStart { customStart = start }
        if let end = inputs.customEnd { customEnd = end }
        minFiat = Self.amountString(inputs.minFiat)
        maxFiat = Self.amountString(inputs.maxFiat)
        searchText = inputs.searchText
        seedCustomWindowIfNeeded()
    }

    private func seedCustomWindowIfNeeded() {
        guard timeRange == .custom else { return }
        if customStart <= customEnd { return }
        let now = Date()
        customEnd = now
        customStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
    }

    private static func defaultInputs() -> WalletActivityFilterInputs {
        WalletActivityFilterInputs(
            sortKey: WalletActivityFilterPreferences.defaultSortKey,
            direction: WalletActivityFilterPreferences.defaultDirection,
            status: WalletActivityFilterPreferences.defaultStatus,
            kind: WalletActivityFilterPreferences.defaultKind,
            assetClass: WalletActivityFilterPreferences.defaultAssetClass,
            selectedNetworks: [],
            selectedSymbols: [],
            timeRange: WalletActivityFilterPreferences.defaultTimeRange,
            customStart: nil,
            customEnd: nil,
            minFiat: nil,
            maxFiat: nil,
            searchText: ""
        )
    }

    private static func amountString(_ value: Decimal?) -> String {
        guard let value else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private static func parseAmount(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Decimal(string: trimmed) { return value }
        return Decimal(string: trimmed.replacingOccurrences(of: ",", with: "."))
    }
}

private enum ActivityPDFExportDestination: Hashable, Codable {
    case networks
    case assets
}

private struct ActivityPDFExportNetworksPicker: View {
    let availableNetworks: [SupportedChain]
    @Binding var selectedNetworks: Set<String>

    var body: some View {
        List {
            Section {
                Button {
                    selectedNetworks.removeAll()
                } label: {
                    HStack {
                        Text("All chains")
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        if selectedNetworks.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(UniColors.Tint.accent)
                        }
                    }
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            Section {
                ForEach(availableNetworks, id: \.rawValue) { chain in
                    Button {
                        toggle(chain)
                    } label: {
                        HStack(spacing: UniSpacing.s) {
                            CoinMark(chain: chain, tokenSymbol: chain.ticker)
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            Text(verbatim: chain.displayName)
                                .foregroundStyle(UniColors.Text.primary)
                            Spacer()
                            if selectedNetworks.contains(chain.rawValue) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(UniColors.Tint.accent)
                            }
                        }
                        .padding(.vertical, UniSpacing.xxs)
                    }
                    .listRowBackground(UniColors.List.rowBackground)
                }
            } header: {
                Text("Chains")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Chains"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ chain: SupportedChain) {
        if selectedNetworks.contains(chain.rawValue) {
            selectedNetworks.remove(chain.rawValue)
        } else {
            selectedNetworks.insert(chain.rawValue)
        }
    }
}

private struct ActivityPDFExportAssetsPicker: View {
    let availableSymbols: [String]
    @Binding var selectedSymbols: Set<String>

    var body: some View {
        List {
            Section {
                Button {
                    selectedSymbols.removeAll()
                } label: {
                    HStack {
                        Text("All coins & tokens")
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        if selectedSymbols.isEmpty {
                            Image(systemName: "checkmark")
                                .foregroundStyle(UniColors.Tint.accent)
                        }
                    }
                }
                .listRowBackground(UniColors.List.rowBackground)
            }

            Section {
                ForEach(availableSymbols, id: \.self) { symbol in
                    Button {
                        toggle(symbol)
                    } label: {
                        HStack(spacing: UniSpacing.s) {
                            Text(verbatim: symbol)
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)
                            Spacer()
                            if selectedSymbols.contains(symbol.uppercased()) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(UniColors.Tint.accent)
                            }
                        }
                        .padding(.vertical, UniSpacing.xxs)
                    }
                    .listRowBackground(UniColors.List.rowBackground)
                }
            } header: {
                Text("Coins & Tokens")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Coins & Tokens"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ symbol: String) {
        let key = symbol.uppercased()
        if selectedSymbols.contains(key) {
            selectedSymbols.remove(key)
        } else {
            selectedSymbols.insert(key)
        }
    }
}
