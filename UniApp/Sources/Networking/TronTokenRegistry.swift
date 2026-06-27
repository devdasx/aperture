import Foundation

/// TRC-20 tokens supported by Aperture on TRON mainnet.
enum TronTokenRegistry {
    struct Entry: Sendable, Hashable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(
            contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6
        ),
        Entry(
            contract: "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8",
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6
        ),
        Entry(
            contract: "TUpMhErZL2fhh4sVNULAbNKLokS4GjC1F4",
            symbol: "TUSD",
            name: "TrueUSD",
            decimals: 18
        ),
        Entry(
            contract: "TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz",
            symbol: "USDD",
            name: "USDD",
            decimals: 18
        ),
    ]
}
