import Foundation
import GRDB

struct ExistingWalletImportMatch: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
}

enum WalletCommandRepositoryError: Error, Sendable, Equatable {
    case alreadyImported(ExistingWalletImportMatch)
}

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

    /// Address seed row. `derivationPath` is required for dual Solana paths
    /// (Phantom + Trust); empty for chains with a single default address.
    typealias AddressSeed = (chainRaw: String, address: String, derivationPath: String)

    private static func seeds(
        from addresses: [(chainRaw: String, address: String)]
    ) -> [AddressSeed] {
        addresses.map { ($0.chainRaw, $0.address, "") }
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
        addresses: [AddressSeed] = []
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

    /// Convenience for tests / callers that only have chain+address pairs.
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
        addresses: [(chainRaw: String, address: String)]
    ) async throws -> UUID {
        try await insertCreatedWallet(
            id: id,
            name: name,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            requiresBackup: requiresBackup,
            manualBackupCompleted: manualBackupCompleted,
            seedData: seedData,
            mnemonicWords: mnemonicWords,
            addresses: Self.seeds(from: addresses)
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
        addresses: [AddressSeed]
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
        try await insertImportedMnemonicWallet(
            id: id,
            name: name,
            mnemonicWordCount: mnemonicWordCount,
            hasPassphrase: hasPassphrase,
            colorTag: colorTag,
            seedData: seedData,
            mnemonicWords: mnemonicWords,
            addresses: Self.seeds(from: addresses)
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
            addresses: addresses.map { ($0.chainRaw, $0.address, "") }
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
            addresses: addresses.map { ($0.chainRaw, $0.address, "") }
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
        addresses: [AddressSeed]
    ) throws -> UUID {
        let now = Date.databaseMilliseconds
        let avatar = WalletAvatarDefaults.spec(forName: name, kind: kind)
        let descriptor = WalletDescriptor(id: id, kind: kind, hasPassphrase: hasPassphrase)

        try database.write { db in
            if kind != .created,
               let existing = try existingWalletMatch(
                for: addresses.map { ($0.chainRaw, $0.address) },
                db: db
               ) {
                throw WalletCommandRepositoryError.alreadyImported(existing)
            }
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

    private struct AddressIdentity: Hashable {
        let chainRaw: String
        let address: String
    }

    private func existingWalletMatch(
        for addresses: [(chainRaw: String, address: String)],
        db: Database
    ) throws -> ExistingWalletImportMatch? {
        let candidates = Set(addresses.compactMap(Self.addressIdentity))
        guard !candidates.isEmpty else { return nil }

        struct MatchScore {
            let match: ExistingWalletImportMatch
            let sortOrder: Int
            var count: Int
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT w.id, w.name, w.sort_order, a.chain_raw, a.address
            FROM wallet_addresses a
            JOIN wallets w ON w.id = a.wallet_id
            ORDER BY w.sort_order ASC, w.created_at_ms ASC
            """
        )
        var scores: [UUID: MatchScore] = [:]
        for row in rows {
            let chainRaw: String = row["chain_raw"]
            let address: String = row["address"]
            guard let identity = Self.addressIdentity((chainRaw, address)),
                  candidates.contains(identity),
                  let walletId = UUID(uuidString: row["id"] as String)
            else { continue }

            if var score = scores[walletId] {
                score.count += 1
                scores[walletId] = score
            } else {
                scores[walletId] = MatchScore(
                    match: ExistingWalletImportMatch(id: walletId, name: row["name"]),
                    sortOrder: row["sort_order"],
                    count: 1
                )
            }
        }

        return scores.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.sortOrder < $1.sortOrder
        }.first?.match
    }

    private static func addressIdentity(
        _ entry: (chainRaw: String, address: String)
    ) -> AddressIdentity? {
        guard let chain = SupportedChain(rawValue: entry.chainRaw) else { return nil }
        var address = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }

        if chain.family == .evm || chain == .aptos || chain == .sui {
            address = address.lowercased()
        } else if chain == .bitcoinCash {
            address = address.lowercased()
            if address.hasPrefix("bitcoincash:") {
                address.removeFirst("bitcoincash:".count)
            }
        }
        return AddressIdentity(chainRaw: chain.rawValue, address: address)
    }

    private func nextSortOrder(_ db: Database) throws -> Int {
        let current = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM wallets") ?? -1
        return current + 1
    }

    private func insertAddressesAndInitialChainStates(
        _ addresses: [AddressSeed],
        walletId: UUID,
        now: Int64,
        db: Database
    ) throws -> [SupportedChain: String] {
        var addressByChain: [SupportedChain: String] = [:]
        for entry in addresses {
            let supportedChain = SupportedChain(rawValue: entry.chainRaw)
            let isFirstAddressForChain = supportedChain.map { addressByChain[$0] == nil } ?? false
            // Prefer caller path (dual Solana Phantom+Trust). Legacy Solana
            // single-row inserts without a path default to Phantom account 0.
            let derivationPath: String
            if !entry.derivationPath.isEmpty {
                derivationPath = entry.derivationPath
            } else if supportedChain == .solana {
                derivationPath = SolanaPathStyle.phantom.derivationPath(account: 0)
            } else {
                derivationPath = ""
            }
            let addressId = UUID()
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path,
                 is_used, is_receive_preferred, last_scanned_at_ms)
                VALUES (?, ?, ?, ?, ?, 0, ?, NULL)
                ON CONFLICT(wallet_id, chain_raw, address) DO UPDATE SET
                    derivation_path = CASE
                        WHEN wallet_addresses.derivation_path = '' THEN excluded.derivation_path
                        ELSE wallet_addresses.derivation_path
                    END,
                    is_receive_preferred = CASE
                        WHEN excluded.is_receive_preferred = 1 THEN 1
                        ELSE wallet_addresses.is_receive_preferred
                    END
                """,
                arguments: [
                    addressId.uuidString,
                    walletId.uuidString,
                    entry.chainRaw,
                    entry.address,
                    derivationPath,
                    isFirstAddressForChain
                ]
            )
            // chain_states is one row per chain — only the preferred (first)
            // address seeds it. Rebuild later sums balances across all path rows.
            if isFirstAddressForChain {
                try db.execute(
                    sql: """
                    INSERT INTO chain_states
                    (id, wallet_id, chain_raw, address, derivation_path,
                     native_balance_raw, native_decimals, native_fiat,
                     native_fiat_numeric, total_fiat, total_fiat_numeric,
                     token_count, fiat_currency_code, sync_state_raw)
                    VALUES (?, ?, ?, ?, ?, '0', 0, '0', 0, '0', 0, 0, ?, 'idle')
                    ON CONFLICT(wallet_id, chain_raw) DO UPDATE SET
                        address = excluded.address,
                        derivation_path = CASE
                            WHEN chain_states.derivation_path = '' THEN excluded.derivation_path
                            ELSE chain_states.derivation_path
                        END
                    """,
                    arguments: [
                        UUID().uuidString,
                        walletId.uuidString,
                        entry.chainRaw,
                        entry.address,
                        derivationPath,
                        CurrencyPreference.defaultCode
                    ]
                )
            }
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
