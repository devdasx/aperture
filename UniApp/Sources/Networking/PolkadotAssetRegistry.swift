import Foundation

/// Polkadot Asset Hub asset registry — verbatim from
/// `SUPPORTED_ASSETS.md` section 3.18.
///
/// Polkadot's asset model lives on the **Asset Hub** parachain, not
/// the relay chain. Each asset is identified by a numeric Asset ID.
/// Balance reads go through Asset Hub's `assets.account` storage
/// map; the relay-chain `state_getStorage` pipeline doesn't see
/// these.
///
/// **Honest scope statement.** Aperture's existing Polkadot
/// adapter targets the relay chain (DOT native balance). Asset
/// Hub queries need a separate RPC endpoint registered in
/// `RPCRegistry`. The registry below ships now so the receive
/// screen surfaces USDC on Polkadot; the balance-scan endpoint
/// registration is on the same turn as the receive expansion.
enum PolkadotAssetRegistry {

    struct Entry: Sendable, Hashable {
        let assetId: UInt32
        let symbol: String
        let name: String
        let decimals: Int
    }

    static let tokens: [Entry] = [
        Entry(assetId: 1337, symbol: "USDC", name: "USD Coin", decimals: 6),
    ]
}
