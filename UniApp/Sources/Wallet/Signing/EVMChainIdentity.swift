import Foundation

/// EVM per-chain identity the signer needs: the numeric `chainId`
/// (EIP-155 replay protection) and whether the chain uses EIP-1559
/// (Type-2) or legacy (Type-0) fee fields.
///
/// **chainId values — live-verified 2026-06-15 via `eth_chainId` on each
/// chain's registered publicnode endpoint:**
/// ETH 1 (0x1), BNB 56 (0x38), Polygon 137 (0x89), Arbitrum 42161
/// (0xa4b1), Base 8453 (0x2105), Optimism 10 (0xa), Avalanche-C 43114
/// (0xa86a), Scroll 534352 (0x82750), Celo 42220 (0xa4ec), Kava EVM 2222
/// (0x8ae), opBNB 204 (0xcc). zkSync Era = 324 (0x144) — the documented
/// mainnet id (the publicnode zkSync endpoint did not answer eth_chainId
/// at verify time; 324 is the canonical constant per the zkSync docs +
/// the Ethereum chain registry).
///
/// Doc URLs: https://ethereum.org/en/developers/docs/apis/json-rpc/
/// (eth_chainId), https://chainlist.org, https://docs.zksync.io.
enum EVMChainIdentity {

    /// EIP-155 numeric chain id. `nil` for non-EVM chains (caller must
    /// only invoke this for `chain.family == .evm`).
    static func chainId(for chain: SupportedChain) -> Int? {
        switch chain {
        case .ethereum:   return 1
        case .bnbChain:   return 56
        case .polygon:    return 137
        case .arbitrum:   return 42161
        case .base:       return 8453
        case .optimism:   return 10
        case .avalanche:  return 43114
        case .scroll:     return 534352
        case .zkSync:     return 324
        case .celo:       return 42220
        case .kavaEvm:    return 2222
        case .opBNB:      return 204
        default:          return nil
        }
    }

    /// `true` when the chain prices fees with EIP-1559 (baseFee + tip);
    /// `false` for legacy single-`gasPrice` chains. BNB Chain is the one
    /// legacy chain in Aperture's EVM set (matches
    /// `ChainComposeCapability` → `.evmLegacy` and the matrix). Every
    /// other EVM chain — including the OP-stack L2s and zkSync — signs a
    /// standard Type-2 transaction; their extra L1/pubdata cost is
    /// charged by the sequencer, NOT set as a tx field (matrix §G2).
    static func usesEIP1559(_ chain: SupportedChain) -> Bool {
        switch chain {
        case .bnbChain:
            return false
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .opBNB, .avalanche, .celo, .kavaEvm:
            return true
        default:
            // Non-EVM — undefined; caller gates on family first.
            return true
        }
    }
}
