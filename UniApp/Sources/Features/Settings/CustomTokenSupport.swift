import Foundation

enum CustomTokenSupport {
    static let chains: [SupportedChain] = [
        .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
        .polygon, .bnbChain, .opBNB, .avalanche, .celo,
        .solana,
        .tron,
    ]

    static func supports(_ chain: SupportedChain) -> Bool {
        chains.contains(chain)
    }

    static func preferredInitialChain(availableChains: [SupportedChain]) -> SupportedChain {
        for chain in availableChains where chain.family == .evm {
            return chain
        }
        if availableChains.contains(.solana) { return .solana }
        if availableChains.contains(.tron) { return .tron }
        return .ethereum
    }

    static func hasSupportedChain(in availableChains: [SupportedChain]) -> Bool {
        availableChains.contains(where: supports)
    }

    static func normalizedInitialChain(_ chain: SupportedChain?) -> SupportedChain {
        guard let chain, supports(chain) else { return .ethereum }
        return chain
    }
}
