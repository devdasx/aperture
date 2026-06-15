import Foundation

/// The Swap picker's asset universe — the swap-side mirror of
/// `ReceiveAsset`. Same two shapes the Receive picker uses, so the Swap
/// token picker can be asset-first → network (pick the coin/token, THEN
/// its network), identical to Receive:
///
/// - `.native(chain)` — the chain's own coin (ETH, SOL, …). Tapping
///   produces the native `SwapToken` directly; no network step (the
///   network IS the chain).
/// - `.token(symbol, name, networks)` — a fungible token that ships on
///   one or more **swappable** networks. Tapping routes to a network
///   step so the user picks which network to swap on; that choice yields
///   a `SwapToken` carrying that network's real contract + decimals.
///
/// **Only the app's curated assets + the user's custom tokens** feed this
/// (via `AssetCatalog` + `CustomTokenSnapshot`), and **only on swappable
/// chains** (`SwapChainMap.isSwappable`) — never the raw provider list.
/// A provider search fallback (`SwapQuoteService.searchTokens`) augments
/// it when the user looks for a token we don't curate.
enum SwapAsset: Hashable, Sendable, Identifiable {
    case native(SupportedChain)
    case token(symbol: String, name: String, networks: [Network])

    /// One swappable network a token ships on, carrying the exact
    /// on-chain identity needed to build a quote-valid `SwapToken`.
    struct Network: Hashable, Sendable {
        let chain: SupportedChain
        /// ERC-20 contract / SPL mint on `chain`. Verbatim.
        let contract: String
        /// On-chain decimals for THIS network (load-bearing for the
        /// quote's raw-amount math — never copied across chains).
        let decimals: Int
        let logoURI: String?
    }

    /// Stable identity. Native rows key by chain; token rows by symbol.
    var id: String {
        switch self {
        case .native(let chain):          return "native.\(chain.rawValue)"
        case .token(let symbol, _, _):    return "token.\(symbol)"
        }
    }

    /// The chains this asset can be swapped on (one for native, the
    /// folded set for a token).
    var chains: [SupportedChain] {
        switch self {
        case .native(let chain):          return [chain]
        case .token(_, _, let networks):  return networks.map(\.chain)
        }
    }

    /// Resolve the quote-valid `SwapToken` for a chosen `chain`. Native →
    /// the chain's native sentinel token; token → the matching network's
    /// contract+decimals. Returns `nil` if the chain isn't a network of
    /// this asset or isn't swappable (so a handed-back token always
    /// satisfies the quote invariants).
    func swapToken(for chain: SupportedChain) -> SwapToken? {
        switch self {
        case .native(let nativeChain):
            guard nativeChain == chain else { return nil }
            return SwapChainMap.nativeToken(for: chain)
        case .token(let symbol, let name, let networks):
            guard let network = networks.first(where: { $0.chain == chain }) else { return nil }
            return SwapToken.swappable(
                chain: chain,
                contract: network.contract,
                symbol: symbol,
                name: name,
                decimals: network.decimals,
                logoURI: network.logoURI
            )
        }
    }
}

// MARK: - Universe builders (curated app assets + custom tokens, swappable only)

extension SwapAsset {
    /// Native coins for every **swappable** chain the wallet has an
    /// address on, in `SupportedChain.allCases` order.
    static func natives(availableChains: Set<SupportedChain>) -> [SwapAsset] {
        SupportedChain.allCases
            .filter { SwapChainMap.isSwappable($0) && availableChains.contains($0) }
            .map { .native($0) }
    }

    /// Folded token rows from the curated catalog + custom tokens,
    /// restricted to swappable chains the wallet has an address on. Mirrors
    /// `ReceiveAsset.tokens` (symbol-bucketed, network-count then
    /// alphabetical sort) but carries each network's contract + decimals so
    /// a pick is quote-valid.
    static func tokens(
        availableChains: Set<SupportedChain>,
        customTokens: [CustomTokenSnapshot] = [],
        catalogAssets: [CatalogAsset] = AssetCatalog.allAssets
    ) -> [SwapAsset] {
        var bucket: [String: (name: String, networks: [Network])] = [:]

        @inline(__always)
        func add(_ symbol: String, _ name: String, _ network: Network) {
            if let existing = bucket[symbol] {
                guard !existing.networks.contains(where: { $0.chain == network.chain }) else { return }
                bucket[symbol] = (existing.name, existing.networks + [network])
            } else {
                bucket[symbol] = (name, [network])
            }
        }

        func swappableAndAvailable(_ chain: SupportedChain) -> Bool {
            SwapChainMap.isSwappable(chain) && availableChains.contains(chain)
        }

        for asset in catalogAssets where swappableAndAvailable(asset.chain) {
            add(asset.symbol, asset.name,
                Network(chain: asset.chain, contract: asset.contract,
                        decimals: asset.decimals, logoURI: nil))
        }
        for snap in customTokens where swappableAndAvailable(snap.chain) {
            add(snap.symbol, snap.name,
                Network(chain: snap.chain, contract: snap.contract,
                        decimals: snap.decimals, logoURI: snap.iconURL))
        }

        return bucket
            .map { symbol, value in
                SwapAsset.token(
                    symbol: symbol,
                    name: value.name,
                    networks: SupportedChain.allCases.compactMap { chain in
                        value.networks.first(where: { $0.chain == chain })
                    }
                )
            }
            .sorted { a, b in
                guard case let .token(symA, _, netsA) = a,
                      case let .token(symB, _, netsB) = b else { return false }
                if netsA.count != netsB.count { return netsA.count > netsB.count }
                return symA < symB
            }
    }

    /// Fold a flat list of provider-found `SwapToken`s (from
    /// `SwapQuoteService.searchTokens`) into `SwapAsset` rows, so provider
    /// search results render exactly like curated rows (one symbol row,
    /// networks merged). Native sentinels collapse to `.native`.
    static func fromProviderTokens(_ tokens: [SwapToken]) -> [SwapAsset] {
        var natives: [SupportedChain: Bool] = [:]
        var bucket: [String: (name: String, networks: [Network])] = [:]
        for token in tokens {
            if token.isNative {
                natives[token.chain] = true
                continue
            }
            // A non-native token with an empty contract can't be swapped (it
            // would resolve to a nil SwapToken → a dead-tap row). Drop it.
            let contract = token.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contract.isEmpty else { continue }
            let network = Network(chain: token.chain, contract: contract,
                                  decimals: token.decimals, logoURI: token.logoURI)
            if let existing = bucket[token.symbol] {
                guard !existing.networks.contains(where: { $0.chain == token.chain }) else { continue }
                bucket[token.symbol] = (existing.name, existing.networks + [network])
            } else {
                bucket[token.symbol] = (token.name, [network])
            }
        }
        let nativeRows = SupportedChain.allCases.filter { natives[$0] == true }.map { SwapAsset.native($0) }
        let tokenRows = bucket.map { symbol, value in
            SwapAsset.token(symbol: symbol, name: value.name, networks: value.networks)
        }.sorted { a, b in
            guard case let .token(symA, _, _) = a, case let .token(symB, _, _) = b else { return false }
            return symA < symB
        }
        return nativeRows + tokenRows
    }
}

// MARK: - Logo resolution (mirrors ReceiveAsset.canonicalChainForLogo)

extension SwapAsset {
    /// Canonical chain for fetching this asset's mark from Trust Wallet's
    /// repo (Rule #7). Native → its own chain. Token → Ethereum when it
    /// ships there (the canonical brand mark for cross-chain stablecoins),
    /// otherwise the first network in `SupportedChain.allCases` order.
    var canonicalChainForLogo: SupportedChain {
        switch self {
        case .native(let chain):
            return chain
        case .token(_, _, let networks):
            if networks.contains(where: { $0.chain == .ethereum }) { return .ethereum }
            return networks.first?.chain ?? .ethereum
        }
    }

    /// The contract on `canonicalChainForLogo` (nil for native rows → the
    /// bundled chain mark). Carried by the `Network` we already folded, so
    /// no registry lookup is needed.
    var canonicalContract: String? {
        guard case let .token(_, _, networks) = self else { return nil }
        let chain = canonicalChainForLogo
        return networks.first(where: { $0.chain == chain })?.contract
    }

    /// Per-network `logoURI` (custom-token icons / provider icons) for the
    /// canonical logo chain, if any.
    var canonicalLogoURI: String? {
        guard case let .token(_, _, networks) = self else { return nil }
        let chain = canonicalChainForLogo
        return networks.first(where: { $0.chain == chain })?.logoURI
    }
}

// MARK: - SwapToken builder for app/custom assets (enforces quote invariants)

extension SwapToken {
    /// Build a NON-native `SwapToken` for a supported/custom token on a
    /// swappable chain. Returns `nil` when the chain isn't swappable or the
    /// contract is empty — so every token this produces satisfies the
    /// quote invariants (chain ∈ swappable, `kind` matches the family, a
    /// real non-empty contract/mint, the network's own decimals). Native
    /// coins must go through `SwapChainMap.nativeToken(for:)` instead.
    static func swappable(
        chain: SupportedChain,
        contract: String,
        symbol: String,
        name: String,
        decimals: Int,
        logoURI: String?
    ) -> SwapToken? {
        guard let kind = SwapChainMap.kind(for: chain) else { return nil }
        let trimmed = contract.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SwapToken(
            chain: chain,
            kind: kind,
            address: trimmed,
            symbol: symbol,
            name: name,
            decimals: decimals,
            logoURI: logoURI
        )
    }
}
