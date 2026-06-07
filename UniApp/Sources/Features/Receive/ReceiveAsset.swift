import Foundation

/// Value type describing a single tappable row in the Receive sheet's
/// Step 1 asset list. Two shapes:
///
/// - `.native(chain)` — the chain's own coin (BTC, ETH, SOL, …).
///   Tapping routes directly to the QR step; no network picker is
///   needed because the network IS the chain.
/// - `.token(symbol, name, chains)` — a fungible token that ships on
///   one or more supported networks (USDC on 13 networks, USDT on N,
///   DAI, etc.). Tapping routes to a network picker so the user can
///   choose the network the sender will use.
///
/// The list is the union of every native chain the active wallet has a
/// derived address for + every token symbol curated across
/// `EVMTokenRegistry` ∪ `SolanaTokenRegistry`.
enum ReceiveAsset: Hashable, Sendable, Identifiable {
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

extension ReceiveAsset {
    /// Builds the unique list of tokens (symbol + name + supporting
    /// chains) across every registry. Symbols are folded so "USDC" on
    /// 12 EVM chains + Solana is one row whose `chains` array has 13
    /// entries.
    ///
    /// **Why filter `availableChains`.** Receiving USDC on Polygon
    /// requires the wallet to have a Polygon address. If the user
    /// imported a single Bitcoin watch-only address, USDC won't appear
    /// — there's nowhere to receive it. The list reflects the wallet,
    /// not the abstract registry.
    static func tokens(availableChains: Set<SupportedChain>) -> [ReceiveAsset] {
        // [symbol: (name, [chain])] — collected then sorted.
        var bucket: [String: (name: String, chains: [SupportedChain])] = [:]

        @inline(__always)
        func add(_ symbol: String, _ name: String, _ chain: SupportedChain) {
            if let existing = bucket[symbol] {
                bucket[symbol] = (existing.name, existing.chains + [chain])
            } else {
                bucket[symbol] = (name, [chain])
            }
        }

        // EVM side (12 chains).
        for chain in availableChains where chain.family == .evm {
            for entry in EVMTokenRegistry.tokens(for: chain) {
                add(entry.symbol, entry.name, chain)
            }
        }

        // Solana side.
        if availableChains.contains(.solana) {
            for entry in SolanaTokenRegistry.mints.values {
                add(entry.symbol, entry.name, .solana)
            }
        }

        // TRON (TRC-20).
        if availableChains.contains(.tron) {
            for entry in TronTokenRegistry.tokens {
                add(entry.symbol, entry.name, .tron)
            }
        }

        // NEAR (NEP-141).
        if availableChains.contains(.near) {
            for entry in NearTokenRegistry.tokens {
                add(entry.symbol, entry.name, .near)
            }
        }

        // Aptos (fungible asset / Aptos Coin).
        if availableChains.contains(.aptos) {
            for entry in AptosTokenRegistry.tokens {
                add(entry.symbol, entry.name, .aptos)
            }
        }

        // Polkadot (Asset Hub).
        if availableChains.contains(.polkadot) {
            for entry in PolkadotAssetRegistry.tokens {
                add(entry.symbol, entry.name, .polkadot)
            }
        }

        // XRP Ledger (IOU).
        if availableChains.contains(.ripple) {
            for entry in XRPLTokenRegistry.tokens {
                add(entry.symbol, entry.name, .ripple)
            }
        }

        // TON (TIP-3 Jetton).
        if availableChains.contains(.ton) {
            for entry in TONJettonRegistry.tokens {
                add(entry.symbol, entry.name, .ton)
            }
        }

        // Kava (Cosmos IBC).
        if availableChains.contains(.kava) {
            for entry in KavaCosmosTokenRegistry.tokens {
                add(entry.symbol, entry.name, .kava)
            }
        }

        // Sort: by descending network count, then alphabetically by
        // symbol. USDC (many networks) lands ahead of niche tokens.
        return bucket
            .map { (symbol, value) in
                ReceiveAsset.token(
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

    /// Canonical chain to use when fetching this token's logo from
    /// Trust Wallet's repo. Picks Ethereum first when the token ships
    /// there (because that's the canonical brand mark for cross-chain
    /// stablecoins), otherwise the first chain in the supported list.
    var canonicalChainForLogo: SupportedChain? {
        guard case let .token(_, _, chains) = self else { return nil }
        if chains.contains(.ethereum) { return .ethereum }
        return chains.first
    }

    /// Token's contract address on its `canonicalChainForLogo`, used
    /// to build the Trust Wallet logo URL. `nil` for native rows or
    /// when no registry entry exists.
    var canonicalContract: String? {
        guard case let .token(symbol, _, _) = self,
              let chain = canonicalChainForLogo,
              chain.family == .evm else {
            return nil
        }
        return EVMTokenRegistry.tokens(for: chain)
            .first(where: { $0.symbol == symbol })?
            .contract
    }
}
