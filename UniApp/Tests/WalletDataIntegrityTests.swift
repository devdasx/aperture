import Foundation
import SwiftData
import Testing
import WalletCore
@testable import Aperture

@Suite struct WalletDataIntegrityTests {
    private func ethereumAddress(for privateKeyHex: String) throws -> (address: String, keyData: Data) {
        let keyData = try WalletCoreKeyImportService.decodePrivateKeyBytes(privateKeyHex, on: .ethereum)
        #expect(PrivateKey.isValid(data: keyData, curve: CoinType.ethereum.curve))
        let privateKey = try #require(PrivateKey(data: keyData))
        return (CoinType.ethereum.deriveAddress(privateKey: privateKey), keyData)
    }

    @Test("imported mnemonic is persisted in encrypted SwiftData and loaded DB-first")
    func importedMnemonicPersistsInEncryptedDatabase() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "wallet-data-integrity-mnemonic")
        let repo = WalletRepository(modelContainer: container)
        let walletId = UUID()

        try await repo.insertImportedMnemonicWallet(
            id: walletId,
            name: "Imported",
            mnemonicWordCount: 2,
            hasPassphrase: false,
            colorTag: "default",
            mnemonicWords: ["Abandon", "ABILITY"],
            addresses: []
        )

        let context = ModelContext(container)
        let loaded = try WalletSecretPersistence.loadMnemonic(for: walletId, in: context)
        #expect(loaded == ["abandon", "ability"])
        #expect(WalletSecretPersistence.hasSecret(kind: .mnemonic, for: walletId, in: context))
    }

    @Test("corrupt DB mnemonic falls back to legacy Keychain and repairs SwiftData")
    func corruptDatabaseMnemonicFallsBackToLegacyAndRepairs() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "wallet-data-integrity-mnemonic-repair")
        let walletId = UUID()
        defer { try? MnemonicVault.deleteMnemonic(for: walletId) }

        let context = ModelContext(container)
        try WalletSecretPersistence.upsertMnemonic(["wrong", "words"], for: walletId, in: context)
        let key = WalletSecretRecord.storageKey(walletId: walletId, kind: .mnemonic)
        var descriptor = FetchDescriptor<WalletSecretRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        let row = try #require(context.fetch(descriptor).first)
        row.cipherData = Data("not-a-valid-aes-gcm-box".utf8)
        try context.save()

        try MnemonicVault.storeMnemonic(["abandon", "ability"], for: walletId)

        let loaded = try await WalletSecretRepository(modelContainer: container)
            .loadMnemonic(for: walletId)
        #expect(loaded == ["abandon", "ability"])

        let repairedContext = ModelContext(container)
        let repaired = try WalletSecretPersistence.loadMnemonic(for: walletId, in: repairedContext)
        #expect(repaired == ["abandon", "ability"])
    }

    @Test("corrupt DB mnemonic without fallback is unavailable, not missing")
    func corruptDatabaseMnemonicWithoutFallbackIsUnavailable() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "wallet-data-integrity-mnemonic-unavailable")
        let walletId = UUID()
        try? MnemonicVault.deleteMnemonic(for: walletId)

        let context = ModelContext(container)
        try WalletSecretPersistence.upsertMnemonic(["wrong", "words"], for: walletId, in: context)
        let key = WalletSecretRecord.storageKey(walletId: walletId, kind: .mnemonic)
        var descriptor = FetchDescriptor<WalletSecretRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        let row = try #require(context.fetch(descriptor).first)
        row.cipherData = Data("not-a-valid-aes-gcm-box".utf8)
        try context.save()

        let availability = await WalletSecretRepository(modelContainer: container)
            .mnemonicAvailability(for: walletId)
        #expect(availability == .encryptedRecordUnavailable)
    }

    @Test("imported private-key wallet stores the secret and encrypted per-chain key")
    func importedPrivateKeyStoresChainKey() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "wallet-data-integrity-private-key")
        let repo = WalletRepository(modelContainer: container)
        let walletId = UUID()
        let privateKey = "0x0000000000000000000000000000000000000000000000000000000000000001"
        let derived = try ethereumAddress(for: privateKey)

        try await repo.insertImportedKeyWallet(
            id: walletId,
            name: "Key Wallet",
            colorTag: "default",
            privateKey: privateKey,
            addresses: [(SupportedChain.ethereum.rawValue, derived.address)]
        )

        let context = ModelContext(container)
        let loadedKey = try WalletSecretPersistence.loadPrivateKey(for: walletId, in: context)
        #expect(loadedKey == privateKey)

        let chainRaw = SupportedChain.ethereum.rawValue
        let rows = try context.fetch(FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        ))
        let chainState = try #require(rows.first)
        #expect(chainState.keyEncryptionScheme == ChainKeyVault.scheme)
        let encrypted = try #require(chainState.encryptedPrivateKey)
        #expect(try ChainKeyVault.open(encrypted) == derived.keyData)
    }

    @Test("chain-key backfill repairs missing encrypted key from stored DB secret")
    func chainKeyBackfillUsesStoredSecret() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "wallet-data-integrity-backfill")
        let repo = WalletRepository(modelContainer: container)
        let walletId = UUID()
        let privateKey = "0x0000000000000000000000000000000000000000000000000000000000000002"
        let derived = try ethereumAddress(for: privateKey)

        try await repo.insertImportedKeyWallet(
            id: walletId,
            name: "Backfill Wallet",
            colorTag: "default",
            privateKey: privateKey,
            addresses: [(SupportedChain.ethereum.rawValue, derived.address)]
        )

        let context = ModelContext(container)
        let chainRaw = SupportedChain.ethereum.rawValue
        let rows = try context.fetch(FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        ))
        let chainState = try #require(rows.first)
        chainState.encryptedPrivateKey = nil
        chainState.keyEncryptionScheme = nil
        try context.save()

        try await repo.backfillEncryptedChainKeysFromStoredSecrets()

        let repairedRows = try context.fetch(FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        ))
        let repaired = try #require(repairedRows.first)
        #expect(repaired.keyEncryptionScheme == ChainKeyVault.scheme)
        let encrypted = try #require(repaired.encryptedPrivateKey)
        #expect(try ChainKeyVault.open(encrypted) == derived.keyData)
    }
}
