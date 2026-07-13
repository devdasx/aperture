import Foundation
import GRDB

final class WalletRepository {
    struct AddressSnapshot: Sendable {
        let id: UUID
        let chain: SupportedChain
        let address: String
    }

    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func walletCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallets") ?? 0
        }
    }

    /// Every persisted address for the wallet (all chains). Preferred rows
    /// sort first within each chain — multi-path BTC / dual Solana return
    /// **all** path rows, not just preferred (P1 #10).
    func addresses(walletId: UUID) throws -> [AddressSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, chain_raw, address
                FROM wallet_addresses
                WHERE wallet_id = ?
                ORDER BY chain_raw ASC, is_receive_preferred DESC
                """,
                arguments: [walletId.uuidString]
            ).compactMap { row in
                guard
                    let id = UUID(uuidString: row["id"]),
                    let chain = SupportedChain(rawValue: row["chain_raw"])
                else { return nil }
                return AddressSnapshot(id: id, chain: chain, address: row["address"])
            }
        }
    }

    /// Every address on a single chain (receive/change, Phantom/Trust, …).
    func addresses(walletId: UUID, chain: SupportedChain) throws -> [AddressSnapshot] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, chain_raw, address
                FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ?
                ORDER BY is_receive_preferred DESC, address ASC
                """,
                arguments: [walletId.uuidString, chain.rawValue]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]) else { return nil }
                return AddressSnapshot(id: id, chain: chain, address: row["address"])
            }
        }
    }

    /// Preferred send/receive address for the chain (`is_receive_preferred`).
    /// Same as the stamp on `chain_states.address` after rebuild — not the
    /// full multi-path set.
    func address(walletId: UUID, chain: SupportedChain) throws -> AddressSnapshot? {
        try preferredAddress(walletId: walletId, chain: chain)
    }

    /// Preferred send/receive address for the chain.
    func preferredAddress(walletId: UUID, chain: SupportedChain) throws -> AddressSnapshot? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, chain_raw, address
                FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ?
                ORDER BY is_receive_preferred DESC
                LIMIT 1
                """,
                arguments: [walletId.uuidString, chain.rawValue]
            ), let id = UUID(uuidString: row["id"]) else {
                return nil
            }
            return AddressSnapshot(id: id, chain: chain, address: row["address"])
        }
    }

    @discardableResult
    func insertCreatedWallet(
        id: UUID,
        name: String,
        mnemonicWordCount: Int,
        hasPassphrase: Bool,
        colorTag: String,
        requiresBackup: Bool,
        manualBackupCompleted: Bool = false,
        mnemonicWords: [String]? = nil,
        addresses: [WalletCommandRepository.AddressSeed] = []
    ) async throws -> UUID {
        try await WalletCommandRepository(database: database).insertCreatedWallet(
            id: id,
            name: name,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            requiresBackup: requiresBackup,
            manualBackupCompleted: manualBackupCompleted,
            mnemonicWords: mnemonicWords,
            addresses: addresses
        )
    }

    @discardableResult
    func insertImportedMnemonicWallet(
        id: UUID,
        name: String,
        mnemonicWordCount: Int,
        hasPassphrase: Bool,
        colorTag: String,
        mnemonicWords: [String]? = nil,
        addresses: [WalletCommandRepository.AddressSeed]
    ) async throws -> UUID {
        try await WalletCommandRepository(database: database).insertImportedMnemonicWallet(
            id: id,
            name: name,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            mnemonicWords: mnemonicWords,
            addresses: addresses
        )
    }

    @discardableResult
    func insertImportedKeyWallet(
        id: UUID,
        name: String,
        colorTag: String,
        privateKey: String? = nil,
        addresses: [(chainRaw: String, address: String)]
    ) async throws -> UUID {
        try await WalletCommandRepository(database: database).insertImportedKeyWallet(
            id: id,
            name: name,
            colorTag: colorTag,
            privateKey: privateKey,
            addresses: addresses
        )
    }

    @discardableResult
    func insertWatchOnlyWallet(
        id: UUID,
        name: String,
        colorTag: String,
        addresses: [(chainRaw: String, address: String)]
    ) async throws -> UUID {
        try await WalletCommandRepository(database: database).insertWatchOnlyWallet(
            id: id,
            name: name,
            colorTag: colorTag,
            addresses: addresses
        )
    }

    @discardableResult
    func updateAvatar(id: UUID, spec: WalletAvatarSpec) async throws -> Bool {
        try await WalletCommandRepository(database: database).updateAvatar(id: id, spec: spec)
    }

    @discardableResult
    func updateAvatar(id: UUID, iconSymbol: String, iconColorHex: String) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE wallets
                SET icon_symbol = ?, icon_color_hex = ?, updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [iconSymbol, iconColorHex, Date.databaseMilliseconds, id.uuidString]
            )
            return (try Int.fetchOne(db, sql: "SELECT changes()") ?? 0) > 0
        }
    }

    func backfillEncryptedChainKeysFromStoredSecrets() throws {
        let candidates = try encryptedChainKeyBackfillCandidates()
        for candidate in candidates {
            let blobs = encryptedChainKeyBlobs(for: candidate)
            guard !blobs.isEmpty else { continue }
            try database.write { db in
                let now = Date.databaseMilliseconds
                for (chain, blob) in blobs {
                    try db.execute(
                        sql: """
                        UPDATE chain_states
                        SET encrypted_private_key = ?,
                            key_encryption_scheme = ?,
                            last_synced_at_ms = COALESCE(last_synced_at_ms, ?)
                        WHERE wallet_id = ?
                          AND chain_raw = ?
                          AND encrypted_private_key IS NULL
                        """,
                        arguments: [
                            blob,
                            ChainKeyVault.scheme,
                            now,
                            candidate.wallet.id.uuidString,
                            chain.rawValue
                        ]
                    )
                }
            }
        }
    }

    @discardableResult
    func renameWallet(id: UUID, to newName: String) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: "UPDATE wallets SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [newName, Date.databaseMilliseconds, id.uuidString]
            )
            return (try Int.fetchOne(db, sql: "SELECT changes()") ?? 0) > 0
        }
    }

    func deleteWallet(id: UUID) async throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallets WHERE id = ?", arguments: [id.uuidString])
            let activeRaw = try String.fetchOne(
                db,
                sql: "SELECT wallet_id FROM active_wallet WHERE id = 'active-wallet-singleton'"
            ) ?? ""
            if activeRaw == id.uuidString {
                try ActiveWalletPointer.mirrorSelection(nil, db: db)
            }
        }
    }

    /// Result of removing one wallet from Settings.
    enum RemoveWalletResult: Sendable, Equatable {
        /// Another wallet became active (priority: balance → used → random).
        case activatedNext(UUID)
        /// This was the last wallet — full factory wipe ran; app is empty.
        case appWiped
    }

    /// Delete `walletId`, then choose the next active wallet:
    /// 1. Highest portfolio fiat among remaining wallets
    /// 2. Else any “used” wallet (address `is_used` or on-chain history)
    /// 3. Else a random remaining wallet (prefer non-hidden)
    /// 4. If none remain → `FactoryReset.performFullWipe` (empty app / onboarding)
    @discardableResult
    func removeWalletSelectingSuccessor(walletId: UUID) async throws -> RemoveWalletResult {
        let remainingCount = try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM wallets WHERE id != ?",
                arguments: [walletId.uuidString]
            ) ?? 0
        }

        if remainingCount == 0 {
            // Last wallet — wipe everything so RootGate returns to onboarding.
            try await FactoryReset.performFullWipe(database: database)
            return .appWiped
        }

        let next = try database.write { db -> UUID? in
            // Priority: non-hidden first, then balance → used → random.
            let nextRaw = try String.fetchOne(
                db,
                sql: """
                SELECT w.id
                FROM wallets w
                WHERE w.id != ?
                ORDER BY
                    CASE WHEN w.is_hidden = 0 THEN 0 ELSE 1 END ASC,
                    COALESCE((
                        SELECT MAX(p.total_fiat_numeric)
                        FROM wallet_portfolio_summaries p
                        WHERE p.wallet_id = w.id
                    ), 0) DESC,
                    COALESCE((
                        SELECT MAX(a.is_used)
                        FROM wallet_addresses a
                        WHERE a.wallet_id = w.id
                    ), 0) DESC,
                    COALESCE((
                        SELECT COUNT(*)
                        FROM transactions t
                        INNER JOIN wallet_addresses a2 ON a2.id = t.address_id
                        WHERE a2.wallet_id = w.id
                    ), 0) DESC,
                    RANDOM()
                LIMIT 1
                """,
                arguments: [walletId.uuidString]
            )
            let nextId = nextRaw.flatMap(UUID.init(uuidString:))
            try ActiveWalletPointer.mirrorSelection(nextId, db: db)
            try db.execute(sql: "DELETE FROM wallets WHERE id = ?", arguments: [walletId.uuidString])
            return nextId
        }

        if let next {
            ActiveWalletPointer.set(next)
            return .activatedNext(next)
        }

        // Defensive: count said others exist but selection failed — wipe closed.
        try await FactoryReset.performFullWipe(database: database)
        return .appWiped
    }

    /// Compatibility wrapper — returns the activated next id, or `nil` if the app was wiped.
    @discardableResult
    func deleteWalletAndActivateNext(walletId: UUID) async throws -> UUID? {
        switch try await removeWalletSelectingSuccessor(walletId: walletId) {
        case .activatedNext(let id):
            return id
        case .appWiped:
            return nil
        }
    }

    func markBackupComplete(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE wallets SET requires_backup = 0, updated_at_ms = ? WHERE id = ?",
                arguments: [Date.databaseMilliseconds, id.uuidString]
            )
        }
    }

    func markManualBackupComplete(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE wallets SET requires_backup = 0, manual_backup_completed = 1, updated_at_ms = ? WHERE id = ?",
                arguments: [Date.databaseMilliseconds, id.uuidString]
            )
        }
    }

    func updateSortOrders(_ walletIds: [UUID]) throws {
        try database.write { db in
            let now = Date.databaseMilliseconds
            for (index, id) in walletIds.enumerated() {
                try db.execute(
                    sql: "UPDATE wallets SET sort_order = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [index, now, id.uuidString]
                )
            }
        }
    }

    func allWalletIds() throws -> [UUID] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM wallets").compactMap(UUID.init(uuidString:))
        }
    }

    func deleteAllWallets() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM wallets")
            try ActiveWalletPointer.mirrorSelection(nil, db: db)
        }
        ActiveWalletPointer.set(nil)
    }

    private struct ChainKeyBackfillCandidate {
        let wallet: WalletDescriptor
        let chainAddresses: [SupportedChain: String]
    }

    private struct MutableChainKeyBackfillCandidate {
        let kind: WalletKind
        let hasPassphrase: Bool
        var chainAddresses: [SupportedChain: String]
    }

    /// Key-seal backfill uses **preferred** `wallet_addresses` rows — never
    /// treat `chain_states.address` as the only path (P1 #10). Sealed keys
    /// match the preferred path; multi-path spend re-derives via mnemonic.
    private func encryptedChainKeyBackfillCandidates() throws -> [ChainKeyBackfillCandidate] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT w.id, w.kind_raw, w.has_passphrase, a.chain_raw, a.address
                FROM wallets w
                JOIN chain_states cs
                  ON cs.wallet_id = w.id
                JOIN wallet_addresses a
                  ON a.wallet_id = w.id
                 AND a.chain_raw = cs.chain_raw
                WHERE cs.encrypted_private_key IS NULL
                  AND w.kind_raw != ?
                  AND a.id = (
                    SELECT a2.id FROM wallet_addresses a2
                    WHERE a2.wallet_id = w.id AND a2.chain_raw = cs.chain_raw
                    ORDER BY a2.is_receive_preferred DESC, a2.address ASC
                    LIMIT 1
                  )
                ORDER BY w.id, a.chain_raw
                """,
                arguments: [WalletKind.watchOnly.rawValue]
            )

            var grouped: [UUID: MutableChainKeyBackfillCandidate] = [:]
            for row in rows {
                guard
                    let walletID = UUID(uuidString: row["id"]),
                    let kind = WalletKind(rawValue: row["kind_raw"]),
                    let chain = SupportedChain(rawValue: row["chain_raw"])
                else { continue }

                var candidate = grouped[walletID] ?? MutableChainKeyBackfillCandidate(
                    kind: kind,
                    hasPassphrase: (row["has_passphrase"] as Int) != 0,
                    chainAddresses: [:]
                )
                // One preferred address per chain (first wins if query returns dups).
                let address: String = row["address"]
                if !address.isEmpty, candidate.chainAddresses[chain] == nil {
                    candidate.chainAddresses[chain] = address
                }
                grouped[walletID] = candidate
            }

            return grouped.compactMap { walletID, candidate in
                guard !candidate.chainAddresses.isEmpty else { return nil }
                return ChainKeyBackfillCandidate(
                    wallet: WalletDescriptor(
                        id: walletID,
                        kind: candidate.kind,
                        hasPassphrase: candidate.hasPassphrase
                    ),
                    chainAddresses: candidate.chainAddresses
                )
            }
        }
    }

    private func encryptedChainKeyBlobs(for candidate: ChainKeyBackfillCandidate) -> [SupportedChain: Data] {
        do {
            switch candidate.wallet.kind {
            case .created, .importedMnemonic:
                let words = try WalletSecretPersistence.loadMnemonic(for: candidate.wallet.id, database: database)
                return SigningKeyProvider.encryptedKeyBlobs(
                    wallet: candidate.wallet,
                    chainAddresses: candidate.chainAddresses,
                    mnemonicWords: words
                )
            case .importedKey:
                let privateKey = try WalletSecretPersistence.loadPrivateKey(for: candidate.wallet.id, database: database)
                return SigningKeyProvider.encryptedKeyBlobs(
                    wallet: candidate.wallet,
                    chainAddresses: candidate.chainAddresses,
                    privateKeyString: privateKey
                )
            case .watchOnly:
                return [:]
            }
        } catch {
            DiagnosticsLogStore.shared.record(
                .warning,
                category: "wallet",
                message: "Encrypted chain-key backfill skipped wallet",
                metadata: [
                    "walletId": candidate.wallet.id.uuidString,
                    "error": String(describing: error)
                ]
            )
            return [:]
        }
    }
}

enum ActiveWalletPointer {
    static let storageKey = "activeWalletId"
    nonisolated(unsafe) private static var database: AppDatabase?

    static func configure(database: AppDatabase) {
        self.database = database
        let selectedID = try? database.write { db -> UUID? in
            let activeRaw = try String.fetchOne(
                db,
                sql: "SELECT wallet_id FROM active_wallet WHERE id = 'active-wallet-singleton'"
            ) ?? ""
            let settingsRaw = try String.fetchOne(
                db,
                sql: "SELECT active_wallet_id FROM app_settings WHERE id = 'app-settings-singleton'"
            ) ?? ""
            let preferenceRaw = try String.fetchOne(
                db,
                sql: "SELECT string_value FROM app_preferences WHERE key = ?",
                arguments: [storageKey]
            ) ?? ""
            let selected = try preferredWalletID(
                activeRecordID: UUID(uuidString: activeRaw.trimmingCharacters(in: .whitespacesAndNewlines)),
                settingsRaw: settingsRaw,
                preferenceRaw: preferenceRaw,
                db: db
            )
            try mirrorSelection(selected, db: db)
            return selected
        }
        AppPreferenceStore.shared.set(selectedID?.uuidString ?? "", forKey: storageKey)
    }

    static var currentId: UUID? {
        UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static var rawValue: String {
        AppPreferenceStore.shared.string(storageKey, default: "")
    }

    static func set(_ id: UUID?) {
        setRaw(id?.uuidString ?? "")
    }

    static func setRaw(_ raw: String) {
        let canonicalRaw = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString ?? ""
        guard let database else { return }
        try? database.write { db in
            try mirrorSelection(UUID(uuidString: canonicalRaw), db: db)
        }
        AppPreferenceStore.shared.set(canonicalRaw, forKey: storageKey)
    }

    /// After a wipe that already called `mirrorSelection` inside a transaction:
    /// refresh the static DB pointer and notify preference observers without
    /// opening another write (nested writes reenter GRDB fatally).
    static func publishMirroredSelection(database: AppDatabase) {
        self.database = database
        AppPreferenceStore.shared.bindDatabase(database)
        AppPreferenceStore.shared.publishChange(forKey: storageKey)
    }

    static func mirrorSelection(_ walletID: UUID?, db: Database) throws {
        let raw = walletID?.uuidString ?? ""
        let now = Date.databaseMilliseconds
        try db.execute(
            sql: """
            INSERT INTO active_wallet (id, wallet_id, updated_at_ms)
            VALUES ('active-wallet-singleton', ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                wallet_id = excluded.wallet_id,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [raw.isEmpty ? nil : raw, now]
        )
        try AppSettingsProjection.ensureSingleton(db, activeWalletId: raw, now: now)
        try AppPreferenceStore.upsert(.string(raw), forKey: storageKey, db: db)
    }

    private static func preferredWalletID(
        activeRecordID: UUID?,
        settingsRaw: String,
        preferenceRaw: String,
        db: Database
    ) throws -> UUID? {
        let candidates = [
            activeRecordID,
            UUID(uuidString: settingsRaw.trimmingCharacters(in: .whitespacesAndNewlines)),
            UUID(uuidString: preferenceRaw.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        for candidate in candidates.compactMap({ $0 }) where try walletExists(candidate, db: db) {
            return candidate
        }
        guard let raw = try String.fetchOne(
            db,
            sql: "SELECT id FROM wallets WHERE is_hidden = 0 ORDER BY sort_order ASC LIMIT 1"
        ) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private static func walletExists(_ walletID: UUID, db: Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM wallets WHERE id = ?",
            arguments: [walletID.uuidString]
        ) ?? 0
        return count > 0
    }
}

enum ActiveWalletResolver {
    static func resolve(rawID: String, wallets: [WalletRecord]) -> WalletRecord? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let walletID = UUID(uuidString: trimmed) else {
            return nil
        }
        return wallets.first(where: { $0.id == walletID })
    }

    static func shouldHeal(rawID: String, wallets: [WalletRecord]) -> Bool {
        guard !wallets.isEmpty else { return false }
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || UUID(uuidString: trimmed) == nil
    }
}

enum WalletRepositoryError: Error, Sendable, Equatable {
    case ephemeralStore
}
