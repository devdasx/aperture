import Foundation
import SwiftData
import Testing
@testable import Aperture

@Suite struct ActiveWalletPointerTests {
    private func insertWallet(
        _ id: UUID,
        name: String,
        sortOrder: Int,
        in context: ModelContext
    ) throws {
        context.insert(WalletRecord(
            id: id,
            name: name,
            kind: .created,
            mnemonicWordCount: 12,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: sortOrder,
            requiresBackup: false
        ))
        try context.save()
    }

    @Test("setting active wallet persists walletID schema and compatibility mirrors")
    @MainActor
    func setPersistsWalletIDSchemaAndMirrors() throws {
        let container = try TestModelContainerFactory.makeContainer(name: "active-wallet-set")
        let context = ModelContext(container)
        let walletID = UUID()
        try insertWallet(walletID, name: "Primary", sortOrder: 0, in: context)

        let priorRaw = UserDefaults.standard.string(forKey: ActiveWalletPointer.storageKey)
        UserDefaults.standard.set("", forKey: ActiveWalletPointer.storageKey)
        defer {
            UserDefaults.standard.set(priorRaw ?? "", forKey: ActiveWalletPointer.storageKey)
        }

        ActiveWalletPointer.configure(modelContainer: container)
        ActiveWalletPointer.set(walletID)

        let verifyContext = ModelContext(container)
        let active = ActiveWalletStore.fetchOrCreate(in: verifyContext)
        let settings = SettingsStore.fetchOrCreate(in: verifyContext)
        #expect(active.walletID == walletID)
        #expect(settings.activeWalletId == walletID.uuidString)
        #expect(ActiveWalletPointer.currentId == walletID)
    }

    @Test("configure migrates legacy activeWalletId into walletID schema")
    @MainActor
    func configureMigratesLegacySettingsPointer() throws {
        let container = try TestModelContainerFactory.makeContainer(name: "active-wallet-migrate")
        let context = ModelContext(container)
        let walletID = UUID()
        try insertWallet(walletID, name: "Migrated", sortOrder: 0, in: context)
        let settings = SettingsStore.fetchOrCreate(in: context)
        settings.activeWalletId = walletID.uuidString
        try context.save()

        let priorRaw = UserDefaults.standard.string(forKey: ActiveWalletPointer.storageKey)
        UserDefaults.standard.set("", forKey: ActiveWalletPointer.storageKey)
        defer {
            UserDefaults.standard.set(priorRaw ?? "", forKey: ActiveWalletPointer.storageKey)
        }

        ActiveWalletPointer.configure(modelContainer: container)

        let verifyContext = ModelContext(container)
        let active = ActiveWalletStore.fetchOrCreate(in: verifyContext)
        #expect(active.walletID == walletID)
        #expect(ActiveWalletPointer.currentId == walletID)
    }

    @Test("resolver refuses to fall back to another wallet for stale IDs")
    func resolverDoesNotFallbackForStaleExplicitID() throws {
        let container = try TestModelContainerFactory.makeContainer(name: "active-wallet-resolver")
        let context = ModelContext(container)
        let walletA = UUID()
        let walletB = UUID()
        try insertWallet(walletA, name: "A", sortOrder: 0, in: context)
        try insertWallet(walletB, name: "B", sortOrder: 1, in: context)
        let wallets = try context.fetch(FetchDescriptor<WalletRecord>(
            sortBy: [SortDescriptor(\WalletRecord.sortOrder, order: .forward)]
        ))

        #expect(ActiveWalletResolver.resolve(rawID: walletB.uuidString, wallets: wallets)?.id == walletB)
        #expect(ActiveWalletResolver.resolve(rawID: UUID().uuidString, wallets: wallets) == nil)
        #expect(ActiveWalletResolver.resolve(rawID: "", wallets: wallets) == nil)
        #expect(!ActiveWalletResolver.shouldHeal(rawID: UUID().uuidString, wallets: wallets))
        #expect(ActiveWalletResolver.shouldHeal(rawID: "", wallets: wallets))
    }
}
