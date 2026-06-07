import Foundation

/// Aptos token registry — verbatim from `SUPPORTED_ASSETS.md`
/// section 3.14. `contract` is the Aptos fungible-asset address
/// (the canonical metadata object on Aptos). Balance reads use
/// the Aptos `view` function `0x1::primary_fungible_store::balance`
/// — works for both legacy CoinStore and the new fungible-asset
/// model (same pattern as the native APT balance read).
enum AptosTokenRegistry {

    struct Entry: Sendable, Hashable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(contract: "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b", symbol: "USDC", name: "USD Coin",   decimals: 6),
        Entry(contract: "0x357b0b74bc833e95a115ad22604854d6b0fca151cecd94111770e5d6ffc9dc2b", symbol: "USDT", name: "Tether USD", decimals: 6),
    ]
}
