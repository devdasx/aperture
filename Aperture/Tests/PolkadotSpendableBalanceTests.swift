import Foundation
import Testing
@testable import Aperture

/// P0-005: DOT spendable balance is FREE only — never free+reserved.
@Suite("Polkadot free vs reserved spendable (P0-005)")
struct PolkadotSpendableBalanceTests {

    private let decimals = SupportedChain.polkadot.nativeDecimals // 10

    // MARK: - Spendable raw selection

    @Test("spendableRawBalance is free, never free+reserved")
    func spendableIsFreeOnly() {
        let free = "100000000000" // 10 DOT
        let reserved = "50000000000" // 5 DOT reserved
        let total = PolkadotAccountBalanceCodec.addDecimalStrings(free, reserved)
        #expect(total == "150000000000")

        let spendable = PolkadotAccountBalanceCodec.spendableRawBalance(free: free, reserved: reserved)
        #expect(spendable == free)
        #expect(spendable != total)

        // Old bug: writing total as rawBalance would inflate spendable by reserved.
        let freeDisplay = ComposeDecimal.toDisplay(Decimal(string: free)!, decimals: decimals)
        let totalDisplay = ComposeDecimal.toDisplay(Decimal(string: total)!, decimals: decimals)
        #expect(freeDisplay == 10)
        #expect(totalDisplay == 15)
        #expect(totalDisplay - freeDisplay == 5)
    }

    // MARK: - MAX / available math

    @Test("MAX on free never offers reserved DOT")
    func maxNeverOffersReserved() {
        let free: Decimal = 10
        let reserved: Decimal = 5
        let wrongTotal = free + reserved // old GRDB value

        var state = SendAmountMath.AccountState()
        state.reserved = reserved
        state.frozen = 0

        let fee = FeeChoice(
            tier: .normal,
            feeModel: .polkadotWeight,
            estimatedTotalNative: 0,
            worstCaseTotalNative: 0
        )

        let maxFree = SendAmountMath.maxSend(
            chain: .polkadot,
            nativeBalance: free,
            tokenBalance: nil,
            isToken: false,
            fee: fee,
            state: state,
            recipientNeedsActivation: false
        )
        let maxWrongTotal = SendAmountMath.maxSend(
            chain: .polkadot,
            nativeBalance: wrongTotal,
            tokenBalance: nil,
            isToken: false,
            fee: fee,
            state: state,
            recipientNeedsActivation: false
        )

        #expect(maxFree <= free)
        #expect(maxFree < maxWrongTotal)
        // ED 0.01 DOT
        #expect(maxFree == free - Decimal(string: "0.01")!)
        // Using total would overstate by ~5 DOT (the reserved portion).
        #expect(maxWrongTotal - maxFree == reserved)
    }

    @Test("Standing reserve is max(frozen, ED) with free-only balance")
    func standingReserveFrozenAndED() {
        let rule = ReserveRule.existentialDeposit(ed: Decimal(string: "0.01")!)

        var plain = SendAmountMath.AccountState()
        plain.frozen = 0
        #expect(SendAmountMath.standingReserve(rule: rule, state: plain) == Decimal(string: "0.01")!)

        var frozen = SendAmountMath.AccountState()
        frozen.frozen = Decimal(string: "2.5")!
        frozen.reserved = 100 // must not reduce frozen floor (free is separate)
        #expect(SendAmountMath.standingReserve(rule: rule, state: frozen) == Decimal(string: "2.5")!)
    }

    @Test("Available = free − ED when frozen is zero")
    func availableFreeMinusED() {
        var state = SendAmountMath.AccountState()
        state.frozen = 0
        let available = SendAmountMath.available(
            chain: .polkadot,
            nativeBalance: 10,
            tokenBalance: nil,
            isToken: false,
            state: state
        )
        #expect(available == Decimal(string: "9.99")!)
    }

    // MARK: - Codec: free / reserved / frozen layout

    @Test("decodeAccountInfo separates free, reserved, frozen")
    func decodeSeparatesFields() throws {
        // Build a minimal SCALE blob: 4×u32 + free + reserved + frozen (all LE).
        var bytes = [UInt8](repeating: 0, count: 64)
        // nonce = 1
        bytes[0] = 1
        // free = 10 * 10^10 = 100_000_000_000 plancks
        writeUInt128LE(100_000_000_000, into: &bytes, at: 16)
        // reserved = 5 * 10^10
        writeUInt128LE(50_000_000_000, into: &bytes, at: 32)
        // frozen = 1 * 10^10
        writeUInt128LE(10_000_000_000, into: &bytes, at: 48)

        let hex = "0x" + bytes.map { String(format: "%02x", $0) }.joined()
        let decoded = try PolkadotAccountBalanceCodec.decodeAccountInfo(hex: hex)

        #expect(decoded.freePlancks == "100000000000")
        #expect(decoded.reservedPlancks == "50000000000")
        #expect(decoded.frozenPlancks == "10000000000")
        #expect(decoded.totalPlancks == "150000000000")
        #expect(decoded.nonce == 1)

        let spendable = PolkadotAccountBalanceCodec.spendableRawBalance(
            free: decoded.freePlancks,
            reserved: decoded.reservedPlancks
        )
        #expect(spendable == decoded.freePlancks)
        #expect(spendable != decoded.totalPlancks)
    }

    @Test("Persisted free row + reserved state feed correct MAX")
    func repositoryFreeAndReserved() throws {
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
                VALUES (?, 'DOT', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'polkadot', '15TestDOTAddressForSpendable00000001', 'm/0', 0, 1)
                """,
                arguments: [addressId.uuidString, walletId.uuidString]
            )
            // Balance row = FREE only (what scanner writes after P0-005).
            try db.execute(
                sql: """
                INSERT INTO token_balances
                (id, address_id, token_symbol, token_contract, decimals, raw_balance,
                 fiat_value_cached, fiat_currency_code, updated_at_ms)
                VALUES (?, ?, 'DOT', NULL, 10, '100000000000', '0', 'USD', ?)
                """,
                arguments: [UUID().uuidString, addressId.uuidString, now]
            )
        }

        try ChainAccountStateRepository(database: database).upsert(
            addressId: addressId,
            chain: .polkadot,
            state: ChainAccountStateSnapshot(
                ownerCount: 0,
                subentryCount: 0,
                numSponsoring: 0,
                numSponsored: 0,
                sellingLiabilitiesRaw: "0",
                frozenRaw: "0",
                reservedRaw: "50000000000", // 5 DOT reserved — not in balance row
                storageUsageBytes: 0,
                lockedRaw: "0",
                freeRaw: "100000000000"
            )
        )

        let snap = try #require(try ChainAccountStateRepository(database: database).load(addressId: addressId))
        #expect(snap.freeRaw == "100000000000")
        #expect(snap.reservedRaw == "50000000000")

        let freeDisplay = ComposeDecimal.toDisplay(Decimal(string: snap.freeRaw)!, decimals: 10)
        let state = snap.toComposeAccountState(nativeBalanceDisplay: freeDisplay, decimals: 10)
        let max = SendAmountMath.maxSend(
            chain: .polkadot,
            nativeBalance: freeDisplay,
            tokenBalance: nil,
            isToken: false,
            fee: FeeChoice(
                tier: .normal,
                feeModel: .polkadotWeight,
                estimatedTotalNative: 0,
                worstCaseTotalNative: 0
            ),
            state: state,
            recipientNeedsActivation: false
        )
        // Must not be ~15 (free+reserved) − ED.
        #expect(max <= 10)
        #expect(max == Decimal(string: "9.99")!)
        #expect(max < 14)
    }

    // MARK: - Helpers

    private func writeUInt128LE(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        var v = value
        for i in 0..<8 {
            bytes[offset + i] = UInt8(v & 0xff)
            v >>= 8
        }
        // high 8 bytes stay 0 for values that fit in UInt64
    }
}
