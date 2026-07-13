import Foundation

/// Formats `ChainBalance` values for display. Two outputs per balance:
/// the native amount (e.g. "0.00412 BTC") and the fiat equivalent
/// (e.g. "≈ $312.45"). Locale-aware via `Decimal.FormatStyle`.
enum BalanceFormatter {

    /// Native amount + ticker. Routes through `WalletFormatting.native` so
    /// the app has ONE token-amount display rule: capped at 8 fractional
    /// digits and truncated toward zero (never rounded up), trailing zeros
    /// trimmed. (Previously this capped per-family — bitcoin 8 / evm 6 /
    /// other 4 — and rounded; unified here so the same token reads the same
    /// on every screen.)
    static func native(_ amount: Decimal, chain: SupportedChain) -> String {
        "\(WalletFormatting.native(amount, decimals: WalletFormatting.maxDisplayFractionDigits)) \(chain.ticker)"
    }

    /// Fiat equivalent with the canonical `≈` approximation mark per
    /// Rule #16's honesty register — the conversion is an estimate
    /// based on a public price feed, not a quoted conversion guarantee.
    static func fiat(_ amount: Decimal, currencyCode: String) -> String {
        // Route through WalletFormatting so currency symbols stay narrow
        // (US$ → $) app-wide, same as the balance hero.
        "≈ \(WalletFormatting.fiat(amount, currencyCode: currencyCode, fractionLength: 2...2))"
    }
}
