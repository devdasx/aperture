import Foundation
import SwiftData

// MARK: - WalletChartPoint

/// One point of a wallet's persisted portfolio-value timeline,
/// flattened to a Sendable value for cross-actor reads.
struct WalletChartPoint: Sendable {
    let capturedAt: Date
    let fiatValue: Decimal
}

// MARK: - WalletChartSnapshotRepository

/// Actor-isolated owner of the `WalletChartSnapshotRecord` table —
/// each wallet's durable, independently-persisted portfolio-value
/// timeline (one series per `(wallet, currency)` pair).
///
/// **Capture throttle.** `capture(...)` skips when a snapshot newer
/// than 10 minutes already exists for the pair — refreshes fire far
/// more often than the timeline needs points.
///
/// **Growth bound.** `prune(...)` runs after each capture: everything
/// ≤ 48 h old kept (≤ 288 rows/pair at the throttle), older rows
/// decimated to one per day (last of the day), and a hard cap of
/// 2,000 rows per pair deletes oldest-first beyond it.
///
/// Per `CLAUDE.md` Rule #2 §C (actor-isolated repositories).
@ModelActor
actor WalletChartSnapshotRepository {

    /// Minimum spacing between two captures for one (wallet, currency).
    static let captureThrottle: TimeInterval = 10 * 60

    /// Raw-retention window: snapshots younger than this are never
    /// decimated.
    static let rawRetentionWindow: TimeInterval = 48 * 3600

    /// Hard row cap per `(wallet, currency)` series.
    static let defaultHardCap = 2_000

    /// Test seam — `_setHardCapForTesting(_:)` shrinks the cap so the
    /// oldest-first eviction is testable without inserting 2,000 rows.
    private var hardCapOverrideForTesting: Int?

    func _setHardCapForTesting(_ cap: Int) {
        hardCapOverrideForTesting = cap
    }

    private var hardCap: Int { hardCapOverrideForTesting ?? Self.defaultHardCap }

    // MARK: - Capture

    /// Record one portfolio-value observation, unless one newer than
    /// `captureThrottle` already exists for `(walletId, currencyCode)`.
    /// Returns `true` when a snapshot was written, `false` when the
    /// throttle skipped it. Prunes after a successful write.
    @discardableResult
    func capture(
        walletId: UUID,
        currencyCode: String,
        fiatValue: Decimal,
        now: Date = Date()
    ) throws -> Bool {
        let code = currencyCode.uppercased()
        var newestDescriptor = FetchDescriptor<WalletChartSnapshotRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.currencyCode == code },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        newestDescriptor.fetchLimit = 1
        if let newest = try modelContext.fetch(newestDescriptor).first,
           now.timeIntervalSince(newest.capturedAt) < Self.captureThrottle {
            return false
        }
        try record(walletId: walletId, currencyCode: code, fiatValue: fiatValue, capturedAt: now)
        try prune(walletId: walletId, currencyCode: code, now: now)
        return true
    }

    /// Unthrottled insert primitive `capture` builds on. Exposed for
    /// backfills and tests that need explicit timestamps; production
    /// paths go through `capture` so the throttle holds.
    func record(
        walletId: UUID,
        currencyCode: String,
        fiatValue: Decimal,
        capturedAt: Date
    ) throws {
        modelContext.insert(WalletChartSnapshotRecord(
            walletId: walletId,
            currencyCode: currencyCode,
            fiatValue: fiatValue,
            capturedAt: capturedAt
        ))
        try modelContext.save()
    }

    /// Convenience used by `WalletRefreshCoordinator`: value the
    /// wallet from its **persisted** `TokenBalanceRecord` rows (sum of
    /// `fiatValueCached` over rows denominated in `currencyCode`) and
    /// `capture(...)` the total. Honesty guard: when the wallet has
    /// balance rows but NONE in the requested currency (mid
    /// currency-switch, before the re-price pass lands), the capture
    /// is skipped — recording a fabricated 0 would carve a false
    /// cliff into the timeline. A wallet with no balance rows at all
    /// captures an honest 0.
    @discardableResult
    func captureFromPersistedBalances(
        walletId: UUID,
        currencyCode: String,
        now: Date = Date()
    ) throws -> Bool {
        let code = currencyCode.uppercased()
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        guard let wallet = try modelContext.fetch(walletDescriptor).first else { return false }

        var total = Decimal(0)
        var totalRows = 0
        var matchingRows = 0
        for address in wallet.addresses {
            for balance in address.balances {
                totalRows += 1
                guard balance.fiatCurrencyCode.uppercased() == code else { continue }
                matchingRows += 1
                total += balance.fiatValueCached
            }
        }
        if totalRows > 0 && matchingRows == 0 {
            return false
        }
        return try capture(walletId: walletId, currencyCode: code, fiatValue: total, now: now)
    }

    // MARK: - Series

    /// The persisted timeline for `(walletId, currencyCode)`, oldest
    /// first, optionally bounded to points at or after `from`.
    func series(
        walletId: UUID,
        currencyCode: String,
        from: Date? = nil
    ) throws -> [WalletChartPoint] {
        let code = currencyCode.uppercased()
        let lowerBound = from ?? Date.distantPast
        let descriptor = FetchDescriptor<WalletChartSnapshotRecord>(
            predicate: #Predicate { row in
                row.walletId == walletId
                    && row.currencyCode == code
                    && row.capturedAt >= lowerBound
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map {
            WalletChartPoint(capturedAt: $0.capturedAt, fiatValue: $0.fiatValue)
        }
    }

    // MARK: - Delete

    /// Drop every snapshot for one wallet (all currencies). Called by
    /// the wallet-removal flow so a deleted wallet leaves no timeline
    /// behind.
    func deleteAll(walletId: UUID) throws {
        let descriptor = FetchDescriptor<WalletChartSnapshotRecord>(
            predicate: #Predicate { $0.walletId == walletId }
        )
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    /// Wipe the whole table — wallet-reset / fresh-install coverage.
    func deleteAll() throws {
        let descriptor = FetchDescriptor<WalletChartSnapshotRecord>()
        for row in try modelContext.fetch(descriptor) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    // MARK: - Prune

    /// Enforce the growth bound for one `(walletId, currencyCode)`
    /// series:
    ///
    /// 1. Snapshots ≤ 48 h old are untouched.
    /// 2. Older snapshots are decimated to one per day — the LAST
    ///    observation of each day.
    /// 3. If the series still exceeds the hard cap (2,000 rows), the
    ///    oldest rows are deleted until it fits.
    ///
    /// Idempotent; runs after every successful `capture`.
    func prune(
        walletId: UUID,
        currencyCode: String,
        now: Date = Date()
    ) throws {
        let code = currencyCode.uppercased()
        let cutoff = now.addingTimeInterval(-Self.rawRetentionWindow)

        // Stage 1+2 — daily decimation beyond the raw window.
        let oldDescriptor = FetchDescriptor<WalletChartSnapshotRecord>(
            predicate: #Predicate { row in
                row.walletId == walletId
                    && row.currencyCode == code
                    && row.capturedAt < cutoff
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        let oldRows = try modelContext.fetch(oldDescriptor)
        var keeperByDay: [Int: WalletChartSnapshotRecord] = [:]
        for row in oldRows {
            if let keeper = keeperByDay[row.dayKey] {
                if row.capturedAt >= keeper.capturedAt {
                    modelContext.delete(keeper)
                    keeperByDay[row.dayKey] = row
                } else {
                    modelContext.delete(row)
                }
            } else {
                keeperByDay[row.dayKey] = row
            }
        }
        if modelContext.hasChanges {
            try modelContext.save()
        }

        // Stage 3 — hard cap, oldest-first eviction.
        let allDescriptor = FetchDescriptor<WalletChartSnapshotRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.currencyCode == code },
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        let allRows = try modelContext.fetch(allDescriptor)
        let overflow = allRows.count - hardCap
        guard overflow > 0 else { return }
        for row in allRows.prefix(overflow) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
