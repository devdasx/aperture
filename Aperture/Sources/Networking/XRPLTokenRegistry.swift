import Foundation

/// XRP Ledger IOU token registry — verbatim from
/// `SUPPORTED_ASSETS.md` section 3.19.
///
/// XRPL doesn't have "tokens" in the EVM sense — it has IOUs
/// issued by a specific account. An asset is identified by
/// `(currency, issuer)`. The `currency` is a 3-character ASCII
/// code OR a 40-character hex string for non-standard currencies
/// (like `RLUSD`). The `issuer` is an XRPL address.
///
/// Balance reads use `account_lines` JSON-RPC, filtered to the
/// matching `(currency, issuer)`.
enum XRPLTokenRegistry {

    struct Entry: Sendable, Hashable {
        let currency: String     // 40-char hex for non-standard codes; 3-char ASCII for standard
        let issuer: String       // r-prefixed XRPL address
        let symbol: String
        let name: String
        /// Always 0 for XRPL IOUs: `account_lines` returns balances
        /// as already-decimal strings ("12.5"), so the amount is
        /// NEVER divided by 10^decimals. A non-zero value here would
        /// tempt a caller into dividing an already-human-readable
        /// amount.
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(
            currency: "524C555344000000000000000000000000000000",
            issuer:   "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De",
            symbol:   "RLUSD",
            name:     "Ripple USD",
            // 0, not 6 — XRPL IOU amounts arrive as decimal strings
            // and are not divided. See the `decimals` doc above.
            decimals: 0
        ),
    ]
}
