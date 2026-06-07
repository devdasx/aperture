import Foundation

/// Aperture's supported chains for wallet import. Mirrors the canonical
/// list in `SUPPORTED_ASSETS.md` (27 networks across five families).
///
/// **Why a separate enum from `SupportedAsset` / `SupportedCurrency`.**
/// `SupportedCurrency` is fiat (USD, EUR, …); `SupportedAsset` is a
/// token (BTC, ETH, USDC, …); `SupportedChain` is the **network** on
/// which keys / addresses live. Import flows are chain-scoped because
/// the private-key format and address derivation differ per chain.
///
/// **Family.** Five cryptographic families. Used by the import flow
/// to share parsers (one EVM parser handles every EVM chain; one
/// Bitcoin-family parser handles BTC/BCH/LTC/DOGE; etc.).
enum SupportedChain: String, CaseIterable, Hashable, Sendable, Codable {
    // Bitcoin family
    case bitcoin
    case bitcoinCash
    case litecoin
    case dogecoin

    // EVM family
    case ethereum
    case arbitrum
    case base
    case optimism
    case scroll
    case zkSync
    case polygon
    case bnbChain
    case opBNB
    case avalanche
    case celo
    case kavaEvm

    // Other families
    case aptos
    case near
    case polkadot
    case ripple
    case solana
    case stellar
    case sui
    case ton
    case tron
    case kava

    /// Cryptographic family. Used to share parsers across sibling chains.
    var family: ChainFamily {
        switch self {
        case .bitcoin, .bitcoinCash, .litecoin, .dogecoin:
            return .bitcoin
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
            return .evm
        case .solana, .stellar, .sui:
            return .ed25519
        case .ripple:
            return .ripple
        case .kava:
            return .cosmos
        case .aptos:    return .aptos
        case .near:     return .near
        case .polkadot: return .polkadot
        case .ton:      return .ton
        case .tron:     return .tron
        }
    }

    /// Whether the chain supports BIP-32 extended public keys
    /// (xpub / ypub / zpub) for watch-only import. Only the Bitcoin
    /// family does.
    var supportsExtendedPublicKey: Bool {
        family == .bitcoin
    }

    /// Human-readable display name (English source, catalog-localized
    /// at call sites via `LocalizedStringKey(chain.displayName)`).
    var displayName: String {
        switch self {
        case .bitcoin:      return "Bitcoin"
        case .bitcoinCash:  return "Bitcoin Cash"
        case .litecoin:     return "Litecoin"
        case .dogecoin:     return "Dogecoin"
        case .ethereum:     return "Ethereum"
        case .arbitrum:     return "Arbitrum"
        case .base:         return "Base"
        case .optimism:     return "Optimism"
        case .scroll:       return "Scroll"
        case .zkSync:       return "zkSync Era"
        case .polygon:      return "Polygon"
        case .bnbChain:     return "BNB Chain"
        case .opBNB:        return "opBNB"
        case .avalanche:    return "Avalanche"
        case .celo:         return "Celo"
        case .kavaEvm:      return "Kava EVM"
        case .aptos:        return "Aptos"
        case .near:         return "NEAR"
        case .polkadot:     return "Polkadot"
        case .ripple:       return "XRP Ledger"
        case .solana:       return "Solana"
        case .stellar:      return "Stellar"
        case .sui:          return "Sui"
        case .ton:          return "TON"
        case .tron:         return "TRON"
        case .kava:         return "Kava"
        }
    }

    /// Native-coin ticker (verbatim, not localized).
    var ticker: String {
        switch self {
        case .bitcoin:      return "BTC"
        case .bitcoinCash:  return "BCH"
        case .litecoin:     return "LTC"
        case .dogecoin:     return "DOGE"
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync:
            return "ETH"
        case .polygon:      return "POL"
        case .bnbChain, .opBNB:
            return "BNB"
        case .avalanche:    return "AVAX"
        case .celo:         return "CELO"
        case .kavaEvm, .kava: return "KAVA"
        case .aptos:        return "APT"
        case .near:         return "NEAR"
        case .polkadot:     return "DOT"
        case .ripple:       return "XRP"
        case .solana:       return "SOL"
        case .stellar:      return "XLM"
        case .sui:          return "SUI"
        case .ton:          return "TON"
        case .tron:         return "TRX"
        }
    }

    /// Asset catalog name for the chain's logo. Routes through the
    /// `Crypto/` namespace in `Assets.xcassets` (per M-001 — Trust
    /// Wallet bundled assets). Returns `nil` if no logo is bundled;
    /// the UI shows a placeholder in that case.
    var logoAssetName: String? {
        // The `Crypto/` folder in Assets.xcassets has
        // `provides-namespace: true`, so call-site `Image(name)`
        // expects the namespace prefix.
        switch self {
        case .bitcoin:      return "Crypto/btc"
        case .bitcoinCash:  return "Crypto/bch"
        case .litecoin:     return "Crypto/ltc"
        case .dogecoin:     return "Crypto/doge"
        case .ethereum:     return "Crypto/eth"
        case .arbitrum:     return "Crypto/arbitrum"
        case .base:         return "Crypto/base"
        case .optimism:     return "Crypto/optimism"
        case .scroll:       return "Crypto/scroll"
        case .zkSync:       return "Crypto/zksync"
        case .polygon:      return "Crypto/pol"
        case .bnbChain:     return "Crypto/bnb"
        case .opBNB:        return "Crypto/opbnb"
        case .avalanche:    return "Crypto/avax"
        case .celo:         return "Crypto/celo"
        case .kavaEvm, .kava: return "Crypto/kava"
        case .aptos:        return "Crypto/apt"
        case .near:         return "Crypto/near"
        case .polkadot:     return "Crypto/dot"
        case .ripple:       return "Crypto/xrp"
        case .solana:       return "Crypto/sol"
        case .stellar:      return "Crypto/xlm"
        case .sui:          return "Crypto/sui"
        case .ton:          return "Crypto/ton"
        case .tron:         return "Crypto/trx"
        }
    }
}

extension SupportedChain {
    /// Short, clearly-labeled-as-fake example of a private-key format
    /// for this chain. Used as the caption below the entry field
    /// (Rule #18 §D — examples must never look real). The `…` is
    /// mandatory; the trailing parenthetical names the format.
    var exampleKeyPreview: String {
        switch family {
        case .bitcoin:  return "L1aW4aubDFB7y… (WIF)"
        case .evm:      return "0x0000…0001 (32-byte hex)"
        case .ed25519:  return "3Mz4…example… (base58 secret key)"
        case .ripple:   return "sEd…example… (XRP family seed)"
        case .cosmos:   return "0x…example… (hex)"
        case .aptos:    return "0x…example… (Aptos hex)"
        case .near:     return "ed25519:…example… (NEAR)"
        case .polkadot: return "0x…example… (Polkadot hex)"
        case .ton:      return "0x…example… (TON ed25519 hex)"
        case .tron:     return "0x…example… (TRON hex)"
        }
    }

    /// Short, fake address example for this chain. Used as the caption
    /// below the watch-only address field.
    var exampleAddressPreview: String {
        switch self {
        case .bitcoin:      return "bc1q…example…example"
        case .bitcoinCash:  return "qz…example…example"
        case .litecoin:     return "ltc1…example…example"
        case .dogecoin:     return "D…example…example"
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
            return "0x0000…example…0000"
        case .solana:       return "So1ana…Example…111"
        case .stellar:      return "GAEx…example…AMPLE"
        case .sui:          return "0x…example…sui"
        case .ripple:       return "rEx4mp…example…le"
        case .kava:         return "kava1…example…kava"
        case .aptos:        return "0x…example…aptos"
        case .near:         return "example.near"
        case .polkadot:     return "1…example…polkadot"
        case .ton:          return "EQ…example…ton"
        case .tron:         return "TEx4mp…example…le"
        }
    }

    /// Optional extended-public-key example. Only Bitcoin-family
    /// chains support xpub/ypub/zpub — for everyone else returns nil.
    var exampleExtendedKeyPreview: String? {
        guard supportsExtendedPublicKey else { return nil }
        return "zpub6r…example… (extended public key)"
    }
}

/// Cryptographic family of a chain. Drives parser selection in
/// `KeyImportService`.
extension SupportedChain {
    /// Number of decimal places the chain's native amounts are
    /// expressed at on-chain. EVM = 18 (wei → ETH), Bitcoin family
    /// = 8 (satoshis → BTC), Solana = 9 (lamports → SOL), etc.
    /// Used by chain adapters to convert raw integer balances back
    /// into `Decimal` chain-units for display.
    var nativeDecimals: Int {
        switch self {
        case .bitcoin, .bitcoinCash, .dogecoin, .litecoin:   return 8
        case .ethereum, .arbitrum, .base, .optimism, .scroll,
             .zkSync, .polygon, .bnbChain, .opBNB,
             .avalanche, .celo, .kavaEvm:                    return 18
        case .solana, .sui, .ton:                            return 9
        case .stellar:                                       return 7
        case .ripple, .tron, .kava:                          return 6
        case .aptos:                                         return 8
        case .near:                                          return 24
        case .polkadot:                                      return 10
        }
    }
}

enum ChainFamily: String, Hashable, Sendable {
    case bitcoin   // secp256k1 + BIP-32/44 + base58check
    case evm       // secp256k1 + keccak256
    case ed25519   // Solana / Stellar / Sui
    case ripple    // secp256k1 or ed25519 + ripple encoding
    case cosmos    // secp256k1 + bech32
    case aptos     // ed25519 + Aptos address
    case near      // ed25519 + NEAR account
    case polkadot  // sr25519 / ed25519 + SS58
    case ton       // ed25519 + TON
    case tron      // secp256k1 + TRON address
}
