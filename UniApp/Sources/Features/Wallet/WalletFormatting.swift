import Foundation
import SwiftData

/// Small, focused formatting helpers shared across the wallet-home
/// surface. Locale-aware. No view code — these are pure functions
/// returning `String` (or `LocalizedStringResource`) so they're safely
/// callable from background actors.
enum WalletFormatting {

    // MARK: - Cached formatters / styles (2026-06-14 perf)
    //
    // Allocating a `RelativeDateTimeFormatter` (a heavy Foundation class)
    // on every call was a confirmed Activity-list scroll-lag source — one
    // allocation per transaction row per render (~12x the cost of reuse).
    // `FormatStyle` values are lightweight structs but were also rebuilt
    // per call across 20+ amount labels. These cached instances move that
    // cost out of the render hot path.
    //
    // **Concurrency.** `RelativeDateTimeFormatter`'s formatting call, like
    // `DateFormatter`/`ISO8601DateFormatter`, is safe to invoke from
    // multiple threads (Foundation formatters are thread-safe for read
    // formatting since iOS 7); `nonisolated(unsafe)` matches the existing
    // `static let iso8601` pattern in the network adapters. `FormatStyle`
    // values are `Sendable`.

    /// Reused relative-date formatter. Configured once; never mutated
    /// after init, so concurrent `localizedString(for:relativeTo:)` calls
    /// are safe.
    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    /// Absolute fallback date style (>1 week ago). Value type, reused.
    private static let absoluteDateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()

    /// Base native-amount style; `.precision(...)` is applied per call
    /// (a cheap value-type copy) for the requested decimal count.
    private static let nativeBaseStyle = Decimal.FormatStyle().grouping(.automatic)

    // MARK: - Fiat

    /// Format a fiat amount with the supplied currency code, in the
    /// user's current locale. Uses `Decimal.FormatStyle.Currency` so
    /// grouping separators, decimal separators, symbol position, and
    /// negative-number conventions all follow the user's locale.
    ///
    /// Example: `123456.78` + `"USD"` →
    /// - en_US: `"$123,456.78"`
    /// - de_DE: `"123.456,78 $"`
    /// - ar_SA: `"١٢٣٬٤٥٦٫٧٨ US$"` (Arabic-Indic digits in ar locales)
    static func fiat(_ amount: Decimal, currencyCode: String) -> String {
        amount.formatted(.currency(code: currencyCode))
    }

    /// Format a native chain amount with up to `decimals` fractional
    /// digits. Trims trailing zeroes (`0.10000000` → `0.1`) so the
    /// number reads cleanly. Locale-aware decimal separator.
    static func native(_ amount: Decimal, decimals: Int) -> String {
        amount.formatted(nativeBaseStyle.precision(.fractionLength(0...decimals)))
    }

    /// Convert a raw integer balance (as stored in `TokenBalanceRecord.rawBalance`)
    /// + decimals into a `Decimal`. Honest about precision: parses the
    /// raw via `Decimal(string:)` (which preserves arbitrary precision
    /// up to `Decimal`'s 38 significant digits), then divides by
    /// `10^decimals`. Returns `.zero` if the raw can't be parsed.
    static func decimalAmount(rawBalance: String, decimals: Int) -> Decimal {
        guard let raw = Decimal(string: rawBalance) else { return .zero }
        if decimals <= 0 { return raw }
        var divisor = Decimal(1)
        var multiplier = Decimal(10)
        var power = decimals
        while power > 0 {
            if power & 1 == 1 { divisor *= multiplier }
            power >>= 1
            if power > 0 { multiplier *= multiplier }
        }
        return raw / divisor
    }

    // MARK: - Time

    /// "2m ago" / "yesterday" / "Mar 4". Compact, locale-aware.
    /// Falls back to the absolute date when the relative formatter
    /// produces something less honest than the absolute (>~7 days ago).
    static func relativeTime(_ date: Date, reference: Date = Date()) -> String {
        let elapsed = reference.timeIntervalSince(date)
        if elapsed > 60 * 60 * 24 * 7 {
            // More than a week — show absolute date in the user's
            // locale. Honest about how long ago.
            return date.formatted(absoluteDateStyle)
        }
        return relativeFormatter.localizedString(for: date, relativeTo: reference)
    }

    // MARK: - Address

    /// Truncate a long blockchain address to `prefix…suffix` form so
    /// it fits in list rows. Default 6 + 4. For very short addresses
    /// (already <= prefix+suffix+1) returns the full address.
    static func shortAddress(_ address: String, prefix: Int = 6, suffix: Int = 4) -> String {
        guard address.count > prefix + suffix + 1 else { return address }
        let head = address.prefix(prefix)
        let tail = address.suffix(suffix)
        return "\(head)…\(tail)"
    }

    // MARK: - Roll-up

    /// Sum the fiat-value snapshots across an array of balance rows,
    /// counting ONLY rows recorded under `currencyCode` (the user's
    /// current preference). Rows cached under a different currency —
    /// e.g. stale rows scanned before the user switched from USD to
    /// EUR — contribute nothing rather than corrupting the total with
    /// mixed-unit arithmetic. They re-enter the sum after the next
    /// refresh re-prices them in the current currency.
    static func totalFiat(
        _ balances: [TokenBalanceRecord],
        currencyCode: String
    ) -> Decimal {
        balances.reduce(Decimal.zero) { running, row in
            guard row.fiatCurrencyCode.caseInsensitiveCompare(currencyCode) == .orderedSame else {
                return running
            }
            return running + row.fiatValueCached
        }
    }

    /// Count distinct chains across an array of address rows.
    static func chainCount(_ addresses: [WalletAddressRecord]) -> Int {
        Set(addresses.map { $0.chainRaw }).count
    }
}
