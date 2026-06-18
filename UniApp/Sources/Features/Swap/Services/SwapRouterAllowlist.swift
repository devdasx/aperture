import Foundation

/// Allowlist of known-safe swap router / bridge contract addresses.
///
/// **Why this exists (security — Rule #16).** A swap routes the user's
/// funds *through a contract*. If a quote's `transactionRequest.to` (or
/// the ERC-20 `approvalAddress` we'd approve spending to) is an
/// attacker-controlled address, signing it drains the wallet. So before
/// any EVM quote is accepted, its router + approval target are checked
/// against this list; an un-allowlisted address makes the quote throw
/// `SwapError.untrustedRouter` instead of ever reaching the signer.
///
/// Ported from Stabro's `RouterAllowlist` (the canonical set of LI.FI
/// Diamond, aggregator, and bridge router addresses), trimmed to the
/// contracts Li.Fi actually returns for Aperture's flow and extended
/// with the addresses observed live 2026-06-15 (LI.FI Diamond
/// `0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE` for both the same-chain
/// swap and the Across bridge quote).
///
/// All addresses are stored lowercased; lookup lowercases the input.
enum SwapRouterAllowlist {

    /// LI.FI Diamond / executor contracts. These are the `to` of every
    /// Li.Fi `transactionRequest` and the `approvalAddress` for ERC-20
    /// swaps. `0x1231DEB6…` confirmed live 2026-06-15.
    static let lifi: Set<String> = [
        "0x1231deb6f5749ef6ce6943a275a1d3e7486f4eae", // LI.FI Diamond (all chains)
        "0x341e94069f53234fe6dabef707ad424830525715", // LI.FI executor
        "0x9b11bc9fac17c058cab6286b0c785be6a65492ef", // LI.FI Diamond (alt)
    ]

    /// Aggregator routers Li.Fi composes same-chain swaps through.
    static let aggregators: Set<String> = [
        "0xdef171fe48cf0115b1d80b88dc8eab59176fee57", // Paraswap V5
        "0x6a000f20005980200259b80c5102003040001068", // Paraswap V6.2
        "0x1111111254eeb25477b68fb85ed929f73a960582", // 1inch V5
        "0x111111125421ca6dc452d289314280a0f8842a65", // 1inch V6
        "0xdef1c0ded9bec7f1a1670819833240f027b25eff", // 0x V1 Exchange Proxy
        "0x7f54f05635d15cde17a49502fedb9d1803a3be8a", // 0x V2 Permit2 Settler
        "0x6131b5fae19ea4f9d964eac0408e4408b66337b5", // KyberSwap aggregator
        "0xe592427a0aece92de3edee1f18e0157c05861564", // Uniswap-class router
        "0x6352a56caadc4f1e25cd6c75970fa768a3304e64", // OpenOcean
        "0xcf5540fffcdc3d510b18bfca6d2b9987b0772559", // Odos V2
        "0x19ceead7105607cd444f5ad10dd51356436095a1", // Odos (alt)
    ]

    /// Bridge router contracts Li.Fi composes cross-chain transfers
    /// through. `across` was the tool returned live 2026-06-15 for the
    /// ETH→Arbitrum bridge.
    static let bridges: Set<String> = [
        "0xef4fb24ad0916217251f553c0596f8edc630eb66", // deBridge DlnSource
        "0xe7351fd770a37282b91d153ee690b63579d6dd7f", // deBridge DlnDestination
        "0x663dc15d3c1ac63ff12e45ab68fea3f0a883c251", // deBridge CrossChain router
        "0xa5f565650890fba1824ee0f21ebbbf660a179934", // Relay
        "0x5c7bcd6e7de5423a257d81b442095a1a6ced35c5", // Across SpokePool (Ethereum)
        "0xe35e9842fceaca96570b734083f4a58e8f7c5f2a", // Across SpokePool (alt)
    ]

    /// All known-safe addresses combined.
    private static let all: Set<String> = lifi.union(aggregators).union(bridges)

    /// `true` if `address` is a known-safe router/bridge/approval target.
    /// In practice Aperture only signs the LI.FI Diamond as the `to`
    /// (Li.Fi composes everything else internally), so the LI.FI set is
    /// the load-bearing check; the aggregator/bridge sets are defense in
    /// depth in case a future Li.Fi route returns a direct router.
    static func isTrusted(_ address: String) -> Bool {
        all.contains(address.lowercased())
    }

    /// The set the `to`/`approvalAddress` of a Li.Fi quote MUST be in.
    /// Li.Fi always routes through its own Diamond, so this is the gate
    /// the quote builder applies.
    static func isTrustedLiFiTarget(_ address: String) -> Bool {
        // Accept the LI.FI Diamond set (the documented invariant) OR any
        // allowlisted aggregator/bridge (belt-and-suspenders).
        isTrusted(address)
    }

    // MARK: - Transaction classification (T-067)

    /// `true` if `address` is a known dedicated cross-chain BRIDGE router.
    /// Drives `.bridge` classification of a persisted transaction whose
    /// counterparty is this address (so the activity feed reads "Bridged").
    static func isBridgeRouter(_ address: String) -> Bool {
        bridges.contains(address.lowercased())
    }

    /// `true` if `address` is a known same-chain SWAP router — a DEX
    /// aggregator or the LI.FI Diamond. Drives `.swap` classification (the
    /// activity feed reads "Swapped"). The LI.FI Diamond also composes
    /// bridges, so callers check `isBridgeRouter` FIRST; a dedicated bridge
    /// match wins over this broader swap set.
    static func isSwapRouter(_ address: String) -> Bool {
        let lowered = address.lowercased()
        return aggregators.contains(lowered) || lifi.contains(lowered)
    }
}
