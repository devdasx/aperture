import Foundation
import SwiftData

// MARK: - PriceSnapshotRecord

/// One **append-only** row per live price fetch for one
/// `(symbol, currency)` pair. Unlike `CachedPriceRecord` (one row per
/// pair, overwritten in place by every refresh) and
/// `HistoricalPriceRecord` (one immutable row per *day*, sourced from
/// Coinbase candles), this table is the wallet's own observation log:
/// every price the app actually fetched, stamped with when it fetched
/// it and from where. It is what makes "price change in the latest
/// 24 hours" and "how much did my balance change because of *price*
/// movement" answerable from local data alone.
///
/// **Writers.** `TokenPricingEngine.unitPrices(symbols:currencyCode:)`
/// appends a snapshot for every LIVE quote it resolves (Coinbase and
/// CoinGecko rungs — never the cache rung, which would re-record an
/// old observation as a new one). See the engine's snapshot hook.
///
/// **Growth bound.** `PriceSnapshotRepository.prune()` runs after every
/// batch insert: every snapshot ≤ 48 h old is kept verbatim; beyond
/// 48 h the table is decimated to one row per `(symbol, currency, day)`
/// — the last observation of that day, mirroring
/// `HistoricalPriceRecord`'s daily-close convention. Worst case at the
/// wallet-home refresh cadence (~1 refresh/min sustained, which real
/// usage never approaches) that is ≤ 2,880 raw rows per pair in the
/// 48 h window plus one row per pair per day of history.
///
/// **No secrets.** Public market data only — same posture as the other
/// price tables.
@Model
final class PriceSnapshotRecord {
    /// Stable identifier. The table is append-only, so the unique key
    /// is a plain UUID — there is deliberately NO composite
    /// `(symbol, currency, time)` key; two fetches in the same second
    /// are two honest observations.
    @Attribute(.unique) var id: UUID

    /// Uppercased token ticker (`BTC`, `ETH`, `USDC`).
    var symbol: String

    /// Uppercased fiat code the price is denominated in (`USD`, `EUR`).
    var currencyCode: String

    /// Spot price in `currencyCode` per 1 token at `fetchedAt`.
    /// `Decimal` per the `CachedPriceRecord` precedent — SwiftData
    /// round-trips it losslessly and money math stays exact.
    var price: Decimal

    /// Wall-clock of the fetch that produced this observation.
    var fetchedAt: Date

    /// Source label (`"coinbase"`, `"coingecko"`, `"fx"`). Rule #16 —
    /// name your data source; the change-24h surface can attribute the
    /// numbers it shows.
    var source: String

    /// `yyyy * 10000 + mm * 100 + dd` of `fetchedAt` (same encoding as
    /// `HistoricalPriceRecord.dayKey`, via `DayKey.from(date:)`).
    /// Stored so the pruning pass groups by day with an integer
    /// comparison instead of re-deriving calendar components per row.
    var dayKey: Int

    init(
        id: UUID = UUID(),
        symbol: String,
        currencyCode: String,
        price: Decimal,
        fetchedAt: Date = Date(),
        source: String
    ) {
        self.id = id
        self.symbol = symbol.uppercased()
        self.currencyCode = currencyCode.uppercased()
        self.price = price
        self.fetchedAt = fetchedAt
        self.source = source
        self.dayKey = DayKey.from(date: fetchedAt)
    }
}
