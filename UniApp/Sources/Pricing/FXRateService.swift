import Foundation
import OSLog

/// Fiat-to-fiat exchange-rate service. Backed by
/// `open.er-api.com/v6/latest/USD` — free, no auth, no third-party
/// SDK (Rule #3), updated daily, covers ~160 currencies including
/// the long-tail ones Coinbase Spot doesn't price directly
/// (JOD, EGP, NGN, KZT, etc.).
///
/// **Why this service exists.** Coinbase Spot returns `null` for
/// most crypto/fiat pairs outside USD / EUR / GBP / a handful of
/// majors. A user whose locale-detected currency is Jordanian Dinar
/// (JOD) — like the screenshot Thuglife ships from — sees
/// "Price unavailable" on every row because there is no
/// `SOL-JOD` spot. The honest fix is to price the crypto in **USD**
/// (Coinbase covers nearly every ticker we ship) and convert
/// USD → user-currency via this service.
///
/// **Caching.** Rates change once a day; the service caches each
/// USD→target conversion for 24 hours. Failures fall through to
/// `nil` — the UI then shows the same "Price unavailable" surface
/// it does for any other gap, honest about what we couldn't read.
///
/// **Honesty (Rule #16).** No fabricated rate. If neither Coinbase
/// nor the FX service can give us a real conversion, the row shows
/// the native balance ("0.0067 APT") and no fiat — the user is told
/// the cryptocurrency amount, never lied to about its dollar value.
actor FXRateService {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "fx")

    /// Endpoint base. The v6 path returns all rates against the
    /// `base` currency in one round-trip — we cache the full rates
    /// dictionary so 26 chains' worth of conversions cost one HTTP
    /// call per day.
    private static let endpoint = URL(string: "https://open.er-api.com/v6/latest/USD")!

    private struct CachedRates: Sendable {
        let base: String
        let rates: [String: Decimal]   // ISO-4217 → factor (1 USD = N target)
        let fetchedAt: Date
    }

    private var cache: CachedRates?

    /// Rates older than this trigger a refetch. ECB updates daily
    /// around 16:00 CET; a 12-hour TTL means the user sees a fresh
    /// rate within at most half a day. Faster wouldn't be honest —
    /// the upstream data doesn't change more often than that.
    private let cacheTTL: TimeInterval = 12 * 60 * 60

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns the multiplier such that
    /// `1 unit of "USD" == N units of "target"` —
    /// i.e. `targetAmount = usdAmount × rate(fromUSDTo: target)`.
    /// Returns `nil` if the target isn't in the rates dictionary or
    /// the upstream call failed.
    ///
    /// (Renamed 2026-06-10 from the misleading `rate(toUSD:)` — the
    /// contract was always USD → target, never target → USD.)
    ///
    /// Special case: `target == "USD"` returns `1` without making a
    /// network call — same-currency conversion is identity.
    func rate(fromUSDTo targetCurrency: String) async -> Decimal? {
        let target = targetCurrency.uppercased()
        guard target != "USD" else { return 1 }

        if let cached = cache,
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL,
           let value = cached.rates[target] {
            return value
        }

        await refreshCache()

        return cache?.rates[target]
    }

    private func refreshCache() async {
        do {
            let (data, response) = try await session.data(from: Self.endpoint)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                Self.log.error("FX endpoint returned non-2xx")
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ratesRaw = json["rates"] as? [String: Any] else {
                Self.log.error("FX endpoint returned malformed JSON")
                return
            }
            var rates: [String: Decimal] = [:]
            rates.reserveCapacity(ratesRaw.count)
            for (code, value) in ratesRaw {
                if let num = value as? NSNumber {
                    // Precision-preserving decode (2026-06-10). The
                    // previous `NSDecimalNumber(value: num.doubleValue)`
                    // round-tripped every rate through a binary Double,
                    // baking float error into the stored Decimal. Use
                    // the number's exact decimal value when
                    // JSONSerialization handed us an NSDecimalNumber;
                    // otherwise parse its string form (NSDecimalNumber's
                    // parser handles exponent notation, returning
                    // `.notANumber` — filtered below — on garbage).
                    let dec: Decimal
                    if let exact = num as? NSDecimalNumber {
                        dec = exact.decimalValue
                    } else {
                        dec = NSDecimalNumber(string: num.stringValue).decimalValue
                    }
                    if !dec.isNaN {
                        rates[code.uppercased()] = dec
                    }
                } else if let str = value as? String, let dec = Decimal(string: str) {
                    rates[code.uppercased()] = dec
                }
            }
            cache = CachedRates(
                base: "USD",
                rates: rates,
                fetchedAt: Date()
            )
            Self.log.info("FX cache refreshed — \(rates.count, privacy: .public) currencies")
        } catch {
            Self.log.error("FX refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}
