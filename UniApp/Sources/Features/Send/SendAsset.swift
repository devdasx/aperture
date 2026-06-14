import Foundation

/// Value type describing a single tappable row in the Send sheet's
/// Step 1 asset list. Mirrors `ReceiveAsset` 1:1 (the Send flow is the
/// Receive flow's twin — "what are you sending?" then "on which
/// network?"), kept as its own type so the Send feature owns its model.
///
/// - `.native(chain)` — the chain's own coin (BTC, ETH, SOL, …).
///   Tapping skips the network picker (the network IS the chain) and
///   goes straight to the compose step.
/// - `.token(symbol, name, chains)` — a fungible token that ships on one
///   or more supported networks (USDC, USDT, …). Tapping routes to a
///   network picker so the user chooses which network to send on.
enum SendAsset: Hashable, Sendable, Identifiable {
    case native(SupportedChain)
    case token(symbol: String, name: String, chains: [SupportedChain])

    /// Stable identity for SwiftUI `Identifiable` + `ForEach`. Native
    /// rows key by chain raw value; token rows key by symbol.
    var id: String {
        switch self {
        case .native(let chain):       return "native.\(chain.rawValue)"
        case .token(let symbol, _, _): return "token.\(symbol)"
        }
    }
}

extension SendAsset {
    /// Builds the unique list of tokens (symbol + name + supporting
    /// chains) across the local-first asset universe. Symbols are folded
    /// so "USDC" on 12 EVM chains + Solana is one row whose `chains`
    /// array has 13 entries — exactly as the Receive list folds them.
    ///
    /// **Why filter `availableChains`.** Sending USDC on Polygon requires
    /// the wallet to have a Polygon address to sign from. The list
    /// reflects the wallet, not the abstract registry.
    static func tokens(
        availableChains: Set<SupportedChain>,
        customTokens: [CustomTokenSnapshot] = [],
        catalogAssets: [CatalogAsset] = AssetCatalog.allAssets
    ) -> [SendAsset] {
        // [symbol: (name, [chain])] — collected then sorted.
        var bucket: [String: (name: String, chains: [SupportedChain])] = [:]

        @inline(__always)
        func add(_ symbol: String, _ name: String, _ chain: SupportedChain) {
            if let existing = bucket[symbol] {
                if !existing.chains.contains(chain) {
                    bucket[symbol] = (existing.name, existing.chains + [chain])
                }
            } else {
                bucket[symbol] = (name, [chain])
            }
        }

        // Local-first (Rule #27 §D): the token universe comes from
        // `catalogAssets` (DB-seeded `AssetRecord` → `CatalogAsset`),
        // defaulting to the static `AssetCatalog`.
        for asset in catalogAssets where availableChains.contains(asset.chain) {
            add(asset.symbol, asset.name, asset.chain)
        }

        // User-added custom tokens fold into the same bucket so a custom
        // symbol that matches a registry symbol merges rather than
        // duplicating.
        for snap in customTokens where availableChains.contains(snap.chain) {
            add(snap.symbol, snap.name, snap.chain)
        }

        // Sort by descending network count, then alphabetically.
        return bucket
            .map { (symbol, value) in
                SendAsset.token(
                    symbol: symbol,
                    name: value.name,
                    chains: SupportedChain.allCases.filter { value.chains.contains($0) }
                )
            }
            .sorted { a, b in
                guard case let .token(symA, _, chainsA) = a,
                      case let .token(symB, _, chainsB) = b else { return false }
                if chainsA.count != chainsB.count {
                    return chainsA.count > chainsB.count
                }
                return symA < symB
            }
    }

    /// Canonical chain for the token logo — Ethereum first when present
    /// (the canonical brand mark for cross-chain stablecoins), else the
    /// first supported chain.
    var canonicalChainForLogo: SupportedChain? {
        guard case let .token(_, _, chains) = self else { return nil }
        if chains.contains(.ethereum) { return .ethereum }
        return chains.first
    }

    /// Token's contract on its `canonicalChainForLogo`, for the Trust
    /// Wallet logo URL. `nil` for native rows or when no registry entry
    /// exists.
    var canonicalContract: String? {
        guard case let .token(symbol, _, _) = self,
              let chain = canonicalChainForLogo else {
            return nil
        }
        if chain.family == .evm {
            return EVMTokenRegistry.tokens(for: chain)
                .first(where: { $0.symbol == symbol })?
                .contract
        }
        if chain == .solana {
            // Solana token logos resolve from the mint address.
            return SolanaTokenRegistry.mints.first(where: { $0.value.symbol == symbol })?.key
        }
        return nil
    }
}

// MARK: - Codable (for NavigationPath persistence across Rule #12 §G rebuilds)

extension SendAsset: Codable {
    private enum Kind: String, Codable { case native, token }

    private enum CodingKeys: String, CodingKey {
        case kind, chain, symbol, name, chains
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .native:
            self = .native(try container.decode(SupportedChain.self, forKey: .chain))
        case .token:
            self = .token(
                symbol: try container.decode(String.self, forKey: .symbol),
                name: try container.decode(String.self, forKey: .name),
                chains: try container.decode([SupportedChain].self, forKey: .chains)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .native(chain):
            try container.encode(Kind.native, forKey: .kind)
            try container.encode(chain, forKey: .chain)
        case let .token(symbol, name, chains):
            try container.encode(Kind.token, forKey: .kind)
            try container.encode(symbol, forKey: .symbol)
            try container.encode(name, forKey: .name)
            try container.encode(chains, forKey: .chains)
        }
    }
}
