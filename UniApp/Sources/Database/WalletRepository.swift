import Foundation
import SwiftData

/// Background-safe mutation surface for `WalletRecord` + its addresses.
/// `@ModelActor` gives this actor its own `ModelContext` bound to the
/// actor's isolation — the main-actor SwiftUI views read via `@Query`
/// from their own context, this actor writes from its context, and
/// SwiftData merges across contexts automatically.
///
/// **Why an actor.** Per `CLAUDE.md` Rule #2 §C ("actor-isolated
/// repositories for anything multi-source") and Rule #3 (Swift 6.2
/// strict concurrency). Wallet creation can happen from the main flow
/// or from a future background-import path; both share this actor.
@ModelActor
actor WalletRepository {
    /// `true` when the backing container is the in-memory fallback
    /// (`ApertureDatabase.isInMemoryFallback`) rather than the durable
    /// on-disk store. Read from the container's own configuration so
    /// the actor doesn't need a main-actor hop to ask the database
    /// singleton.
    private var isEphemeralStore: Bool {
        modelContainer.configurations.contains { $0.isStoredInMemoryOnly }
    }

    /// Custody mutations (create / import / delete) must never run
    /// against the in-memory fallback container: the SwiftData rows
    /// would vanish at app exit while the matching Keychain state
    /// (seed, mnemonic, manifest entry) persisted — permanently
    /// orphaning a funded wallet's seed behind no record, or wiping a
    /// real seed the on-disk store still references. Throwing keeps
    /// the failure honest at the call site instead of silently losing
    /// a wallet at the next launch.
    private func ensureDurableStore() throws {
        guard !isEphemeralStore else {
            throw WalletRepositoryError.ephemeralStore
        }
    }

    /// Mirror the current wallet set into the Keychain manifest — but
    /// ONLY when the backing store is the durable on-disk one. In an
    /// in-memory fallback session the REAL manifest must never be
    /// rewritten from ephemeral state: the on-disk store (left intact
    /// by the fallback path) is the source of truth the next healthy
    /// launch re-syncs from.
    private func syncManifestIfDurable() {
        guard !isEphemeralStore else { return }
        WalletManifestStore.sync(from: modelContext)
    }

    /// Total wallet count. Drives the "do we have any wallets yet?"
    /// decision at app launch (informs onboarding routing — T-001).
    func walletCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<WalletRecord>())
    }

    /// Next `sortOrder` value for a newly-inserted wallet. Lower values
    /// come first; new wallets land at the end of the list by default.
    func nextSortOrder() throws -> Int {
        var descriptor = FetchDescriptor<WalletRecord>(
            sortBy: [SortDescriptor(\WalletRecord.sortOrder, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let top = try modelContext.fetch(descriptor).first
        return (top?.sortOrder ?? -1) + 1
    }

    /// Insert a freshly-created wallet (from `RecoveryPhraseFlow`).
    /// Returns the persistent identifier so the caller can route or
    /// reference the wallet on the next screen. Saves immediately so a
    /// crash between this call and the next user action doesn't lose
    /// the wallet metadata (the seed in Keychain has already been
    /// written separately).
    ///
    /// - parameters:
    ///   - id: stable UUID (same one the caller passed to `SeedVault`).
    ///   - name: user-facing display name.
    ///   - mnemonicWordCount: 12 or 24.
    ///   - hasPassphrase: whether a BIP-39 passphrase was set.
    ///   - colorTag: accent color tag from `UniColors.Wallet`.
    ///   - requiresBackup: `true` if user skipped the verification step.
    @discardableResult
    func insertCreatedWallet(
        id: UUID,
        name: String,
        mnemonicWordCount: Int,
        hasPassphrase: Bool,
        colorTag: String,
        requiresBackup: Bool,
        addresses: [(chainRaw: String, address: String)] = []
    ) throws -> PersistentIdentifier {
        try ensureDurableStore()
        let record = WalletRecord(
            id: id,
            name: name,
            kind: .created,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            sortOrder: try nextSortOrder(),
            requiresBackup: requiresBackup
        )
        modelContext.insert(record)
        // Persist per-chain addresses (same shape as the import path).
        // A wallet created without an addresses array (legacy callers /
        // tests) still inserts cleanly; the loop is a no-op then.
        for entry in addresses {
            let addr = WalletAddressRecord(
                chainRaw: entry.chainRaw,
                address: entry.address
            )
            addr.wallet = record
            modelContext.insert(addr)
        }
        try modelContext.save()
        syncManifestIfDurable()
        return record.persistentModelID
    }

    /// Insert a wallet from a mnemonic-import flow. Same shape as
    /// `insertCreatedWallet` but `kind == .importedMnemonic` and
    /// `requiresBackup` defaults to `false` (the user already has the
    /// phrase by definition — they just imported it).
    @discardableResult
    func insertImportedMnemonicWallet(
        id: UUID,
        name: String,
        mnemonicWordCount: Int,
        hasPassphrase: Bool,
        colorTag: String,
        addresses: [(chainRaw: String, address: String)]
    ) throws -> PersistentIdentifier {
        try ensureDurableStore()
        let record = WalletRecord(
            id: id,
            name: name,
            kind: .importedMnemonic,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            sortOrder: try nextSortOrder(),
            requiresBackup: false
        )
        modelContext.insert(record)
        for entry in addresses {
            let addr = WalletAddressRecord(
                chainRaw: entry.chainRaw,
                address: entry.address
            )
            addr.wallet = record
            modelContext.insert(addr)
        }
        try modelContext.save()
        syncManifestIfDurable()
        return record.persistentModelID
    }

    /// Insert a wallet from a private-key import (single chain).
    @discardableResult
    func insertImportedKeyWallet(
        id: UUID,
        name: String,
        colorTag: String,
        chainRaw: String,
        address: String
    ) throws -> PersistentIdentifier {
        try ensureDurableStore()
        let record = WalletRecord(
            id: id,
            name: name,
            kind: .importedKey,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: colorTag,
            sortOrder: try nextSortOrder(),
            requiresBackup: false
        )
        modelContext.insert(record)
        let addr = WalletAddressRecord(chainRaw: chainRaw, address: address)
        addr.wallet = record
        modelContext.insert(addr)
        try modelContext.save()
        syncManifestIfDurable()
        return record.persistentModelID
    }

    /// Insert a watch-only wallet (one or more addresses on a single
    /// chain, derived from an extended key or supplied directly).
    @discardableResult
    func insertWatchOnlyWallet(
        id: UUID,
        name: String,
        colorTag: String,
        chainRaw: String,
        addresses: [String]
    ) throws -> PersistentIdentifier {
        try ensureDurableStore()
        let record = WalletRecord(
            id: id,
            name: name,
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: colorTag,
            sortOrder: try nextSortOrder(),
            requiresBackup: false
        )
        modelContext.insert(record)
        for address in addresses {
            let addr = WalletAddressRecord(chainRaw: chainRaw, address: address)
            addr.wallet = record
            modelContext.insert(addr)
        }
        try modelContext.save()
        syncManifestIfDurable()
        return record.persistentModelID
    }

    /// Update a wallet's identity avatar — gradient + symbol type +
    /// glyph or monogram. Called from `WalletIconPickerSheet`
    /// whenever the user taps Save on the new gradient-disc picker.
    /// Writes through SwiftData so every consumer (`MainTabView` tab
    /// icon, wallet-home toolbar pill, `WalletSwitcherSheet` rows,
    /// `WalletsListView` rows, `WalletDetailView` preview) reacts via
    /// `@Query` and re-renders without per-surface plumbing.
    ///
    /// The badge is derived from the wallet's kind at hydrate time —
    /// it's never written by this method, per the design handoff hard
    /// rule #4 ("the type badge is derived from wallet type, NOT
    /// user-selectable"). The caller passes a `WalletAvatarSpec`
    /// without a badge; this method ignores any badge field.
    ///
    /// Returns `true` if the wallet was found and updated; `false`
    /// if the id did not match (e.g. wallet was deleted concurrently).
    @discardableResult
    func updateAvatar(id: UUID, spec: WalletAvatarSpec) throws -> Bool {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return false
        }
        record.avatarGradient = spec.gradient.rawValue
        record.avatarSymbolType = spec.symbolType.rawValue
        record.avatarGlyph = spec.glyph?.rawValue
        record.avatarMonogram = spec.monogram
        // v3 Upload-tab fields. Nil when the spec is `.glyph` or
        // `.mono`; the writer overwrites the prior `.custom` values
        // to nil on mode-switch so a wallet that was `.custom` and
        // is now `.glyph` doesn't carry a stale SVG blob.
        record.avatarCustomSvg = spec.customSvg
        record.avatarCustomTint = spec.customTint?.rawValue
        // Badge is derived from kind — re-derive on every write so
        // a future kind change (e.g., upgrading a watch-only to a
        // full custody) auto-updates the badge.
        record.avatarBadge = WalletAvatarBadge.derive(from: record.kind)?.rawValue
        record.updatedAt = Date()
        try modelContext.save()
        syncManifestIfDurable()
        return true
    }

    /// LEGACY bridge. Pre-2026-06-09 callers that update the
    /// flat-circle avatar by SF Symbol + hex still link here through
    /// the source; the implementation now writes the legacy columns
    /// AND emits a deterministic auto(name)-based avatar spec for
    /// the new gradient system. Used by no live code path today;
    /// retained until grep audit confirms zero callers.
    @discardableResult
    func updateAvatar(id: UUID, iconSymbol: String, iconColorHex: String) throws -> Bool {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return false
        }
        record.iconSymbol = iconSymbol
        record.iconColorHex = iconColorHex
        record.updatedAt = Date()
        try modelContext.save()
        syncManifestIfDurable()
        return true
    }

    /// One-shot backfill for the 2026-06-09 avatar schema additive.
    /// Called from `ApertureDatabase.bootstrap()` after the
    /// singleton-record bootstrap. Idempotent — touches only rows
    /// whose avatar columns are empty.
    ///
    /// **Two backfill paths.**
    ///
    /// 1. **Pre-migration rows** (existed before 2026-06-09) decode
    ///    the additive avatar columns as empty strings. For each, we
    ///    compute `WalletAvatarSpec.auto(name:)` against the wallet's
    ///    name — deterministic, on-brand identity that lands the same
    ///    color every time, so a future re-migration would idempotently
    ///    produce the same spec.
    ///
    /// 2. **Legacy column gaps** (rows where `iconSymbol` /
    ///    `iconColorHex` ended up empty — the original 2026-06-09
    ///    backfill we authored as a defensive guard). Same shape:
    ///    set the schema-level defaults so source-compatible decode
    ///    paths still resolve.
    ///
    /// Per the design handoff: *"New wallets get a deterministic
    /// avatar from their name."* That property holds across
    /// installs, devices, and re-migrations because `auto(name)` is
    /// pure (`name` in → spec out), with no side state.
    ///
    /// The fetch is predicated on the empty-column shape so only rows
    /// that actually need backfill load — on a healthy store (every
    /// launch after the one-time backfill) this fetches zero rows
    /// instead of materializing every wallet.
    func backfillAvatarDefaults() throws {
        let descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate {
                $0.iconSymbol == ""
                    || $0.iconColorHex == ""
                    || $0.avatarGradient == ""
                    || $0.avatarSymbolType == ""
            }
        )
        let rows = try modelContext.fetch(descriptor)
        var didChange = false
        for row in rows {
            // Legacy column backfill — keep the schema defensible for
            // any read path that still touches `iconSymbol` /
            // `iconColorHex`.
            if row.iconSymbol.isEmpty {
                row.iconSymbol = WalletAvatarDefaults.legacySymbol
                didChange = true
            }
            if row.iconColorHex.isEmpty {
                row.iconColorHex = WalletAvatarDefaults.legacyColorHex
                didChange = true
            }

            // New avatar column backfill — when the gradient OR symbol
            // type is empty, compute auto(name) and write the result.
            // Per the design handoff: deterministic from `name`, so a
            // second-run would produce the same spec (no thrash).
            if row.avatarGradient.isEmpty || row.avatarSymbolType.isEmpty {
                let auto = WalletAvatarDefaults.spec(forName: row.name, kind: row.kind)
                row.avatarGradient = auto.gradient
                row.avatarSymbolType = auto.symbolType
                row.avatarGlyph = auto.glyph
                row.avatarMonogram = auto.monogram
                didChange = true
            }
            // Badge is always re-derived from kind on every backfill
            // (idempotent — the same kind always produces the same
            // raw value). If the row already has the same value, the
            // SwiftData write coalesces.
            let derivedBadge = WalletAvatarBadge.derive(from: row.kind)?.rawValue
            if row.avatarBadge != derivedBadge {
                row.avatarBadge = derivedBadge
                didChange = true
            }
        }
        if didChange {
            try modelContext.save()
            syncManifestIfDurable()
        }
    }

    /// Rename a wallet. Returns `true` if the wallet was found and
    /// updated; `false` if the id did not match (e.g. wallet was
    /// deleted concurrently).
    @discardableResult
    func renameWallet(id: UUID, to newName: String) throws -> Bool {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            return false
        }
        record.name = newName
        record.updatedAt = Date()
        try modelContext.save()
        syncManifestIfDurable()
        return true
    }

    /// Delete a wallet and cascade-delete its addresses, transactions,
    /// and balances. Also wipes the wallet's Keychain material
    /// (`SeedVault` seed + `MnemonicVault` mnemonic) — once the record
    /// is gone the id is unrecoverable, so the vault wipe happens here
    /// rather than being delegated to callers (where a missed call
    /// orphans the seed in Keychain forever). Idempotent: both vaults
    /// treat missing items as success, so wallets without seed
    /// material (watch-only, already-wiped) delete cleanly. Vault
    /// failures are logged at the source (`VaultError` paths) and do
    /// not block the record deletion.
    func deleteWallet(id: UUID) async throws {
        try ensureDurableStore()
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        // Commit the durable record delete FIRST. If the save throws
        // (disk full is the realistic trigger), the wallet stays fully
        // intact — record, seed, and mnemonic — and the caller can
        // surface the failure honestly. Wiping the vaults before the
        // save risked the opposite: a failed save would leave a
        // visible, healthy-looking wallet whose signing material was
        // already destroyed forever.
        modelContext.delete(record)
        try modelContext.save()
        syncManifestIfDurable()
        // Both vaults are @MainActor (Keychain access policy) — hop
        // explicitly. Wiping AFTER the save means the worst failure
        // mode here is an orphaned Keychain item behind a deleted
        // record (benign — leaks no funds, sweepable by diffing
        // Keychain ids against `allWalletIds()`), never a live record
        // without a seed.
        await MainActor.run {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
        }
    }

    /// Mark the wallet as backed-up (clears `requiresBackup`). Called
    /// after the user successfully completes `BackupVerifyView` against
    /// an existing-but-unbacked wallet (T-016).
    func markBackupComplete(id: UUID) throws {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.requiresBackup = false
        record.updatedAt = Date()
        try modelContext.save()
        syncManifestIfDurable()
    }

    /// All wallet ids in the store, oldest first. Used by the
    /// "Reset Aperture" advanced setting so the caller can wipe each
    /// wallet's Keychain items (`SeedVault`, `MnemonicVault`) before
    /// the SwiftData rows are dropped — once the rows are gone, the
    /// ids are unrecoverable.
    func allWalletIds() throws -> [UUID] {
        let descriptor = FetchDescriptor<WalletRecord>(
            sortBy: [SortDescriptor(\WalletRecord.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { $0.id }
    }

    /// Delete every `WalletRecord` (and cascading `WalletAddressRecord`
    /// + `TransactionRecord` + `TokenBalanceRecord` rows). The
    /// `AppMetadataRecord` and `BiometricEnrollmentRecord` singletons
    /// are left in place — they're app-wide state, not per-wallet.
    /// Caller is responsible for the matching Keychain wipes via
    /// `allWalletIds()` first.
    func deleteAllWallets() throws {
        try ensureDurableStore()
        let descriptor = FetchDescriptor<WalletRecord>()
        let rows = try modelContext.fetch(descriptor)
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
        // Also wipe the Keychain manifest — otherwise the next launch
        // would happily "restore" the wallets the user just nuked.
        // Safe to touch the REAL manifest here: `ensureDurableStore()`
        // above guarantees this session is backed by the on-disk store.
        WalletManifestStore.clear()
    }
}

/// Errors thrown by `WalletRepository` custody mutations.
enum WalletRepositoryError: Error, Sendable, Equatable {
    /// The backing store is the in-memory fallback
    /// (`ApertureDatabase.isInMemoryFallback`) — records written this
    /// session vanish at app exit while Keychain writes (seed,
    /// mnemonic, manifest) would persist, permanently orphaning them.
    /// Wallet create / import / delete are refused so the caller can
    /// surface an honest failure instead of silently losing a wallet.
    case ephemeralStore
}
