import Foundation
import GRDB
import Testing
@testable import Aperture

/// P1-001: never invent zeros on RPC failure; keep last-good balances/UTXOs;
/// mark chain failed so portfolio does not look "synced at $0".
@Suite("Balance probe keep-last-good (P1-001 / BUG-004)")
struct BalanceProbeKeepLastGoodTests {

    // MARK: - Pure policy

    @Test("balance upsert gated on probe success")
    func balanceUpsertGate() {
        #expect(BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: true))
        #expect(!BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: false))
    }

    @Test("UTXO replace gated on probe success — never invent empty set")
    func utxoReplaceGate() {
        #expect(BalanceProbeKeepLastGood.shouldReplaceUTXOs(probeSucceeded: true))
        #expect(!BalanceProbeKeepLastGood.shouldReplaceUTXOs(probeSucceeded: false))
    }

    @Test("native or token probe failure marks chain failed")
    func failedChainsPolicy() {
        #expect(
            BalanceProbeKeepLastGood.failedChains(
                chain: .polkadot,
                nativeProbeSucceeded: true,
                tokenProbeSucceeded: true
            ).isEmpty
        )
        #expect(
            BalanceProbeKeepLastGood.failedChains(
                chain: .polkadot,
                nativeProbeSucceeded: false,
                tokenProbeSucceeded: true
            ) == [.polkadot]
        )
        #expect(
            BalanceProbeKeepLastGood.failedChains(
                chain: .solana,
                nativeProbeSucceeded: true,
                tokenProbeSucceeded: false
            ) == [.solana]
        )
        #expect(
            BalanceProbeKeepLastGood.failedChains(
                chain: .litecoin,
                nativeProbeSucceeded: false,
                tokenProbeSucceeded: false
            ) == [.litecoin]
        )
        #expect(
            BalanceProbeKeepLastGood.failedChains(
                chain: .dogecoin,
                nativeProbeSucceeded: false
            ) == [.dogecoin]
        )
        #expect(
            BalanceProbeKeepLastGood.failedChains(
                chain: .aptos,
                nativeProbeSucceeded: true,
                tokenProbeSucceeded: false
            ) == [.aptos]
        )
    }

    @Test("per-mint failures omit rows instead of inventing zero")
    func compactSuccessfulProbes() {
        let (rows, anyFailed) = BalanceProbeKeepLastGood.compactSuccessfulProbes([
            Optional("100"),
            nil,
            Optional("0"),
            nil,
            Optional("42")
        ])
        #expect(rows == ["100", "0", "42"])
        #expect(anyFailed)
        // Legitimate zero from a successful probe is kept; only nils are dropped.
        #expect(rows.contains("0"))

        let (allOk, noneFailed) = BalanceProbeKeepLastGood.compactSuccessfulProbes([
            Optional("1"),
            Optional("2")
        ])
        #expect(allOk == ["1", "2"])
        #expect(!noneFailed)

        let (allFail, failed) = BalanceProbeKeepLastGood.compactSuccessfulProbes([
            Optional<String>.none,
            Optional<String>.none
        ])
        #expect(allFail.isEmpty)
        #expect(failed)
    }

    // MARK: - Persistence: keep last-good under failed rebuild

    @Test("failed chain rebuild keeps last-good native balance (no invent-zero wipe)")
    func failedRebuildKeepsNativeBalance() async throws {
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
                VALUES (?, 'P1-001', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, ?, '15TestDOTKeepLastGood0000000000001', 'm/0', 1, 1)
                """,
                arguments: [addressId.uuidString, walletId.uuidString, SupportedChain.polkadot.rawValue]
            )
        }

        let goodRaw = "1234567890123"
        try TransactionRepository(database: database).upsertBalance(
            addressId: addressId,
            tokenSymbol: SupportedChain.polkadot.ticker,
            tokenContract: nil,
            decimals: SupportedChain.polkadot.nativeDecimals,
            rawBalance: goodRaw,
            fiatValueCached: 50,
            fiatCurrencyCode: "USD"
        )

        // Simulate a successful prior rebuild (synced with real balance).
        _ = try ChainStateRepository(database: database).rebuild(
            walletId: walletId,
            fiatCurrencyCode: "USD",
            onlyChains: [.polkadot],
            failedChains: [],
            interim: false
        )

        // P1-001 path: native probe failed → skip invent-zero upsert, mark failed.
        let shouldWrite = BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: false)
        #expect(!shouldWrite)
        let failed = BalanceProbeKeepLastGood.failedChains(
            chain: .polkadot,
            nativeProbeSucceeded: false,
            tokenProbeSucceeded: false
        )
        _ = try ChainStateRepository(database: database).rebuild(
            walletId: walletId,
            fiatCurrencyCode: "USD",
            onlyChains: [.polkadot],
            failedChains: failed,
            interim: false
        )

        let raw = try TestAppDatabaseFactory.scalarString(
            """
            SELECT raw_balance FROM token_balances
            WHERE address_id = ? AND token_symbol = ? AND token_contract IS NULL
            """,
            arguments: [addressId.uuidString, SupportedChain.polkadot.ticker],
            database: database
        )
        #expect(raw == goodRaw, "transport failure must not overwrite last-good DOT with invented zero")

        let syncState = try TestAppDatabaseFactory.scalarString(
            """
            SELECT sync_state_raw FROM chain_states
            WHERE wallet_id = ? AND chain_raw = ?
            """,
            arguments: [walletId.uuidString, SupportedChain.polkadot.rawValue],
            database: database
        )
        #expect(syncState == ChainSyncState.failed.rawValue, "chain must be marked failed, not synced-at-zero")
    }

    @Test("LTC/DOGE: failed UTXO probe keeps last-good UTXOs (compose cache)")
    func failedUTXOProbeKeepsCache() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        let addressId = UUID()
        let address = "ltc1qtestkeepgood0000000000000000001"
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'P1-001-LTC', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, ?, ?, 'm/84''/2''/0''/0/0', 1, 1)
                """,
                arguments: [
                    addressId.uuidString,
                    walletId.uuidString,
                    SupportedChain.litecoin.rawValue,
                    address
                ]
            )
        }

        try TransactionRepository(database: database).upsertBalance(
            addressId: addressId,
            tokenSymbol: SupportedChain.litecoin.ticker,
            tokenContract: nil,
            decimals: SupportedChain.litecoin.nativeDecimals,
            rawBalance: "50000000",
            fiatValueCached: 40,
            fiatCurrencyCode: "USD"
        )

        let chainRepo = ChainStateRepository(database: database)
        _ = try chainRepo.replaceAddressedUTXOs(
            walletId: walletId,
            chain: .litecoin,
            utxos: [
                .init(
                    address: address,
                    txid: "good-utxo-txid",
                    vout: 0,
                    valueSats: 50_000_000,
                    scriptHex: "0014deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                    confirmed: true
                )
            ]
        )
        _ = try chainRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: "USD",
            onlyChains: [.litecoin],
            failedChains: [],
            interim: false
        )

        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM chain_utxos WHERE wallet_id = ?",
            arguments: [walletId.uuidString],
            database: database
        ) == 1)

        // P1-001: snapshot + UTXO probes failed → do not invent zero balance,
        // do not replace UTXOs with [], mark chain failed.
        #expect(!BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: false))
        #expect(!BalanceProbeKeepLastGood.shouldReplaceUTXOs(probeSucceeded: false))
        let failed = BalanceProbeKeepLastGood.failedChains(
            chain: .litecoin,
            nativeProbeSucceeded: false
        )
        _ = try chainRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: "USD",
            onlyChains: [.litecoin],
            failedChains: failed,
            interim: false
        )

        let raw = try TestAppDatabaseFactory.scalarString(
            """
            SELECT raw_balance FROM token_balances
            WHERE address_id = ? AND token_symbol = ?
            """,
            arguments: [addressId.uuidString, SupportedChain.litecoin.ticker],
            database: database
        )
        #expect(raw == "50000000", "LTC balance must survive REST outage")

        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM chain_utxos WHERE wallet_id = ?",
            arguments: [walletId.uuidString],
            database: database
        ) == 1, "UTXO cache must survive REST outage for compose")

        let syncState = try TestAppDatabaseFactory.scalarString(
            """
            SELECT sync_state_raw FROM chain_states
            WHERE wallet_id = ? AND chain_raw = ?
            """,
            arguments: [walletId.uuidString, SupportedChain.litecoin.rawValue],
            database: database
        )
        #expect(syncState == ChainSyncState.failed.rawValue)
    }

    @Test("Solana/Aptos: omit failed mints; keep last-good token row")
    func tokenMintFailureKeepsLastGood() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletId = UUID()
        let addressId = UUID()
        let usdcMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'P1-001-SOL', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, ?, 'So11111111111111111111111111111111111111112', 'm/44''/501''/0''/0''', 1, 1)
                """,
                arguments: [addressId.uuidString, walletId.uuidString, SupportedChain.solana.rawValue]
            )
        }

        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: addressId,
            tokenSymbol: SupportedChain.solana.ticker,
            tokenContract: nil,
            decimals: SupportedChain.solana.nativeDecimals,
            rawBalance: "1000000000",
            fiatValueCached: 100,
            fiatCurrencyCode: "USD"
        )
        try txRepo.upsertBalance(
            addressId: addressId,
            tokenSymbol: "USDC",
            tokenContract: usdcMint,
            decimals: 6,
            rawBalance: "2500000",
            fiatValueCached: 2.5,
            fiatCurrencyCode: "USD"
        )

        // Per-mint RPC failure → compact drops that mint; scanner must not upsert "0".
        let probes: [String?] = [nil] // USDC probe failed
        let (rows, anyFailed) = BalanceProbeKeepLastGood.compactSuccessfulProbes(probes)
        #expect(rows.isEmpty)
        #expect(anyFailed)
        #expect(!BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: false))

        // Native still OK; only token path partial-failed → mark chain failed,
        // leave USDC row untouched.
        _ = try ChainStateRepository(database: database).rebuild(
            walletId: walletId,
            fiatCurrencyCode: "USD",
            onlyChains: [.solana],
            failedChains: BalanceProbeKeepLastGood.failedChains(
                chain: .solana,
                nativeProbeSucceeded: true,
                tokenProbeSucceeded: !anyFailed
            ),
            interim: false
        )

        let usdcRaw = try TestAppDatabaseFactory.scalarString(
            """
            SELECT raw_balance FROM token_balances
            WHERE address_id = ? AND token_contract = ?
            """,
            arguments: [addressId.uuidString, usdcMint],
            database: database
        )
        #expect(usdcRaw == "2500000", "failed SPL/FA mint must not invent zero over last-good")

        let solRaw = try TestAppDatabaseFactory.scalarString(
            """
            SELECT raw_balance FROM token_balances
            WHERE address_id = ? AND token_contract IS NULL
            """,
            arguments: [addressId.uuidString],
            database: database
        )
        #expect(solRaw == "1000000000")
    }

    @Test("successful probe may write real zero; failure must not")
    func realZeroVsInventedZero() {
        // Successful empty inventory → "0" is legitimate and may be upserted.
        #expect(BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: true))
        let (okRows, okFailed) = BalanceProbeKeepLastGood.compactSuccessfulProbes([
            Optional("0"),
            Optional("0")
        ])
        #expect(okRows == ["0", "0"])
        #expect(!okFailed)

        // Transport failure → omit, never materialize invented zero for upsert.
        let (failRows, failAny) = BalanceProbeKeepLastGood.compactSuccessfulProbes([
            Optional<String>.none
        ])
        #expect(failRows.isEmpty)
        #expect(failAny)
        #expect(!BalanceProbeKeepLastGood.shouldUpsertBalance(probeSucceeded: false))
    }
}
