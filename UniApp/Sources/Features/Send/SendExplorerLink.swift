import Foundation

/// Maps a confirmed/pending transaction hash to its canonical, human-facing
/// block-explorer URL so the "Sent" state can offer an honest "View on
/// explorer" link (Rule #16 — the hash is real, and the user can verify it
/// on a third-party explorer they trust, not only inside Aperture).
///
/// **Why a separate helper from the RPC registry.** `RPCRegistry` holds the
/// *data* endpoints (publicnode / Esplora / Blockbook) the app reads
/// balances and history from — machine APIs. An explorer URL is the
/// *human* surface: a web page a person opens in Safari to see the tx in
/// context. They're different concerns; conflating them would couple the
/// fetch layer to a presentation detail.
///
/// **Scheme per chain.** Each chain's explorer takes the transaction id in
/// a chain-specific path. EVM chains use the per-chain Etherscan-family
/// explorer keyed on the same `chainId` the signer uses
/// (`EVMChainIdentity`), so the chain id is the single source of truth and
/// there's no second list to drift. Non-EVM chains use their established
/// canonical explorers (`mempool.space`, `solscan.io`, `tronscan.org`, …).
///
/// **Honesty (Rule #16).** When no explorer is known for a chain, this
/// returns `nil` and the UI hides the link rather than linking to a page
/// that may not resolve. The transaction is still real; the *external view*
/// is simply not offered.
enum TransactionExplorer {

    /// The canonical block-explorer URL for `hash` on `chain`, or `nil`
    /// when no explorer is wired (the UI hides the link in that case).
    static func url(for hash: String, chain: SupportedChain) -> URL? {
        let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if chain.family == .evm {
            return evmURL(for: trimmed, chain: chain)
        }

        guard let base = nonEVMBase(for: chain) else { return nil }
        return URL(string: base + trimmed)
    }

    // MARK: - EVM

    /// EVM explorers, keyed on the EIP-155 `chainId` the signer already
    /// owns (`EVMChainIdentity`). Each entry is the chain's canonical
    /// Etherscan-family explorer with a `/tx/` path that accepts the
    /// `0x`-prefixed transaction hash.
    private static func evmURL(for hash: String, chain: SupportedChain) -> URL? {
        guard let chainId = EVMChainIdentity.chainId(for: chain),
              let base = evmExplorerBase(chainId: chainId) else { return nil }
        return URL(string: base + "/tx/" + hash)
    }

    /// Per-`chainId` explorer origin (no trailing slash). The ids match
    /// `EVMChainIdentity.chainId(for:)` exactly so the two never diverge.
    private static func evmExplorerBase(chainId: Int) -> String? {
        switch chainId {
        case 1:      return "https://etherscan.io"            // Ethereum
        case 56:     return "https://bscscan.com"             // BNB Chain
        case 137:    return "https://polygonscan.com"         // Polygon
        case 42161:  return "https://arbiscan.io"             // Arbitrum One
        case 8453:   return "https://basescan.org"            // Base
        case 10:     return "https://optimistic.etherscan.io" // Optimism
        case 43114:  return "https://snowtrace.io"            // Avalanche C-Chain
        case 534352: return "https://scrollscan.com"          // Scroll
        case 324:    return "https://explorer.zksync.io"      // zkSync Era
        case 42220:  return "https://celoscan.io"             // Celo
        case 2222:   return "https://kavascan.io"             // Kava EVM
        case 204:    return "https://opbnb.bscscan.com"       // opBNB
        default:     return nil
        }
    }

    // MARK: - Non-EVM

    /// Canonical explorer base (including the path prefix that precedes the
    /// raw transaction id) for non-EVM chains. The id is appended verbatim.
    private static func nonEVMBase(for chain: SupportedChain) -> String? {
        switch chain {
        // Bitcoin family — mempool.space (BTC/LTC) + Blockchair (BCH/DOGE).
        case .bitcoin:     return "https://mempool.space/tx/"
        case .litecoin:    return "https://litecoinspace.org/tx/"
        case .bitcoinCash: return "https://blockchair.com/bitcoin-cash/transaction/"
        case .dogecoin:    return "https://blockchair.com/dogecoin/transaction/"

        // ed25519 family.
        case .solana:      return "https://solscan.io/tx/"
        case .stellar:     return "https://stellar.expert/explorer/public/tx/"
        case .sui:         return "https://suiscan.xyz/mainnet/tx/"

        // Other families.
        case .ripple:      return "https://xrpscan.com/tx/"
        case .tron:        return "https://tronscan.org/#/transaction/"
        case .aptos:       return "https://explorer.aptoslabs.com/txn/"
        case .near:        return "https://nearblocks.io/txns/"
        case .polkadot:    return "https://polkadot.subscan.io/extrinsic/"
        case .ton:         return "https://tonviewer.com/transaction/"
        case .kava:        return "https://www.mintscan.io/kava/tx/"

        // EVM chains are handled by `evmURL` — never reached here.
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
            return nil
        }
    }
}
