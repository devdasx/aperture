import Foundation

/// Kava (Cosmos) IBC token registry — verbatim from
/// `SUPPORTED_ASSETS.md` section 3.13.
///
/// On Cosmos chains, fungible tokens that arrive via IBC live as
/// `denom` strings in the bank module. The `denom` identifies the
/// token across all balance queries via
/// `/cosmos/bank/v1beta1/balances/{address}`.
///
/// The doc shows `erc20/tether/usdt` as the canonical Kava
/// identifier — this matches Kava's ERC-20 module bridge from
/// their EVM side, not a traditional IBC denom path. Both shapes
/// (ERC-20-bridged + native IBC `ibc/<hash>`) work as `denom`
/// strings; the bank module accepts either.
enum KavaCosmosTokenRegistry {

    struct Entry: Sendable, Hashable {
        let denom: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(denom: "erc20/tether/usdt", symbol: "USDT", name: "Tether USD", decimals: 6),
    ]
}
