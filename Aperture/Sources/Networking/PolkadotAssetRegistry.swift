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

        /// Catalog / balance `token_contract` string form.
        var assetIdString: String { String(assetId) }
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

    static func entry(assetId: UInt32) -> Entry? {
        tokens.first { $0.assetId == assetId }
    }

    static func entry(assetIdString: String) -> Entry? {
        let trimmed = assetIdString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UInt32(trimmed) else { return nil }
        return entry(assetId: id)
    }

    static func entry(symbol: String) -> Entry? {
        let upper = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return nil }
        // Catalog uses USDT; on-chain metadata often uses USDt — same after uppercasing.
        return tokens.first { $0.symbol.uppercased() == upper }
    }

    /// True when `contract` is a known Asset Hub asset id (or any numeric
    /// u32 id we can encode into `assets.transfer*`).
    static func isSendSupportedAssetId(_ contract: String) -> Bool {
        UInt32(contract.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
}
