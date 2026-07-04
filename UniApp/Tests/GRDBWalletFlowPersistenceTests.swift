import Foundation
import GRDB
import Testing
@testable import Aperture

@MainActor
@Suite("GRDB wallet flow persistence")
struct GRDBWalletFlowPersistenceTests {
    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        .split(separator: " ")
        .map(String.init)

    @Test("create-wallet state persists and selects the wallet without nested transactions")
    func createWalletStatePersistsAndSelectsActiveWallet() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { cleanup(database: database) }
        ActiveWalletPointer.configure(database: database)

        let state = CreateWalletState(words: mnemonic)
        let walletID = try await state.persist(
            into: WalletCommandRepository(database: database),
            requiresBackup: true,
            defaultName: "Created Flow"
        )

        #expect(ActiveWalletPointer.currentId == walletID)
        #expect(try WalletRepository(database: database).walletCount() == 1)
        #expect(try walletKind(walletID, database: database) == WalletKind.created.rawValue)
        #expect(try activeWalletRaw(database: database) == walletID.uuidString)
        #expect(try WalletSecretPersistence.loadMnemonic(for: walletID, database: database) == mnemonic)
        #expect(try manualBackupRaw(walletID, database: database) == 0)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM wallet_addresses WHERE wallet_id = ?",
            arguments: [walletID.uuidString],
            database: database
        ) > 0)
        let snapshotWallets = try await observedWalletSnapshot(database: database)
        #expect(snapshotWallets.map(\.id).contains(walletID))
    }

    @Test("mnemonic import state persists with the iCloud restore naming path")
    func mnemonicImportStatePersistsWithDefaultName() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { cleanup(database: database) }
        ActiveWalletPointer.configure(database: database)

        let state = ImportWalletState()
        state.mnemonicWords = mnemonic
        let walletID = try await state.persist(
            result: .mnemonic,
            into: WalletCommandRepository(database: database),
            defaultName: "Cloud Restored Wallet"
        )

        #expect(ActiveWalletPointer.currentId == walletID)
        #expect(try walletName(walletID, database: database) == "Cloud Restored Wallet")
        #expect(try walletKind(walletID, database: database) == WalletKind.importedMnemonic.rawValue)
        #expect(try activeWalletRaw(database: database) == walletID.uuidString)
        #expect(try WalletSecretPersistence.loadMnemonic(for: walletID, database: database) == mnemonic)
        #expect(try manualBackupRaw(walletID, database: database) == 0)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM chain_states WHERE wallet_id = ? AND encrypted_private_key IS NOT NULL",
            arguments: [walletID.uuidString],
            database: database
        ) > 0)
        try database.write { db in
            try db.execute(
                sql: "UPDATE wallets SET manual_backup_completed = NULL WHERE id = ?",
                arguments: [walletID.uuidString]
            )
        }
        let snapshotWallets = try await observedWalletSnapshot(database: database)
        let wallet = try #require(snapshotWallets.first { $0.id == walletID })
        #expect(wallet.manualBackupCompleted == false)
    }

    @Test("private-key import state persists EVM wallet and encrypted secret rows")
    func privateKeyImportStatePersists() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { cleanup(database: database) }
        ActiveWalletPointer.configure(database: database)

        let privateKey = "0x59c6995e998f97a5a0044966f094538f5dae440fdf24c8063c61fbb1c5ab7d7a"
        let state = ImportWalletState()
        state.privateKeyRaw = privateKey
        state.derivedAddressFromKey = try await state.service.deriveAddress(
            fromPrivateKey: privateKey,
            on: .ethereum
        )
        let walletID = try await state.persist(
            result: .privateKey(.ethereum),
            into: WalletCommandRepository(database: database)
        )

        #expect(ActiveWalletPointer.currentId == walletID)
        #expect(try walletKind(walletID, database: database) == WalletKind.importedKey.rawValue)
        #expect(try manualBackupRaw(walletID, database: database) == 0)
        #expect(try WalletSecretPersistence.loadPrivateKey(for: walletID, database: database) == privateKey)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM wallet_addresses WHERE wallet_id = ?",
            arguments: [walletID.uuidString],
            database: database
        ) == ImportWalletState.evmChains.count)
        let snapshotWallets = try await observedWalletSnapshot(database: database)
        #expect(snapshotWallets.map(\.id).contains(walletID))
    }

    @Test("watch-only import state persists address-only wallet without key material")
    func watchOnlyImportStatePersists() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { cleanup(database: database) }
        ActiveWalletPointer.configure(database: database)

        let state = ImportWalletState()
        state.watchOnlyAddresses = ["0x0000000000000000000000000000000000000001"]
        let walletID = try await state.persist(
            result: .watchOnly(.ethereum),
            into: WalletCommandRepository(database: database)
        )

        #expect(ActiveWalletPointer.currentId == walletID)
        #expect(try walletKind(walletID, database: database) == WalletKind.watchOnly.rawValue)
        #expect(try manualBackupRaw(walletID, database: database) == 0)
        #expect(try TestAppDatabaseFactory.count("wallet_secrets", database: database) == 0)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM chain_states WHERE wallet_id = ? AND encrypted_private_key IS NOT NULL",
            arguments: [walletID.uuidString],
            database: database
        ) == 0)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM wallet_addresses WHERE wallet_id = ?",
            arguments: [walletID.uuidString],
            database: database
        ) == ImportWalletState.evmChains.count)
        let snapshotWallets = try await observedWalletSnapshot(database: database)
        #expect(snapshotWallets.map(\.id).contains(walletID))
    }

    private func walletName(_ walletID: UUID, database: AppDatabase) throws -> String? {
        try TestAppDatabaseFactory.scalarString(
            "SELECT name FROM wallets WHERE id = ?",
            arguments: [walletID.uuidString],
            database: database
        )
    }

    private func walletKind(_ walletID: UUID, database: AppDatabase) throws -> String? {
        try TestAppDatabaseFactory.scalarString(
            "SELECT kind_raw FROM wallets WHERE id = ?",
            arguments: [walletID.uuidString],
            database: database
        )
    }

    private func activeWalletRaw(database: AppDatabase) throws -> String? {
        try TestAppDatabaseFactory.scalarString(
            "SELECT wallet_id FROM active_wallet WHERE id = 'active-wallet-singleton'",
            database: database
        )
    }

    private func manualBackupRaw(_ walletID: UUID, database: AppDatabase) throws -> Int {
        try TestAppDatabaseFactory.scalarInt(
            "SELECT manual_backup_completed FROM wallets WHERE id = ?",
            arguments: [walletID.uuidString],
            database: database
        )
    }

    private func observedWalletSnapshot(database: AppDatabase) async throws -> [WalletRecord] {
        let observation = DatabaseSnapshotObservation(database: database)
        for _ in 0..<20 {
            if let error = observation.lastError {
                throw error
            }
            if !observation.wallets.isEmpty {
                return observation.wallets
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let error = observation.lastError {
            throw error
        }
        return observation.wallets
    }

    private func cleanup(database: AppDatabase) {
        if let ids = try? WalletRepository(database: database).allWalletIds() {
            for id in ids {
                try? SeedVault.deleteSeed(for: id)
                try? MnemonicVault.deleteMnemonic(for: id)
                try? MnemonicVault.deletePrivateKey(for: id)
            }
        }
        TestAppDatabaseFactory.cleanup(database)
    }
}
