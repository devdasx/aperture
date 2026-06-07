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
        return record.persistentModelID
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
        return true
    }

    /// Delete a wallet and cascade-delete its addresses, transactions,
    /// and balances. The caller is responsible for also calling
    /// `SeedVault.deleteSeed(for:)` so the Keychain item is removed —
    /// this actor does not touch Keychain so it stays a pure database
    /// surface.
    func deleteWallet(id: UUID) throws {
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(record)
        try modelContext.save()
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
        let descriptor = FetchDescriptor<WalletRecord>()
        let rows = try modelContext.fetch(descriptor)
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }
}
