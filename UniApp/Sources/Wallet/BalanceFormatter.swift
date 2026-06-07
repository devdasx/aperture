import Foundation

/// Formats `ChainBalance` values for display. Two outputs per balance:
/// the native amount (e.g. "0.00412 BTC") and the fiat equivalent
/// (e.g. "≈ $312.45"). Locale-aware via `Decimal.FormatStyle`.
enum BalanceFormatter {

    /// Native amount + ticker. Precision adapts to the chain family:
    /// Bitcoin family uses 8 fractional digits, EVM uses 6, others
    /// pick 4 by default. Trimmed of trailing zeros so "0.00412 BTC"
    /// reads cleaner than "0.00412000 BTC".
    static func native(_ amount: Decimal, chain: SupportedChain) -> String {
        let maxFraction: Int
        switch chain.family {
        case .bitcoin:  maxFraction = 8
        case .evm:      maxFraction = 6
        default:        maxFraction = 4
        }
        let style = Decimal.FormatStyle.number
            .precision(.fractionLength(0...maxFraction))
            .grouping(.never)
        return "\(amount.formatted(style)) \(chain.ticker)"
    }

    /// Fiat equivalent with the canonical `≈` approximation mark per
    /// Rule #16's honesty register — the conversion is an estimate
    /// based on a public price feed, not a quoted exchange rate.
    static func fiat(_ amount: Decimal, currencyCode: String) -> String {
        let style = Decimal.FormatStyle.Currency(code: currencyCode)
            .precision(.fractionLength(2))
        return "≈ \(amount.formatted(style))"
    }
}
