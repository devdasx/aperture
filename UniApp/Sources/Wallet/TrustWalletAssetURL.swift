import Foundation

/// Builds Trust Wallet `trustwallet/assets` raw GitHub URLs for token
/// logos. Per M-001, Trust Wallet's assets repo is the authoritative
/// source for crypto brand marks — we already bundle native-chain
/// logos from there; for fungible tokens we load remotely (the repo
/// is too large to bundle every token Aperture might one day
/// support, and the URL is stable on `master`).
///
/// **URL shape:**
///   `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/<slug>/assets/<address>/logo.png`
///
/// **Address case** matters for the EVM repo path — Trust Wallet
/// stores tokens by their EIP-55 checksummed address. Aperture's
/// `EVMTokenRegistry` already uses checksummed addresses verbatim,
/// so we pass the contract through unchanged. Solana mints are
/// case-sensitive base58 and also pass through unchanged.
enum TrustWalletAssetURL {

    /// Trust Wallet's `blockchains/<slug>` directory name for each
    /// supported chain. Matches `registry.json` from the
    /// `trustwallet/wallet-core` repo (audited 2026-06-06).
    static func slug(for chain: SupportedChain) -> String? {
        switch chain {
        case .bitcoin:      return "bitcoin"
        case .bitcoinCash:  return "bitcoincash"
        case .litecoin:     return "litecoin"
        case .dogecoin:     return "doge"
        case .ethereum:     return "ethereum"
        case .arbitrum:     return "arbitrum"
        case .base:         return "base"
        case .optimism:     return "optimism"
        case .scroll:       return "scroll"
        case .zkSync:       return "zksync"
        case .polygon:      return "polygon"
        case .bnbChain:     return "smartchain"
        case .opBNB:        return "opbnb"
        case .avalanche:    return "avalanchec"
        case .celo:         return "celo"
        case .kavaEvm:      return "kavaevm"
        case .solana:       return "solana"
        case .ripple:       return "ripple"
        case .stellar:      return "stellar"
        case .near:         return "near"
        case .ton:          return "ton"
        case .tron:         return "tron"
        case .polkadot:     return "polkadot"
        case .aptos:        return "aptos"
        case .sui:          return "sui"
        case .kava:         return "kava"
        }
    }

    /// Logo URL for a fungible token (ERC-20 / SPL / TRC-20 / …)
    /// hosted in `trustwallet/assets`. Returns `nil` if the chain
    /// isn't in `slug(for:)` — caller falls back to a monogram.
    static func tokenLogoURL(chain: SupportedChain, contract: String) -> URL? {
        guard let slug = slug(for: chain) else { return nil }
        let urlString = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(slug)/assets/\(contract)/logo.png"
        return URL(string: urlString)
    }
}
