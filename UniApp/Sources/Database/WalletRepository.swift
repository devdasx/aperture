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

    func address(walletId: UUID, chain: SupportedChain) throws -> AddressSnapshot? {
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
        addresses: [(chainRaw: String, address: String)] = []
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
        addresses: [(chainRaw: String, address: String)]
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

    func backfillAvatarDefaults() throws {}
    func backfillAddressWalletIds() throws {}
    func repairMnemonicAddressRowsFromStoredSecrets() async throws {}
    func backfillEncryptedChainKeysFromStoredSecrets() throws {}

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

    func deleteWalletAndActivateNext(walletId: UUID) async throws -> UUID? {
        let next = try database.write { db -> UUID? in
            let nextRaw = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM wallets
                WHERE id != ? AND is_hidden = 0
                ORDER BY sort_order ASC, created_at_ms ASC
                LIMIT 1
                """,
                arguments: [walletId.uuidString]
            )
            let nextId = nextRaw.flatMap(UUID.init(uuidString:))
            try ActiveWalletPointer.mirrorSelection(nextId, db: db)
            try db.execute(sql: "DELETE FROM wallets WHERE id = ?", arguments: [walletId.uuidString])
            return nextId
        }
        ActiveWalletPointer.set(next)
        return next
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
