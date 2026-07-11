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
        Entry(
            tokenAccount: "usdc.near",
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
