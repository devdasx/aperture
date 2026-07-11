import Foundation
import Testing
@testable import Aperture

/// M-001…M-011: code / docs / UI honesty regressions.
@Suite("Misunderstanding honesty (M-001…011)")
struct MisunderstandingHonestyTests {

    // MARK: - M-001 account-state load fallback

    @Test("Account-state load falls back when preferred address has no row")
    func accountStateFallback() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletId = UUID()
        let addressWithState = UUID()
        let addressWithout = UUID()
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'M-001', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'ripple', 'rPreferredNoState', 'm/44''/144''/0''/0/0', 1, 1)
                """,
                arguments: [addressWithout.uuidString, walletId.uuidString]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'ripple', 'rHasState', 'm/44''/144''/0''/0/1', 1, 0)
                """,
                arguments: [addressWithState.uuidString, walletId.uuidString]
            )
        }
        try ChainAccountStateRepository(database: database).upsert(
            addressId: addressWithState,
            chain: .ripple,
            state: ChainAccountStateSnapshot(
                ownerCount: 7,
                subentryCount: 0,
                numSponsoring: 0,
                numSponsored: 0,
                sellingLiabilitiesRaw: "0",
                frozenRaw: "0",
                reservedRaw: "0",
                storageUsageBytes: 0,
                lockedRaw: "0",
                freeRaw: ""
            )
        )
        // Preferred has no state row — must fall back to rHasState (ownerCount 7).
        let snap = try ChainAccountStateRepository(database: database).load(
            walletId: walletId,
            chain: .ripple,
            preferredAddress: "rPreferredNoState"
        )
        #expect(snap?.ownerCount == 7)
    }

    // MARK: - M-007 XRP ter* never applied success

    @Test("All ter* codes are notAppliedRetryable, never appliedSuccess")
    func terNeverSuccess() {
        for code in ["terQUEUED", "terNO_ACCOUNT", "terRETRY", "terFUNDS_SPENT", "terPRE_SEQ"] {
            #expect(BroadcastService.xrpSubmitOutcome(code) == .notAppliedRetryable)
            #expect(BroadcastService.xrpSubmitOutcome(code) != .appliedSuccess)
        }
        #expect(BroadcastService.xrpSubmitOutcome("tesSUCCESS") == .appliedSuccess)
    }

    // MARK: - M-006 chainNotWired is defensive residual

    @Test("chainNotWired user message remains honest refuse")
    func chainNotWiredHonest() {
        let msg = SigningError.chainNotWired(.sui).userMessage
        #expect(msg.lowercased().contains("available") || msg.lowercased().contains("sui"))
    }

    // MARK: - M-011 fee ETA is chain-specific

    @Test("Fee ETA for Solana differs from Bitcoin")
    func feeETANotUniversal() {
        let btc = SendFeeSheet.etaCopy(for: .bitcoin)
        let sol = SendFeeSheet.etaCopy(for: .solana)
        #expect(btc.slow != sol.slow)
        #expect(btc.normal.contains("min") || btc.slow.contains("min"))
        #expect(sol.fast.contains("slot") || sol.normal.contains("s"))
    }

    // MARK: - M-010 failed status label is Failed

    @Test("Failed status rawValue is failed not canceled")
    func failedStatusRaw() {
        #expect(TransactionStatus.failed.rawValue == "failed")
        #expect(TransactionStatus(rawValue: "canceled") == nil)
    }
}
