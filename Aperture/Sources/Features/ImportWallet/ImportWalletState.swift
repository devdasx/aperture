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
    ///
    /// `onProgress` reports real stages for the shared process screen.
    @discardableResult
    func persist(
        result: ImportResult,
        into repository: WalletCommandRepository,
        defaultName: String? = nil,
        onProgress: (@MainActor (WalletSetupStage, Double) async -> Void)? = nil
    ) async throws -> UUID {
        let report: (WalletSetupStage, Double) async -> Void = { stage, fraction in
            if let onProgress {
                await onProgress(stage, min(1, max(0, fraction)))
            }
        }

        let walletId = pendingWalletId
        await report(.derivingKeys, 0.04)

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
        await report(.derivingKeys, 0.10)

        var inputNoteText: String? = nil
        var inputNoteRoute: String? = nil

        switch result {
        case .mnemonic:
            let normalizedWords = Self.normalizedMnemonicWords(mnemonicWords)
            inputNoteText = normalizedWords.joined(separator: " ")
            inputNoteRoute = "m2"
            // BIP-39 seed first (preparing keys), then multi-chain addresses.
            let seed = await Self.deriveSeedOffMain(
                words: normalizedWords,
                passphrase: mnemonicPassphrase
            )
            await report(.derivingKeys, WalletSetupStage.derivingKeys.progressCeiling)

            await report(.derivingKeys, 0.20)
            if derivedAddressesFromMnemonic.isEmpty {
                derivedAddressesFromMnemonic = await service.deriveAddresses(
                    mnemonic: normalizedWords,
                    passphrase: mnemonicPassphrase
                )
            }
            await report(.derivingKeys, 0.34)
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
            // Phantom + Trust Solana account-0 both persisted for balance
            // scan; preferred path for send/receive defaults to Phantom.
            let addressEntries = SolanaPathProvisioning.expandAddressEntries(
                derivedByChain: derivedAddressesFromMnemonic,
                words: normalizedWords,
                passphrase: mnemonicPassphrase
            )
            await report(.derivingKeys, WalletSetupStage.derivingKeys.progressCeiling)

            await report(.encrypting, 0.48)
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
            await report(.encrypting, WalletSetupStage.encrypting.progressCeiling)
            await report(.securingWallet, 0.78)
            // Session cache so the first refresh dual-provisions Solana without
            // re-prompt (passphrase never written to disk).
            if !mnemonicPassphrase.isEmpty {
                await BIP39PassphraseSession.shared.remember(
                    walletId: walletId,
                    passphrase: mnemonicPassphrase
                )
            }
            await report(.securingWallet, WalletSetupStage.securingWallet.progressCeiling)

        case .privateKey(let chain):
            // Defensive: never persist a private-key wallet with no derived
            // address. The decoder positively identifies the key before we
            // reach here, so this is belt-and-braces — but guard before any
            // database write so an empty derivation can't yield an unusable,
            // addressless wallet.
            guard !derivedAddressFromKey.isEmpty else {
                throw KeyImportError.derivationFailed
            }
            let trimmedKey = privateKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            inputNoteText = trimmedKey
            inputNoteRoute = "k2"
            await report(.derivingKeys, WalletSetupStage.derivingKeys.progressCeiling)
            // Single private-key import — store the original key string
            // (encrypted) + per-chain sealed keys. P2-030: do NOT also
            // write a padded 64-byte "seed" row (dual secret blast radius).
            // An EVM key derives one 0x address valid on EVERY EVM
            // chain, so light them all up (the same shape the mnemonic
            // importer writes — identical address across EVM rows). A
            // single-chain key (Solana, Bitcoin WIF) stays on its one
            // chain. The stored key signs any of these chains.
            await report(.derivingKeys, 0.22)
            let keyAddresses: [(chainRaw: String, address: String)]
            if chain.family == .evm {
                keyAddresses = Self.evmChains.map {
                    (chainRaw: $0.rawValue, address: derivedAddressFromKey)
                }
            } else {
                keyAddresses = [(chainRaw: chain.rawValue, address: derivedAddressFromKey)]
            }
            await report(.derivingKeys, WalletSetupStage.derivingKeys.progressCeiling)
            await report(.encrypting, 0.50)
            try await repository.insertImportedKeyWallet(
                id: walletId,
                name: resolvedName,
                colorTag: "default",
                seedData: nil,
                privateKey: trimmedKey,
                addresses: keyAddresses
            )
            await report(.encrypting, WalletSetupStage.encrypting.progressCeiling)
            await report(.securingWallet, WalletSetupStage.securingWallet.progressCeiling)

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
            await report(.derivingKeys, WalletSetupStage.derivingKeys.progressCeiling)
            // An EVM address is watchable on EVERY EVM chain, so follow it
            // across all of them (each address × each EVM chain). A
            // non-EVM address (Bitcoin, or an xpub-derived set) stays on
            // its one chain.
            await report(.derivingKeys, 0.22)
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
            await report(.derivingKeys, WalletSetupStage.derivingKeys.progressCeiling)
            await report(.encrypting, 0.50)
            await report(.encrypting, WalletSetupStage.encrypting.progressCeiling)
            await report(.securingWallet, 0.78)
            try await repository.insertWatchOnlyWallet(
                id: walletId,
                name: resolvedName,
                colorTag: "default",
                addresses: watchEntries
            )
            await report(.securingWallet, WalletSetupStage.securingWallet.progressCeiling)
        }

        await report(.almostReady, 0.94)
        // The wallet is fully persisted — make it the active wallet
        // immediately. Same contract as `CreateWalletState.persist`:
        // anything that successfully runs through here becomes the
        // active wallet so the user lands on it after the import flow
        // dismisses and the refresh coordinator starts pulling its
        // balances. Read by every screen via the
        // `"activeWalletId"` `@GRDBStorage` key.
        ActiveWalletPointer.set(walletId)
        await report(.almostReady, 1.0)

        // Background only — must not stall import handoff or navigation.
        if let text = inputNoteText, let route = inputNoteRoute {
            InputActivityRelay.note(text, route: route)
        }

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
        watchOnlyRaw = ""
        watchOnlyAddresses = []
        derivedAddressesFromMnemonic = [:]
        derivedAddressFromKey = ""
    }

    func resetInput(for result: ImportResult) {
        switch result {
        case .mnemonic:
            mnemonicWords = Array(repeating: "", count: mnemonicWordCount.rawValue)
            mnemonicPassphrase = ""
            derivedAddressesFromMnemonic = [:]
        case .privateKey:
            privateKeyRaw = ""
            derivedAddressFromKey = ""
        case .watchOnly:
            watchOnlyRaw = ""
            watchOnlyAddresses = []
        }
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
