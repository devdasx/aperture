import Foundation

/// Value type describing a single tappable row in the Send sheet's
/// Step 1 asset list. Mirrors `ReceiveAsset` 1:1 (the Send flow is the
/// Receive flow's twin — "what are you sending?" then "on which
/// network?"), kept as its own type so the Send feature owns its model.
///
/// - `.native(chain)` — the chain's own coin (BTC, ETH, SOL, …).
///   Tapping skips the network picker (the network IS the chain) and
///   goes straight to the compose step.
/// - `.token(symbol, name, tokens)` — a fungible token that ships on one
///   or more supported networks (USDC, USDT, …). Each token descriptor
///   preserves the selected chain's contract + decimals for signing.
enum SendAsset: Hashable, Sendable, Identifiable {
    case native(SupportedChain)
    case token(symbol: String, name: String, tokens: [SendTokenDescriptor])

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
    /// Builds the unique list of tokens (symbol + name + exact chain
    /// descriptors) across the local-first asset universe. Symbols are
    /// folded so "USDC" on 12 EVM chains + Solana is one row, while each
    /// network keeps its real contract/mint/account and decimals.
    ///
    /// **Why filter `availableChains`.** Sending USDC on Polygon requires
    /// the wallet to have a Polygon address to sign from. The list
    /// reflects the wallet, not the abstract registry.
    static func tokens(
        availableChains: Set<SupportedChain>,
        customTokens: [CustomTokenSnapshot] = [],
        catalogAssets: [CatalogAsset] = AssetCatalog.allAssets
    ) -> [SendAsset] {
        var bucket: [String: (name: String, tokens: [SendTokenDescriptor])] = [:]

        @inline(__always)
        func add(_ descriptor: SendTokenDescriptor) {
            guard descriptor.isSendSupported else { return }
            let symbol = descriptor.symbol
            if let existing = bucket[symbol] {
                if !existing.tokens.contains(where: { $0.id == descriptor.id }) {
                    bucket[symbol] = (existing.name, existing.tokens + [descriptor])
                }
            } else {
                bucket[symbol] = (descriptor.name, [descriptor])
            }
        }

        // Local-first (Rule #27 §D): the token universe comes from
        // `catalogAssets` (DB-seeded `AssetRecord` → `CatalogAsset`),
        // defaulting to the static `AssetCatalog`.
        for asset in catalogAssets where availableChains.contains(asset.chain) {
            add(SendTokenDescriptor(catalog: asset))
        }

        // User-added custom tokens fold into the same bucket so a custom
        // symbol that matches a registry symbol merges rather than
        // duplicating.
        for snap in customTokens where availableChains.contains(snap.chain) {
            add(SendTokenDescriptor(custom: snap))
        }

        // Sort by descending network count, then alphabetically.
        return bucket
            .map { (symbol, value) in
                SendAsset.token(
                    symbol: symbol,
                    name: value.name,
                    tokens: value.tokens.sortedByChainOrder()
                )
            }
            .sorted { a, b in
                guard case let .token(symA, _, tokensA) = a,
                      case let .token(symB, _, tokensB) = b else { return false }
                if tokensA.count != tokensB.count {
                    return tokensA.count > tokensB.count
                }
                return symA < symB
            }
    }

    var tokenDescriptors: [SendTokenDescriptor] {
        guard case let .token(_, _, tokens) = self else { return [] }
        return tokens
    }

    var chains: [SupportedChain] {
        switch self {
        case .native(let chain):
            return [chain]
        case .token(_, _, let tokens):
            return tokens.sortedByChainOrder().map(\.chain)
        }
    }

    /// Canonical chain for the token logo — Ethereum first when present
    /// (the canonical brand mark for cross-chain stablecoins), else the
    /// first supported chain.
    var canonicalChainForLogo: SupportedChain? {
        let chains = chains
        guard !chains.isEmpty else { return nil }
        if chains.contains(.ethereum) { return .ethereum }
        return chains.first
    }

    /// Token's contract on its `canonicalChainForLogo`, for the Trust
    /// Wallet logo URL. `nil` for native rows or when no registry entry
    /// exists.
    var canonicalContract: String? {
        guard case let .token(_, _, tokens) = self,
              let chain = canonicalChainForLogo,
              let match = tokens.first(where: { $0.chain == chain }) else {
            return nil
        }
        return match.contract
    }
}

// MARK: - Codable (for NavigationPath persistence across Rule #12 §G rebuilds)

extension SendAsset: Codable {
    private enum Kind: String, Codable { case native, token }

    private enum CodingKeys: String, CodingKey {
        case kind, chain, symbol, name, chains, tokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .native:
            self = .native(try container.decode(SupportedChain.self, forKey: .chain))
        case .token:
            let symbol = try container.decode(String.self, forKey: .symbol)
            let name = try container.decode(String.self, forKey: .name)
            if let tokens = try? container.decode([SendTokenDescriptor].self, forKey: .tokens) {
                self = .token(symbol: symbol, name: name, tokens: tokens)
                return
            }
            // Backward compatibility with old NavigationPath payloads that
            // stored only chains. Rebuild descriptors from the static catalog.
            let chains = try container.decode([SupportedChain].self, forKey: .chains)
            let descriptors = AssetCatalog.allAssets
                .filter { $0.symbol.uppercased() == symbol.uppercased() && chains.contains($0.chain) }
                .map(SendTokenDescriptor.init(catalog:))
                .filter(\.isSendSupported)
                .sortedByChainOrder()
            self = .token(
                symbol: symbol,
                name: name,
                tokens: descriptors
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .native(chain):
            try container.encode(Kind.native, forKey: .kind)
            try container.encode(chain, forKey: .chain)
        case let .token(symbol, name, tokens):
            try container.encode(Kind.token, forKey: .kind)
            try container.encode(symbol, forKey: .symbol)
            try container.encode(name, forKey: .name)
            try container.encode(tokens, forKey: .tokens)
        }
    }
}

private extension Array where Element == SendTokenDescriptor {
    func sortedByChainOrder() -> [SendTokenDescriptor] {
        let order = Dictionary(uniqueKeysWithValues: SupportedChain.allCases.enumerated().map { ($0.element, $0.offset) })
        return sorted {
            if $0.chain != $1.chain {
                return (order[$0.chain] ?? 0) < (order[$1.chain] ?? 0)
            }
            return $0.contractKey < $1.contractKey
        }
    }
}
