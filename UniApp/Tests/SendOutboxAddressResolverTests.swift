import Foundation
import GRDB
import Testing
@testable import Aperture

/// BUG-018: pending outbox must attach to the exact `fromAddress` row —
/// never the chain's preferred address when the draft address is missing
/// or only a different address exists for that chain.
@Suite("Send outbox address resolver (BUG-018)")
struct SendOutboxAddressResolverTests {

    // MARK: - Pure match rules

    @Test("EVM address match is case-insensitive")
    func evmCaseInsensitiveMatch() {
        let lower = "0xabcdef0123456789abcdef0123456789abcdef01"
        let mixed = "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01"
        #expect(
            SendOutboxAddressResolver.matchesAddress(
                stored: lower,
                fromAddress: mixed,
                chain: .ethereum
            )
        )
        #expect(
            !SendOutboxAddressResolver.matchesAddress(
                stored: lower,
                fromAddress: "0x0000000000000000000000000000000000000001",
                chain: .ethereum
            )
        )
    }

    @Test("Bitcoin address match is case-sensitive (exact)")
    func bitcoinExactMatch() {
        let a = "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh"
        let b = "BC1QXY2KGDYGJRSQTZQ2N0YRF2493P83KKFJHX0WLH"
        #expect(
            SendOutboxAddressResolver.matchesAddress(
                stored: a,
                fromAddress: a,
                chain: .bitcoin
            )
        )
        #expect(
            !SendOutboxAddressResolver.matchesAddress(
                stored: a,
                fromAddress: b,
                chain: .bitcoin
            )
        )
    }

    // MARK: - Real DB resolution

    @Test("Exact fromAddress resolves to that addressId, not preferred")
    func exactMatchReturnsThatRowNotPreferred() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        let preferredId = UUID()
        let spentId = UUID()
        let preferredAddress = "bc1qpreferred000000000000000000000000000"
        let spentAddress = "bc1qspentfrom000000000000000000000000000"

        try seedWallet(
            walletId: walletId,
            database: database,
            addresses: [
                (preferredId, preferredAddress, isPreferred: true),
                (spentId, spentAddress, isPreferred: false),
            ],
            chain: .bitcoin
        )

        let resolution = SendOutboxAddressResolver.resolve(
            walletId: walletId,
            chain: .bitcoin,
            fromAddress: spentAddress,
            database: database
        )

        guard case .resolved(_, let addressId) = resolution else {
            Issue.record("Expected .resolved, got \(resolution)")
            return
        }
        #expect(addressId == spentId)
        #expect(addressId != preferredId)
    }

    @Test("Missing fromAddress fails even when preferred address exists")
    func missingFromAddressFailsNoPreferredFallback() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        let preferredId = UUID()
        let preferredAddress = "bc1qpreferred000000000000000000000000000"
        let draftFromAddress = "bc1qnotinstore00000000000000000000000000"

        try seedWallet(
            walletId: walletId,
            database: database,
            addresses: [
                (preferredId, preferredAddress, isPreferred: true),
            ],
            chain: .bitcoin
        )

        let resolution = SendOutboxAddressResolver.resolve(
            walletId: walletId,
            chain: .bitcoin,
            fromAddress: draftFromAddress,
            database: database
        )

        #expect(resolution == .addressNotFound)

        // Regression: old bug would have returned preferredId here.
        if case .resolved(_, let addressId) = resolution {
            Issue.record(
                "Must not fall back to preferred addressId \(addressId); got \(addressId)"
            )
        }
    }

    @Test("Unknown wallet fails with walletNotFound")
    func unknownWallet() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let resolution = SendOutboxAddressResolver.resolve(
            walletId: UUID(),
            chain: .ethereum,
            fromAddress: "0xabcdef0123456789abcdef0123456789abcdef01",
            database: database
        )
        #expect(resolution == .walletNotFound)
    }

    @Test("EVM stored lowercase matches draft checksummed address")
    func evmChecksumVarianceResolvesExactRow() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        let addressId = UUID()
        let preferredOtherId = UUID()
        let stored = "0xabcdef0123456789abcdef0123456789abcdef01"
        let draft = "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01"
        let otherPreferred = "0x1111111111111111111111111111111111111111"

        try seedWallet(
            walletId: walletId,
            database: database,
            addresses: [
                (preferredOtherId, otherPreferred, isPreferred: true),
                (addressId, stored, isPreferred: false),
            ],
            chain: .ethereum
        )

        let resolution = SendOutboxAddressResolver.resolve(
            walletId: walletId,
            chain: .ethereum,
            fromAddress: draft,
            database: database
        )

        guard case .resolved(_, let resolvedId) = resolution else {
            Issue.record("Expected .resolved for EVM checksum variance, got \(resolution)")
            return
        }
        #expect(resolvedId == addressId)
        #expect(resolvedId != preferredOtherId)
    }

    @Test("Pending outbox row attaches to exact addressId (not preferred)")
    func pendingOutboxWritesUnderExactAddressId() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        let preferredId = UUID()
        let spentId = UUID()
        let preferredAddress = "bc1qpreferred000000000000000000000000000"
        let spentAddress = "bc1qspentfrom000000000000000000000000000"

        try seedWallet(
            walletId: walletId,
            database: database,
            addresses: [
                (preferredId, preferredAddress, isPreferred: true),
                (spentId, spentAddress, isPreferred: false),
            ],
            chain: .bitcoin
        )

        // Mirror SendExecutor: resolve exact, then write pending under that id.
        let resolution = SendOutboxAddressResolver.resolve(
            walletId: walletId,
            chain: .bitcoin,
            fromAddress: spentAddress,
            database: database
        )
        guard case .resolved(_, let addressId) = resolution else {
            Issue.record("Expected resolve success")
            return
        }
        #expect(addressId == spentId)

        let txHash = "deadbeef" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let recordId = UUID()
        try TransactionRepository(database: database).upsertTransaction(
            addressId: addressId,
            txHash: txHash,
            direction: .outgoing,
            amountRaw: "100000",
            tokenSymbol: "BTC",
            tokenContract: nil,
            kind: nil,
            blockNumber: nil,
            occurredAt: Date(),
            status: .pending,
            counterparty: "bc1qrecipient00000000000000000000000000",
            feeRaw: "250",
            id: recordId,
            save: true
        )

        let storedAddressId = try TestAppDatabaseFactory.scalarString(
            "SELECT address_id FROM transactions WHERE id = ?",
            arguments: [recordId.uuidString],
            database: database
        )
        #expect(storedAddressId == spentId.uuidString)
        #expect(storedAddressId != preferredId.uuidString)

        // Confirm we never wrote under preferred just because it was preferred.
        let preferredPending = try TestAppDatabaseFactory.scalarInt(
            """
            SELECT COUNT(*) FROM transactions
            WHERE address_id = ? AND status_raw = 'pending'
            """,
            arguments: [preferredId.uuidString],
            database: database
        )
        #expect(preferredPending == 0)
    }

    @Test("Send path refuses when only preferred exists and fromAddress differs")
    func sendPathMapsAddressNotFoundToMalformedDraftSemantics() throws {
        // Documents the contract SendExecutor.execute uses: addressNotFound
        // → SigningError.malformedDraft (not silent attach to preferred).
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        try seedWallet(
            walletId: walletId,
            database: database,
            addresses: [
                (UUID(), "bc1qpreferred000000000000000000000000000", isPreferred: true),
            ],
            chain: .bitcoin
        )

        switch SendOutboxAddressResolver.resolve(
            walletId: walletId,
            chain: .bitcoin,
            fromAddress: "bc1qotheraddress000000000000000000000000",
            database: database
        ) {
        case .addressNotFound:
            break // expected — executor returns .failure(.malformedDraft(...))
        case .walletNotFound:
            Issue.record("Wallet should exist")
        case .resolved(_, let id):
            Issue.record("Must not resolve preferred fallback \(id)")
        }
    }

    // MARK: - Helpers

    private func seedWallet(
        walletId: UUID,
        database: AppDatabase,
        addresses: [(id: UUID, address: String, isPreferred: Bool)],
        chain: SupportedChain
    ) throws {
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'BUG-018', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            for entry in addresses {
                try db.execute(
                    sql: """
                    INSERT INTO wallet_addresses
                    (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                    VALUES (?, ?, ?, ?, ?, 0, ?)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        walletId.uuidString,
                        chain.rawValue,
                        entry.address,
                        "m/test/0",
                        entry.isPreferred ? 1 : 0,
                    ]
                )
            }
        }
    }
}
