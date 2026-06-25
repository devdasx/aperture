import Foundation
import SwiftData

/// The one pricing front door. Every consumer that needs "unit price of
/// SYMBOL in the user's currency" — the Send review/amount fiat estimate,
/// the wallet/activity rows, the currency-change re-price pass — calls
/// `unitPrices(symbols:currencyCode:)` or `crossRate(from:to:)`.
///
/// **2026-06-25 — price fetching removed (data-fetching-layer removal).**
/// All in-app and remote price retrieval is gone: the Render/neon price
/// server client (`RemotePriceService`), the FX cross, and the local
/// cache/historical fallback rungs. This facade is *retained* — Send and the
/// wallet/activity UI call it directly — but it now resolves **no prices**, so
/// every fiat value renders empty ("Price unavailable") and no network runs.
/// The signatures (`unitPrices`, `crossRate`), `static let shared`,
/// `ResolvedPrice`, and `init(container:)` are kept verbatim so all call sites
/// compile unchanged.
actor TokenPricingEngine {

    /// App-wide shared instance, retained for the existing call sites. Holds
    /// no pricing state anymore.
    static let shared = TokenPricingEngine()

    /// One resolved unit price, denominated in the requested currency. Kept
    /// because consumers reference `TokenPricingEngine.ResolvedPrice` / `.amount`.
    struct ResolvedPrice: Sendable {
        /// Price of 1 unit of the token in the requested currency.
        let amount: Decimal
        /// Data source label (e.g. `"neon"` / `"cache"`). Retained for the type.
        let source: String
        /// `true` when not a live quote. Retained for the type.
        let isStale: Bool
    }

    /// Retained so existing callers (including tests) that pass a container
    /// still compile. Unused now that no pricing data is read or written.
    private let injectedContainer: ModelContainer?

    init(container: ModelContainer? = nil) {
        self.injectedContainer = container
    }

    // MARK: - Public API (no-data facade — price fetching removed)

    /// Price fetching is removed: always resolves nothing, so every caller's
    /// fiat side renders empty without any network call.
    func unitPrices(symbols: [String], currencyCode: String) async -> [String: ResolvedPrice] {
        [:]
    }

    /// FX fetching is removed: identity for the same currency, otherwise `nil`
    /// (callers omit rather than fabricate a converted value).
    func crossRate(from sourceCode: String, to targetCode: String) async -> Decimal? {
        sourceCode.uppercased() == targetCode.uppercased() ? 1 : nil
    }
}
