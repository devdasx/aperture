import Foundation
import GRDB
import OSLog
import WalletCore

/// One-shot + on-demand rewrite of EVM `wallet_addresses` to the unified
/// Ethereum path address (`m/44'/60'/0'/0/0`) — BUG-002.
///
/// Existing mnemonic wallets may still hold Trust Wallet–style per-L2
/// addresses derived from distinct WalletCore coin ids. After the coin-map
/// fix, signing uses the Ethereum key, so stored L2 rows must match that
/// address or nonce/parity breaks.
///
/// **Passphrase wallets:** require the passphrase (never persisted). Call
/// `unifyWalletIfNeeded` when the user supplies it (send / export).
enum EVMUnifiedAddressMigration {
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "evm-address-migration")
    static let preferenceKey = "migration.evmUnifiedAddress.v1"

    private static var evmChainRaws: [String] {
        SupportedChain.allCases.filter { $0.family == .evm }.map(\.rawValue)
    }

    /// Bootstrap pass: migrate every mnemonic wallet whose secret is
    /// available without a passphrase. Self-gated by `preferenceKey`.
    static func runBootstrapIfNeeded(database: AppDatabase = .shared) {
        if AppPreferenceStore.shared.bool(preferenceKey, default: false) {
            return
        }
        do {
            let walletIds = try loadMigratableWalletIds(database: database)
            var migrated = 0
            for id in walletIds {
                if (try? unifyWallet(id, passphrase: nil, database: database)) == true {
                    migrated += 1
                }
            }
            AppPreferenceStore.shared.set(true, forKey: preferenceKey)
            log.notice("EVM unified-address migration finished wallets=\(migrated, privacy: .public)")
            DiagnosticsLogStore.shared.record(
                .info,
                category: "migration",
                message: "EVM unified address migration finished",
                metadata: ["migratedWallets": String(migrated)]
            )
        } catch {
            log.error("EVM unified-address migration failed: \(String(describing: error), privacy: .public)")
            DiagnosticsLogStore.shared.record(
                .error,
                category: "migration",
                message: "EVM unified address migration failed",
                metadata: ["error": String(describing: error)]
            )
        }
    }

    /// Ensure this wallet's EVM address rows match the Ethereum derivation.
    /// Returns `true` when at least one row was updated.
    @discardableResult
    static func unifyWalletIfNeeded(
        walletId: UUID,
        passphrase: String? = nil,
        database: AppDatabase = .shared
    ) throws -> Bool {
        try unifyWallet(walletId, passphrase: passphrase, database: database)
    }

    // MARK: - Core

    @discardableResult
    private static func unifyWallet(
        _ walletId: UUID,
        passphrase: String?,
        database: AppDatabase
    ) throws -> Bool {
        let meta = try database.read { db -> (kind: String, hasPassphrase: Bool)? in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT kind_raw, has_passphrase
                FROM wallets
                WHERE id = ?
                LIMIT 1
                """,
                arguments: [walletId.uuidString]
            ) else { return nil }
            return (kind: row["kind_raw"], hasPassphrase: (row["has_passphrase"] as Int) != 0)
        }
        guard let meta else { return false }
        let kind = WalletKind(rawValue: meta.kind) ?? .watchOnly
        guard kind == .created || kind == .importedMnemonic else { return false }
        if meta.hasPassphrase && passphrase == nil { return false }

        let resolvedPassphrase = passphrase ?? ""
        guard let words = try WalletSecretPersistence.loadMnemonic(for: walletId, database: database),
              !words.isEmpty,
              let hdWallet = HDWallet(
                  mnemonic: words.joined(separator: " "),
                  passphrase: resolvedPassphrase
              )
        else { return false }

        let ethAddress = hdWallet.getAddressForCoin(coin: ChainCoinType.evm)
        guard !ethAddress.isEmpty else { return false }

        let chainRaws = evmChainRaws
        let placeholders = Array(repeating: "?", count: chainRaws.count).joined(separator: ",")
        var arguments: [any DatabaseValueConvertible] = [walletId.uuidString]
        arguments.append(contentsOf: chainRaws)

        let existing: [(id: String, chain: String, address: String)] = try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, chain_raw, address
                FROM wallet_addresses
                WHERE wallet_id = ?
                  AND chain_raw IN (\(placeholders))
                """,
                arguments: StatementArguments(arguments)
            )
            return rows.map { (id: $0["id"], chain: $0["chain_raw"], address: $0["address"]) }
        }

        let mismatched = existing.filter {
            $0.address.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(ethAddress) != .orderedSame
        }
        guard !mismatched.isEmpty else { return false }

        try database.write { db in
            for row in mismatched {
                try db.execute(
                    sql: """
                    UPDATE wallet_addresses
                    SET address = ?
                    WHERE id = ?
                    """,
                    arguments: [ethAddress, row.id]
                )
            }
            // Drop sealed per-chain keys so the next refresh re-seals the
            // Ethereum key against the unified address (parity).
            try db.execute(
                sql: """
                UPDATE chain_states
                SET encrypted_private_key = NULL,
                    key_encryption_scheme = NULL
                WHERE wallet_id = ?
                  AND chain_raw IN (\(placeholders))
                """,
                arguments: StatementArguments(arguments)
            )
        }

        log.notice(
            "Unified EVM addresses for wallet \(walletId.uuidString, privacy: .public) rows=\(mismatched.count, privacy: .public)"
        )
        return true
    }

    private static func loadMigratableWalletIds(database: AppDatabase) throws -> [UUID] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id FROM wallets
                WHERE kind_raw IN ('created', 'importedMnemonic')
                  AND has_passphrase = 0
                """
            )
            return rows.compactMap { UUID(uuidString: $0["id"]) }
        }
    }
}
