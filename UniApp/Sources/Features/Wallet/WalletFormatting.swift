import Foundation
import SwiftData

/// Small, focused formatting helpers shared across the wallet-home
/// surface. Locale-aware. No view code — these are pure functions
/// returning `String` (or `LocalizedStringResource`) so they're safely
/// callable from background actors.
enum WalletFormatting {

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
        let style = Decimal.FormatStyle()
            .precision(.fractionLength(0...decimals))
            .grouping(.automatic)
        return amount.formatted(style)
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
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return date.formatted(style)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: reference)
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

    /// Sum the fiat-value snapshots across an array of balance rows.
    /// Returns the total in the most-recently-recorded currency
    /// (typically all rows are recorded under the same currency, which
    /// is the user's preference at the time of the most recent scan).
    static func totalFiat(_ balances: [TokenBalanceRecord]) -> Decimal {
        balances.reduce(Decimal.zero) { running, row in
            running + row.fiatValueCached
        }
    }

    /// Count distinct chains across an array of address rows.
    static func chainCount(_ addresses: [WalletAddressRecord]) -> Int {
        Set(addresses.map { $0.chainRaw }).count
    }
}
