import Foundation

/// SPL tokens supported by Aperture on Solana mainnet.
///
/// Solana balances are read by mint with `getTokenAccountsByOwner`, so each
/// entry is keyed by the canonical mint address.
enum SolanaTokenRegistry {
    struct Entry: Sendable, Hashable {
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let mints: [String: Entry] = [
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": Entry(
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6
        ),
        "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": Entry(
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6
        ),
    ]
}
