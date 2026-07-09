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
    /// derivation. Populated during the direct mnemonic commit path, or
    /// by restore flows that already have addresses.
    var derivedAddressesFromMnemonic: [SupportedChain: String] = [:]

    /// Derived address from a private-key entry. Populated by the
    /// private-key review step.
    var derivedAddressFromKey: String = ""

    /// Derived addresses from the watch-only entry. Populated by the
    /// watch-only review step.
    var watchOnlyAddresses: [String] = []

    /// Stable identifier for the wallet being imported. Same role as
    /// `CreateWalletState.pendingWalletId` — used as the wallet-secret
    /// owner id and the `WalletRecord.id` so every row targets the same
    /// logical wallet.
    let pendingWalletId: UUID = UUID()

    /// Persist this import end-to-end via the appropriate
    /// `WalletCommandRepository` shape. Mirrors `CreateWalletState.persist(...)`:
    /// key material and wallet metadata are committed together in GRDB.
    ///
    /// `result` tells us which import method finished so we pick the
    /// right repository call (mnemonic → `insertImportedMnemonicWallet`,
    /// privateKey → `insertImportedKeyWallet`, watchOnly →
    /// `insertWatchOnlyWallet`).
    @discardableResult
    func persist(
        result: ImportResult,
        into repository: WalletCommandRepository,
        defaultName: String? = nil
    ) async throws -> UUID {
        let walletId = pendingWalletId
        // Locale-aware auto-numbered default name. `String(localized:)`
        // pulls "Wallet" from the catalog so each language renders its
        // own word ("Кошелёк", "محفظة", "ウォレット"); the counter is
        // `walletCount + 1` so "Wallet 1" / "Wallet 2" sequence
        // matches what the user expects from Phantom / Trust Wallet.
        // The default name reflects HOW the wallet came in, localized to the
        // user's language (2026-06-20 user direction): an imported phrase →
        // "Imported Wallet N" / Arabic "محفظة مستوردة N", a private key → an
        // "Imported Key N", a watched address → "Watch-Only N". An explicit
        // name (e.g. an iCloud restore passing the backed-up name) always wins.
        let resolvedName: String
        if let defaultName, !defaultName.isEmpty {
            resolvedName = defaultName
        } else {
            let existingCount = (try? await repository.walletCount()) ?? 0
            let prefix: String
            switch result {
            case .mnemonic:   prefix = String.apertureLocalized("Imported Wallet")
            case .privateKey: prefix = String.apertureLocalized("Imported Key")
            case .watchOnly:  prefix = String.apertureLocalized("Watch-Only")
            }
            resolvedName = "\(prefix) \(existingCount + 1)"
        }
        switch result {
        case .mnemonic:
            let normalizedWords = Self.normalizedMnemonicWords(mnemonicWords)
            if derivedAddressesFromMnemonic.isEmpty {
                derivedAddressesFromMnemonic = await service.deriveAddresses(
                    mnemonic: normalizedWords,
                    passphrase: mnemonicPassphrase
                )
            }
            // Defensive: never persist a mnemonic wallet with zero derived
            // addresses. `service.deriveAddresses(mnemonic:)` returns `[:]`
            // (it does NOT throw) when WalletCore can't build an HDWallet —
            // e.g. an iCloud backup that decrypts to a non-BIP-39 word list.
            // Guard before any seed derivation or database write so a
            // zero-address "zombie" wallet can never land in the store via
            // any path. Nothing has been written yet, so there's nothing to
            // roll back.
            guard !derivedAddressesFromMnemonic.isEmpty else {
                throw KeyImportError.derivationFailed
            }
            // BIP-39 mnemonic import — derive the seed off-main, then
            // persist seed, mnemonic, wallet metadata, and addresses in
            // one GRDB transaction.
            let seed = await Self.deriveSeedOffMain(
                words: normalizedWords,
                passphrase: mnemonicPassphrase
            )
            let addressEntries: [(chainRaw: String, address: String)] =
                derivedAddressesFromMnemonic.map { (chain, address) in
                    (chainRaw: chain.rawValue, address: address)
                }
            try await repository.insertImportedMnemonicWallet(
                id: walletId,
                name: resolvedName,
                mnemonicWordCount: normalizedWords.count,
                hasPassphrase: !mnemonicPassphrase.isEmpty,
                colorTag: "default",
                seedData: seed,
                mnemonicWords: normalizedWords,
                addresses: addressEntries
            )

        case .privateKey(let chain):
            // Defensive: never persist a private-key wallet with no derived
            // address. The decoder positively identifies the key before we
            // reach here, so this is belt-and-braces — but guard before any
            // database write so an empty derivation can't yield an unusable,
            // addressless wallet.
            guard !derivedAddressFromKey.isEmpty else {
                throw KeyImportError.derivationFailed
            }
            // Single private-key import — decode the typed key into
            // its raw byte payload off-main, then store the padded seed
            // bytes and original key string in GRDB with the wallet.
            let seedData = try await Self.privateKeySeedMaterial(
                privateKeyRaw: privateKeyRaw,
                chain: chain
            )
            // An EVM key derives one 0x address valid on EVERY EVM
            // chain, so light them all up (the same shape the mnemonic
            // importer writes — identical address across EVM rows). A
            // single-chain key (Solana, Bitcoin WIF) stays on its one
            // chain. The stored key signs any of these chains.
            let keyAddresses: [(chainRaw: String, address: String)]
            if chain.family == .evm {
                keyAddresses = Self.evmChains.map {
                    (chainRaw: $0.rawValue, address: derivedAddressFromKey)
                }
            } else {
                keyAddresses = [(chainRaw: chain.rawValue, address: derivedAddressFromKey)]
            }
            try await repository.insertImportedKeyWallet(
                id: walletId,
                name: resolvedName,
                colorTag: "default",
                seedData: seedData,
                privateKey: privateKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                addresses: keyAddresses
            )

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
            // An EVM address is watchable on EVERY EVM chain, so follow it
            // across all of them (each address × each EVM chain). A
            // non-EVM address (Bitcoin, or an xpub-derived set) stays on
            // its one chain.
            let watchEntries: [(chainRaw: String, address: String)]
            if chain.family == .evm {
                watchEntries = watchOnlyAddresses.flatMap { address in
                    Self.evmChains.map { (chainRaw: $0.rawValue, address: address) }
                }
            } else {
                watchEntries = watchOnlyAddresses.map {
                    (chainRaw: chain.rawValue, address: $0)
                }
            }
            try await repository.insertWatchOnlyWallet(
                id: walletId,
                name: resolvedName,
                colorTag: "default",
                addresses: watchEntries
            )
        }

        // The wallet is fully persisted — make it the active wallet
        // immediately. Same contract as `CreateWalletState.persist`:
        // anything that successfully runs through here becomes the
        // active wallet so the user lands on it after the import flow
        // dismisses and the refresh coordinator starts pulling its
        // balances. Read by every screen via the
        // `"activeWalletId"` `@GRDBStorage` key.
        ActiveWalletPointer.set(walletId)
        return walletId
    }

    nonisolated private static func normalizedMnemonicWords(_ words: [String]) -> [String] {
        words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Every supported EVM chain, in declaration order (ethereum first).
    /// An EVM key/address is valid on all of them, so EVM imports fan out
    /// across this set.
    nonisolated static let evmChains: [SupportedChain] =
        SupportedChain.allCases.filter { $0.family == .evm }

    /// Zero the sensitive in-memory inputs once persistence has
    /// succeeded (or the entry surface is abandoned). The seed / key
    /// bytes live encrypted locally; the plaintext words, passphrase,
    /// and raw key string have no reason to outlive the flow.
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
    nonisolated private static func paddedTo64(bytes: Data) -> Data {
        var padded = bytes
        if padded.count < 64 {
            padded.append(contentsOf: [UInt8](repeating: 0, count: 64 - padded.count))
        } else if padded.count > 64 {
            padded = padded.prefix(64)
        }
        return padded
    }

    /// Decode a single private key's material off the main actor and pad it
    /// to the fixed 64-byte seed slot stored in GRDB.
    nonisolated private static func privateKeySeedMaterial(
        privateKeyRaw: String,
        chain: SupportedChain
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let keyBytes = try WalletCoreKeyImportService.decodePrivateKeyBytes(
                privateKeyRaw,
                on: chain
            )
            return paddedTo64(bytes: keyBytes)
        }.value
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
