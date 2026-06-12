import Foundation
import SwiftData

// MARK: - WalletChartSnapshotRecord

/// One row per captured **portfolio-value observation** for one
/// `(wallet, currency)` pair. The wallet-home chart's *shape* remains
/// transaction-derived (`BalanceHistoryReconstructor` — the user's
/// prior direction); this table is the durable per-wallet record that
/// survives and grows: each refresh stamps "this wallet was worth X in
/// currency C at time T", building a real measured timeline that no
/// reconstruction can drift away from.
///
/// **Writers.** `WalletRefreshCoordinator.performRefresh` calls
/// `WalletChartSnapshotRepository.captureFromPersistedBalances(...)`
/// at the end of every refresh. The repository throttles to at most
/// one snapshot per `(wallet, currency)` per 10 minutes.
///
/// **Growth bound.** `WalletChartSnapshotRepository.prune(...)` runs
/// after each capture: snapshots ≤ 48 h old are kept verbatim (at the
/// 10-minute throttle that is ≤ 288 rows per pair); beyond 48 h the
/// series is decimated to one row per day (the last observation of
/// the day); and a hard cap of 2,000 rows per `(wallet, currency)`
/// deletes oldest-first beyond the cap — ≈ 288 recent + ~4.7 years of
/// daily history before the cap bites.
///
/// **No secrets.** Aggregate fiat value only — no addresses, no
/// balances per token, no keys.
@Model
final class WalletChartSnapshotRecord {
    /// Stable identifier — append-only table, plain UUID unique key.
    @Attribute(.unique) var id: UUID

    /// Owning wallet's `WalletRecord.id`. A primitive column (not a
    /// relationship) so capture/series/prune predicates never traverse
    /// an optional relationship (the `addressId` precedent), and so
    /// rows survive independent of the wallet row's lifecycle until
    /// `deleteAll(walletId:)` is called by the wallet-removal flow.
    var walletId: UUID

    /// Uppercased fiat code the value is denominated in (`USD`, …).
    /// A wallet that lived under two currencies has two independent
    /// series — values in different currencies are never mixed.
    var currencyCode: String

    /// Total portfolio fiat value at `capturedAt` — the sum of the
    /// wallet's persisted `TokenBalanceRecord.fiatValueCached` rows
    /// matching `currencyCode` at capture time.
    var fiatValue: Decimal

    /// Wall-clock of the capture.
    var capturedAt: Date

    /// `yyyy * 10000 + mm * 100 + dd` of `capturedAt` (the
    /// `HistoricalPriceRecord.dayKey` encoding via `DayKey.from`).
    /// Lets the pruning pass decimate by day with integer grouping.
    var dayKey: Int

    init(
        id: UUID = UUID(),
        walletId: UUID,
        currencyCode: String,
        fiatValue: Decimal,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.walletId = walletId
        self.currencyCode = currencyCode.uppercased()
        self.fiatValue = fiatValue
        self.capturedAt = capturedAt
        self.dayKey = DayKey.from(date: capturedAt)
    }
}
