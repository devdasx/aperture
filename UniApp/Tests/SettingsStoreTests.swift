import Testing
import Foundation
import SwiftData
@testable import Aperture

/// Contract tests for the local-first settings row (Rule #27 §D).
/// `SettingsStore.syncFromAppStorage` reads `UserDefaults.standard`,
/// which the test bundle shares with the host — asserting against it
/// would race a parallel dev session (same boundary `ResetCompletenessTests`
/// documents for Keychain). So these pin the DB-side contract: the
/// singleton is exactly one row and fetch-or-create is idempotent.
@MainActor
@Suite struct SettingsStoreTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ApertureSchemaV1.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("fetchOrCreate returns the singleton and never duplicates it")
    func singletonIsStable() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let first = SettingsStore.fetchOrCreate(in: context)
        #expect(first.id == AppSettingsRecord.singletonId)
        try context.save()

        let second = SettingsStore.fetchOrCreate(in: context)
        #expect(second.id == AppSettingsRecord.singletonId)
        try context.save()

        let count = try context.fetchCount(FetchDescriptor<AppSettingsRecord>())
        #expect(count == 1)
    }

    @Test("a fresh settings row carries the documented defaults")
    func freshRowDefaults() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let record = SettingsStore.fetchOrCreate(in: context)
        // The init defaults must match the on-by-default preferences so a
        // pre-sync read is honest (haptics on, background refresh on).
        #expect(record.hapticFeedbackEnabled == true)
        #expect(record.backgroundBalanceRefresh == true)
        #expect(record.pinEnabled == false)
        #expect(record.biometricEnabled == false)
        #expect(record.isTestMode == false)
    }
}
