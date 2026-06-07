import Foundation

/// NEP-141 token registry for NEAR — verbatim from
/// `SUPPORTED_ASSETS.md` section 3.17.
///
/// `tokenAccount` is the NEAR account id of the FT contract (NEAR's
/// version of an ERC-20 address). Balance reads call the
/// `ft_balance_of` view method on that contract via the NEAR
/// JSON-RPC `query` method with `request_type=call_function`.
enum NearTokenRegistry {

    struct Entry: Sendable, Hashable {
        let tokenAccount: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(tokenAccount: "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1", symbol: "USDC", name: "USD Coin",   decimals: 6),
        Entry(tokenAccount: "usdt.tether-token.near",                                            symbol: "USDT", name: "Tether USD", decimals: 6),
    ]
}
