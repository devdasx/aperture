import Foundation
import SwiftData
import WalletCore

/// Resolves the active wallet's wallet-core signing key + address for a
/// given chain. Generalizes `EVMDAppSigner`'s proven custody pattern to
/// every supported family.
///
/// **Custody boundaries (Rule #16 — honest by construction).** Only
/// mnemonic-backed wallets (`created` / `importedMnemonic`) whose phrase
/// is still on the device and that carry no BIP-39 passphrase can sign;
/// everything else throws `walletCannotSign` rather than producing a
/// wrong-key signature. The mnemonic and the derived `PrivateKey` are
/// locals that drop at function exit; nothing key-shaped is logged.
///
/// **Off-main (Rule #28).** `nonisolated` + a private background
/// `ModelContext` + the (now non-`@MainActor`) `MnemonicVault`, so the
/// PBKDF2 seed stretch + HD derivation never touch the main thread.
enum ChainKeyProvider {

    /// The wallet-core coin used for HD key derivation. Every EVM chain
    /// shares Ethereum's secp256k1 derivation (the chain id differentiates
    /// the transaction, not the key); each non-EVM family has its own.
    static func coinType(for chain: SupportedChain) -> CoinType {
        switch chain {
        case .bitcoin:      return .bitcoin
        case .bitcoinCash:  return .bitcoinCash
        case .litecoin:     return .litecoin
        case .dogecoin:     return .dogecoin
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
            return .ethereum
        case .solana:       return .solana
        case .ripple:       return .xrp
        case .stellar:      return .stellar
        case .sui:          return .sui
        case .ton:          return .ton
        case .tron:         return .tron
        case .aptos:        return .aptos
        case .near:         return .near
        case .polkadot:     return .polkadot
        case .kava:         return .kava
        }
    }

    /// Derive the signing key + sender address for `chain` from the active
    /// wallet's on-device mnemonic. Runs off the main actor.
    nonisolated static func signingMaterial(
        for chain: SupportedChain
    ) throws(ChainSendError) -> (key: PrivateKey, address: String) {
        let words = try activeSigningWords()
        guard let wallet = HDWallet(mnemonic: words.joined(separator: " "), passphrase: "") else {
            throw .signingFailed("Could not reconstruct the wallet key.")
        }
        let coin = coinType(for: chain)
        let key = wallet.getKeyForCoin(coin: coin)
        let address = wallet.getAddressForCoin(coin: coin)
        guard !address.isEmpty else {
            throw .signingFailed("Could not derive the \(chain.displayName) address.")
        }
        return (key, address)
    }

    // MARK: - Active wallet mnemonic (custody-checked, off-main)

    private nonisolated static func activeSigningWords() throws(ChainSendError) -> [String] {
        guard let record = activeWallet() else { throw .walletCannotSign }
        switch record.kind {
        case .created, .importedMnemonic:
            break
        case .importedKey, .watchOnly:
            throw .walletCannotSign
        }
        // A BIP-39 passphrase is never persisted; deriving with an empty
        // one would sign with the WRONG key. Refuse honestly.
        guard !record.hasPassphrase else { throw .walletCannotSign }

        let stored = (try? MnemonicVault.loadMnemonic(for: record.id)) ?? nil
        guard let words = stored, !words.isEmpty else {
            throw .walletCannotSign  // backed-up wallets keep only the seed
        }
        return words
    }

    /// Same active-wallet contract as `EVMDAppSigner` / `ActiveWalletReader`
    /// (shared `activeWalletId` default, first wallet as fallback), via a
    /// background `ModelContext` so it's safe off the main actor.
    private nonisolated static func activeWallet() -> WalletRecord? {
        let activeId = UserDefaults.standard.string(forKey: "activeWalletId") ?? ""
        let context = ModelContext(ApertureDatabase.shared.container)
        if let activeUUID = UUID(uuidString: activeId) {
            var descriptor = FetchDescriptor<WalletRecord>(
                predicate: #Predicate { $0.id == activeUUID }
            )
            descriptor.fetchLimit = 1
            if let match = (try? context.fetch(descriptor))?.first {
                return match
            }
        }
        var fallback = FetchDescriptor<WalletRecord>()
        fallback.fetchLimit = 1
        return (try? context.fetch(fallback))?.first
    }
}
