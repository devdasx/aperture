import Foundation

/// Sui coin registry.
///
/// Sui identifies every fungible asset by its full Move coin type:
/// `package::module::Type`. Balance reads use `suix_getAllBalances`
/// and match against this canonical coin type.
enum SuiTokenRegistry {

    struct Entry: Sendable, Hashable {
        let coinType: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(
            coinType: "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC",
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6
        ),
    ]
}
