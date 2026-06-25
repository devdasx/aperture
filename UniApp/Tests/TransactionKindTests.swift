import Testing
import Foundation
import SwiftData
@testable import Aperture

/// Transaction taxonomy contract tests against an isolated temporary SwiftData
/// store:
///
/// 1. Kind mapping at upsert — `.internal` direction → `.selfTransfer`
///    when the caller doesn't classify; everything else → `.transfer`;
///    explicit kinds persist and may reclassify on a later upsert.
/// 2. Legacy rows (`kindRaw == nil`, written before the column
///    existed) resolve through the direction-derived default.
/// 3. Repository filters — sending (direction), receiving (direction),
///    failed (status), bridge / self (kind) — and per-wallet
///    isolation, ordering, and limit.
@Suite struct TransactionKindTests {

    // MARK: - Fixtures

    private struct Fixture {
        let container: ModelContainer
        let repo: TransactionRepository
        let walletId: UUID
        let addressId: UUID
    }

    private func makeFixture() throws -> Fixture {
        let container = try TestModelContainerFactory.makeContainer()
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Test", kind: .watchOnly, mnemonicWordCount: nil,
            hasPassphrase: false, colorTag: "default", sortOrder: 0, requiresBackup: false
        )
        context.insert(wallet)
        let address = WalletAddressRecord(chainRaw: "ethereum", address: "0xabc")
        address.wallet = wallet
        context.insert(address)
        try context.save()
        return Fixture(
            container: container,
            repo: TransactionRepository(modelContainer: container),
            walletId: wallet.id,
            addressId: address.id
        )
    }

    private func upsert(
        _ fixture: Fixture,
        txHash: String,
        direction: TransactionDirection,
        kind: TransactionKind? = nil,
        status: TransactionStatus = .confirmed,
        symbol: String = "ETH",
        counterparty: String = "0xdead",
        occurredAt: Date = Date()
    ) async throws {
        try await fixture.repo.upsertTransaction(
            addressId: fixture.addressId,
            txHash: txHash,
            direction: direction,
            amountRaw: "1",
            tokenSymbol: symbol,
            tokenContract: nil,
            kind: kind,
            blockNumber: 1,
            occurredAt: occurredAt,
            status: status,
            counterparty: counterparty,
            feeRaw: nil
        )
    }

    // MARK: - T-067 post-swap taxonomy

    // Former bridge-router address. Counterparty allowlist classification was
    // removed with the swap feature; kept here to prove it no longer relabels
    // unclassified scanner legs.
    private static let acrossBridge = "0x5c7bcd6e7de5423a257d81b442095a1a6ced35c5"

    @Test("classifyKind maps only direction to the default kind")
    func classifyKindMapping() {
        #expect(TransactionRepository.classifyKind(direction: .outgoing) == .transfer)
        #expect(TransactionRepository.classifyKind(direction: .incoming) == .transfer)
        #expect(TransactionRepository.classifyKind(direction: .internal) == .selfTransfer)
    }

    @Test("an unclassified leg to a former bridge router persists as .transfer")
    func upsertDoesNotClassifyRouterCounterparty() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, counterparty: Self.acrossBridge)
        let rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.first?.kind == .transfer)
    }

    @Test("a nil-kind re-scan does not upgrade a stored .transfer from counterparty")
    func rescanKeepsTransferForRouterCounterparty() async throws {
        let fixture = try makeFixture()
        let when = Date()
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, counterparty: "0xdead", occurredAt: when)
        var rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.first?.kind == .transfer)
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, counterparty: Self.acrossBridge, occurredAt: when)
        rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.count == 1, "same leg identity upserts in place")
        #expect(rows.first?.kind == .transfer)
    }

    @Test("a nil-kind re-scan NEVER downgrades an explicit .bridge")
    func rescanNeverDowngrades() async throws {
        let fixture = try makeFixture()
        let when = Date()
        // Explicit bridge classification from a caller that knows the action.
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, kind: .bridge, counterparty: "0xdead", occurredAt: when)
        // A later unclassified poll must not overwrite the stronger explicit
        // .bridge, even when the counterparty is a former router address.
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, counterparty: Self.acrossBridge, occurredAt: when)
        let rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.first?.kind == .bridge)
    }

    // MARK: - Raw-value stability (schema contract)

    @Test("TransactionKind raw values are stable schema strings")
    func rawValuesAreStable() {
        #expect(TransactionKind.transfer.rawValue == "transfer")
        #expect(TransactionKind.bridge.rawValue == "bridge")
        #expect(TransactionKind.selfTransfer.rawValue == "selfTransfer")
    }

    // MARK: - Mapping at upsert

    @Test("an unclassified .internal leg persists as .selfTransfer")
    func internalMapsToSelfTransfer() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .internal)
        let rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.count == 1)
        #expect(rows.first?.kind == .selfTransfer)
    }

    @Test("unclassified incoming and outgoing legs persist as .transfer")
    func nonInternalDefaultsToTransfer() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .incoming)
        try await upsert(fixture, txHash: "0x2", direction: .outgoing)
        let rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.kind == .transfer })
    }

    @Test("an explicit kind persists verbatim")
    func explicitKindPersists() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, kind: .bridge)
        let rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.first?.kind == .bridge)
    }

    @Test("a later explicit kind reclassifies the same leg; a nil-kind touch never downgrades")
    func reclassificationRules() async throws {
        let fixture = try makeFixture()
        let when = Date()
        // Same leg identity (hash + address + asset + direction).
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, occurredAt: when)
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, kind: .bridge, occurredAt: when)
        var rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.count == 1, "same leg identity upserts in place")
        #expect(rows.first?.kind == .bridge)

        // A later unclassified poll of the same leg must NOT reset the
        // adapter's classification back to .transfer.
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, occurredAt: when)
        rows = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(rows.first?.kind == .bridge)
    }

    // MARK: - Legacy rows

    @Test("legacy rows with nil kindRaw resolve through the direction-derived default")
    func legacyNilKindResolves() async throws {
        let fixture = try makeFixture()
        // Simulate rows written before the taxonomy column existed —
        // direct context insert with kindRaw left nil.
        let context = ModelContext(fixture.container)
        var descriptor = FetchDescriptor<WalletAddressRecord>()
        descriptor.fetchLimit = 1
        let address = try #require(try context.fetch(descriptor).first)
        for (hash, directionRaw) in [("0xa", "internal"), ("0xb", "incoming")] {
            let record = TransactionRecord(
                txHash: hash,
                direction: TransactionDirection(rawValue: directionRaw) ?? .incoming,
                amountRaw: "1",
                tokenSymbol: "ETH",
                occurredAt: Date(),
                status: .confirmed,
                counterparty: "0xdead"
            )
            record.kindRaw = nil
            record.address = address
            record.addressId = address.id
            context.insert(record)
        }
        try context.save()

        let selfTransfers = try await fixture.repo.transactions(
            walletId: fixture.walletId, kind: .selfTransfer
        )
        let transfers = try await fixture.repo.transactions(
            walletId: fixture.walletId, kind: .transfer
        )
        #expect(selfTransfers.map(\.txHash) == ["0xa"])
        #expect(transfers.map(\.txHash) == ["0xb"])
    }

    // MARK: - Filters

    @Test("kind filter returns only matching legs")
    func filterByKind() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .outgoing)                  // transfer
        try await upsert(fixture, txHash: "0x2", direction: .internal)                  // selfTransfer
        try await upsert(fixture, txHash: "0x3", direction: .incoming, kind: .bridge)   // bridge

        let bridges = try await fixture.repo.transactions(walletId: fixture.walletId, kind: .bridge)
        let selfs = try await fixture.repo.transactions(walletId: fixture.walletId, kind: .selfTransfer)
        #expect(bridges.map(\.txHash) == ["0x3"])
        #expect(selfs.map(\.txHash) == ["0x2"])
    }

    @Test("failed filter (status axis) returns only failed legs")
    func filterFailed() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, status: .confirmed)
        try await upsert(fixture, txHash: "0x2", direction: .outgoing, status: .failed)
        try await upsert(fixture, txHash: "0x3", direction: .incoming, status: .pending)

        let failed = try await fixture.repo.failedTransactions(walletId: fixture.walletId)
        #expect(failed.map(\.txHash) == ["0x2"])
    }

    @Test("direction filters: sending = outgoing, receiving = incoming")
    func filterDirections() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .outgoing)
        try await upsert(fixture, txHash: "0x2", direction: .incoming)
        try await upsert(fixture, txHash: "0x3", direction: .internal)

        let sending = try await fixture.repo.transactions(walletId: fixture.walletId, direction: .outgoing)
        let receiving = try await fixture.repo.transactions(walletId: fixture.walletId, direction: .incoming)
        #expect(sending.map(\.txHash) == ["0x1"])
        #expect(receiving.map(\.txHash) == ["0x2"])
    }

    @Test("filters compose: failed bridges only")
    func filtersCompose() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0x1", direction: .outgoing, kind: .bridge, status: .confirmed)
        try await upsert(fixture, txHash: "0x2", direction: .outgoing, kind: .bridge, status: .failed)
        try await upsert(fixture, txHash: "0x3", direction: .outgoing, status: .failed)

        let failedBridges = try await fixture.repo.transactions(
            walletId: fixture.walletId, kind: .bridge, status: .failed
        )
        #expect(failedBridges.map(\.txHash) == ["0x2"])
    }

    // MARK: - Ordering, limit, isolation

    @Test("results are newest-first and the limit caps the result")
    func orderingAndLimit() async throws {
        let fixture = try makeFixture()
        let t0 = Date()
        try await upsert(fixture, txHash: "0xold", direction: .incoming, occurredAt: t0.addingTimeInterval(-200))
        try await upsert(fixture, txHash: "0xmid", direction: .incoming, occurredAt: t0.addingTimeInterval(-100))
        try await upsert(fixture, txHash: "0xnew", direction: .incoming, occurredAt: t0)

        let all = try await fixture.repo.transactions(walletId: fixture.walletId)
        #expect(all.map(\.txHash) == ["0xnew", "0xmid", "0xold"])

        let limited = try await fixture.repo.transactions(walletId: fixture.walletId, limit: 2)
        #expect(limited.map(\.txHash) == ["0xnew", "0xmid"])
    }

    @Test("per-wallet isolation: wallet A's query never returns wallet B's legs")
    func perWalletIsolation() async throws {
        let fixture = try makeFixture()
        try await upsert(fixture, txHash: "0xa", direction: .incoming)

        // Second wallet + address in the same store.
        let context = ModelContext(fixture.container)
        let walletB = WalletRecord(
            name: "Other", kind: .watchOnly, mnemonicWordCount: nil,
            hasPassphrase: false, colorTag: "default", sortOrder: 1, requiresBackup: false
        )
        context.insert(walletB)
        let addressB = WalletAddressRecord(chainRaw: "ethereum", address: "0xdef")
        addressB.wallet = walletB
        context.insert(addressB)
        try context.save()
        let addressBId = addressB.id
        let walletBId = walletB.id

        try await fixture.repo.upsertTransaction(
            addressId: addressBId,
            txHash: "0xb",
            direction: .incoming,
            amountRaw: "2",
            tokenSymbol: "ETH",
            tokenContract: nil,
            blockNumber: 1,
            occurredAt: Date(),
            status: .confirmed,
            counterparty: "0xdead",
            feeRaw: nil
        )

        let rowsA = try await fixture.repo.transactions(walletId: fixture.walletId)
        let rowsB = try await fixture.repo.transactions(walletId: walletBId)
        #expect(rowsA.map(\.txHash) == ["0xa"])
        #expect(rowsB.map(\.txHash) == ["0xb"])
    }

    @Test("an unknown wallet id returns an empty result, not an error")
    func unknownWalletReturnsEmpty() async throws {
        let fixture = try makeFixture()
        let rows = try await fixture.repo.transactions(walletId: UUID())
        #expect(rows.isEmpty)
    }
}
