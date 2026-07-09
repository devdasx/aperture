import Foundation

enum CustomTokenSupport {
    static let chains: [SupportedChain] = [
        .solana,
        .tron,
        .ethereum, .bnbChain, .base, .arbitrum, .polygon,
        .optimism, .avalanche, .zkSync, .scroll, .celo, .opBNB,
    ]

    static func supports(_ chain: SupportedChain) -> Bool {
        chains.contains(chain)
    }

    static func preferredInitialChain(availableChains: [SupportedChain]) -> SupportedChain {
        if availableChains.contains(.solana) { return .solana }
        if availableChains.contains(.tron) { return .tron }
        return orderedChains(availableChains: availableChains).first ?? .solana
    }

    static func hasSupportedChain(in availableChains: [SupportedChain]) -> Bool {
        availableChains.contains(where: supports)
    }

    static func normalizedInitialChain(_ chain: SupportedChain?) -> SupportedChain {
        guard let chain, supports(chain) else { return .solana }
        return chain
    }

    static func orderedChains(availableChains: [SupportedChain]) -> [SupportedChain] {
        let available = Set(availableChains)
        guard !available.isEmpty else { return chains }
        return chains.filter { available.contains($0) }
    }
}
