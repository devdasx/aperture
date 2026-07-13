import Foundation

/// NEP-141 tokens supported by Aperture on NEAR mainnet.
enum NearTokenRegistry {
    struct Entry: Sendable, Hashable {
        let tokenAccount: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        // Native Circle USDC on NEAR mainnet (NEP-141). The legacy
        // `usdc.near` account has no contract code and returns
        // CodeDoesNotExist / missing `result.result` on ft_balance_of.
        Entry(
            tokenAccount: "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1",
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6
        ),
        Entry(
            tokenAccount: "usdt.tether-token.near",
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6
        ),
    ]
}
