import Foundation

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

    /// Friendlier relative-date formatter for activity rows. The wallet
    /// header uses compact time ("2m ago"), but activity subtitles need
    /// spoken labels ("1 minute ago") so the row reads naturally.
    nonisolated(unsafe) private static let activityRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// Absolute fallback date style (>1 week ago). Value type, reused.
    private static let absoluteDateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()

    /// Base native-amount style; `.precision(...)` is applied per call
    /// (a cheap value-type copy) for the requested decimal count.
    private static let nativeBaseStyle = Decimal.FormatStyle().grouping(.automatic)

    /// The display cap for token amounts, app-wide. Eight fractional
    /// digits is enough precision for every supported asset on screen
    /// (Bitcoin's satoshi precision is exactly 8); rendering an 18-decimal
    /// ERC-20 balance in full is noise. This cap applies to DISPLAY only —
    /// the editable amount fields and the signing/MAX math keep the token's
    /// full precision. See `native(_:decimals:)`.
    static let maxDisplayFractionDigits = 8

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

    // MARK: - Fiat parts (balance-card three-run rendering)

    /// The currency string split into three independently-styleable runs
    /// for the flagship balance card, which renders the currency code
    /// **muted**, the integer in **primary**, and the decimals in a
    /// **fainter tint** (handoff `design_handoff_balance_card 2`).
    ///
    /// - `currency`: the currency symbol / code run (`"US$"`, `"JOD"`,
    ///   `"€"`), positioned per the locale (prefix in en, suffix in de).
    /// - `integer`: the grouped integer run including the grouping
    ///   separators and any sign (`"12,480"`).
    /// - `fraction`: the decimal run *including its leading separator*
    ///   (`".25"`), or `nil` when the locale renders no fraction.
    /// - `currencyLeads`: `true` when the currency run comes before the
    ///   number (en), `false` when it trails (de) — so the card can lay
    ///   the runs out in the locale's order.
    struct FiatParts: Equatable {
        let currency: String
        let integer: String
        let fraction: String?
        let currencyLeads: Bool
    }

    /// Decompose a fiat amount into its currency / integer / fraction
    /// runs, locale-correct. Uses `Decimal.FormatStyle.Currency`'s
    /// `.attributed` output so grouping, decimal separator, symbol
    /// position, and digit shaping all follow the user's locale, then
    /// buckets the runs by their `numberPart` (integer / fraction) and
    /// `numberSymbol` (currency / sign / separators) format-field
    /// attributes — the native, honest way to split a formatted currency
    /// (never hand-parses the digits).
    ///
    /// Classification per run:
    /// - `numberSymbol == .currency` → the currency run.
    /// - `numberPart == .fraction`, or `numberSymbol == .decimalSeparator`
    ///   → the fraction run (the separator flips us into fraction mode).
    /// - everything else numeric (`.integer`, `.sign`, grouping separator)
    ///   → the integer run (until the decimal separator is seen).
    /// - non-attributed literals (the gap between symbol and number) are
    ///   dropped; the card re-introduces a single gap when laying out.
    static func fiatParts(_ amount: Decimal, currencyCode: String) -> FiatParts {
        let attributed = amount.formatted(
            .currency(code: currencyCode).attributed
        )

        var currency = ""
        var integer = ""
        var fraction = ""
        var sawDecimalSeparator = false
        var sawNumber = false
        var currencyLeads = true

        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let symbol = run.numberSymbol
            let part = run.numberPart

            if symbol == .currency {
                currency += text
                if !sawNumber { currencyLeads = true }
                continue
            }

            if symbol == .decimalSeparator || part == .fraction {
                sawDecimalSeparator = true
                fraction += text
                sawNumber = true
                if currency.isEmpty { currencyLeads = false }
                continue
            }

            if part == .integer || symbol == .sign || symbol == .groupingSeparator {
                sawNumber = true
                if currency.isEmpty { currencyLeads = false }
                if sawDecimalSeparator {
                    fraction += text
                } else {
                    integer += text
                }
                continue
            }

            // Non-attributed literal (whitespace between symbol & number,
            // or an unmapped glyph). Drop pure whitespace; fold any other
            // stray glyph into the currency run.
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                currency += trimmed
            }
        }

        let integerTrimmed = integer.trimmingCharacters(in: .whitespaces)
        let currencyTrimmed = currency.trimmingCharacters(in: .whitespaces)
        return FiatParts(
            currency: currencyTrimmed,
            integer: integerTrimmed.isEmpty ? "0" : integerTrimmed,
            fraction: fraction.isEmpty ? nil : fraction,
            currencyLeads: currencyLeads
        )
    }

    /// Format a native chain (token/coin) amount for DISPLAY. Capped at
    /// `maxDisplayFractionDigits` (8) fractional digits and **truncated
    /// toward zero** — never rounded up — so a balance is never overstated
    /// (`0.032642421940371101` → `0.03264242`, not `…03`). Trims trailing
    /// zeroes (`0.10000000` → `0.1`). Locale-aware decimal separator.
    ///
    /// The `decimals:` argument is the caller's *requested* precision (often
    /// the token's own `decimals`, up to 18/24); it is clamped down to the
    /// 8-digit display cap here so every screen shows the same, readable
    /// amount. Truncation, not rounding, satisfies the honesty rule: the
    /// shown value is always ≤ the true value.
    static func native(_ amount: Decimal, decimals: Int) -> String {
        let cap = min(max(decimals, 0), maxDisplayFractionDigits)
        return amount.formatted(
            nativeBaseStyle
                .precision(.fractionLength(0...cap))
                .rounded(rule: .towardZero)
        )
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

    /// "A moment ago" / "1 minute ago" / "2 weeks ago" for activity
    /// subtitles. Unlike `relativeTime`, this never falls back to an
    /// absolute date because the activity list now carries fiat value on
    /// the trailing subtitle and uses this line as the time anchor.
    static func activityRelativeTime(_ date: Date, reference: Date = Date()) -> String {
        let elapsed = reference.timeIntervalSince(date)
        if abs(elapsed) < 60 {
            return elapsed < 0
                ? String.apertureLocalized("In a moment")
                : String.apertureLocalized("A moment ago")
        }
        return sentenceCased(activityRelativeFormatter.localizedString(for: date, relativeTo: reference))
    }

    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
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
