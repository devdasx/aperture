import Foundation

/// TIP-3 Jetton registry for TON — verbatim from
/// `SUPPORTED_ASSETS.md` section 3.20.
///
/// On TON, fungible tokens are "Jettons". Each jetton has a master
/// contract address; a user's balance lives in a per-user jetton
/// wallet (derived deterministically from the user's address +
/// the jetton master).
///
/// Balance reads call the jetton master's `get_wallet_address`
/// off-chain method (via TonCenter's `runGetMethod`), then call
/// `get_wallet_data` on the resulting jetton wallet.
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
            symbol:         "USDT",
            name:           "Tether USD",
            decimals:       6
        ),
    ]
}
