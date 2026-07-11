import Foundation
import WalletCore

/// Batch per-chain key derivation → AES-GCM sealed blobs, for the
/// per-chain database's `ChainStateRecord.encryptedPrivateKey` column
/// (user direction 2026-06-17: store each chain's key as an encrypted
/// blob in the DB).
///
/// **Performance.** Building an `HDWallet` runs the BIP-39 PBKDF2
/// seed-stretch (the expensive step). Deriving each chain's key from an
/// already-built `HDWallet` is cheap. So this builds the `HDWallet` ONCE
/// and derives every requested chain from it — populating all 24 chains
/// costs one stretch, not 24 separate `withPrivateKey` calls.
///
/// **Security (same contract as `SigningKeyProvider`).** Raw key material
/// — the mnemonic, the `HDWallet`, every `PrivateKey` — lives ONLY inside
/// this function and drops at return. Only the AES-GCM-sealed `Data`
/// blobs escape; plaintext keys never reach GRDB. Each key is
/// parity-checked against the wallet's funded address before sealing, so
/// a wrong-address key is never stored. Best-effort by design: watch-only
/// wallets, backed-up / passphrase wallets without the secret, and any
/// per-chain derivation/parity/seal failure simply produce no entry — key
/// population must never break a refresh.
extension SigningKeyProvider {

    static func encryptedKeyBlobs(
        wallet: WalletDescriptor,
        chainAddresses: [SupportedChain: String],
        passphrase: String? = nil,
        mnemonicWords: [String]? = nil,
        privateKeyString: String? = nil
    ) -> [SupportedChain: Data] {
        guard !chainAddresses.isEmpty else { return [:] }
        switch wallet.kind {
        case .watchOnly:
            return [:]
        case .importedKey:
            return importedKeyBlobs(
                wallet: wallet,
                chainAddresses: chainAddresses,
                privateKeyString: privateKeyString
            )
        case .created, .importedMnemonic:
            return mnemonicKeyBlobs(
                wallet: wallet,
                chainAddresses: chainAddresses,
                passphrase: passphrase,
                mnemonicWords: mnemonicWords
            )
        }
    }

    // MARK: - Mnemonic wallets (one HDWallet, every chain)

    private static func mnemonicKeyBlobs(
        wallet: WalletDescriptor,
        chainAddresses: [SupportedChain: String],
        passphrase: String?,
        mnemonicWords: [String]?
    ) -> [SupportedChain: Data] {
        // Passphrase wallets derived their addresses WITH the passphrase,
        // which is never persisted. Without it we'd derive wrong keys —
        // refuse rather than store a wrong-address key.
        if wallet.hasPassphrase && passphrase == nil { return [:] }
        let resolvedPassphrase = passphrase ?? ""

        guard let words = mnemonicWords,
              !words.isEmpty,
              let hdWallet = HDWallet(mnemonic: words.joined(separator: " "), passphrase: resolvedPassphrase)
        else { return [:] }

        var out: [SupportedChain: Data] = [:]
        for (chain, address) in chainAddresses {
            guard let coin = ChainCoinType.coinType(for: chain) else { continue }
            let privateKey = hdWallet.getKeyForCoin(coin: coin)
            guard addressMatches(privateKey: privateKey, coin: coin, expected: address, chain: chain) else { continue }
            if let blob = try? ChainKeyVault.seal(privateKey.data) { out[chain] = blob }
        }
        return out
        // `words`, `hdWallet`, every `privateKey` drop here.
    }

    // MARK: - Single-private-key wallets

    private static func importedKeyBlobs(
        wallet: WalletDescriptor,
        chainAddresses: [SupportedChain: String],
        privateKeyString: String?
    ) -> [SupportedChain: Data] {
        guard let keyString = privateKeyString,
              !keyString.isEmpty
        else { return [:] }

        var out: [SupportedChain: Data] = [:]
        for (chain, address) in chainAddresses {
            guard let coin = ChainCoinType.coinType(for: chain),
                  let keyData = try? WalletCoreKeyImportService.decodePrivateKeyBytes(keyString, on: chain),
                  PrivateKey.isValid(data: keyData, curve: coin.curve),
                  let privateKey = PrivateKey(data: keyData),
                  addressMatches(privateKey: privateKey, coin: coin, expected: address, chain: chain)
            else { continue }
            if let blob = try? ChainKeyVault.seal(privateKey.data) { out[chain] = blob }
        }
        return out
    }

    // MARK: - Parity (never seal a wrong-address key)

    private static func addressMatches(
        privateKey: PrivateKey,
        coin: CoinType,
        expected: String,
        chain: SupportedChain
    ) -> Bool {
        guard !expected.isEmpty else { return false }
        let derived = coin.deriveAddress(privateKey: privateKey)
        return chain.family == .evm
            ? derived.lowercased() == expected.lowercased()
            : derived == expected
    }
}
