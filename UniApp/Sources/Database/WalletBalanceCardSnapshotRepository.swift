import Foundation
import SwiftData

// MARK: - WalletBalanceCardSnapshotRepository

/// Actor-isolated builder for the wallet-home balance-card read model.
///
/// The card renders from `WalletBalanceCardSnapshotRecord` only. Network
/// workers update balances, prices, histories, and sync rows first; this
/// repository folds those persisted rows into the exact card payload the UI
/// needs: current total, hidden state, selected range, range deltas, and chart
/// points. That keeps launch and wallet switching DB-first instead of showing
/// `$0` while refresh work is still running.
@ModelActor
actor WalletBalanceCardSnapshotRepository {
    private static let maxRenderedChartSamples = 180

    @discardableResult
    func rebuildFromStoredPreferences(
        walletId: UUID,
        currencyCode: String,
        now: Date = Date()
    ) throws -> WalletBalanceCardDisplaySnapshot {
        let selectedRange = UserDefaults.standard.string(forKey: "walletHomeBalanceHistoryRange")
            ?? BalanceHistoryRange.all.rawValue
        let hidden = UserDefaults.standard.bool(forKey: Self.hiddenPreferenceKey(walletId: walletId))
        return try rebuild(
            walletId: walletId,
            currencyCode: currencyCode,
            selectedRangeRaw: selectedRange,
            isBalanceHidden: hidden,
            now: now
        )
    }

    @discardableResult
    func rebuild(
        walletId: UUID,
        currencyCode: String,
        selectedRangeRaw: String,
        isBalanceHidden: Bool,
        now: Date = Date()
    ) throws -> WalletBalanceCardDisplaySnapshot {
        let code = currencyCode.uppercased()
        let addresses = try walletAddresses(walletId: walletId)
        let addressIds = Set(addresses.map(\.id))
        let ownAddresses = Set(addresses.map { $0.address.lowercased() })
        let transactions = try transactionSnapshots(addressIds: addressIds)
        let prices = try cachedPrices(currencyCode: code)
        let history = try historicalPrices(currencyCode: code)
        let total = try totalFiat(currencyCode: code, addressIds: addressIds)
        let hourlyHoldings = try holdings(addressIds: addressIds, prices: prices)
        let hourlySnapshots = try hourlyPriceSnapshots(currencyCode: code, since: now.addingTimeInterval(-7_200))
        let lastUpdated = try lastRefreshDate(walletId: walletId)

        let ranges = BalanceHistoryRange.allCases.map { range in
            makeRangeSnapshot(
                range: range,
                totalFiat: total,
                transactions: transactions,
                ownAddresses: ownAddresses,
                prices: prices,
                history: history,
                hourlyHoldings: hourlyHoldings,
                hourlySnapshots: hourlySnapshots,
                now: now
            )
        }

        let key = WalletBalanceCardSnapshotRecord.key(walletId: walletId, currencyCode: code)
        var descriptor = FetchDescriptor<WalletBalanceCardSnapshotRecord>(
            predicate: #Predicate { $0.id == key }
        )
        descriptor.fetchLimit = 1

        let record: WalletBalanceCardSnapshotRecord
        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(
                totalFiat: total,
                lastUpdatedAt: lastUpdated,
                selectedRangeRaw: selectedRangeRaw,
                isBalanceHidden: isBalanceHidden,
                ranges: ranges,
                updatedAt: now
            )
            record = existing
        } else {
            let inserted = WalletBalanceCardSnapshotRecord(
                walletId: walletId,
                currencyCode: code,
                totalFiat: total,
                lastUpdatedAt: lastUpdated,
                selectedRangeRaw: selectedRangeRaw,
                isBalanceHidden: isBalanceHidden,
                ranges: ranges,
                updatedAt: now
            )
            modelContext.insert(inserted)
            record = inserted
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
        return record.displaySnapshot()
    }

    func setHidden(
        walletId: UUID,
        currencyCode: String,
        isHidden: Bool
    ) throws {
        UserDefaults.standard.set(isHidden, forKey: Self.hiddenPreferenceKey(walletId: walletId))
        let code = currencyCode.uppercased()
        let key = WalletBalanceCardSnapshotRecord.key(walletId: walletId, currencyCode: code)
        var descriptor = FetchDescriptor<WalletBalanceCardSnapshotRecord>(
            predicate: #Predicate { $0.id == key }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.isBalanceHidden = isHidden
            record.updatedAt = Date()
            try modelContext.save()
        } else {
            try rebuildFromStoredPreferences(walletId: walletId, currencyCode: code)
        }
    }

    func setSelectedRange(
        walletId: UUID,
        currencyCode: String,
        selectedRangeRaw: String
    ) throws {
        UserDefaults.standard.set(selectedRangeRaw, forKey: "walletHomeBalanceHistoryRange")
        let code = currencyCode.uppercased()
        let key = WalletBalanceCardSnapshotRecord.key(walletId: walletId, currencyCode: code)
        var descriptor = FetchDescriptor<WalletBalanceCardSnapshotRecord>(
            predicate: #Predicate { $0.id == key }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.selectedRangeRaw = selectedRangeRaw
            record.updatedAt = Date()
            try modelContext.save()
        } else {
            try rebuildFromStoredPreferences(walletId: walletId, currencyCode: code)
        }
    }

    private func makeRangeSnapshot(
        range: BalanceHistoryRange,
        totalFiat: Decimal,
        transactions: [BalanceHistoryReconstructor.HistoryTx],
        ownAddresses: Set<String>,
        prices: [String: Decimal],
        history: [String: [Int: Decimal]],
        hourlyHoldings: [BalanceHourlyHolding],
        hourlySnapshots: [BalanceHourlyPriceSnapshot],
        now: Date
    ) -> WalletBalanceCardRangeSnapshot {
        let points: [BalancePoint]
        if range == .hour, !hasInHourTransaction(transactions, ownAddresses: ownAddresses, now: now) {
            points = BalanceHourPortfolioReconstructor.reconstruct(
                holdings: hourlyHoldings,
                priceSnapshots: hourlySnapshots,
                currentTotalFiat: totalFiat,
                now: now
            )
        } else {
            points = BalanceHistoryReconstructor.reconstruct(
                txSnapshots: transactions,
                priceCache: prices,
                priceHistory: history,
                ownAddresses: ownAddresses,
                range: range,
                now: now
            )
        }

        let resolved = Self.downsample(
            points.count >= 2 ? points : Self.zeroBaseline(for: range, now: now),
            maxCount: Self.maxRenderedChartSamples
        )
        let projected = resolved.map { NSDecimalNumber(decimal: $0.fiat).doubleValue }
        let baseline = resolved.first?.fiat ?? 0
        let last = resolved.last?.fiat ?? 0
        let change = last - baseline
        let percent: Double
        if baseline > 0 {
            let base = NSDecimalNumber(decimal: baseline).doubleValue
            let delta = NSDecimalNumber(decimal: change).doubleValue
            percent = base == 0 ? 0 : delta / abs(base) * 100
        } else {
            percent = 0
        }

        return WalletBalanceCardRangeSnapshot(
            rangeRaw: range.rawValue,
            points: resolved.map { WalletBalanceCardPointSnapshot(timestamp: $0.timestamp, fiat: $0.fiat) },
            xFractions: Self.timeFractions(for: resolved),
            minValue: projected.min() ?? 0,
            maxValue: projected.max() ?? 0,
            baselineFiat: baseline,
            changeFiat: change,
            changePercent: percent,
            signRaw: Self.signRaw(change: change)
        )
    }

    private func walletAddresses(walletId: UUID) throws -> [WalletAddressRecord] {
        let owner = Optional(walletId)
        let descriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.walletId == owner }
        )
        return try modelContext.fetch(descriptor)
    }

    private func transactionSnapshots(addressIds: Set<UUID>) throws -> [BalanceHistoryReconstructor.HistoryTx] {
        guard !addressIds.isEmpty else { return [] }
        var byId: [UUID: TransactionRecord] = [:]
        for addressId in addressIds {
            let optionalAddressId = Optional(addressId)
            let descriptor = FetchDescriptor<TransactionRecord>(
                predicate: #Predicate { $0.addressId == optionalAddressId }
            )
            for row in try modelContext.fetch(descriptor) {
                byId[row.id] = row
            }
        }
        let legacyDescriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == nil }
        )
        for row in try modelContext.fetch(legacyDescriptor) {
            guard let resolvedAddressId = row.address?.id,
                  addressIds.contains(resolvedAddressId) else {
                continue
            }
            row.addressId = resolvedAddressId
            byId[row.id] = row
        }

        return byId.values.map {
            BalanceHistoryReconstructor.HistoryTx(
                occurredAt: $0.occurredAt,
                statusRaw: $0.statusRaw,
                tokenSymbol: $0.tokenSymbol,
                tokenContract: $0.tokenContract,
                amountRaw: $0.amountRaw,
                directionRaw: $0.directionRaw,
                counterparty: $0.counterparty
            )
        }
    }

    private func cachedPrices(currencyCode: String) throws -> [String: Decimal] {
        let code = currencyCode.uppercased()
        let descriptor = FetchDescriptor<CachedPriceRecord>(
            predicate: #Predicate { $0.fiat == code }
        )
        var map: [String: Decimal] = [:]
        for row in try modelContext.fetch(descriptor) {
            map[row.symbol.uppercased()] = row.price
        }
        return map
    }

    private func historicalPrices(currencyCode: String) throws -> [String: [Int: Decimal]] {
        let code = currencyCode.uppercased()
        let descriptor = FetchDescriptor<HistoricalPriceRecord>(
            predicate: #Predicate { $0.fiat == code }
        )
        var map: [String: [Int: Decimal]] = [:]
        for row in try modelContext.fetch(descriptor) {
            map[row.symbol.uppercased(), default: [:]][row.dayKey] = row.price
        }
        return map
    }

    private func totalFiat(currencyCode: String, addressIds: Set<UUID>) throws -> Decimal {
        let code = currencyCode.uppercased()
        return try tokenBalances(addressIds: addressIds)
            .filter { $0.fiatCurrencyCode.caseInsensitiveCompare(code) == .orderedSame }
            .reduce(Decimal.zero) { $0 + $1.fiatValueCached }
    }

    private func holdings(
        addressIds: Set<UUID>,
        prices: [String: Decimal]
    ) throws -> [BalanceHourlyHolding] {
        guard !addressIds.isEmpty else { return [] }
        var bySymbol: [String: Decimal] = [:]
        for row in try tokenBalances(addressIds: addressIds) {
            let amount = WalletFormatting.decimalAmount(
                rawBalance: row.rawBalance,
                decimals: row.decimals
            )
            guard amount > 0 else { continue }
            bySymbol[row.tokenSymbol.uppercased(), default: 0] += amount
        }
        return bySymbol
            .map { symbol, amount in
                BalanceHourlyHolding(
                    symbol: symbol,
                    amount: amount,
                    currentPrice: prices[symbol]
                )
            }
            .sorted { $0.symbol < $1.symbol }
    }

    private func tokenBalances(addressIds: Set<UUID>) throws -> [TokenBalanceRecord] {
        guard !addressIds.isEmpty else { return [] }
        var byId: [UUID: TokenBalanceRecord] = [:]
        for addressId in addressIds {
            let optionalAddressId = Optional(addressId)
            let descriptor = FetchDescriptor<TokenBalanceRecord>(
                predicate: #Predicate { $0.addressId == optionalAddressId }
            )
            for row in try modelContext.fetch(descriptor) {
                byId[row.id] = row
            }
        }
        let legacyDescriptor = FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == nil }
        )
        for row in try modelContext.fetch(legacyDescriptor) {
            guard let resolvedAddressId = row.address?.id,
                  addressIds.contains(resolvedAddressId) else {
                continue
            }
            row.addressId = resolvedAddressId
            byId[row.id] = row
        }
        return Array(byId.values)
    }

    private func hourlyPriceSnapshots(
        currencyCode: String,
        since: Date,
        until: Date = Date()
    ) throws -> [BalanceHourlyPriceSnapshot] {
        let code = currencyCode.uppercased()
        let descriptor = FetchDescriptor<PriceSnapshotRecord>(
            predicate: #Predicate { row in
                row.currencyCode == code
                    && row.fetchedAt >= since
                    && row.fetchedAt <= until
                    && row.price > 0
            },
            sortBy: [SortDescriptor(\.fetchedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map {
            BalanceHourlyPriceSnapshot(
                symbol: $0.symbol,
                price: $0.price,
                fetchedAt: $0.fetchedAt
            )
        }
    }

    private func lastRefreshDate(walletId: UUID) throws -> Date? {
        let scope = walletId.uuidString
        let descriptor = FetchDescriptor<SyncStatusRecord>(
            predicate: #Predicate { $0.scopeId == scope }
        )
        let domains: Set<String> = [
            SyncDomain.balances.rawValue,
            SyncDomain.transactions.rawValue
        ]
        return try modelContext.fetch(descriptor)
            .filter { domains.contains($0.domainRaw) }
            .compactMap(\.lastSyncedAt)
            .max()
    }

    private func hasInHourTransaction(
        _ transactions: [BalanceHistoryReconstructor.HistoryTx],
        ownAddresses: Set<String>,
        now: Date
    ) -> Bool {
        let cutoff = BalanceHistoryRange.hour.cutoff(from: now)
        return transactions.contains {
            $0.statusRaw != TransactionStatus.failed.rawValue
                && $0.occurredAt >= cutoff
                && $0.occurredAt <= now
                && ($0.counterparty.isEmpty || !ownAddresses.contains($0.counterparty.lowercased()))
        }
    }

    private static func hiddenPreferenceKey(walletId: UUID) -> String {
        "balanceCardHidden.\(walletId.uuidString)"
    }

    private static func signRaw(change: Decimal) -> String {
        if change > 0 { return "up" }
        if change < 0 { return "down" }
        return "flat"
    }

    private static func downsample(_ points: [BalancePoint], maxCount: Int) -> [BalancePoint] {
        guard maxCount > 1, points.count > maxCount else { return points }
        var result: [BalancePoint] = []
        result.reserveCapacity(maxCount)
        var lastIndex: Int?
        for outputIndex in 0..<maxCount {
            let rawIndex = Double(outputIndex) * Double(points.count - 1) / Double(maxCount - 1)
            let sourceIndex = max(0, min(points.count - 1, Int(rawIndex.rounded())))
            guard sourceIndex != lastIndex else { continue }
            result.append(points[sourceIndex])
            lastIndex = sourceIndex
        }
        if result.first?.timestamp != points.first?.timestamp {
            result.insert(points[0], at: 0)
        }
        if result.last?.timestamp != points.last?.timestamp {
            result.append(points[points.count - 1])
        }
        return result
    }

    private static func timeFractions(for points: [BalancePoint]) -> [Double] {
        guard let first = points.first?.timestamp,
              let last = points.last?.timestamp,
              last > first else { return [] }
        let span = last.timeIntervalSince(first)
        return points.map { max(0, min(1, $0.timestamp.timeIntervalSince(first) / span)) }
    }

    private static func zeroBaseline(for range: BalanceHistoryRange, now: Date) -> [BalancePoint] {
        let span: TimeInterval
        switch range {
        case .hour:  span = 3_600
        case .day:   span = 86_400
        case .week:  span = 86_400 * 7
        case .month: span = 86_400 * 30
        case .year:  span = 86_400 * 365
        case .all:   span = 86_400 * 365
        }
        return [
            BalancePoint(timestamp: now.addingTimeInterval(-span), fiat: 0),
            BalancePoint(timestamp: now, fiat: 0)
        ]
    }
}
