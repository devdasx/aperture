import Foundation
import OSLog
import SwiftData

/// The one pricing front door. Every consumer that needs "unit price
/// of SYMBOL in the user's currency" — the balance scanner's shared
/// batch, the currency-change re-price pass — calls
/// `unitPrices(symbols:currencyCode:)` and gets prices **already
/// denominated in the active currency**, so `fiatValueCached` is
/// always written in the currency the user currently has selected.
///
/// **The ladder** (per symbol, per currency — each rung only runs for
/// the symbols the previous rung failed to resolve):
///
/// 1. **Coinbase** — USD spot batch × FX rate (identity when the
///    target IS USD, i.e. a direct quote). Coinbase reliably covers
///    ticker→USD; `FXRateService` (open.er-api.com) covers USD→every
///    long-tail fiat (JOD, EGP, NGN, …).
/// 2. **Per-currency persisted cache** — `CachedPriceRecord` keyed
///    `"SYMBOL-FIAT"`. A stale price the user has seen before beats
///    no price (`isStale` marks it internally; honesty per Rule #16
///    is carried by the row's "Last synced" footer).
/// 3. **CoinGecko** — independent public API, one batched
///    `simple/price` call (direct vs_currency when CoinGecko supports
///    the fiat, else its USD value × FX).
/// 4. **Balance-derived per-unit** — caller-side
///    (`WalletRefreshCoordinator.repriceWallet`): re-denominate the
///    row's own cached fiat via `crossRate(from:to:)` when every
///    fetch rung failed.
/// 5. **Omit** — the symbol is absent from the result; the row
///    renders its native amount with no fiat ("Price unavailable",
///    never a fabricated number).
///
/// Fresh results from rungs 1 and 3 are persisted back into the
/// per-currency cache so rung 2 works the next time this currency is
/// active — that is what makes a previously-used currency survive a
/// full Coinbase outage.
///
/// **Parallelism.** Rung 1's two halves (Coinbase batch — itself
/// 3-chunk/8-wide bounded — and the FX rate) run concurrently via
/// `async let` ("promise.all"); rung 3 is one batched call.
/// Cancellation propagates: every rung boundary checks
/// `Task.isCancelled`, and `URLSession` aborts in-flight requests of
/// a cancelled task.
actor TokenPricingEngine {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "pricing")

    /// App-wide shared instance so the Coinbase TTL cache, the FX
    /// rates cache, and the CoinGecko TTL cache accumulate across
    /// every scan and re-price instead of resetting per refresh.
    static let shared = TokenPricingEngine()

    /// One resolved unit price, denominated in the requested currency.
    struct ResolvedPrice: Sendable {
        /// Price of 1 unit of the token in the requested currency.
        let amount: Decimal
        /// `"coinbase"` / `"cache"` / `"coingecko"` — surfaces in the
        /// persisted record's `source` column (Rule #16 §A: name your
        /// data source).
        let source: String
        /// `true` when served from the persisted per-currency cache
        /// (rung 2) — i.e. not a live quote.
        let isStale: Bool
    }

    private let coinbase: CoinbasePriceService
    private let coinGecko: CoinGeckoPriceService
    private let fxService: FXRateService

    /// Injected for tests; `nil` resolves lazily to
    /// `ApertureDatabase.shared.container` on first cache access.
    private let injectedContainer: ModelContainer?
    private var cachedRepository: PriceCacheRepository?
    private var cachedSnapshotRepository: PriceSnapshotRepository?

    init(
        container: ModelContainer? = nil,
        coinbase: CoinbasePriceService = CoinbasePriceService(),
        coinGecko: CoinGeckoPriceService = CoinGeckoPriceService(),
        fxService: FXRateService = FXRateService()
    ) {
        self.injectedContainer = container
        self.coinbase = coinbase
        self.coinGecko = coinGecko
        self.fxService = fxService
    }

    // MARK: - Public API

    /// Resolve unit prices for `symbols` in `currencyCode`, walking
    /// the ladder documented on the type. Symbols missing from the
    /// returned map could not be priced by any fetch/cache rung —
    /// the caller applies rung 4 (balance-derived) or rung 5 (omit).
    func unitPrices(symbols: [String], currencyCode: String) async -> [String: ResolvedPrice] {
        let code = currencyCode.uppercased()
        let unique = Array(Set(symbols.map { $0.uppercased() }))
        guard !unique.isEmpty else { return [:] }

        var resolved: [String: ResolvedPrice] = [:]

        // Rung 1 — Coinbase USD batch + FX rate, concurrently. The
        // batch is bounded inside `CoinbasePriceService` (8-wide
        // chunks, 3 chunks in flight); `rate(fromUSDTo: "USD")`
        // short-circuits to 1 without a network call.
        async let usdPricesAsync = coinbase.prices(symbols: unique, fiat: "USD")
        async let fxAsync = fxService.rate(fromUSDTo: code)
        let usdPrices = await usdPricesAsync
        let fxRate = await fxAsync

        if let fxRate, fxRate > 0 {
            for (symbol, price) in usdPrices where price.amount > 0 {
                resolved[symbol.uppercased()] = ResolvedPrice(
                    amount: price.amount * fxRate,
                    source: "coinbase",
                    isStale: false
                )
            }
        }

        var missing = Set(unique).subtracting(resolved.keys)

        // Rung 2 — persisted per-currency cache. Only consulted for
        // the symbols rung 1 missed (Coinbase gap, rate limit, or a
        // failed FX fetch). A stale price the user has already seen
        // in this currency beats no price.
        if !missing.isEmpty, !Task.isCancelled {
            let repo = await repository()
            if let cached = try? await repo.prices(symbols: Array(missing), fiat: code) {
                for (symbol, entry) in cached where entry.price > 0 {
                    let upper = symbol.uppercased()
                    guard missing.contains(upper) else { continue }
                    resolved[upper] = ResolvedPrice(
                        amount: entry.price,
                        source: "cache",
                        isStale: true
                    )
                    missing.remove(upper)
                }
            }
        }

        // Rung 3 — CoinGecko, one batched call for everything still
        // missing (first use of a currency + Coinbase down). Direct
        // vs_currency value preferred; USD value × FX otherwise.
        if !missing.isEmpty, !Task.isCancelled {
            let quotes = await coinGecko.quotes(symbols: Array(missing), fiat: code)
            for (symbol, quote) in quotes {
                let upper = symbol.uppercased()
                guard missing.contains(upper) else { continue }
                let amount: Decimal?
                if code == "USD" {
                    amount = quote.usd
                } else if let direct = quote.direct {
                    amount = direct
                } else if let usd = quote.usd, let fxRate, fxRate > 0 {
                    amount = usd * fxRate
                } else {
                    amount = nil
                }
                if let amount, amount > 0 {
                    resolved[upper] = ResolvedPrice(
                        amount: amount,
                        source: "coingecko",
                        isStale: false
                    )
                    missing.remove(upper)
                }
            }
        }

        // Persist every LIVE quote under (symbol, currency) so rung 2
        // answers for this currency on the next failure — this is the
        // "preset price for this token for the current currency"
        // contract. Cache-served entries are already on disk.
        let fresh = resolved.filter { !$0.value.isStale }
        if !fresh.isEmpty {
            let repo = await repository()
            let entries = fresh.map { (symbol: $0.key, fiat: code, price: $0.value.amount, source: $0.value.source) }
            do {
                try await repo.upsertMany(entries)
            } catch {
                Self.log.error("price-cache bulk upsert failed for \(code, privacy: .public): \(String(describing: error), privacy: .public)")
            }

            // 2026-06-13 — append the same LIVE quotes to the
            // immutable `PriceSnapshotRecord` history (the cache row
            // above is overwritten in place; the snapshot table is
            // what makes "price change in the last 24h" and
            // balance-change attribution answerable from local data).
            // Cache-served (stale) entries are deliberately excluded —
            // re-recording an old observation as a new one would
            // forge the timeline. Failures log and never block the
            // pricing ladder.
            let snapshotRepo = await snapshotRepository()
            let snapshotEntries = entries.map {
                (symbol: $0.symbol, currencyCode: $0.fiat, price: $0.price, source: $0.source)
            }
            do {
                try await snapshotRepo.record(snapshotEntries)
            } catch {
                Self.log.error("price-snapshot record failed for \(code, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if !missing.isEmpty {
            Self.log.info("unpriced after full ladder (\(code, privacy: .public)): \(missing.sorted().joined(separator: ","), privacy: .public)")
        }
        return resolved
    }

    /// Fiat→fiat cross rate via the USD pivot
    /// (`rate(USD→to) / rate(USD→from)`). Used by the
    /// balance-derived rung (4): re-denominating a row's cached fiat
    /// from the currency it was scanned under into the active one.
    /// Returns `nil` when either leg is unavailable — the caller
    /// omits rather than fabricates.
    func crossRate(from sourceCode: String, to targetCode: String) async -> Decimal? {
        let source = sourceCode.uppercased()
        let target = targetCode.uppercased()
        guard source != target else { return 1 }
        guard
            let toTarget = await fxService.rate(fromUSDTo: target),
            let toSource = await fxService.rate(fromUSDTo: source),
            toSource > 0, toTarget > 0
        else {
            return nil
        }
        return toTarget / toSource
    }

    // MARK: - Lazy repository

    /// `PriceCacheRepository` bound to the injected container, or to
    /// the app-wide store on first use. `ApertureDatabase.shared` is
    /// `@MainActor`; its `container` is an immutable `let` created at
    /// app launch, read here via one main-actor hop.
    private func repository() async -> PriceCacheRepository {
        if let cachedRepository { return cachedRepository }
        let repo = PriceCacheRepository(modelContainer: await resolvedContainer())
        cachedRepository = repo
        return repo
    }

    /// `PriceSnapshotRepository` bound to the same container as the
    /// cache repository — the append-only observation log the 24h
    /// change surface reads (see the snapshot hook in `unitPrices`).
    private func snapshotRepository() async -> PriceSnapshotRepository {
        if let cachedSnapshotRepository { return cachedSnapshotRepository }
        let repo = PriceSnapshotRepository(modelContainer: await resolvedContainer())
        cachedSnapshotRepository = repo
        return repo
    }

    /// Shared container resolution for both lazy repositories.
    private func resolvedContainer() async -> ModelContainer {
        if let injectedContainer { return injectedContainer }
        return await MainActor.run { ApertureDatabase.shared.container }
    }
}
