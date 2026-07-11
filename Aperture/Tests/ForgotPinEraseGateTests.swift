import Foundation
import Testing
@testable import Aperture

/// P1-010: Forgot-PIN / lock-screen erase must never unlock on wipe failure.
@Suite("Forgot-PIN erase gate (P1-010)")
struct ForgotPinEraseGateTests {

    // MARK: - Pure policy

    @Test("Wipe failure keeps lock closed")
    func wipeFailureStaysLocked() {
        let outcome = ForgotPinEraseGate.outcome(wipeSucceeded: false, residualSecrets: true)
        #expect(outcome == .stayLocked(reason: .wipeFailed))

        // Even if residual looks clean (racy read), failed wipe must not unlock.
        let stillLocked = ForgotPinEraseGate.outcome(wipeSucceeded: false, residualSecrets: false)
        #expect(stillLocked == .stayLocked(reason: .wipeFailed))
    }

    @Test("Wipe success with residual secrets stays locked")
    func residualSecretsStayLocked() {
        let outcome = ForgotPinEraseGate.outcome(wipeSucceeded: true, residualSecrets: true)
        #expect(outcome == .stayLocked(reason: .residualSecrets))
    }

    @Test("Wipe success and clean residual unlocks")
    func successAndCleanUnlocks() {
        let outcome = ForgotPinEraseGate.outcome(wipeSucceeded: true, residualSecrets: false)
        #expect(outcome == .unlock)
    }

    // MARK: - Residual secret verification against real DB

    @Test("hasResidualSpendableSecrets true when wallet row exists")
    func residualWhenWalletPresent() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let now = Date.databaseMilliseconds
        let walletId = UUID()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'P1-010', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
        }
        #expect(try FactoryReset.hasResidualSpendableSecrets(database: database) == true)
    }

    @Test("Successful full wipe clears residual secrets; gate unlocks")
    func successfulWipeClearsResiduals() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let now = Date.databaseMilliseconds
        let walletId = UUID()
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'P1-010-wipe', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_secrets
                (key, wallet_id, kind_raw, cipher_data, created_at_ms, updated_at_ms)
                VALUES (?, ?, 'seed', ?, ?, ?)
                """,
                arguments: [
                    "seed.\(walletId.uuidString)",
                    walletId.uuidString,
                    Data([0x01, 0x02, 0x03]),
                    now,
                    now,
                ]
            )
        }
        #expect(try FactoryReset.hasResidualSpendableSecrets(database: database) == true)

        try await FactoryReset.performFullWipe(database: database)

        let residual = try FactoryReset.hasResidualSpendableSecrets(database: database)
        #expect(residual == false)
        #expect(
            ForgotPinEraseGate.outcome(wipeSucceeded: true, residualSecrets: residual) == .unlock
        )

        let wallets = try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM wallets",
            database: database
        )
        let secrets = try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM wallet_secrets",
            database: database
        )
        #expect(wallets == 0)
        #expect(secrets == 0)
    }

    @Test("try? wipe failure path must not map to unlock (regression)")
    func tryQuestionMarkPatternNeverUnlocks() {
        // Documents the pre-fix anti-pattern:
        //   try? await FactoryReset.performFullWipe(...)
        //   unlock()  // ALWAYS ran
        // Gate must reject wipeSucceeded=false regardless of residual flag.
        for residual in [true, false] {
            let outcome = ForgotPinEraseGate.outcome(wipeSucceeded: false, residualSecrets: residual)
            #expect(outcome != .unlock)
            if case .stayLocked = outcome {
                // expected
            } else {
                Issue.record("Expected stayLocked when wipeSucceeded is false")
            }
        }
    }
}
