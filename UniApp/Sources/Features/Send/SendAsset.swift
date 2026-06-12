import Foundation

/// The concrete thing being sent — a single `(asset, network)` pair.
///
/// **Why send-shaped, not receive-shaped.** `ReceiveAsset` is a list row
/// that may span many networks ("USDC on 13 networks") because the user
/// hasn't yet committed to one. A *send* is always to exactly one network
/// — you sign one transaction on one chain. So `SendAsset` carries the
/// resolved network directly:
///
/// - `.native(chain)` — the chain's own coin (BTC on Bitcoin, ETH on
///   Ethereum, SOL on Solana, …). The network IS the chain.
/// - `.token(symbol, name, network, contract)` — a fungible token on one
///   specific network (USDC on Polygon, USDT on Tron, …). The contract is
///   threaded so the fee model and the (future) signing path know which
///   token-transfer to build.
///
/// The amount / review / advanced screens all read `network` to shape
/// themselves, so the flow works for **any** selected asset — not just
/// ETH. The Advanced sheet branches on `network.family` (Rule: never show
/// a control a chain doesn't have).
enum SendAsset: Hashable, Sendable, Identifiable, Codable {
    case native(SupportedChain)
    case token(symbol: String, name: String, network: SupportedChain, contract: String?)

    var id: String {
        switch self {
        case .native(let chain):
            return "native.\(chain.rawValue)"
        case let .token(symbol, _, network, _):
            return "token.\(symbol).\(network.rawValue)"
        }
    }

    /// The network the send executes on.
    var network: SupportedChain {
        switch self {
        case .native(let chain):            return chain
        case let .token(_, _, network, _):  return network
        }
    }

    /// The ticker shown beside the amount numerals.
    var unitTicker: String {
        switch self {
        case .native(let chain):           return chain.ticker
        case let .token(symbol, _, _, _):  return symbol
        }
    }

    /// Display name for chrome (the asset row, the review tile subtitle).
    var displayName: String {
        switch self {
        case .native(let chain):          return chain.displayName
        case let .token(_, name, _, _):   return name
        }
    }

    /// Decimal places for amount entry / formatting. Native = chain's
    /// native decimals; tokens default to the registry's decimals where
    /// known, else 6 (the most common stablecoin precision). The mock
    /// layer doesn't need exact token decimals; the real send path
    /// (T-061) threads the registry decimals here.
    var decimals: Int {
        switch self {
        case .native(let chain):
            return chain.nativeDecimals
        case .token:
            // `// TODO: (T-061)` thread registry decimals per token.
            return 6
        }
    }

    /// The token's contract address on its network, used by `CoinMark`
    /// to resolve the Trust Wallet mark. `nil` for native assets and for
    /// tokens whose contract isn't carried (non-EVM where the registry
    /// keys differently).
    var contract: String? {
        switch self {
        case .native:                         return nil
        case let .token(_, _, _, contract):   return contract
        }
    }

    /// Whether this asset can be signed-and-sent by the active wallet.
    /// Watch-only wallets can't send. For the design every asset is
    /// sendable; the real gate reads the wallet's signing capability.
    /// `// TODO: (T-064)`.
    var isSendable: Bool { true }
}

extension SendAsset {
    /// Builds the full list of sendable assets for the active wallet —
    /// the union of every native chain the wallet has an address for +
    /// every (token, network) pair from every registry, mirroring
    /// `ReceiveAsset.tokens(...)` coverage exactly so the Send asset
    /// picker is never narrower than Receive.
    ///
    /// Unlike `ReceiveAsset` (which folds a token across networks into
    /// one row), this expands each token into one row **per network** —
    /// because a send commits to one network, the user picks the
    /// network here, not in a second step. USDC on 13 networks becomes
    /// 13 selectable `SendAsset.token` rows, grouped under USDC in the
    /// picker UI.
    ///
    /// **Design-time note.** The real balance-aware ordering (assets the
    /// wallet actually holds first, dust last) lands with T-061. For the
    /// design, the list is ordered native-first then tokens by symbol.
    static func sendable(
        availableChains: Set<SupportedChain>,
        customTokens: [CustomTokenSnapshot] = []
    ) -> [SendAsset] {
        var natives: [SendAsset] = []
        for chain in SupportedChain.allCases where availableChains.contains(chain) {
            natives.append(.native(chain))
        }

        // Reuse `ReceiveAsset.tokens(...)` as the canonical registry
        // union (every chain/token the wallet holds), then expand each
        // multi-network token into per-network `SendAsset` rows.
        let tokenRows = ReceiveAsset.tokens(
            availableChains: availableChains,
            customTokens: customTokens
        )

        var tokens: [SendAsset] = []
        for row in tokenRows {
            guard case let .token(symbol, name, chains) = row else { continue }
            for chain in chains {
                tokens.append(
                    .token(
                        symbol: symbol,
                        name: name,
                        network: chain,
                        contract: contractFor(symbol: symbol, chain: chain)
                    )
                )
            }
        }

        return natives + tokens
    }

    /// Resolve a token's contract on a chain for the Trust Wallet mark.
    /// EVM registry only for now; other families key differently and
    /// the mock layer doesn't need their contracts. `// TODO: (T-061)`
    /// thread non-EVM token identifiers when the real send path lands.
    private static func contractFor(symbol: String, chain: SupportedChain) -> String? {
        guard chain.family == .evm else { return nil }
        return EVMTokenRegistry.tokens(for: chain)
            .first(where: { $0.symbol == symbol })?
            .contract
    }
}
