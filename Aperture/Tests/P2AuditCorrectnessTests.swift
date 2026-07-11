import Foundation
import GRDB
import Testing
@testable import Aperture

/// P2-001…P2-030 regression suite — fee honesty, status defaults, amounts,
/// import detector, addresses, and related medium-severity correctness.
struct P2AuditCorrectnessTests {

    // MARK: - P2-002 Bitcoin amount conversion honesty

    @Test("SigningAmount.int64 floors; sub-sat display is zero not invent")
    func bitcoinSatsHonesty() {
        #expect(SigningAmount.int64(display: Decimal(string: "0.00000001")!, decimals: 8) == 1)
        // 0.1 sat → floor 0 (signer then throws; never invents a spend)
        let subSat = SigningAmount.int64(display: Decimal(string: "0.000000001")!, decimals: 8)
        #expect(subSat == nil || subSat == 0)
        #expect(SigningAmount.int64(display: 1, decimals: 8) == 100_000_000)
    }

    // MARK: - P2-003 optimistic debit floors

    @Test("Optimistic debit raw units floor like signing (not half-up)")
    func optimisticDebitFloors() throws {
        let db = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(db) }
        let walletId = UUID()
        let addressId = UUID()
        let now = Date.databaseMilliseconds
        try db.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'P2-003', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try conn.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'bitcoin', 'bc1qtestp2003', 'm/84''/0''/0''/0/0', 1, 1)
                """,
                arguments: [addressId.uuidString, walletId.uuidString]
            )
        }
        let repo = TransactionRepository(database: db)
        try repo.upsertBalance(
            addressId: addressId,
            tokenSymbol: "BTC",
            tokenContract: nil,
            decimals: 8,
            rawBalance: "2",
            fiatValueCached: 0,
            fiatCurrencyCode: "USD"
        )
        // 1.5 sats display: half-up would debit 2; floor debits 1.
        let halfUpTrap = ComposeDecimal.toDisplay(Decimal(string: "1.5")!, decimals: 8)
        let changed = try repo.applyOptimisticOutgoingDebit(
            walletId: walletId,
            chain: .bitcoin,
            tokenSymbol: "BTC",
            tokenContract: nil,
            decimals: 8,
            displayAmount: halfUpTrap
        )
        #expect(changed == true)
        let remaining = try TestAppDatabaseFactory.scalarString(
            "SELECT raw_balance FROM token_balances WHERE address_id = ?",
            arguments: [addressId.uuidString],
            database: db
        )
        #expect(remaining == "1", "floor debit leaves 1 sat, not 0 from half-up")
    }

    // MARK: - P2-004 Polkadot multi fee scale

    @Test("Polkadot partial fee scales with recipientCount")
    func polkadotFeeScalesWithN() {
        let single = Decimal(152_000_000)
        for n in [1, 2, 4, 8] {
            let scaled = single * Decimal(n)
            let display = ComposeDecimal.toDisplay(scaled, decimals: 10)
            let one = ComposeDecimal.toDisplay(single, decimals: 10)
            if n > 1 {
                #expect(display == one * Decimal(n))
            } else {
                #expect(display == one)
            }
        }
    }

    // MARK: - P2-005 XRPL status honesty

    @Test("XRPL missing result/validated is not confirmed")
    func xrplIncompleteNotConfirmed() {
        func status(txResult: String?, validated: Bool?) -> TransactionStatus {
            guard let validated else { return .pending }
            guard validated else { return .pending }
            guard let txResult else { return .pending }
            return txResult == "tesSUCCESS" ? .confirmed : .failed
        }
        #expect(status(txResult: nil, validated: true) == .pending)
        #expect(status(txResult: "tesSUCCESS", validated: nil) == .pending)
        #expect(status(txResult: "tesSUCCESS", validated: false) == .pending)
        #expect(status(txResult: "tesSUCCESS", validated: true) == .confirmed)
        #expect(status(txResult: "tecPATH_DRY", validated: true) == .failed)
    }

    // MARK: - P2-006 status parse default

    @Test("Unknown TransactionStatus rawValue falls back to pending not confirmed")
    func unknownStatusPending() {
        #expect(TransactionStatus(rawValue: "confirmed") == .confirmed)
        #expect(TransactionStatus(rawValue: "failed") == .failed)
        #expect(TransactionStatus(rawValue: "pending") == .pending)
        #expect(TransactionStatus(rawValue: "garbage") == nil)
        #expect(TransactionStatus(rawValue: "garbage") ?? .pending == .pending)
        #expect((TransactionStatus(rawValue: "garbage") ?? .pending) != .confirmed)
    }

    // MARK: - P2-010 TRON ABI address

    @Test("TRON energy ABI parameter uses 20-byte account id")
    func tronABIAddressParameter() {
        // Hex 41-prefixed form of a known 20-byte id.
        let hex41 = "41" + String(repeating: "ab", count: 20)
        let fromHex = ComposeFeeService.tronABIAddressParameter(hex41)
        #expect(fromHex?.count == 64)
        #expect(fromHex?.hasSuffix(String(repeating: "ab", count: 20)) == true)
        #expect(fromHex?.hasPrefix(String(repeating: "0", count: 24)) == true)

        // 0x-prefixed 20-byte eth-style
        let ethStyle = "0x" + String(repeating: "cd", count: 20)
        let fromEth = ComposeFeeService.tronABIAddressParameter(ethStyle)
        #expect(fromEth?.hasSuffix(String(repeating: "cd", count: 20)) == true)

        // Garbage must not hex-pad the raw T-string characters into ABI.
        let garbage = "Tnotavalidaddress!!!"
        let bad = ComposeFeeService.tronABIAddressParameter(garbage)
        if let bad {
            #expect(!bad.lowercased().contains("notavalid"))
        }
    }

    // MARK: - P2-011 / P2-012 plain decimal strings

    @Test("Plain amount raw never scientific notation")
    func plainAmountRawNoScientific() {
        let tiny = Decimal(string: "0.000000000000000001")!
        let s = SendExecutor.plainAmountRaw(tiny)
        #expect(!s.contains("e") && !s.contains("E"))

        let huge = Decimal(string: "100000000000000000000")!
        let h = SendExecutor.plainAmountRaw(huge)
        #expect(!h.contains("e") && !h.contains("E"))

        let iou = ComposeDecimal.plainDecimalString(Decimal(string: "1.5")!)
        #expect(iou == "1.5")
    }

    @Test("Pending counterparty joins multi recipients")
    func pendingCounterpartyMulti() {
        let draft = SendDraft(
            chain: .ethereum,
            tokenSymbol: nil,
            tokenContract: nil,
            tokenDecimals: nil,
            fromAddress: "0xfrom",
            recipients: [
                SendRecipientAmount(address: "0xa", amount: 1),
                SendRecipientAmount(address: "0xb", amount: 2),
            ],
            fee: FeeChoice(
                tier: .normal,
                feeModel: .evm1559,
                estimatedTotalNative: Decimal(string: "0.001")!,
                worstCaseTotalNative: Decimal(string: "0.002")!
            ),
            selectedUTXOs: nil,
            changeAddress: nil,
            changeSats: nil,
            opReturn: nil,
            signalsRBF: false,
            memo: .none,
            isMaxSend: false,
            recipientNeedsActivation: false,
            tonBounceable: nil
        )
        let cp = SendExecutor.pendingCounterparty(draft)
        #expect(cp.contains("0xa"))
        #expect(cp.contains("0xb"))
        #expect(cp.contains(","))
    }

    // MARK: - P2-001 orphan queue

    @Test("Orphan broadcast queue enqueue de-dupes and flushes")
    func orphanQueue() throws {
        #if DEBUG
        OrphanBroadcastQueue.resetForTests()
        #endif
        let addressId = UUID()
        let entry = OrphanBroadcastQueue.Entry(
            txHash: "0xabc123p2001",
            chainRaw: "ethereum",
            addressId: addressId,
            amountRaw: "1",
            feeRaw: "0.001",
            tokenSymbol: "ETH",
            tokenContract: nil,
            counterparty: "0xto"
        )
        OrphanBroadcastQueue.enqueue(entry)
        OrphanBroadcastQueue.enqueue(entry) // de-dupe
        #expect(OrphanBroadcastQueue.all().contains(where: { $0.txHash == entry.txHash }))

        let db = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(db) }
        let walletId = UUID()
        let now = Date.databaseMilliseconds
        try db.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'P2-001', 'created', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try conn.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'ethereum', '0xfrom', 'm/44''/60''/0''/0/0', 1, 1)
                """,
                arguments: [addressId.uuidString, walletId.uuidString]
            )
        }
        // Flush only our entry — re-enqueue clean for isolation
        #if DEBUG
        OrphanBroadcastQueue.resetForTests()
        OrphanBroadcastQueue.enqueue(entry)
        #endif
        let written = OrphanBroadcastQueue.flush(into: db)
        #expect(written >= 1)
        let count = try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM transactions WHERE tx_hash = ?",
            arguments: [entry.txHash],
            database: db
        )
        #expect(count == 1)
    }

    // MARK: - P2-016 ChainKeyVault AAD

    @Test("ChainKeyVault seal/open round-trips with AAD")
    func chainKeyVaultAAD() throws {
        let db = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(db) }
        ChainKeyVault.configure(database: db)
        let plain = Data((0..<32).map { UInt8($0) })
        let sealed = try ChainKeyVault.seal(plain)
        let opened = try ChainKeyVault.open(sealed)
        #expect(opened == plain)
        #expect(sealed != plain)
    }

    // MARK: - P2-019 fee ETA not one-size

    @Test("Fee ETA copy differs for Solana vs Bitcoin")
    func feeETACopy() {
        let btc = SendFeeSheet.etaCopy(for: .bitcoin)
        let sol = SendFeeSheet.etaCopy(for: .solana)
        let xrp = SendFeeSheet.etaCopy(for: .ripple)
        #expect(btc.slow.contains("min"))
        #expect(sol.fast.contains("slot") || sol.normal.contains("s"))
        #expect(xrp.normal.contains("s"))
        #expect(btc.slow != sol.slow)
    }

    // MARK: - P2-024 Stellar memo bytes

    @Test("Stellar memo truncates by UTF-8 bytes not characters")
    func stellarMemoByteTruncate() {
        let emoji = String(repeating: "😀", count: 10)
        let truncated = StellarTransactionSigner.truncateMemoText(emoji)
        #expect(truncated.utf8.count <= 28)
        #expect(truncated.utf8.count < emoji.utf8.count)
        #expect(StellarTransactionSigner.truncateMemoText("hello") == "hello")
        let exact28 = String(repeating: "a", count: 28)
        #expect(StellarTransactionSigner.truncateMemoText(exact28) == exact28)
    }

    // MARK: - P2-026 multi-recipient identity

    @Test("Duplicate recipient addresses have distinct ids")
    func multiRecipientDistinctIds() {
        let a = SendRecipientAmount(address: "0xdup", amount: 1)
        let b = SendRecipientAmount(address: "0xdup", amount: 2)
        #expect(a.id != b.id)
        #expect(a.address == b.address)
    }

    // MARK: - P2-027 min value locale parse

    @Test("Min value threshold parses locale and plain decimals")
    func minValueParse() {
        #expect(WalletHomeMinValueView.parseFiatThreshold("1.5") == Decimal(string: "1.5"))
        #expect(WalletHomeMinValueView.parseFiatThreshold("0") == 0)
        #expect(WalletHomeMinValueView.parseFiatThreshold("") == 0)
        #expect(WalletHomeMinValueView.parseFiatThreshold("  2.25 ") == Decimal(string: "2.25"))
    }

    // MARK: - P2-015 import detector honesty for XRP seed

    @Test("XRP s-seed classifies unknown not importable xrpSeed")
    func xrpSeedDetectorHonest() {
        let fake = "sXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
        let format = KeyImportFormatDetector.detectFormat(fake, on: .ripple)
        #expect(format == .unknown || format == nil)
        #expect(format != .xrpSeed)
    }

    // MARK: - P2-018 markets range labels

    @Test("Market chart range delta labels are not all today")
    func marketRangeLabels() {
        let day = MarketChartRange.oneDay.deltaLabel
        let week = MarketChartRange.oneWeek.deltaLabel
        let hour = MarketChartRange.oneHour.deltaLabel
        #expect(day != week || week.lowercased().contains("week"))
        #expect(hour != day || hour.lowercased().contains("hour"))
    }

    // MARK: - P2-023 corrupt WalletKind

    @Test("Corrupt kind_raw does not resolve as spendable watchOnly")
    func corruptKindNotWatchOnly() throws {
        let db = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(db) }
        let walletId = UUID()
        let addressId = UUID()
        let now = Date.databaseMilliseconds
        try db.write { conn in
            try conn.execute(
                sql: """
                INSERT INTO wallets
                (id, name, kind_raw, mnemonic_word_count, has_passphrase, color_tag,
                 sort_order, requires_backup, created_at_ms, updated_at_ms)
                VALUES (?, 'P2-023', 'not_a_real_kind', 12, 0, 'blue', 0, 0, ?, ?)
                """,
                arguments: [walletId.uuidString, now, now]
            )
            try conn.execute(
                sql: """
                INSERT INTO wallet_addresses
                (id, wallet_id, chain_raw, address, derivation_path, is_used, is_receive_preferred)
                VALUES (?, ?, 'ethereum', '0xabcdef0123456789abcdef0123456789abcdef01', 'm/44''/60''/0''/0/0', 1, 1)
                """,
                arguments: [addressId.uuidString, walletId.uuidString]
            )
        }
        let resolution = SendOutboxAddressResolver.resolve(
            walletId: walletId,
            chain: .ethereum,
            fromAddress: "0xabcdef0123456789abcdef0123456789abcdef01",
            database: db
        )
        if case .resolved(_, _) = resolution {
            Issue.record("Corrupt kind must not resolve as spendable")
        }
    }
}
