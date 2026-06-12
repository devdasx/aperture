import Foundation

/// **Asset identity for the per-asset detail screen.**
///
/// An "asset" in Aperture's vocabulary is a **symbol family**, not a
/// single (network, contract) pair. USDC is one asset; its presence on
/// Ethereum + Arbitrum + Base + Polygon + Solana is detail, not five
/// assets. The user thinks of "my USDC" as one number across networks;
/// the detail screen renders that number on top and shows the per-
/// network breakdown beneath.
///
/// **Two kinds.**
///
/// 1. **Native coins** carry the chain in the identity. ETH on
///    Ethereum is a different asset from ETH on Arbitrum because they
///    are different chains' native coins (even though the ticker
///    matches). When the user taps the Ethereum coin row on the
///    wallet home, the screen is "ETH on Ethereum" — not aggregated
///    across every chain whose native ticker is `"ETH"`. This is the
///    honest representation because gas balances on different L2s do
///    not pool.
///
/// 2. **Tokens** are matched by symbol across networks. USDC on
///    Ethereum and USDC on Polygon ARE the same asset to the user —
///    they redeem against the same Circle treasury, settle to the same
///    dollar, are bridgeable to each other. The detail screen
///    aggregates across networks for tokens (Σ balance × today's
///    price = aggregate fiat).
///
/// **Why an enum nested inside a struct, not a flat enum.** The
/// `kind` discriminates by case (coin vs token) while every identity
/// carries the same `symbol` field. This keeps Hashable / Codable /
/// Equatable derivable for the whole struct without a custom
/// implementation.
///
/// **Codable** because `NavigationPath` round-trips destinations
/// through Codable when restoring state across app launches.
struct AssetIdentity: Hashable, Codable, Sendable {

    /// Asset ticker — `"ETH"`, `"BTC"`, `"USDC"`, `"DAI"`, etc.
    /// Always uppercase per Aperture's registry convention.
    let symbol: String

    let kind: Kind

    enum Kind: Hashable, Codable, Sendable {
        /// Native chain coin. The chain is part of identity — ETH on
        /// Ethereum is distinct from ETH on Arbitrum even though both
        /// natives use the same ticker.
        case nativeCoin(SupportedChain)

        /// Smart-contract or registry-bridged token. Aggregated by
        /// symbol across every network the token exists on. The
        /// per-network breakdown is resolved at view time from the
        /// registries, not stored in the identity.
        case token
    }

    // MARK: - Convenience constructors

    /// Build an identity for a native coin row on the wallet home.
    static func nativeCoin(_ chain: SupportedChain) -> AssetIdentity {
        AssetIdentity(symbol: chain.ticker, kind: .nativeCoin(chain))
    }

    /// Build an identity for a token row on the wallet home.
    /// Symbol is uppercased so identity equality is case-insensitive
    /// against registry data (Trust Wallet's `USDC` vs a misread
    /// `usdc` collapse to the same identity).
    static func token(symbol: String) -> AssetIdentity {
        AssetIdentity(symbol: symbol.uppercased(), kind: .token)
    }
}

// MARK: - Convenience accessors

extension AssetIdentity {

    /// The chain this asset belongs to, if it's a native coin. Token
    /// identities return `nil` because tokens span networks.
    var nativeChain: SupportedChain? {
        if case .nativeCoin(let chain) = kind { return chain }
        return nil
    }

    /// `true` when the identity is a native coin (single network);
    /// `false` for tokens (potentially multi-network).
    var isNativeCoin: Bool {
        nativeChain != nil
    }
}
