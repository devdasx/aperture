import Foundation
import GRDB
import Testing
@testable import Aperture

@MainActor
@Suite struct GRDBStorageTests {
    @Test("schema opens with singleton rows and seeds the asset catalog idempotently")
    func schemaAndCatalogSeed() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        try AssetCatalogSeeder.seed(database: database)
        try AssetCatalogSeeder.seed(database: database)

        let foreignKeys = try TestAppDatabaseFactory.scalarInt("PRAGMA foreign_keys", database: database)
        let journalMode = try TestAppDatabaseFactory.scalarString("PRAGMA journal_mode", database: database)
        #expect(foreignKeys == 1)
        #expect(journalMode?.lowercased() == "wal")
        #expect(try TestAppDatabaseFactory.count("app_settings", database: database) == 1)
        #expect(try TestAppDatabaseFactory.count("active_wallet", database: database) == 1)
        #expect(try TestAppDatabaseFactory.count("chains", database: database) == AssetCatalog.allChains.count)
        #expect(try TestAppDatabaseFactory.count("assets", database: database) == AssetCatalog.allAssets.count)
    }

    @Test("legacy defaults are ignored because GRDB is the single preference store")
    func legacyDefaultsAreIgnoredByGRDBPreferenceStore() throws {
        let defaultsSnapshot = UserDefaults.standard.dictionaryRepresentation()
        defer { restoreStandardDefaults(defaultsSnapshot) }
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        UserDefaults.standard.set("dark", forKey: "themePreference")
        UserDefaults.standard.set("vi", forKey: "languagePreference")
        UserDefaults.standard.set("EUR", forKey: CurrencyPreference.storageKey)
        UserDefaults.standard.set(false, forKey: HapticPreference.storageKey)
        UserDefaults.standard.set(false, forKey: "backgroundBalanceRefresh")
        UserDefaults.standard.set(BalanceHistoryRange.month.rawValue, forKey: "walletHomeBalanceHistoryRange")
        UserDefaults.standard.set(UUID().uuidString, forKey: ActiveWalletPointer.storageKey)
        UserDefaults.standard.set(true, forKey: PinCodePreference.pinEnabledKey)
        UserDefaults.standard.set(true, forKey: PinCodePreference.biometricEnabledKey)
        UserDefaults.standard.set("wallets", forKey: "settingsDeepLink")
        UserDefaults.standard.set("session-token", forKey: "onboardingSession")

        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let store = AppPreferenceStore.shared

        #expect(store.string("themePreference") == ThemePreference.defaultRaw)
        #expect(store.string("languagePreference") == LanguagePreference.systemCode)
        #expect(store.string(CurrencyPreference.storageKey) == CurrencyPreference.defaultForCurrentRegion())
        #expect(store.bool(HapticPreference.storageKey, default: true) == HapticPreference.defaultValue)
        #expect(store.bool("backgroundBalanceRefresh", default: true) == true)
        #expect(store.string("walletHomeBalanceHistoryRange") == BalanceHistoryRange.all.rawValue)
        #expect(store.string(ActiveWalletPointer.storageKey) == "")
        #expect(store.bool(PinCodePreference.pinEnabledKey) == false)
        #expect(store.bool(PinCodePreference.biometricEnabledKey) == false)
        #expect(store.string("settingsDeepLink") == "")
        #expect(UserDefaults.standard.string(forKey: "themePreference") == "dark")
        #expect(UserDefaults.standard.object(forKey: ActiveWalletPointer.storageKey) != nil)
        #expect(UserDefaults.standard.string(forKey: "onboardingSession") == "session-token")
    }

    @Test("wallet create, import, active selection, delete, and encrypted secrets are database-backed")
    func walletLifecycleActiveWalletAndSecrets() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let createdID = UUID()
        let importedID = UUID()
        let words = ["ABANDON", "ability", "ABLE", "about"]
        let command = WalletCommandRepository(database: database)
        try await command.insertCreatedWallet(
            id: createdID,
            name: "Created",
            mnemonicWordCount: words.count,
            hasPassphrase: false,
            colorTag: "blue",
            requiresBackup: true,
            mnemonicWords: words,
            addresses: [
                (SupportedChain.bitcoin.rawValue, "bc1qcreated"),
                (SupportedChain.ethereum.rawValue, "0xCreated")
            ]
        )
        try await command.insertImportedMnemonicWallet(
            id: importedID,
            name: "Imported",
            mnemonicWordCount: words.count,
            hasPassphrase: false,
            colorTag: "green",
            mnemonicWords: words.reversed(),
            addresses: [(SupportedChain.solana.rawValue, "solanaImported")]
        )
        try WalletSecretPersistence.upsertPrivateKey("  0xabc123  ", for: importedID, database: database)

        ActiveWalletPointer.configure(database: database)
        #expect(ActiveWalletPointer.currentId == createdID)
        ActiveWalletPointer.set(importedID)

        let activeRaw = try TestAppDatabaseFactory.scalarString(
            "SELECT wallet_id FROM active_wallet WHERE id = 'active-wallet-singleton'",
            database: database
        )
        let settingsRaw = try TestAppDatabaseFactory.scalarString(
            "SELECT active_wallet_id FROM app_settings WHERE id = 'app-settings-singleton'",
            database: database
        )
        #expect(activeRaw == importedID.uuidString)
        #expect(settingsRaw == importedID.uuidString)
        #expect(try WalletRepository(database: database).walletCount() == 2)
        #expect(try WalletSecretPersistence.loadMnemonic(for: createdID, database: database) == words.map { $0.lowercased() })
        #expect(try WalletSecretRepository(database: database).loadPrivateKey(for: importedID) == "0xabc123")
        #expect(try TestAppDatabaseFactory.count("wallet_secrets", database: database) == 3)

        let next = try await WalletRepository(database: database).deleteWalletAndActivateNext(walletId: importedID)
        #expect(next == createdID)
        #expect(try WalletRepository(database: database).walletCount() == 1)
        #expect(try WalletSecretPersistence.loadPrivateKey(for: importedID, database: database) == nil)
        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT wallet_id FROM active_wallet WHERE id = 'active-wallet-singleton'",
            database: database
        ) == createdID.uuidString)
    }

    @Test("transactions upsert by leg identity and query by wallet in SQL order")
    func transactionIdentityAndFilters() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletID = try await insertWatchWallet(database, chains: [.ethereum])
        let addressID = try firstAddressID(walletID: walletID, chain: .ethereum, database: database)
        let repo = TransactionRepository(database: database)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)

        try repo.upsertTransaction(
            addressId: addressID,
            txHash: "0xabc",
            direction: .incoming,
            amountRaw: "100",
            tokenSymbol: "ETH",
            blockNumber: nil,
            occurredAt: older,
            status: .pending,
            counterparty: "0xsender",
            feeRaw: nil
        )
        try repo.upsertTransaction(
            addressId: addressID,
            txHash: "0xabc",
            direction: .incoming,
            amountRaw: "100",
            tokenSymbol: "ETH",
            blockNumber: 99,
            occurredAt: newer,
            status: .confirmed,
            counterparty: "0xsender",
            feeRaw: "1"
        )
        try repo.upsertTransaction(
            addressId: addressID,
            txHash: "0xabc",
            direction: .outgoing,
            amountRaw: "25",
            tokenSymbol: "ETH",
            blockNumber: 100,
            occurredAt: newer.addingTimeInterval(1),
            status: .confirmed,
            counterparty: "0xrecipient",
            feeRaw: "2"
        )

        #expect(try TestAppDatabaseFactory.count("transactions", database: database) == 2)
        let all = try repo.transactions(walletId: walletID)
        #expect(all.map(\.direction) == [.outgoing, .incoming])
        #expect(all.last?.status == .confirmed)
        #expect(all.last?.blockNumber == 99)
        #expect(try repo.transactions(walletId: walletID, direction: .incoming).count == 1)
    }

    @Test("balance upserts, chain summaries, and UTXO snapshots aggregate across owned addresses")
    func balancesChainSummariesAndUTXOs() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletID = try await insertWatchWallet(
            database,
            chainsAndAddresses: [
                (.bitcoin, "bc1qreceive"),
                (.bitcoin, "bc1qchange")
            ]
        )
        let addressIDs = try addressIDs(walletID: walletID, chain: .bitcoin, database: database)
        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: addressIDs[0],
            tokenSymbol: "BTC",
            tokenContract: nil,
            decimals: 8,
            rawBalance: "100000000",
            fiatValueCached: 30_000,
            fiatCurrencyCode: "USD"
        )
        try txRepo.upsertBalance(
            addressId: addressIDs[0],
            tokenSymbol: "BTC",
            tokenContract: nil,
            decimals: 8,
            rawBalance: "200000000",
            fiatValueCached: nil,
            fiatCurrencyCode: "USD"
        )
        try txRepo.upsertTransaction(
            addressId: addressIDs[0],
            txHash: "btc-in",
            direction: .incoming,
            amountRaw: "200000000",
            tokenSymbol: "BTC",
            blockNumber: 1,
            occurredAt: Date(timeIntervalSince1970: 10),
            status: .confirmed,
            counterparty: "external",
            feeRaw: nil
        )
        try txRepo.upsertTransaction(
            addressId: addressIDs[1],
            txHash: "btc-out",
            direction: .outgoing,
            amountRaw: "50000",
            tokenSymbol: "BTC",
            blockNumber: 2,
            occurredAt: Date(timeIntervalSince1970: 20),
            status: .pending,
            counterparty: "external",
            feeRaw: "100"
        )

        let chainRepo = ChainStateRepository(database: database)
        let utxoResult = try chainRepo.replaceAddressedUTXOs(
            walletId: walletID,
            chain: .bitcoin,
            utxos: [
                .init(address: "bc1qreceive", txid: "utxo-a", vout: 0, valueSats: 10_000, scriptHex: "51", confirmed: true),
                .init(address: "bc1qchange", txid: "utxo-b", vout: 1, valueSats: 20_000, scriptHex: "52", confirmed: false)
            ]
        )
        #expect(utxoResult.count == 2)
        #expect(utxoResult.totalSats == 30_000)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM chain_utxos WHERE address_id IS NOT NULL",
            database: database
        ) == 2)

        try chainRepo.storeEncryptedKeys(walletId: walletID, blobs: [.bitcoin: Data([1, 2, 3])])
        #expect(try chainRepo.chainsMissingKey(walletId: walletID, candidates: [.bitcoin, .ethereum]) == [.ethereum])
        try chainRepo.rebuild(walletId: walletID, fiatCurrencyCode: "USD")

        let maybeState = try chainRepo.chainState(walletId: walletID, chain: .bitcoin)
        let state = try #require(maybeState)
        #expect(state.nativeBalanceRaw == "2")
        #expect(state.nativeFiat == 60_000)
        #expect(state.totalFiat == 60_000)
        #expect(state.txReceivedCount == 1)
        #expect(state.txSentCount == 1)
        #expect(state.txPendingCount == 1)
        #expect(state.utxoCount == 2)
        #expect(state.utxoTotalSats == 30_000)
        #expect(state.hasEncryptedKey)
    }

    @Test("optimistic outgoing debits persisted balances and cached UTXOs")
    func optimisticOutgoingDebitAndUTXOCache() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletID = try await insertWatchWallet(
            database,
            chainsAndAddresses: [
                (.bitcoin, "bc1qreceive"),
                (.bitcoin, "bc1qchange")
            ]
        )
        let addressIDs = try addressIDs(walletID: walletID, chain: .bitcoin, database: database)
        let txRepo = TransactionRepository(database: database)
        try txRepo.upsertBalance(
            addressId: addressIDs[0],
            tokenSymbol: "BTC",
            tokenContract: nil,
            decimals: 8,
            rawBalance: "100000000",
            fiatValueCached: 30_000,
            fiatCurrencyCode: "USD"
        )

        #expect(try txRepo.applyOptimisticOutgoingDebit(
            walletId: walletID,
            chain: .bitcoin,
            tokenSymbol: "BTC",
            tokenContract: nil,
            decimals: 8,
            displayAmount: Decimal(string: "0.2501")!
        ))
        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT raw_balance FROM token_balances WHERE address_id = ?",
            arguments: [addressIDs[0].uuidString],
            database: database
        ) == "74990000")
        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT fiat_value_cached FROM token_balances WHERE address_id = ?",
            arguments: [addressIDs[0].uuidString],
            database: database
        ) == "22497")

        let chainRepo = ChainStateRepository(database: database)
        try chainRepo.replaceAddressedUTXOs(
            walletId: walletID,
            chain: .bitcoin,
            utxos: [
                .init(address: "bc1qreceive", txid: "spent-a", vout: 0, valueSats: 20_000, scriptHex: "51", confirmed: true),
                .init(address: "bc1qchange", txid: "spent-b", vout: 1, valueSats: 10_000, scriptHex: "52", confirmed: false)
            ]
        )
        let cached = try chainRepo.utxos(walletId: walletID, chain: .bitcoin)
        #expect(cached.map(\.ownerAddress) == ["bc1qreceive", "bc1qchange"])
        try chainRepo.removeUTXOs(walletId: walletID, chain: .bitcoin, utxos: [cached[0]])
        #expect(try chainRepo.utxos(walletId: walletID, chain: .bitcoin).map(\.txid) == ["spent-b"])
    }

    @Test("discovered Bitcoin receive/change addresses are persisted before UTXO linking")
    func bitcoinDiscoveredAddressesLinkUTXOs() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletID = try await insertWatchWallet(
            database,
            chainsAndAddresses: [(.bitcoin, "bc1qreceive")]
        )
        let chainRepo = ChainStateRepository(database: database)

        #expect(try chainRepo.upsertDiscoveredAddresses(
            walletId: walletID,
            chain: .bitcoin,
            addresses: [
                .init(address: "bc1qreceive", derivationPath: "m/84'/0'/0'/0/0", isUsed: true),
                .init(address: "bc1qchange", derivationPath: "m/84'/0'/0'/1/0", isUsed: true)
            ]
        ) == 2)
        try chainRepo.replaceAddressedUTXOs(
            walletId: walletID,
            chain: .bitcoin,
            utxos: [
                .init(address: "bc1qreceive", txid: "receive-utxo", vout: 0, valueSats: 10_000, scriptHex: nil, confirmed: true),
                .init(address: "bc1qchange", txid: "change-utxo", vout: 1, valueSats: 20_000, scriptHex: nil, confirmed: true)
            ]
        )

        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT derivation_path FROM wallet_addresses WHERE wallet_id = ? AND chain_raw = ? AND address = ?",
            arguments: [walletID.uuidString, SupportedChain.bitcoin.rawValue, "bc1qchange"],
            database: database
        ) == "m/84'/0'/0'/1/0")
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM chain_utxos WHERE wallet_id = ? AND chain_raw = ? AND address_id IS NOT NULL",
            arguments: [walletID.uuidString, SupportedChain.bitcoin.rawValue],
            database: database
        ) == 2)
    }

    @Test("price, chart, and sync repositories persist cache rows with upsert semantics")
    func priceChartAndSyncCaches() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletID = try await insertWatchWallet(database, chains: [.ethereum])
        let addressID = try firstAddressID(walletID: walletID, chain: .ethereum, database: database)
        let priceRepo = PriceSnapshotRepository(database: database)
        let now = Date(timeIntervalSince1970: 10_000)
        try priceRepo.record([(symbol: "btc", currencyCode: "usd", price: 100, source: "test")], at: now.addingTimeInterval(-24 * 3600))
        try priceRepo.record([(symbol: "BTC", currencyCode: "USD", price: 110, source: "test")], at: now)
        let latest = try priceRepo.latest(symbol: "btc", currency: "usd")
        let maybeChange = try priceRepo.change24h(symbol: "BTC", currency: "USD", now: now)
        let change = try #require(maybeChange)
        #expect(latest?.price == 110)
        #expect(change.absolute == 10)
        #expect(change.percent == 10)

        try TransactionRepository(database: database).upsertBalance(
            addressId: addressID,
            tokenSymbol: "ETH",
            tokenContract: nil,
            decimals: 18,
            rawBalance: "1000000000000000000",
            fiatValueCached: 2500,
            fiatCurrencyCode: "USD"
        )
        let chartRepo = WalletChartSnapshotRepository(database: database)
        #expect(try chartRepo.captureFromPersistedBalances(walletId: walletID, currencyCode: "usd", now: now))
        #expect(try chartRepo.capture(walletId: walletID, currencyCode: "USD", fiatValue: 2600, now: now.addingTimeInterval(60)) == false)
        let series = try chartRepo.series(walletId: walletID, currencyCode: "USD")
        #expect(series.count == 1)
        #expect(series.first?.fiatValue == 2500)

        let syncRepo = SyncStatusRepository(database: database)
        try syncRepo.markSyncing(domain: .balances, scopeId: walletID.uuidString)
        try syncRepo.markFailed(domain: .balances, scopeId: walletID.uuidString, error: String(repeating: "x", count: 260))
        let row = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_statuses WHERE key = ?", arguments: [
                SyncStatusRecord.makeKey(domain: .balances, scopeId: walletID.uuidString)
            ])
        }
        #expect((row?["is_syncing"] as Int?) == 0)
        #expect(((row?["last_error_message"] as String?) ?? "").count == 200)
        #expect(try TestAppDatabaseFactory.count("sync_statuses", database: database) == 1)
    }

    @Test("full reset wipes wallet-private tables and preserves catalog/cache reference data")
    func resetCompleteness() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let defaultsSnapshot = UserDefaults.standard.dictionaryRepresentation()
        defer { restoreStandardDefaults(defaultsSnapshot) }

        try AssetCatalogSeeder.seed(database: database)
        let walletID = try await insertCreatedWalletWithData(database)
        ActiveWalletPointer.configure(database: database)
        ActiveWalletPointer.set(walletID)
        try seedResetRows(walletID: walletID, database: database)

        try await FactoryReset.performFullWipe(database: database)

        for table in [
            "wallets", "wallet_addresses", "wallet_secrets", "transactions",
            "token_balances", "chain_states", "chain_utxos",
            "wallet_chart_snapshots", "wallet_portfolio_summaries",
            "custom_tokens", "biometric_enrollment", "asset_logo_cache",
            "wallet_avatar_raster_cache", "generated_documents",
            "cloudkit_backup_cache", "diagnostic_log_entries"
        ] {
            #expect(try TestAppDatabaseFactory.count(table, database: database) == 0, "\(table) was not reset")
        }
        #expect(try TestAppDatabaseFactory.count("local_secure_blobs", database: database) == 2)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM local_secure_blobs WHERE key IN (?, ?)",
            arguments: [LocalSecureBlobStore.walletSecretMasterKey, LocalSecureBlobStore.chainKeyMasterKey],
            database: database
        ) == 2)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM sync_statuses WHERE scope_id != ?",
            arguments: [SyncDomain.globalScope],
            database: database
        ) == 0)
        #expect(try TestAppDatabaseFactory.scalarString(
            "SELECT wallet_id FROM active_wallet WHERE id = 'active-wallet-singleton'",
            database: database
        ) == nil)
        #expect(try TestAppDatabaseFactory.count("chains", database: database) == AssetCatalog.allChains.count)
        #expect(try TestAppDatabaseFactory.count("cached_prices", database: database) == 1)
        #expect(try TestAppDatabaseFactory.count("historical_prices", database: database) == 1)
        #expect(try TestAppDatabaseFactory.scalarInt(
            "SELECT COUNT(*) FROM sync_statuses WHERE scope_id = ?",
            arguments: [SyncDomain.globalScope],
            database: database
        ) == 1)
    }

    @Test("large wallet home and activity projections are bounded SQL reads")
    func largeWalletProjectionsPageInSQL() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }
        let walletID = try await insertWatchWallet(database, chains: [.ethereum])
        let addressID = try firstAddressID(walletID: walletID, chain: .ethereum, database: database)
        try TransactionRepository(database: database).upsertBalance(
            addressId: addressID,
            tokenSymbol: "ETH",
            tokenContract: nil,
            decimals: 18,
            rawBalance: "1000000000000000000",
            fiatValueCached: 2000,
            fiatCurrencyCode: "USD"
        )
        try database.write { db in
            for index in 0..<1_200 {
                try db.execute(
                    sql: """
                    INSERT INTO transactions
                    (id, address_id, tx_hash, direction_raw, amount_raw, token_symbol,
                     token_contract, block_number, occurred_at_ms, status_raw, counterparty, fee_raw, kind_raw)
                    VALUES (?, ?, ?, ?, ?, 'ETH', NULL, ?, ?, ?, '', NULL, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        addressID.uuidString,
                        "large-\(index)",
                        TransactionDirection.incoming.rawValue,
                        "\(index)",
                        index,
                        Int64(10_000 + index),
                        TransactionStatus.confirmed.rawValue,
                        TransactionKind.transfer.rawValue
                    ]
                )
            }
        }

        let summary = try database.read { db in
            try WalletHomeProjection.summary(db: db, walletId: walletID, currencyCode: "usd")
        }
        let firstPage = try database.read { db in
            try WalletActivityProjection.rows(db: db, walletId: walletID, limit: 25)
        }
        let secondPage = try database.read { db in
            try WalletActivityProjection.rows(db: db, walletId: walletID, limit: 25, offset: 25)
        }

        #expect(summary.totalFiat == 2000)
        #expect(summary.balanceRowCount == 1)
        #expect(summary.transactionCount == 1_200)
        #expect(firstPage.count == 25)
        #expect(secondPage.count == 25)
        #expect(firstPage.first?.txHash == "large-1199")
        #expect(secondPage.first?.txHash == "large-1174")
    }

    private func insertWatchWallet(
        _ database: AppDatabase,
        chains: [SupportedChain]
    ) async throws -> UUID {
        try await insertWatchWallet(
            database,
            chainsAndAddresses: chains.map { ($0, "\($0.rawValue)-address") }
        )
    }

    private func insertWatchWallet(
        _ database: AppDatabase,
        chainsAndAddresses: [(SupportedChain, String)]
    ) async throws -> UUID {
        let id = UUID()
        try await WalletCommandRepository(database: database).insertWatchOnlyWallet(
            id: id,
            name: "Watch \(id.uuidString.prefix(4))",
            colorTag: "gray",
            addresses: chainsAndAddresses.map { ($0.0.rawValue, $0.1) }
        )
        return id
    }

    private func insertCreatedWalletWithData(_ database: AppDatabase) async throws -> UUID {
        let id = UUID()
        try await WalletCommandRepository(database: database).insertCreatedWallet(
            id: id,
            name: "Reset Wallet",
            mnemonicWordCount: 4,
            hasPassphrase: false,
            colorTag: "red",
            requiresBackup: true,
            mnemonicWords: ["abandon", "ability", "able", "about"],
            addresses: [(SupportedChain.ethereum.rawValue, "0xreset")]
        )
        let addressID = try firstAddressID(walletID: id, chain: .ethereum, database: database)
        try TransactionRepository(database: database).upsertBalance(
            addressId: addressID,
            tokenSymbol: "ETH",
            tokenContract: nil,
            decimals: 18,
            rawBalance: "1",
            fiatValueCached: 1,
            fiatCurrencyCode: "USD"
        )
        try TransactionRepository(database: database).upsertTransaction(
            addressId: addressID,
            txHash: "reset-tx",
            direction: .incoming,
            amountRaw: "1",
            tokenSymbol: "ETH",
            blockNumber: 1,
            occurredAt: Date(),
            status: .confirmed,
            counterparty: "",
            feeRaw: nil
        )
        try ChainStateRepository(database: database).replaceAddressedUTXOs(
            walletId: id,
            chain: .ethereum,
            utxos: [.init(address: "0xreset", txid: "reset-utxo", vout: 0, valueSats: 1, scriptHex: nil, confirmed: true)]
        )
        try WalletChartSnapshotRepository(database: database).record(
            walletId: id,
            currencyCode: "USD",
            fiatValue: 1,
            capturedAt: Date()
        )
        try ChainStateRepository(database: database).rebuild(walletId: id, fiatCurrencyCode: "USD")
        return id
    }

    private func seedResetRows(walletID: UUID, database: AppDatabase) throws {
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(sql: "INSERT INTO biometric_enrollment (id, domain_state_snapshot, updated_at_ms) VALUES ('bio', ?, ?)", arguments: [Data([1]), now])
            try db.execute(
                sql: """
                INSERT INTO custom_tokens
                (id, chain_raw, contract, symbol, name, decimals, icon_url, added_at_ms, metadata_from_chain, dedup_key)
                VALUES (?, ?, ?, 'TST', 'Test', 18, NULL, ?, 1, ?)
                """,
                arguments: [UUID().uuidString, SupportedChain.ethereum.rawValue, "0xtoken", now, "ethereum|0xtoken"]
            )
            try db.execute(
                sql: """
                INSERT INTO cached_prices (key, symbol, fiat, price, price_numeric, fetched_at_ms, source)
                VALUES ('ETH|USD', 'ETH', 'USD', '1', 1, ?, 'test')
                """,
                arguments: [now]
            )
            try db.execute(
                sql: """
                INSERT INTO historical_prices (key, symbol, fiat, day_key, price, price_numeric, fetched_at_ms)
                VALUES ('ETH|USD|1', 'ETH', 'USD', 1, '1', 1, ?)
                """,
                arguments: [now]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_logo_cache (cache_key, source_url, png_data, updated_at_ms)
                VALUES ('logo', 'https://example.com/logo.png', ?, ?)
                """,
                arguments: [Data([1, 2, 3]), now]
            )
            try db.execute(
                sql: """
                INSERT INTO wallet_avatar_raster_cache (wallet_id, png_data, updated_at_ms)
                VALUES (?, ?, ?)
                """,
                arguments: [walletID.uuidString, Data([4, 5, 6]), now]
            )
            try db.execute(
                sql: """
                INSERT INTO generated_documents (id, kind_raw, file_name, mime_type, data, created_at_ms)
                VALUES (?, 'activityStatement', 'statement.pdf', 'application/pdf', ?, ?)
                """,
                arguments: [UUID().uuidString, Data([7, 8, 9]), now]
            )
            try db.execute(
                sql: """
                INSERT INTO cloudkit_backup_cache (wallet_id, version, encoded_blob, created_at_ms, updated_at_ms)
                VALUES (?, 1, ?, ?, ?)
                """,
                arguments: [walletID.uuidString, Data([10, 11, 12]), now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO diagnostic_log_entries (id, timestamp_ms, level_raw, category, message, metadata_json)
                VALUES (?, ?, 'debug', 'test', 'reset fixture', '{}')
                """,
                arguments: [UUID().uuidString, now]
            )
            try db.execute(
                sql: """
                INSERT INTO local_secure_blobs (key, blob, created_at_ms, updated_at_ms)
                VALUES ('pin.test.fixture', ?, ?, ?)
                """,
                arguments: [Data([13, 14, 15]), now, now]
            )
        }
        let sync = SyncStatusRepository(database: database)
        try sync.markSynced(domain: .balances, scopeId: walletID.uuidString)
        try sync.markSynced(domain: .prices, scopeId: SyncDomain.globalScope)
    }

    private func firstAddressID(walletID: UUID, chain: SupportedChain, database: AppDatabase) throws -> UUID {
        try #require(addressIDs(walletID: walletID, chain: chain, database: database).first)
    }

    private func addressIDs(walletID: UUID, chain: SupportedChain, database: AppDatabase) throws -> [UUID] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT id FROM wallet_addresses
                WHERE wallet_id = ? AND chain_raw = ?
                ORDER BY is_receive_preferred DESC, address ASC
                """,
                arguments: [walletID.uuidString, chain.rawValue]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    private func restoreStandardDefaults(_ snapshot: [String: Any]) {
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        for (key, value) in snapshot {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}
