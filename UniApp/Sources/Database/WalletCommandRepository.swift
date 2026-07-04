import Foundation
import GRDB

@MainActor
final class WalletCommandRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func walletCount() async throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallets") ?? 0
        }
    }

    @discardableResult
    func updateAvatar(id: UUID, spec: WalletAvatarSpec) async throws -> Bool {
        try database.write { db in
            let kindRaw = try String.fetchOne(
                db,
                sql: "SELECT kind_raw FROM wallets WHERE id = ?",
                arguments: [id.uuidString]
            )
            guard let kindRaw, let kind = WalletKind(rawValue: kindRaw) else {
                return false
            }
            try db.execute(
                sql: """
                UPDATE wallets
                SET avatar_gradient = ?,
                    avatar_symbol_type = ?,
                    avatar_glyph = ?,
                    avatar_monogram = ?,
                    avatar_custom_svg = ?,
                    avatar_custom_tint = ?,
                    avatar_badge = ?,
                    updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    spec.customColorHex ?? spec.gradient.rawValue,
                    spec.symbolType.rawValue,
                    spec.glyph?.rawValue,
                    spec.monogram,
                    spec.customSvg,
                    spec.customTint?.rawValue,
                    WalletAvatarBadge.derive(from: kind)?.rawValue,
                    Date.databaseMilliseconds,
                    id.uuidString
                ]
            )
            return (try Int.fetchOne(db, sql: "SELECT changes()") ?? 0) > 0
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
        seedData: Data? = nil,
        mnemonicWords: [String]? = nil,
        addresses: [(chainRaw: String, address: String)] = []
    ) async throws -> UUID {
        try insertWallet(
            id: id,
            name: name,
            kind: .created,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            requiresBackup: requiresBackup,
            manualBackupCompleted: manualBackupCompleted,
            seedData: seedData,
            mnemonicWords: mnemonicWords,
            privateKey: nil,
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
        seedData: Data? = nil,
        mnemonicWords: [String]? = nil,
        addresses: [(chainRaw: String, address: String)]
    ) async throws -> UUID {
        try insertWallet(
            id: id,
            name: name,
            kind: .importedMnemonic,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            requiresBackup: false,
            manualBackupCompleted: false,
            seedData: seedData,
            mnemonicWords: mnemonicWords,
            privateKey: nil,
            addresses: addresses
        )
    }

    @discardableResult
    func insertImportedKeyWallet(
        id: UUID,
        name: String,
        colorTag: String,
        seedData: Data? = nil,
        privateKey: String? = nil,
        addresses: [(chainRaw: String, address: String)]
    ) async throws -> UUID {
        try insertWallet(
            id: id,
            name: name,
            kind: .importedKey,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: colorTag,
            requiresBackup: false,
            manualBackupCompleted: false,
            seedData: seedData,
            mnemonicWords: nil,
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
        try insertWallet(
            id: id,
            name: name,
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: colorTag,
            requiresBackup: false,
            manualBackupCompleted: false,
            seedData: nil,
            mnemonicWords: nil,
            privateKey: nil,
            addresses: addresses
        )
    }

    @discardableResult
    private func insertWallet(
        id: UUID,
        name: String,
        kind: WalletKind,
        mnemonicWordCount: Int?,
        hasPassphrase: Bool,
        colorTag: String,
        requiresBackup: Bool,
        manualBackupCompleted: Bool,
        seedData: Data?,
        mnemonicWords: [String]?,
        privateKey: String?,
        addresses: [(chainRaw: String, address: String)]
    ) throws -> UUID {
        let now = Date.databaseMilliseconds
        let avatar = WalletAvatarDefaults.spec(forName: name, kind: kind)
        let descriptor = WalletDescriptor(id: id, kind: kind, hasPassphrase: hasPassphrase)

        try database.write { db in
            let sortOrder = try nextSortOrder(db)
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase,
                 color_tag, icon_symbol, icon_color_hex,
                 avatar_gradient, avatar_symbol_type, avatar_glyph,
                 avatar_monogram, avatar_badge, sort_order, is_hidden,
                 requires_backup, manual_backup_completed,
                 created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString,
                    name,
                    kind.rawValue,
                    mnemonicWordCount,
                    hasPassphrase,
                    colorTag,
                    WalletAvatarDefaults.legacySymbol,
                    WalletAvatarDefaults.legacyColorHex,
                    avatar.gradient,
                    avatar.symbolType,
                    avatar.glyph,
                    avatar.monogram,
                    avatar.badge,
                    sortOrder,
                    requiresBackup,
                    manualBackupCompleted,
                    now,
                    now
                ]
            )

            let addressByChain = try insertAddressesAndInitialChainStates(
                addresses,
                walletId: id,
                now: now,
                db: db
            )

            if let seedData {
                try insertSecret(
                    try WalletSecretPersistence.encryptedSeedRow(seedData, for: id),
                    now: now,
                    db: db
                )
            }
            if let mnemonicWords {
                try insertSecret(
                    try WalletSecretPersistence.encryptedMnemonicRow(mnemonicWords, for: id),
                    now: now,
                    db: db
                )
            }
            if let privateKey {
                try insertSecret(
                    try WalletSecretPersistence.encryptedPrivateKeyRow(privateKey, for: id),
                    now: now,
                    db: db
                )
            }

            try insertEncryptedChainKeys(
                wallet: descriptor,
                addressByChain: addressByChain,
                mnemonicWords: mnemonicWords,
                privateKey: privateKey,
                now: now,
                db: db
            )
        }
        return id
    }

    private func nextSortOrder(_ db: Database) throws -> Int {
        let current = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM wallets") ?? -1
        return current + 1
    }

    private func insertAddressesAndInitialChainStates(
        _ addresses: [(chainRaw: String, address: String)],
        walletId: UUID,
        now: Int64,
        db: Database
    ) throws -> [SupportedChain: String] {
        var addressByChain: [SupportedChain: String] = [:]
        for entry in addresses {
            let supportedChain = SupportedChain(rawValue: entry.chainRaw)
            let isFirstAddressForChain = supportedChain.map { addressByChain[$0] == nil } ?? false
            let addressId = UUID()
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path,
                 is_used, is_receive_preferred, last_scanned_at_ms)
                VALUES (?, ?, ?, ?, '', 0, ?, NULL)
                ON CONFLICT(wallet_id, chain_raw, address) DO UPDATE SET
                    is_receive_preferred = excluded.is_receive_preferred
                """,
                arguments: [
                    addressId.uuidString,
                    walletId.uuidString,
                    entry.chainRaw,
                    entry.address,
                    isFirstAddressForChain
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO chain_states
                (id, wallet_id, chain_raw, address, derivation_path,
                 native_balance_raw, native_decimals, native_fiat,
                 native_fiat_numeric, total_fiat, total_fiat_numeric,
                 token_count, fiat_currency_code, sync_state_raw)
                VALUES (?, ?, ?, ?, '', '0', 0, '0', 0, '0', 0, 0, ?, 'idle')
                ON CONFLICT(wallet_id, chain_raw) DO UPDATE SET
                    address = excluded.address
                """,
                arguments: [
                    UUID().uuidString,
                    walletId.uuidString,
                    entry.chainRaw,
                    entry.address,
                    CurrencyPreference.defaultCode
                ]
            )
            if let chain = supportedChain, addressByChain[chain] == nil {
                addressByChain[chain] = entry.address
            }
        }
        return addressByChain
    }

    private func insertSecret(
        _ secret: WalletSecretPersistence.EncryptedSecretRow,
        now: Int64,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO wallet_secrets
            (key, wallet_id, kind_raw, cipher_data, created_at_ms, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(wallet_id, kind_raw) DO UPDATE SET
                cipher_data = excluded.cipher_data,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                secret.key,
                secret.walletId.uuidString,
                secret.kindRaw,
                secret.cipherData,
                now,
                now
            ]
        )
    }

    private func insertEncryptedChainKeys(
        wallet: WalletDescriptor,
        addressByChain: [SupportedChain: String],
        mnemonicWords: [String]?,
        privateKey: String?,
        now: Int64,
        db: Database
    ) throws {
        let blobs = SigningKeyProvider.encryptedKeyBlobs(
            wallet: wallet,
            chainAddresses: addressByChain,
            passphrase: nil,
            mnemonicWords: mnemonicWords,
            privateKeyString: privateKey
        )
        for (chain, blob) in blobs {
            try db.execute(
                sql: """
                UPDATE chain_states
                SET encrypted_private_key = ?,
                    key_encryption_scheme = ?,
                    last_synced_at_ms = COALESCE(last_synced_at_ms, ?)
                WHERE wallet_id = ? AND chain_raw = ?
                """,
                arguments: [
                    blob,
                    ChainKeyVault.scheme,
                    now,
                    wallet.id.uuidString,
                    chain.rawValue
                ]
            )
        }
    }
}
