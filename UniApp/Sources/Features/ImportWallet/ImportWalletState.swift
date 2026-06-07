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
            let seed = BIP39.deriveSeed(words: mnemonicWords, passphrase: mnemonicPassphrase)
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
            // Single private-key import — store the raw key in Keychain
            // (as the 64-byte seed-slot; PBKDF2 isn't applicable to a
            // single-chain key, so we pad/encode the key bytes
            // directly via SeedVault's 64-byte contract by hashing for
            // length only when needed. For v1 we store the UTF-8 bytes
            // of the user's typed key padded to 64 bytes — the real
            // import (T-024..T-031) will replace this with proper
            // per-chain key bytes).
            //
            // NOTE: this is intentionally lightweight for v1. The
            // private-key import flow is stub-grade (T-024..T-031); the
            // SeedVault row exists so the wallet's identity has a
            // Keychain anchor that future key-extraction work can
            // upgrade in place without changing the WalletRecord row.
            let padded = Self.paddedTo64(string: privateKeyRaw)
            try SeedVault.storeSeed(padded, for: walletId)
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
                throw error
            }

        case .watchOnly(let chain):
            // Watch-only: no key material. SeedVault is skipped on
            // purpose — there's nothing secret to store.
            try await repository.insertWatchOnlyWallet(
                id: walletId,
                name: resolvedName,
                colorTag: "default",
                chainRaw: chain.rawValue,
                addresses: watchOnlyAddresses.isEmpty
                    ? [watchOnlyRaw].filter { !$0.isEmpty }
                    : watchOnlyAddresses
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

    /// Pad a UTF-8 string to exactly 64 bytes for the SeedVault
    /// contract. Pure transformation, no hash — placeholder for the
    /// per-chain key-extraction work that lands as T-024..T-031.
    private static func paddedTo64(string: String) -> Data {
        var bytes = Data(string.utf8)
        if bytes.count < 64 {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 64 - bytes.count))
        } else if bytes.count > 64 {
            bytes = bytes.prefix(64)
        }
        return bytes
    }
}
