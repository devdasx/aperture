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
        let oldActive = UserDefaults.standard.string(forKey: ActiveWalletPointer.storageKey)
        defer { cleanup(database: database, previousActiveWalletRaw: oldActive) }
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
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM wallet_addresses WHERE wallet_id = ?",
            arguments: [walletID.uuidString],
            database: database
        ) > 0)
    }

    @Test("mnemonic import state persists with the iCloud restore naming path")
    func mnemonicImportStatePersistsWithDefaultName() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        let oldActive = UserDefaults.standard.string(forKey: ActiveWalletPointer.storageKey)
        defer { cleanup(database: database, previousActiveWalletRaw: oldActive) }
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
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM chain_states WHERE wallet_id = ? AND encrypted_private_key IS NOT NULL",
            arguments: [walletID.uuidString],
            database: database
        ) > 0)
    }

    @Test("private-key import state persists EVM wallet and encrypted secret rows")
    func privateKeyImportStatePersists() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        let oldActive = UserDefaults.standard.string(forKey: ActiveWalletPointer.storageKey)
        defer { cleanup(database: database, previousActiveWalletRaw: oldActive) }
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
        #expect(try WalletSecretPersistence.loadPrivateKey(for: walletID, database: database) == privateKey)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM wallet_addresses WHERE wallet_id = ?",
            arguments: [walletID.uuidString],
            database: database
        ) == ImportWalletState.evmChains.count)
    }

    @Test("watch-only import state persists address-only wallet without key material")
    func watchOnlyImportStatePersists() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        let oldActive = UserDefaults.standard.string(forKey: ActiveWalletPointer.storageKey)
        defer { cleanup(database: database, previousActiveWalletRaw: oldActive) }
        ActiveWalletPointer.configure(database: database)

        let state = ImportWalletState()
        state.watchOnlyAddresses = ["0x0000000000000000000000000000000000000001"]
        let walletID = try await state.persist(
            result: .watchOnly(.ethereum),
            into: WalletCommandRepository(database: database)
        )

        #expect(ActiveWalletPointer.currentId == walletID)
        #expect(try walletKind(walletID, database: database) == WalletKind.watchOnly.rawValue)
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

    private func cleanup(database: AppDatabase, previousActiveWalletRaw: String?) {
        if let ids = try? WalletRepository(database: database).allWalletIds() {
            for id in ids {
                try? SeedVault.deleteSeed(for: id)
                try? MnemonicVault.deleteMnemonic(for: id)
                try? MnemonicVault.deletePrivateKey(for: id)
            }
        }
        TestAppDatabaseFactory.cleanup(database)
        if let previousActiveWalletRaw {
            UserDefaults.standard.set(previousActiveWalletRaw, forKey: ActiveWalletPointer.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ActiveWalletPointer.storageKey)
        }
    }
}
