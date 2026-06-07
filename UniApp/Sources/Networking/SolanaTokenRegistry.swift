import Foundation

/// SPL token registry for Solana — verbatim from
/// `SUPPORTED_ASSETS.md` section 3.15. Each entry maps a mint
/// address to (symbol, name, standard, decimals). Token standard
/// is either `splToken` (legacy) or `splToken2022` — the streaming
/// scanner uses the right SPL Token program id for each.
///
/// **No unauthorized additions.** Per Rule #21 + M-012, this list
/// matches the spec exactly. JLP / JUP / RNDR (previously here as
/// agent additions) are removed; only the 10 spec rows remain.
enum SolanaTokenRegistry {

    enum Standard: Sendable, Hashable {
        case splToken           // Tokenkeg…23VQ5DA
        case splToken2022       // TokenzQd…Wb3UYUg
    }

    struct Entry: Sendable, Hashable {
        let symbol: String
        let name: String
        let decimals: Int
        let standard: Standard
    }

    /// Mint → (symbol, name, decimals, standard). Mints not in the
    /// map are dropped by the scanner (per the curated-only rule
    /// shipped earlier today).
    static let mints: [String: Entry] = [
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": Entry(symbol: "USDC",   name: "USD Coin",                    decimals: 6, standard: .splToken),
        "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": Entry(symbol: "USDT",   name: "Tether USD",                  decimals: 6, standard: .splToken),
        "USD1ttGY1N17NEEHLmELoaybftRBUSErhqYiQzvEmuB":  Entry(symbol: "USD1",   name: "World Liberty Financial USD", decimals: 6, standard: .splToken),
        "AUSD1jCcCyPLybk1YnvPWsHQSrZ46dxwoMniN4N2UEB9": Entry(symbol: "AUSD",   name: "Agora Dollar",                decimals: 6, standard: .splToken2022),
        "DUSDt4AeLZHWYmcXnVGYdgAzjtzU5mXUVnTMdnSzAttM": Entry(symbol: "DUSD",   name: "StandX DUSD",                 decimals: 6, standard: .splToken2022),
        "2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo": Entry(symbol: "PYUSD",  name: "PayPal USD",                  decimals: 6, standard: .splToken2022),
        "2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH": Entry(symbol: "USDG",   name: "Global Dollar",               decimals: 6, standard: .splToken2022),
        "HzwqbKZw8HxMN6bF2yFZNrht3c2iXXzpKcFu7uBEDKtr": Entry(symbol: "EURC",   name: "EURC",                        decimals: 6, standard: .splToken),
        "3NZ9JMVBmGAqocybic2c7LQCJScmgsAZ6vQqTDzcqmJh": Entry(symbol: "WBTC",   name: "Wrapped Bitcoin",             decimals: 8, standard: .splToken),
        "7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs": Entry(symbol: "WETH",   name: "Wrapped Ether",               decimals: 8, standard: .splToken),
    ]

    static func symbol(for mint: String) -> String {
        if let entry = mints[mint] { return entry.symbol }
        guard mint.count > 9 else { return mint }
        return "\(mint.prefix(5))…\(mint.suffix(4))"
    }

    static func name(for mint: String) -> String {
        if let entry = mints[mint] { return entry.name }
        return symbol(for: mint)
    }
}
