import Foundation

/// Jettons supported by Aperture on TON mainnet.
enum TONJettonRegistry {
    struct Entry: Sendable, Hashable {
        let masterContract: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(
            masterContract: "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs",
            symbol: "USDT",
            name: "Tether USD",
            decimals: 6
        ),
    ]
}
