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
        WalletActivityFilterApply.apply(
            transactions: dustFreeTransactions,
            with: filterInputs,
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
            selectedNetworksJSON: selectedNetworksJSON,
            selectedSymbolsJSON: selectedSymbolsJSON,
            timeRangeRaw: timeRangeRaw,
            minFiat: minFiat,
            maxFiat: maxFiat
        ) || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if displayedTransactions.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
            } else {
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text("Search address, asset, or hash")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportPDF()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .accessibilityLabel(Text("Export PDF"))
                }
                .tint(UniColors.Icon.accent)
                .disabled(displayedTransactions.isEmpty || isGeneratingPDF)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingFilter = true
                } label: {
                    Image(systemName: isFilterActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease")
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

    /// Dimmed "Preparing PDF…" overlay shown while the document renders.
    private var pdfGeneratingOverlay: some View {
        ZStack {
            UniColors.Background.primary.opacity(0.6).ignoresSafeArea()
            VStack(spacing: UniSpacing.s) {
                ProgressView()
                Text("Preparing PDF…")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            .padding(UniSpacing.l)
            .background(UniColors.Background.secondary, in: RoundedRectangle(cornerRadius: UniRadius.l))
        }
        .transition(.opacity)
    }

    // MARK: - Empty state

    /// Empty state — two registers. When the dust-free feed itself is
    /// empty, the wallet genuinely has no activity. When it has activity
    /// but the user's filter/search excludes all of it, say so and point
    /// them at the filter, mirroring `AssetActivityView`.
    private var emptyState: some View {
        let hasActivity = !dustFreeTransactions.isEmpty
        return UniEmptyState(
            title: hasActivity ? "No activity matches the filter." : "No activity yet.",
            detail: hasActivity
                ? "Adjust the filter or search to see more of your activity."
                : "Transactions appear here as they confirm on-chain.",
            mark: .icon(systemName: "list.bullet.rectangle.portrait")
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
    /// fetch (covers the `@Query` merge lag) → first existing wallet.
    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw) {
            if let match = allWallets.first(where: { $0.id == uuid }) {
                return match
            }
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == uuid }
            )
            descriptor.fetchLimit = 1
            if let stored = try? modelContext.fetch(descriptor).first {
                return stored
            }
        }
        return allWallets.first(where: { walletExists(id: $0.id) })
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
    private func exportPDF() {
        guard !displayedTransactions.isEmpty, !isGeneratingPDF else { return }
        let rows = pdfRows()
        let document = pdfDocument(rowCount: rows.count)
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
    private func pdfRows() -> [ActivityPDFRow] {
        let map = priceMap
        return displayedTransactions.map { tx in
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
                dateText: Self.rowDateFormatter.string(from: tx.occurredAt),
                assetSymbol: tx.tokenSymbol,
                networkName: chainFor(tx)?.displayName ?? "—",
                typeText: pdfTypeLabel(direction),
                isIncoming: direction == .incoming,
                amountText: "\(sign)\(WalletFormatting.native(amount, decimals: 6)) \(tx.tokenSymbol)",
                fiatText: fiat.map { WalletFormatting.fiat($0, currencyCode: currencyCode) } ?? "—",
                statusText: pdfStatusLabel(status),
                status: pdfStatusKind(status)
            )
        }
    }

    /// The localized document metadata + column labels.
    private func pdfDocument(rowCount: Int) -> ActivityPDFDocument {
        let isRTL = LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft
        let summary: String
        if rowCount == dustFreeTransactions.count {
            summary = String(format: String(localized: "All %lld transactions"), Int64(rowCount))
        } else {
            summary = String(
                format: String(localized: "Showing %lld of %lld transactions"),
                Int64(rowCount), Int64(dustFreeTransactions.count)
            )
        }
        return ActivityPDFDocument(
            appName: "Aperture",
            title: String(localized: "Activity Statement"),
            walletName: activeWallet?.name ?? String(localized: "Wallet"),
            generatedText: String(
                format: String(localized: "Generated %@"),
                Self.generatedDateFormatter.string(from: Date())
            ),
            summaryText: summary,
            filterLines: pdfFilterLines(),
            downloadCaption: String(localized: "Scan to download Aperture"),
            appStoreURLText: ApertureWeb.appStoreDisplay,
            footerText: "aperturex.io",
            pageLabelFormat: String(localized: "Page %1$lld of %2$lld"),
            emptyText: String(localized: "No transactions to show."),
            colDate: String(localized: "Date"),
            colAsset: String(localized: "Asset"),
            colType: String(localized: "Type"),
            colAmount: String(localized: "Amount"),
            colValue: String(localized: "Value"),
            colStatus: String(localized: "Status"),
            isRTL: isRTL
        )
    }

    /// Localized one-line descriptions of each active filter, for the PDF
    /// header band. Empty when nothing is narrowing the list.
    private func pdfFilterLines() -> [String] {
        let inputs = filterInputs
        var lines: [String] = []

        switch inputs.direction {
        case .all: break
        case .incoming:
            lines.append(String(format: String(localized: "Direction: %@"), String(localized: "Received")))
        case .outgoing:
            lines.append(String(format: String(localized: "Direction: %@"), String(localized: "Sent")))
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

    private func pdfStatusLabel(_ status: TransactionStatus) -> String {
        switch status {
        case .confirmed: return String(localized: "Confirmed")
        case .pending:   return String(localized: "Pending")
        case .failed:    return String(localized: "Failed")
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
