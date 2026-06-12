import SwiftUI

/// Observable shared model for the Import Wallet flow. Mirrors
/// `CreateWalletState`'s shape — `@Observable`, `@MainActor`,
/// instance-per-fullScreenCover.
@MainActor
@Observable
final class ImportWalletState {
    /// Mnemonic words the user is currently entering / has entered.
    /// Length is whatever the user has typed; `BIP39.validate(_:)`
    /// checks completeness for 12 or 24.
    var mnemonicWords: [String] = Array(repeating: "", count: 12)

    /// User-toggled mnemonic length (12 or 24). Defaults to 12.
    var mnemonicWordCount: BIP39WordCount = .twelve {
        didSet {
            // Resize the buffer, preserving leading words.
            let target = mnemonicWordCount.rawValue
            if mnemonicWords.count < target {
                mnemonicWords.append(contentsOf: Array(repeating: "", count: target - mnemonicWords.count))
            } else if mnemonicWords.count > target {
                mnemonicWords.removeLast(mnemonicWords.count - target)
            }
        }
    }

    /// Optional BIP-39 passphrase. In-memory only.
    var mnemonicPassphrase: String = ""

    /// Selected chain for the private-key / watch-only flows.
    var selectedChain: SupportedChain? = nil

    /// Raw private key the user has entered. Kept until commit, then
    /// zeroed by the caller.
    var privateKeyRaw: String = ""

    /// Watch-only entries — addresses (one per line) or an extended
    /// public key, depending on the mode.
    var watchOnlyRaw: String = ""

    /// Whether the Bitcoin watch-only entry is in "Extended key" mode
    /// (default) vs "Addresses" mode. Ignored for non-Bitcoin chains.
    var watchOnlyExtendedKeyMode: Bool = false

    /// Service used for per-chain validation + address derivation.
    /// Backed by Trust Wallet Core (`WalletCoreKeyImportService`) per
    /// Rule #3 §B exception logged in `SHIPPED.md` 2026-06-06.
    /// Delivers real derivation for all 24 chains via the same crypto
    /// library Trust Wallet itself uses.
    let service: any KeyImportService = WalletCoreKeyImportService()

    /// Derived per-chain addresses after a successful mnemonic
    /// derivation. Populated by the review step.
    var derivedAddressesFromMnemonic: [SupportedChain: String] = [:]

    /// Derived address from a private-key entry. Populated by the
    /// private-key review step.
    var derivedAddressFromKey: String = ""

    /// Derived addresses from the watch-only entry. Populated by the
    /// watch-only review step.
    var watchOnlyAddresses: [String] = []

    /// Stable identifier for the wallet being imported. Same role as
    /// `CreateWalletState.pendingWalletId` — used as the `SeedVault`
    /// Keychain key and the `WalletRecord.id` so both writes target
    /// the same logical wallet.
    let pendingWalletId: UUID = UUID()

    /// Persist this import end-to-end via the appropriate
    /// `WalletRepository` shape. Mirrors `CreateWalletState.persist(...)`'s
    /// Keychain-then-database transactional pattern: seed (if any) goes
    /// to Keychain first; on database failure the seed is rolled back.
    ///
    /// `result` tells us which import method finished so we pick the
    /// right repository call (mnemonic → `insertImportedMnemonicWallet`,
    /// privateKey → `insertImportedKeyWallet`, watchOnly →
    /// `insertWatchOnlyWallet`).
    @discardableResult
    func persist(
        result: ImportResult,
        into repository: WalletRepository,
        defaultName: String? = nil
    ) async throws -> UUID {
        let walletId = pendingWalletId
        // Locale-aware auto-numbered default name. `String(localized:)`
        // pulls "Wallet" from the catalog so each language renders its
        // own word ("Кошелёк", "محفظة", "ウォレット"); the counter is
        // `walletCount + 1` so "Wallet 1" / "Wallet 2" sequence
        // matches what the user expects from Phantom / Trust Wallet.
        let resolvedName: String
        if let defaultName, !defaultName.isEmpty {
            resolvedName = defaultName
        } else {
            let existingCount = (try? await repository.walletCount()) ?? 0
            let prefix = String.apertureLocalized("Wallet")
            resolvedName = "\(prefix) \(existingCount + 1)"
        }
        switch result {
        case .mnemonic:
            // BIP-39 mnemonic import — derive the seed and store it
            // in Keychain, then persist the WalletRecord with one
            // address per supported chain (already populated by the
            // mnemonic-review step via `state.service`).
            //
            // PBKDF2 (2048 × HMAC-SHA512) runs off the main actor so
            // the UI doesn't hitch during commit; the Keychain writes
            // below stay on `@MainActor`.
            let seed = await Self.deriveSeedOffMain(
                words: mnemonicWords,
                passphrase: mnemonicPassphrase
            )
            try SeedVault.storeSeed(seed, for: walletId)
            // ALSO store the mnemonic encrypted in `MnemonicVault`
            // so the user can re-view it from Settings → Wallets
            // → "View recovery phrase" at any time. AES-GCM 256-bit
            // + Keychain `WhenPasscodeSetThisDeviceOnly` ACL — the
            // phrase stays on this iPhone and is unreadable while
            // the device is locked. Matches the create-wallet path.
            do {
                try MnemonicVault.storeMnemonic(mnemonicWords, for: walletId)
            } catch {
                try? SeedVault.deleteSeed(for: walletId)
                throw error
            }
            do {
                let addressEntries: [(chainRaw: String, address: String)] =
                    derivedAddressesFromMnemonic.map { (chain, address) in
                        (chainRaw: chain.rawValue, address: address)
                    }
                try await repository.insertImportedMnemonicWallet(
                    id: walletId,
                    name: resolvedName,
                    mnemonicWordCount: mnemonicWordCount.rawValue,
                    hasPassphrase: !mnemonicPassphrase.isEmpty,
                    colorTag: "default",
                    addresses: addressEntries
                )
            } catch {
                try? SeedVault.deleteSeed(for: walletId)
                try? MnemonicVault.deleteMnemonic(for: walletId)
                throw error
            }

        case .privateKey(let chain):
            // Single private-key import — decode the typed key into
            // its raw byte payload, positively identified for `chain`
            // (hex → 32 raw bytes; Bitcoin-family WIF → base58check
            // payload without version byte / compression flag; Solana
            // base58 secret → the 32-byte ed25519 seed). The decoder
            // throws on anything it can't positively identify, so
            // garbage never lands in the Keychain.
            //
            // **Byte format stored:** the 32 raw private-key bytes
            // (secp256k1 scalar or ed25519 seed, per the chain's
            // curve), zero-padded to SeedVault's fixed 64-byte slot —
            // bytes 0..<32 are the key, bytes 32..<64 are zero padding.
            let keyBytes = try WalletCoreKeyImportService.decodePrivateKeyBytes(
                privateKeyRaw,
                on: chain
            )
            try SeedVault.storeSeed(Self.paddedTo64(bytes: keyBytes), for: walletId)
            // ALSO store the original key string (hex / WIF, as typed
            // after trimming) encrypted in `MnemonicVault` so the user
            // can re-view it from Settings → Wallets → "View private
            // key" at any time. The SeedVault slot above holds only the
            // decoded raw bytes — those can't be rendered back to the
            // WIF/base58 form the user imported. AES-GCM 256-bit +
            // Keychain `WhenPasscodeSetThisDeviceOnly` ACL — the key
            // stays on this iPhone and is unreadable while the device
            // is locked. Matches the mnemonic path below.
            do {
                try MnemonicVault.storePrivateKey(
                    privateKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                    for: walletId
                )
            } catch {
                try? SeedVault.deleteSeed(for: walletId)
                throw error
            }
            do {
                try await repository.insertImportedKeyWallet(
                    id: walletId,
                    name: resolvedName,
                    colorTag: "default",
                    chainRaw: chain.rawValue,
                    address: derivedAddressFromKey
                )
            } catch {
                try? SeedVault.deleteSeed(for: walletId)
                try? MnemonicVault.deletePrivateKey(for: walletId)
                throw error
            }

        case .watchOnly(let chain):
            // Watch-only: no key material. SeedVault is skipped on
            // purpose — there's nothing secret to store. Only the
            // validated `watchOnlyAddresses` set persists; the raw
            // entry buffer is never used as a fallback (it may hold
            // entries that failed validation). The review screen
            // hides the commit button while this set is empty.
            guard !watchOnlyAddresses.isEmpty else {
                throw KeyImportError.invalidFormat
            }
            try await repository.insertWatchOnlyWallet(
                id: walletId,
                name: resolvedName,
                colorTag: "default",
                chainRaw: chain.rawValue,
                addresses: watchOnlyAddresses
            )
        }

        // The wallet is fully persisted — make it the active wallet
        // immediately. Same contract as `CreateWalletState.persist`:
        // anything that successfully runs through here becomes the
        // active wallet so the user lands on it after the import
        // success screen and the refresh coordinator starts pulling
        // its balances. Read by every screen via the
        // `"activeWalletId"` `@AppStorage` key.
        UserDefaults.standard.set(
            walletId.uuidString,
            forKey: "activeWalletId"
        )
        return walletId
    }

    /// Zero the sensitive in-memory inputs once persistence has
    /// succeeded (or the entry surface is abandoned). The seed / key
    /// bytes now live encrypted in Keychain; the plaintext words,
    /// passphrase, and raw key string have no reason to outlive the
    /// flow.
    func zeroSensitiveInput() {
        mnemonicWords = []
        mnemonicPassphrase = ""
        privateKeyRaw = ""
    }

    /// Zero-pad raw key bytes to exactly 64 bytes for the SeedVault
    /// fixed-slot contract. The key occupies the leading bytes; the
    /// remainder is zero padding. Inputs longer than 64 bytes are
    /// rejected by the decoder before reaching here, but are truncated
    /// defensively rather than trapping.
    private static func paddedTo64(bytes: Data) -> Data {
        var padded = bytes
        if padded.count < 64 {
            padded.append(contentsOf: [UInt8](repeating: 0, count: 64 - padded.count))
        } else if padded.count > 64 {
            padded = padded.prefix(64)
        }
        return padded
    }

    /// Run the PBKDF2-HMAC-SHA512 BIP-39 seed derivation off the main
    /// actor. The class is `@MainActor`; without this hop the 2048
    /// HMAC iterations would run on the UI thread during commit.
    nonisolated private static func deriveSeedOffMain(
        words: [String],
        passphrase: String
    ) async -> Data {
        await Task.detached(priority: .userInitiated) {
            BIP39.deriveSeed(words: words, passphrase: passphrase)
        }.value
    }
}
