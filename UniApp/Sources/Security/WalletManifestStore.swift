import Foundation
import Security
import SwiftData
import OSLog

/// `WalletManifestStore` is the Keychain-backed mirror of every
/// `WalletRecord` (+ its addresses) so the user's wallet identity
/// **survives an app reinstall**.
///
/// **The problem this solves.** iOS wipes an app's sandbox on reinstall —
/// Documents, Library, Caches, the SwiftData store, all gone. But
/// **Keychain items survive reinstall** (that's the entire point of the
/// Keychain — it's bound to the bundle ID + iCloud account, not the app
/// container). On 2026-06-09 the user reported the symptom live: every
/// `devicectl install` cycle dropped them back at onboarding, even though
/// `SeedVault` still had their seed material in Keychain. The seed had
/// nowhere to attach itself — `WalletRecord` lives in SwiftData and was
/// gone. The routing in `RootGate` reads `@Query wallets` and routes to
/// `OnboardingView` when empty. Result: a returning user with a real,
/// signable seed gets treated as a brand-new install.
///
/// **The fix.** Mirror the wallet metadata into Keychain as a single
/// JSON blob, written on every wallet mutation. On `ApertureDatabase.
/// bootstrap()`, if the SwiftData store is empty *and* the Keychain
/// manifest has entries, re-insert the `WalletRecord`s + their
/// `WalletAddressRecord`s from the manifest. `@Query` sees the populated
/// store on the first body pass, `RootGate` routes to `MainTabView` not
/// `OnboardingView`, and the user is home with their disc identity,
/// addresses, balances scope, and signing capability intact. The seed
/// (`SeedVault`) was always there — now the wallet that points at it is
/// too.
///
/// **What's in the manifest.** Everything `WalletRecord` carries that
/// can't be regenerated cheaper from the seed alone: the user-set name,
/// the kind, the sortOrder, the requiresBackup flag, the avatar fields
/// (gradient / symbolType / glyph / monogram / badge), the wall-clocks,
/// and the per-chain addresses + derivation paths. Cached balances, USD
/// prices, transaction history are NOT manifest material — they'll re-
/// scan automatically once the wallet is back in the UI. The manifest
/// stays small (kilobytes, not megabytes).
///
/// **What's NOT in the manifest.** Seed material (lives in `SeedVault`),
/// PIN hash (lives in `PinCodeStorage`), biometric preference (lives in
/// `PinCodePreference`), mnemonic plaintext (lives in `MnemonicVault`).
/// Each Keychain item has its own service+account namespace; this store
/// is purely the "wallet metadata bridge."
///
/// **Why a single Keychain item, not one-per-wallet.** Reading +
/// merging N keychain items at bootstrap is slower than reading one JSON
/// blob. Writing a single blob on every mutation is fine — the blob is
/// small (≤ a few KB), and rewriting one item is cheaper than
/// orchestrating N items with their own delete/update cycles. The
/// trade-off would matter for hundreds of wallets; we'll cross that
/// bridge when we get there.
///
/// **ACL.** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
/// available the moment the device is unlocked once after boot, so the
/// restore can run from `ApertureDatabase.bootstrap()` (synchronous,
/// before the first `WindowGroup` body), and never syncs to iCloud
/// (matches `SeedVault`'s posture — Aperture is device-local
/// self-custody).
///
/// **Rule #3 (native-only).** Pure `Foundation` + `Security` framework.
/// No third-party Keychain wrapper, no JSON helper library — `Codable`
/// + `JSONEncoder`/`Decoder` handle everything.
///
/// **Rule #16 §A.2.** The honest claim this enables: *"Your wallet's
/// identity is stored in iOS Keychain — Aperture re-creates it on
/// reinstall from the same encrypted vault that holds your seed."*
///
/// **Why not `@MainActor`.** Sync calls fire from `WalletRepository`,
/// which is `@ModelActor`-isolated to its own context, not main. The
/// `Security` framework is thread-safe and `JSONEncoder` /
/// `JSONDecoder` carry no shared mutable state — so this enum can
/// safely sit outside any actor and be called from any isolation.
enum WalletManifestStore {

    // MARK: - Constants

    /// Keychain service identifier. Mirrors the `SeedVault` /
    /// `PinCodeStorage` namespace pattern.
    private static let service = "com.thuglife.aperture.wallet-manifest"
    /// Single Keychain account name — the manifest is one row, not
    /// one-per-wallet.
    private static let account = "manifest"

    private static let log = Logger(
        subsystem: "com.thuglife.aperture",
        category: "wallet-manifest"
    )

    // MARK: - Entry model

    /// A single wallet's manifest snapshot. Field names + types mirror
    /// `WalletRecord` so the restore path is a straight copy back into
    /// the schema's `init(...)`.
    struct Entry: Codable, Sendable, Equatable {
        let id: UUID
        let name: String
        let kindRaw: String
        let mnemonicWordCount: Int?
        let hasPassphrase: Bool
        let colorTag: String
        let sortOrder: Int
        let isHidden: Bool
        let requiresBackup: Bool
        let createdAt: Date
        let updatedAt: Date
        let iconSymbol: String
        let iconColorHex: String
        let avatarGradient: String
        let avatarSymbolType: String
        let avatarGlyph: String?
        let avatarMonogram: String?
        let avatarCustomSvg: String?
        let avatarCustomTint: String?
        let avatarBadge: String?
        let addresses: [Address]

        /// Per-chain on-chain address row. Mirrors
        /// `WalletAddressRecord` — minus the SwiftData relationships,
        /// which the restore path rebuilds.
        struct Address: Codable, Sendable, Equatable {
            let id: UUID
            let chainRaw: String
            let address: String
            let derivationPath: String
            let isUsed: Bool
            let lastScannedAt: Date?
        }
    }

    // MARK: - Public surface

    /// Read the persisted manifest. Returns `[]` on first launch / no
    /// prior install / decode failure. Never throws — a corrupt
    /// manifest is logged and treated as "nothing to restore" rather
    /// than blocking app launch.
    static func load() -> [Entry] {
        guard let data = readKeychainItem() else { return [] }
        do {
            let entries = try JSONDecoder.aperture.decode([Entry].self, from: data)
            return entries
        } catch {
            log.error("Manifest decode failed: \(String(describing: error), privacy: .public). Treating as empty.")
            return []
        }
    }

    /// Overwrite the persisted manifest. Idempotent — same payload
    /// twice in a row writes twice. Callers should batch mutations
    /// (each `WalletRepository` mutation calls `sync(from:)` once at
    /// the end) rather than per-field.
    static func save(_ entries: [Entry]) throws {
        let data = try JSONEncoder.aperture.encode(entries)
        try writeKeychainItem(data: data)
    }

    /// Wipe the manifest. Used by the future "reset Aperture" surface
    /// in Settings → Security. Idempotent.
    static func clear() {
        deleteKeychainItem()
    }

    // MARK: - SwiftData bridge

    /// Read every `WalletRecord` from the supplied context, snapshot
    /// the matching `Entry` for each, and write the resulting array as
    /// the manifest. Called at the end of every wallet mutation (via
    /// `WalletRepository`) and from `WalletIconPickerSheet.commit(_:)`.
    ///
    /// Failures are logged but never thrown — keeping the manifest in
    /// sync is best-effort. The user's UX is driven by SwiftData; the
    /// manifest is a one-way restore bridge. A Keychain hiccup must
    /// not roll back a successful wallet edit.
    static func sync(from context: ModelContext) {
        do {
            let wallets = try context.fetch(
                FetchDescriptor<WalletRecord>(
                    sortBy: [SortDescriptor(\WalletRecord.sortOrder)]
                )
            )
            let entries = wallets.map(Entry.init(from:))
            try save(entries)
            log.debug("Manifest synced: \(entries.count) wallets")
        } catch {
            log.error("Manifest sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Restore step run from `ApertureDatabase.bootstrap()`. If
    /// SwiftData has no wallets AND the Keychain manifest has entries,
    /// insert the `WalletRecord`s + their `WalletAddressRecord`s and
    /// save. Returns the count restored (`0` = no restore happened).
    ///
    /// Idempotent: every subsequent launch re-reads the manifest, sees
    /// the SwiftData store already has rows, and skips. The restore
    /// only fires on the first launch after a fresh install (or any
    /// other time the user starts with an empty SwiftData but a
    /// populated Keychain — the canonical post-reinstall shape).
    @discardableResult
    static func restoreIfNeeded(into context: ModelContext) -> Int {
        do {
            let existingCount = try context.fetchCount(FetchDescriptor<WalletRecord>())
            guard existingCount == 0 else {
                log.debug("Restore skipped: SwiftData already has \(existingCount) wallets")
                return 0
            }
            let entries = load()
            guard !entries.isEmpty else {
                log.debug("Restore skipped: manifest is empty (fresh install)")
                return 0
            }

            log.info("Restoring \(entries.count) wallets from manifest after reinstall")
            for entry in entries {
                let kind = WalletKind(rawValue: entry.kindRaw) ?? .created
                let record = WalletRecord(
                    id: entry.id,
                    name: entry.name,
                    kind: kind,
                    mnemonicWordCount: entry.mnemonicWordCount,
                    hasPassphrase: entry.hasPassphrase,
                    colorTag: entry.colorTag,
                    sortOrder: entry.sortOrder,
                    requiresBackup: entry.requiresBackup,
                    iconSymbol: entry.iconSymbol,
                    iconColorHex: entry.iconColorHex,
                    avatarGradient: entry.avatarGradient,
                    avatarSymbolType: entry.avatarSymbolType,
                    avatarGlyph: entry.avatarGlyph,
                    avatarMonogram: entry.avatarMonogram,
                    avatarCustomSvg: entry.avatarCustomSvg,
                    avatarCustomTint: entry.avatarCustomTint,
                    avatarBadge: entry.avatarBadge
                )
                // Preserve the original wall-clocks so "created at" and
                // "last updated at" don't reset to now on restore — the
                // wallet's history is the user's, not the install's.
                record.createdAt = entry.createdAt
                record.updatedAt = entry.updatedAt
                record.isHidden = entry.isHidden

                context.insert(record)

                for addrEntry in entry.addresses {
                    let addr = WalletAddressRecord(
                        id: addrEntry.id,
                        chainRaw: addrEntry.chainRaw,
                        address: addrEntry.address,
                        derivationPath: addrEntry.derivationPath,
                        isUsed: addrEntry.isUsed
                    )
                    addr.lastScannedAt = addrEntry.lastScannedAt
                    addr.wallet = record
                    context.insert(addr)
                }
            }
            try context.save()
            return entries.count
        } catch {
            log.error("Restore failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: - Keychain primitives

    private static func writeKeychainItem(data: Data) throws {
        // Delete then add (matches the SeedVault pattern — simpler
        // than `SecItemUpdate` and the same outcome).
        deleteKeychainItem()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            log.error("Keychain write failed status=\(status)")
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain write failed"]
            )
        }
    }

    private static func readKeychainItem() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            log.error("Keychain read failed status=\(status)")
            return nil
        }
    }

    private static func deleteKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Entry init from WalletRecord

private extension WalletManifestStore.Entry {
    init(from record: WalletRecord) {
        self.init(
            id: record.id,
            name: record.name,
            kindRaw: record.kindRaw,
            mnemonicWordCount: record.mnemonicWordCount,
            hasPassphrase: record.hasPassphrase,
            colorTag: record.colorTag,
            sortOrder: record.sortOrder,
            isHidden: record.isHidden,
            requiresBackup: record.requiresBackup,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            iconSymbol: record.iconSymbol,
            iconColorHex: record.iconColorHex,
            avatarGradient: record.avatarGradient,
            avatarSymbolType: record.avatarSymbolType,
            avatarGlyph: record.avatarGlyph,
            avatarMonogram: record.avatarMonogram,
            avatarCustomSvg: record.avatarCustomSvg,
            avatarCustomTint: record.avatarCustomTint,
            avatarBadge: record.avatarBadge,
            addresses: record.addresses.map { addr in
                Address(
                    id: addr.id,
                    chainRaw: addr.chainRaw,
                    address: addr.address,
                    derivationPath: addr.derivationPath,
                    isUsed: addr.isUsed,
                    lastScannedAt: addr.lastScannedAt
                )
            }
        )
    }
}

// MARK: - Aperture-standard JSON coders

private extension JSONEncoder {
    static let aperture: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()
}

private extension JSONDecoder {
    static let aperture: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}
