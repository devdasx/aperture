import Foundation

/// TRC-20 token registry for TRON — verbatim from
/// `SUPPORTED_ASSETS.md` section 3.16.
enum TronTokenRegistry {

    struct Entry: Sendable, Hashable {
        let contract: String          // TRON base58 address
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", symbol: "USDT", name: "Tether USD",                  decimals: 6),
        Entry(contract: "TPFqcBAaaUMCSVRCqPaQ9QnzKhmuoLR6Rc", symbol: "USD1", name: "World Liberty Financial USD", decimals: 18),
        Entry(contract: "TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz", symbol: "USDD", name: "Decentralized USD",           decimals: 18),
        Entry(contract: "TUpMhErZL2fhh4sVNULAbNKLokS4GjC1F4", symbol: "TUSD", name: "TrueUSD",                     decimals: 18),
        Entry(contract: "TXpw8XeWYeTUd4quDskoUqeQPowRh4jY65", symbol: "WBTC", name: "Wrapped Bitcoin",             decimals: 8),
    ]
}
