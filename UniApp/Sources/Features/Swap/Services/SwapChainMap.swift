import Foundation

/// Maps Aperture's `SupportedChain` to the chain identifiers the swap
/// providers expect.
///
/// **EVM chain ids** come from the live-verified `EVMChainIdentity`
/// (Ethereum 1, Arbitrum 42161, Base 8453, …) — Li.Fi's `fromChain` /
/// `toChain` accept the numeric chain id directly.
///
/// **Solana** uses Li.Fi's SVM chain id `1151111081099710` —
/// live-verified 2026-06-15 via `GET /chains?chainTypes=SVM`
/// (`{"id":1151111081099710,"key":"sol","chainType":"SVM"}`).
///
/// **Which chains can swap.** Li.Fi indexes a subset of EVM chains. We
/// only expose chains Li.Fi actually supports (verified against the
/// provider; opBNB and Kava EVM are excluded because no aggregator
/// bridges them — same exclusion Stabro documented in `SwapAllowlist`).
/// Solana swaps go through Jupiter (keyless) for same-chain and Li.Fi
/// for EVM↔Solana bridges.
enum SwapChainMap {

    /// Li.Fi's SVM chain id for Solana. Live-verified 2026-06-15.
    static let lifiSolanaChainID = 1_151_111_081_099_710

    /// EVM chains Aperture exposes for swapping (Li.Fi-supported subset).
    /// opBNB (204) and Kava EVM (2222) are excluded — no aggregator
    /// bridges them (Stabro `SwapAllowlist` documented the same).
    static let swappableEVMChains: Set<SupportedChain> = [
        .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
        .polygon, .bnbChain, .avalanche, .celo,
    ]

    /// Every chain that can participate in a swap (EVM subset + Solana).
    static var swappableChains: Set<SupportedChain> {
        swappableEVMChains.union([.solana])
    }

    /// `true` if `chain` can be a swap from/to side.
    static func isSwappable(_ chain: SupportedChain) -> Bool {
        swappableChains.contains(chain)
    }

    /// The kind discriminant for provider routing.
    static func kind(for chain: SupportedChain) -> SwapChainKind? {
        if chain == .solana { return .solana }
        if swappableEVMChains.contains(chain) { return .evm }
        return nil
    }

    /// Li.Fi `fromChain` / `toChain` value (numeric chain id as the API
    /// accepts). EVM → EIP-155 chain id; Solana → the SVM chain id.
    static func lifiChainID(for chain: SupportedChain) -> Int? {
        if chain == .solana { return lifiSolanaChainID }
        guard swappableEVMChains.contains(chain) else { return nil }
        return EVMChainIdentity.chainId(for: chain)
    }

    /// The native-coin token identifier the providers expect for `chain`:
    /// EVM native sentinel (`0x0…0`) or wrapped-SOL mint.
    static func nativeTokenAddress(for chain: SupportedChain) -> String? {
        switch kind(for: chain) {
        case .evm:    return SwapToken.nativeEVMSentinel
        case .solana: return SwapToken.wrappedSOLMint
        case .none:   return nil
        }
    }

    /// Build the native-coin `SwapToken` for a swappable chain (the
    /// default "from" asset).
    static func nativeToken(for chain: SupportedChain) -> SwapToken? {
        guard let kind = kind(for: chain),
              let address = nativeTokenAddress(for: chain) else { return nil }
        return SwapToken(
            chain: chain,
            kind: kind,
            address: address,
            symbol: chain.ticker,
            name: chain.displayName,
            decimals: chain.nativeDecimals,
            logoURI: nil
        )
    }
}
