import Testing
import Foundation
import SwiftData
@testable import Aperture

/// Contract tests for the local-first freshness ledger (Rule #27 §B):
/// `SyncStatusRepository` stamps when each domain/scope last synced, is
/// syncing, or failed — the data the wallet-home `SyncFreshnessLabel`
/// reads. The honesty guarantee under test: **a failed attempt never
/// erases the last KNOWN-good `lastSyncedAt`**, so the UI keeps showing
/// the true age of the data it's displaying instead of blanking it.
@Suite struct SyncStatusRepositoryTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ApertureSchemaV1.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func fetch(
        _ container: ModelContainer,
        domain: SyncDomain,
        scope: String
    ) throws -> SyncStatusRecord? {
        let key = SyncStatusRecord.makeKey(domain: domain, scopeId: scope)
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<SyncStatusRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @Test("markSynced creates a row stamped synced, with lastSyncedAt set")
    func markSyncedCreatesRow() async throws {
        let container = try makeContainer()
        let repo = SyncStatusRepository(modelContainer: container)
        try await repo.markSynced(domain: .balances, scopeId: "w1")

        let row = try fetch(container, domain: .balances, scope: "w1")
        #expect(row != nil)
        #expect(row?.isSyncing == false)
        #expect(row?.lastSyncedAt != nil)
        #expect(row?.lastErrorMessage == nil)
        #expect(row?.domainRaw == SyncDomain.balances.rawValue)
        #expect(row?.scopeId == "w1")
    }

    @Test("markSyncing then markSynced clears syncing and stamps the time")
    func syncingThenSynced() async throws {
        let container = try makeContainer()
        let repo = SyncStatusRepository(modelContainer: container)

        try await repo.markSyncing(domain: .prices, scopeId: SyncDomain.globalScope)
        var row = try fetch(container, domain: .prices, scope: SyncDomain.globalScope)
        #expect(row?.isSyncing == true)
        #expect(row?.lastSyncedAt == nil) // syncing has never succeeded yet

        try await repo.markSynced(domain: .prices, scopeId: SyncDomain.globalScope)
        row = try fetch(container, domain: .prices, scope: SyncDomain.globalScope)
        #expect(row?.isSyncing == false)
        #expect(row?.lastSyncedAt != nil)
    }

    @Test("markFailed records the error but preserves the prior lastSyncedAt")
    func failedPreservesLastSynced() async throws {
        let container = try makeContainer()
        let repo = SyncStatusRepository(modelContainer: container)

        try await repo.markSynced(domain: .transactions, scopeId: "w2")
        let knownGood = try fetch(container, domain: .transactions, scope: "w2")?.lastSyncedAt
        #expect(knownGood != nil)

        try await repo.markFailed(domain: .transactions, scopeId: "w2", error: "network down")
        let row = try fetch(container, domain: .transactions, scope: "w2")
        #expect(row?.isSyncing == false)
        #expect(row?.lastErrorMessage == "network down")
        // The honest invariant: a failure never erases the last good time.
        #expect(row?.lastSyncedAt == knownGood)
    }

    @Test("markFailed truncates an over-long error to 200 chars")
    func failedTruncatesError() async throws {
        let container = try makeContainer()
        let repo = SyncStatusRepository(modelContainer: container)
        let huge = String(repeating: "x", count: 5_000)
        try await repo.markFailed(domain: .balances, scopeId: "w3", error: huge)
        let row = try fetch(container, domain: .balances, scope: "w3")
        #expect((row?.lastErrorMessage?.count ?? 0) <= 200)
    }

    @Test("distinct (domain, scope) pairs get distinct rows; same pair upserts")
    func distinctRowsAndUpsert() async throws {
        let container = try makeContainer()
        let repo = SyncStatusRepository(modelContainer: container)

        try await repo.markSynced(domain: .balances, scopeId: "w1")
        try await repo.markSynced(domain: .balances, scopeId: "w2")
        try await repo.markSynced(domain: .prices, scopeId: SyncDomain.globalScope)
        // Re-stamp an existing pair — must update in place, not duplicate.
        try await repo.markSyncing(domain: .balances, scopeId: "w1")

        let context = ModelContext(container)
        let all = try context.fetch(FetchDescriptor<SyncStatusRecord>())
        #expect(all.count == 3)
    }
}
