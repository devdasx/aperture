import Foundation
import Testing
@testable import Aperture

/// P0-004 / P0-005: Send MAX and spendable must use live account reserves
/// (OwnerCount, Stellar subentries, NEAR locked/storage, DOT free/reserved).
@Suite("Send account-state reserves (P0-004)")
struct SendAccountStateReserveTests {

    // MARK: - Pure standingReserve math

    @Test("XRP reserve scales with OwnerCount")
    func xrpOwnerReserve() {
        let rule = ReserveRule.xrpReserve(base: 1, perOwnedObject: Decimal(string: "0.2")!)
        var bare = SendAmountMath.AccountState()
        bare.ownerCount = 0
        #expect(SendAmountMath.standingReserve(rule: rule, state: bare) == 1)

        var withLines = SendAmountMath.AccountState()
        withLines.ownerCount = 5
        // 1 + 5×0.2 = 2.0
        #expect(SendAmountMath.standingReserve(rule: rule, state: withLines) == 2)

        // Regression: empty state understates reserve vs real OwnerCount.
        #expect(
            SendAmountMath.standingReserve(rule: rule, state: withLines)
                > SendAmountMath.standingReserve(rule: rule, state: bare)
        )
    }

    @Test("XRP MAX deducts owner reserve")
    func xrpMaxUsesOwnerCount() {
        var state = SendAmountMath.AccountState()
        state.ownerCount = 10 // 1 + 2.0 = 3 XRP reserve
        let fee = FeeChoice.zero(for: .ripple)
        let max = SendAmountMath.maxSend(
            chain: .ripple,
            nativeBalance: 10,
            tokenBalance: nil,
            isToken: false,
            fee: fee,
            state: state,
            recipientNeedsActivation: false
        )
        // 10 − 3 − fee ≈ 7 when fee is 0
        let reserve = SendAmountMath.standingReserve(
            rule: ChainComposeCapability.capability(for: .ripple).reserve,
            state: state
        )
        #expect(reserve == 3)
        let expected = Swift.max(10 - reserve - fee.worstCaseTotalNative, 0)
        #expect(max == expected)
        #expect(max < 10)
    }

    @Test("Stellar reserve uses subentries and liabilities")
    func stellarSubentries() {
        let rule = ReserveRule.stellarReserve(baseReserve: Decimal(string: "0.5")!)
        let bare = SendAmountMath.AccountState()
        // entries = 2 + 0 → 1 XLM
        #expect(SendAmountMath.standingReserve(rule: rule, state: bare) == 1)

        var busy = SendAmountMath.AccountState()
        busy.subentryCount = 4
        busy.numSponsoring = 0
        busy.numSponsored = 0
        // entries = 2+4 = 6 → 3 XLM
        #expect(SendAmountMath.standingReserve(rule: rule, state: busy) == 3)

        busy.sellingLiabilities = Decimal(string: "1.5")!
        #expect(SendAmountMath.standingReserve(rule: rule, state: busy) == Decimal(string: "4.5")!)
    }

    @Test("NEAR reserve uses locked + storage_usage × perByte")
    func nearStorage() {
        let perByte = Decimal(string: "0.00001")!
        let rule = ReserveRule.nearStorage(perByte: perByte)
        var state = SendAmountMath.AccountState()
        state.locked = 1 // 1 NEAR locked
        state.storageUsageBytes = 100_000 // 100k × 1e-5 = 1 NEAR
        #expect(SendAmountMath.standingReserve(rule: rule, state: state) == 2)
    }

    @Test("DOT existential reserve uses free balance path (P0-005)")
    func polkadotED() {
        let rule = ReserveRule.existentialDeposit(ed: Decimal(string: "0.01")!)
        var state = SendAmountMath.AccountState()
        state.frozen = 0
        state.reserved = 5 // reserved is NOT in free balance — must not change ED floor
        // floor = max(frozen, ED) = 0.01 (not frozen − reserved)
        #expect(SendAmountMath.standingReserve(rule: rule, state: state) == Decimal(string: "0.01")!)

        let fee = FeeChoice.zero(for: .polkadot)
        let max = SendAmountMath.maxSend(
            chain: .polkadot,
            nativeBalance: 1, // free only
            tokenBalance: nil,
            isToken: false,
            fee: fee,
            state: state,
            recipientNeedsActivation: false
        )
        #expect(max == Decimal(string: "0.99")!)
        #expect(max >= 0)
    }

    @Test("Snapshot → compose state converts base units to display")
    func snapshotConversion() {
        let snap = ChainAccountStateSnapshot(
            ownerCount: 3,
            subentryCount: 2,
            numSponsoring: 1,
            numSponsored: 0,
            sellingLiabilitiesRaw: "15000000", // 1.5 XLM at 7 dec
            frozenRaw: "0",
            reservedRaw: "10000000000", // 1 DOT at 10 dec
            storageUsageBytes: 50_000,
            lockedRaw: "500000000000000000000000", // 0.5 NEAR at 24 dec
            freeRaw: "0"
        )
        let xlm = snap.toComposeAccountState(nativeBalanceDisplay: 10, decimals: 7)
        #expect(xlm.subentryCount == 2)
        #expect(xlm.sellingLiabilities == Decimal(string: "1.5")!)

        let dot = snap.toComposeAccountState(nativeBalanceDisplay: 5, decimals: 10)
        #expect(dot.reserved == 1)

        let near = snap.toComposeAccountState(nativeBalanceDisplay: 3, decimals: 24)
        #expect(near.storageUsageBytes == 50_000)
        #expect(near.locked == Decimal(string: "0.5")!)
        #expect(near.ownerCount == 3)
    }

    // MARK: - GRDB persistence

    @Test("ChainAccountStateRepository round-trips XRP owner count")
    func repositoryRoundTrip() throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        let addressId = UUID()
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'Reserve', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'ripple', 'rTestAddressForReserve0000000000001', 'm/0', 0, 1)
                """,
                arguments: [addressId.uuidString, walletId.uuidString]
            )
        }

        let repo = ChainAccountStateRepository(database: database)
        try repo.upsert(
            addressId: addressId,
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
                freeRaw: "25000000"
            )
        )

        let loadedOptional = try repo.load(addressId: addressId)
        let loaded = try #require(loadedOptional)
        #expect(loaded.ownerCount == 7)
        #expect(loaded.freeRaw == "25000000")

        let byWalletOptional = try repo.load(
            walletId: walletId,
            chain: .ripple,
            preferredAddress: "rTestAddressForReserve0000000000001"
        )
        let byWallet = try #require(byWalletOptional)
        #expect(byWallet.ownerCount == 7)

        let compose = loaded.toComposeAccountState(nativeBalanceDisplay: 25, decimals: 6)
        let reserve = SendAmountMath.standingReserve(
            rule: ChainComposeCapability.capability(for: .ripple).reserve,
            state: compose
        )
        // 1 + 7×0.2 = 2.4
        #expect(reserve == Decimal(string: "2.4")!)
    }

    @Test("Empty AccountState understates XRP reserve vs persisted OwnerCount (regression)")
    func emptyStateRegression() {
        let rule = ChainComposeCapability.capability(for: .ripple).reserve
        let empty = SendAmountMath.AccountState()
        var real = SendAmountMath.AccountState()
        real.ownerCount = 12
        let emptyReserve = SendAmountMath.standingReserve(rule: rule, state: empty)
        let realReserve = SendAmountMath.standingReserve(rule: rule, state: real)
        #expect(emptyReserve == 1) // base only — the old bug
        #expect(realReserve == Decimal(string: "3.4")!) // 1 + 2.4
        #expect(realReserve > emptyReserve)
    }
}

// MARK: - FeeChoice zero helper

private extension FeeChoice {
    /// Minimal fee choice for MAX math tests (no network).
    static func zero(for chain: SupportedChain) -> FeeChoice {
        let model = ChainComposeCapability.capability(for: chain).feeModel
        return FeeChoice(
            tier: .normal,
            feeModel: model,
            estimatedTotalNative: 0,
            worstCaseTotalNative: 0
        )
    }
}
