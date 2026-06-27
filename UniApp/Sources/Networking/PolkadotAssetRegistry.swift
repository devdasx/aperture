import Foundation

/// Polkadot Asset Hub assets supported by Aperture.
///
/// Asset Hub balances are separate from relay-chain DOT. The relay scanner
/// handles native DOT; Asset Hub token scanners should match these IDs.
enum PolkadotAssetRegistry {
    struct Entry: Sendable, Hashable {
        let assetId: UInt32
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(
            assetId: 1337,
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6
        ),
        Entry(
            assetId: 1984,
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6
        ),
    ]
}
