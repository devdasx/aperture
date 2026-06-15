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
    /// `SwapQuoteService.searchTokens`) into `SwapAsset` rows — one row per
    /// symbol, networks merged across providers (so a token found on several
    /// EVM chains + Solana is a single row carrying all of them). Native
    /// sentinels collapse to `.native`.
    ///
    /// **Ranking (the fix for "real Chainlink is buried").** Rows are ranked
    /// by, in order: how exactly they MATCH the query (exact > prefix >
    /// contains), then how many NETWORKS the token spans — a canonical
    /// multi-chain token (LINK on 10+ chains) beats a single-chain scam
    /// look-alike ("ChainlinkOnSol"). Ties keep the providers' own relevance
    /// order (which already ranks the real token first). It does NOT sort
    /// alphabetically by symbol — that bug pushed "$LINK"/"CHA" above "LINK".
    static func fromProviderTokens(_ tokens: [SwapToken], query: String = "") -> [SwapAsset] {
        var nativeOrder: [SupportedChain] = []
        var nativeSeen = Set<SupportedChain>()
        var bucket: [String: (name: String, networks: [Network])] = [:]
        var symbolOrder: [String] = []   // first-seen order = provider relevance

        for token in tokens {
            if token.isNative {
                if !nativeSeen.contains(token.chain) {
                    nativeSeen.insert(token.chain)
                    nativeOrder.append(token.chain)
                }
                continue
            }
            // A non-native token with an empty contract can't be swapped (it
            // would resolve to a nil SwapToken → a dead-tap row). Drop it.
            let contract = token.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contract.isEmpty else { continue }
            let network = Network(chain: token.chain, contract: contract,
                                  decimals: token.decimals, logoURI: token.logoURI)
            if var existing = bucket[token.symbol] {
                guard !existing.networks.contains(where: { $0.chain == token.chain }) else { continue }
                existing.networks.append(network)
                bucket[token.symbol] = existing
            } else {
                bucket[token.symbol] = (token.name, [network])
                symbolOrder.append(token.symbol)
            }
        }

        let nativeRows = nativeOrder.map { SwapAsset.native($0) }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokenRows = symbolOrder.enumerated()
            .map { index, symbol -> (asset: SwapAsset, score: Int, networks: Int, order: Int) in
                let value = bucket[symbol]!
                return (
                    .token(symbol: symbol, name: value.name, networks: value.networks),
                    Self.matchScore(query: q, symbol: symbol, name: value.name),
                    value.networks.count,
                    index
                )
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.networks != b.networks { return a.networks > b.networks }
                return a.order < b.order
            }
            .map(\.asset)

        return nativeRows + tokenRows
    }

    /// Textual relevance of a (symbol, name) to a lowercased query: 3 =
    /// exact, 2 = prefix, 1 = contains, 0 = no textual match (still shown —
    /// the provider returned it). Ordering only.
    private static func matchScore(query q: String, symbol: String, name: String) -> Int {
        guard !q.isEmpty else { return 0 }
        let s = symbol.lowercased()
        let n = name.lowercased()
        if s == q || n == q { return 3 }
        if s.hasPrefix(q) || n.hasPrefix(q) { return 2 }
        if s.contains(q) || n.contains(q) { return 1 }
        return 0
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
