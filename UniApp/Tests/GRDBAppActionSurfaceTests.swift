import Foundation
import GRDB
import Testing
@testable import Aperture

@MainActor
@Suite("GRDB app action surface")
struct GRDBAppActionSurfaceTests {
    private let mnemonic = ["abandon", "abandon", "abandon", "abandon", "abandon", "abandon", "abandon", "abandon", "abandon", "abandon", "abandon", "about"]

    @Test("wallet management mutations persist and drive GRDB observations")
    func walletManagementMutationsPersistAndDriveObservations() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { cleanup(database: database) }

        let createdID = UUID()
        let hiddenID = UUID()
        let visibleID = UUID()
        let commands = WalletCommandRepository(database: database)
        try await commands.insertCreatedWallet(
            id: createdID,
            name: "Created Wallet",
            mnemonicWordCount: mnemonic.count,
            hasPassphrase: false,
            colorTag: "blue",
            requiresBackup: true,
            mnemonicWords: mnemonic,
            addresses: [(SupportedChain.ethereum.rawValue, "0xcreated")]
        )
        try await commands.insertWatchOnlyWallet(
            id: hiddenID,
            name: "Hidden Watch",
            colorTag: "gray",
            addresses: [(SupportedChain.ethereum.rawValue, "0xhidden")]
        )
        try await commands.insertImportedKeyWallet(
            id: visibleID,
            name: "Visible Key",
            colorTag: "green",
            privateKey: "0x59c6995e998f97a5a0044966f094538f5dae440fdf24c8063c61fbb1c5ab7d7a",
            addresses: [(SupportedChain.ethereum.rawValue, "0xvisible")]
        )

        let wallets = WalletRepository(database: database)
        #expect(try wallets.renameWallet(id: createdID, to: "Renamed Wallet"))
        try wallets.markManualBackupComplete(id: createdID)
        try wallets.markBackupComplete(id: visibleID)
        try wallets.updateSortOrders([visibleID, hiddenID, createdID])
        try database.write { db in
            try db.execute(sql: "UPDATE wallets SET is_hidden = 1 WHERE id = ?", arguments: [hiddenID.uuidString])
        }

        let spec = WalletAvatarSpec(
            gradient: .violet,
            symbolType: .mono,
            glyph: nil,
            monogram: "VK",
            badge: nil
        )
        #expect(try await wallets.updateAvatar(id: visibleID, spec: spec))
        let visibleRow = try walletRow(id: visibleID, database: database)
        #expect(visibleRow?["name"] as String? == "Visible Key")
        #expect(visibleRow?["avatar_gradient"] as String? == WalletAvatarGradient.violet.rawValue)
        #expect(visibleRow?["avatar_symbol_type"] as String? == WalletAvatarSpec.WalletAvatarSymbolType.mono.rawValue)
        #expect(visibleRow?["avatar_monogram"] as String? == "VK")
        #expect(visibleRow?["avatar_badge"] as String? == WalletAvatarBadge.derive(from: .importedKey)?.rawValue)

        let createdRow = try walletRow(id: createdID, database: database)
        #expect(createdRow?["name"] as String? == "Renamed Wallet")
        #expect(createdRow?["requires_backup"] as Int? == 0)
        #expect(createdRow?["manual_backup_completed"] as Int? == 1)

        let listObservation = WalletListObservation(database: database)
        let visibleRows = try await waitForWalletList(listObservation, count: 2)
        #expect(visibleRows.map(\.id) == [visibleID, createdID])
        #expect(!visibleRows.map(\.id).contains(hiddenID))

        let maybeVisibleAddress = try wallets.address(walletId: visibleID, chain: .ethereum)
        let visibleAddress = try #require(maybeVisibleAddress)
        try TransactionRepository(database: database).upsertBalance(
            addressId: visibleAddress.id,
            tokenSymbol: "ETH",
            tokenContract: nil,
            decimals: 18,
            rawBalance: "1200000000000000000",
            fiatValueCached: 42,
            fiatCurrencyCode: "USD"
        )
        try TransactionRepository(database: database).upsertTransaction(
            addressId: visibleAddress.id,
            txHash: "0xsurface",
            direction: .incoming,
            amountRaw: "1200000000000000000",
            tokenSymbol: "ETH",
            blockNumber: 12,
            occurredAt: Date(timeIntervalSince1970: 1_000),
            status: .confirmed,
            counterparty: "0xsender",
            feeRaw: nil
        )

        let summaryObservation = WalletHomeSummaryObservation(walletId: visibleID, currencyCode: "usd", database: database)
        let summary = try await waitForSummary(summaryObservation)
        #expect(summary.currencyCode == "USD")
        #expect(summary.totalFiat == 42)
        #expect(summary.balanceRowCount == 1)
        #expect(summary.transactionCount == 1)

        let activityObservation = WalletActivityPageObservation(walletId: visibleID, limit: 10, database: database)
        let activityRows = try await waitForActivity(activityObservation, count: 1)
        #expect(activityRows.first?.txHash == "0xsurface")
        #expect(activityRows.first?.chain == .ethereum)

        ActiveWalletPointer.configure(database: database)
        ActiveWalletPointer.set(createdID)
        let next = try await wallets.deleteWalletAndActivateNext(walletId: createdID)
        #expect(next == visibleID)
        #expect(ActiveWalletPointer.currentId == visibleID)
        #expect(try activeWalletRaw(database: database) == visibleID.uuidString)
        #expect(try WalletSecretPersistence.loadMnemonic(for: createdID, database: database) == nil)
    }

    @Test("settings, custom tokens, biometric state, and market caches persist through GRDB")
    func settingsCustomTokensBiometricsAndMarketsPersist() async throws {
        let database = try TestAppDatabaseFactory.makeDatabase()
        defer { TestAppDatabaseFactory.cleanup(database) }

        let walletID = UUID()
        try await WalletCommandRepository(database: database).insertWatchOnlyWallet(
            id: walletID,
            name: "Settings Wallet",
            colorTag: "blue",
            addresses: [(SupportedChain.ethereum.rawValue, "0xsettings")]
        )

        let store = AppPreferenceStore.shared
        store.set("dark", forKey: "themePreference")
        store.set("ar", forKey: "languagePreference")
        store.set(true, forKey: PinCodePreference.pinEnabledKey)
        store.set(true, forKey: PinCodePreference.biometricEnabledKey)
        store.set(30, forKey: AutoLockPreference.storageKey)
        store.set("EUR", forKey: CurrencyPreference.storageKey)
        store.set(false, forKey: HapticPreference.storageKey)
        store.set(false, forKey: "backgroundBalanceRefresh")
        store.set(BalanceHistoryRange.week.rawValue, forKey: "walletHomeBalanceHistoryRange")
        store.set(MainTab.markets.rawValue, forKey: MainTab.storageKey)
        store.set(walletID.uuidString, forKey: ActiveWalletPointer.storageKey)
        store.set("security", forKey: "settingsDeepLink")
        store.set(true, forKey: "hasUnbackedupWallet")
        store.set(true, forKey: "hideImportKeyWarning")

        let settings = try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM app_settings WHERE id = 'app-settings-singleton'")
        }
        #expect(settings?["theme_preference"] as String? == "dark")
        #expect(settings?["language_preference"] as String? == "ar")
        #expect(settings?["pin_enabled"] as Int? == 1)
        #expect(settings?["biometric_enabled"] as Int? == 1)
        #expect(settings?["auto_lock_seconds"] as Int? == 30)
        #expect(settings?["currency_preference"] as String? == "EUR")
        #expect(settings?["haptic_feedback_enabled"] as Int? == 0)
        #expect(settings?["background_balance_refresh"] as Int? == 0)
        #expect(settings?["wallet_home_balance_history_range"] as String? == BalanceHistoryRange.week.rawValue)
        #expect(settings?["selected_tab"] as Int? == 2)
        #expect(settings?["active_wallet_id"] as String? == walletID.uuidString)
        #expect(settings?["settings_deep_link"] as String? == "security")
        #expect(settings?["has_unbackedup_wallet"] as Int? == 1)
        #expect(settings?["hide_import_key_warning"] as Int? == 1)
        #expect(try activeWalletRaw(database: database) == walletID.uuidString)

        let customTokens = CustomTokenRepository(database: database)
        let tokenID = UUID()
        try customTokens.add(
            id: tokenID,
            chain: .ethereum,
            contract: "0xABCDEF",
            symbol: "TST",
            name: "Test Token",
            decimals: 6,
            metadataFromChain: false
        )
        let maybeFetched = try customTokens.fetchByContract(chain: .ethereum, contract: "0xabcdef")
        let fetched = try #require(maybeFetched)
        #expect(fetched.id == tokenID)
        #expect(fetched.symbol == "TST")
        #expect(fetched.metadataFromChain == false)
        do {
            try customTokens.add(chain: .ethereum, contract: "0xabcdef", symbol: "DUP", name: "Duplicate", decimals: 6)
            Issue.record("Duplicate custom token insert unexpectedly succeeded")
        } catch CustomTokenError.duplicate {
        }
        #expect(try customTokens.fetchAll(chain: .ethereum).count == 1)

        BiometricEnrollmentTracker.captureSnapshot(database: database)
        try database.write { db in
            try db.execute(
                sql: "UPDATE app_metadata SET requires_biometric_reenrollment = 1 WHERE id = 'app-metadata-singleton'"
            )
        }
        #expect(BiometricEnrollmentTracker.requiresReenrollment(database: database))
        BiometricEnrollmentTracker.acknowledgeReenrollment(database: database)
        #expect(!BiometricEnrollmentTracker.requiresReenrollment(database: database))
        #expect(try TestAppDatabaseFactory.count("biometric_enrollment", database: database) == 1)

        try seedMarketCache(database: database)
        let markets = MarketsViewModel(database: database)
        markets.loadCached()
        #expect(markets.assets.map(\.symbol) == ["ETH"])
        markets.toggleWatchlist(symbol: "eth")
        #expect(markets.isWatchlisted("ETH"))
        let reloadedMarkets = MarketsViewModel(database: database)
        reloadedMarkets.loadCached()
        #expect(reloadedMarkets.isWatchlisted("eth"))
        reloadedMarkets.toggleWatchlist(symbol: "ETH")
        #expect(try TestAppDatabaseFactory.count("market_watchlist", database: database) == 0)

        let chart = try #require(markets.cachedChart(symbol: "eth", range: .oneDay, currencyCode: "usd"))
        #expect(chart.currencyCode == "USD")
        #expect(chart.source == "test")
        #expect(chart.points.map(\.price) == [2_000, 2_100])

        try customTokens.remove(id: tokenID)
        #expect(try customTokens.fetchAll(chain: .ethereum).isEmpty)
    }

    private func walletRow(id: UUID, database: AppDatabase) throws -> Row? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM wallets WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private func activeWalletRaw(database: AppDatabase) throws -> String? {
        try TestAppDatabaseFactory.scalarString(
            "SELECT wallet_id FROM active_wallet WHERE id = 'active-wallet-singleton'",
            database: database
        )
    }

    private func waitForWalletList(_ observation: WalletListObservation, count: Int) async throws -> [WalletListRowDTO] {
        for _ in 0..<50 {
            if let error = observation.lastError { throw error }
            if observation.wallets.count == count { return observation.wallets }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let error = observation.lastError { throw error }
        return observation.wallets
    }

    private func waitForSummary(_ observation: WalletHomeSummaryObservation) async throws -> WalletHomeSummaryDTO {
        for _ in 0..<50 {
            if let error = observation.lastError { throw error }
            if let summary = observation.summary, summary.transactionCount > 0 { return summary }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let error = observation.lastError { throw error }
        return try #require(observation.summary)
    }

    private func waitForActivity(_ observation: WalletActivityPageObservation, count: Int) async throws -> [WalletActivityRowDTO] {
        for _ in 0..<50 {
            if let error = observation.lastError { throw error }
            if observation.rows.count == count { return observation.rows }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let error = observation.lastError { throw error }
        return observation.rows
    }

    private func seedMarketCache(database: AppDatabase) throws {
        let points = [
            MarketPoint(date: Date(timeIntervalSince1970: 1_000), price: 2_000),
            MarketPoint(date: Date(timeIntervalSince1970: 2_000), price: 2_100)
        ]
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO market_assets
                (symbol, name, provider_id, rank, price, currency_code,
                 price_change_24h_percent, price_change_24h_amount,
                 market_cap, volume_24h, circulating_supply, ath, high_24h, low_24h,
                 about, sparkline_json, source, last_updated_at_ms)
                VALUES ('ETH', 'Ethereum', 'ethereum', 2, 2000, 'USD',
                        1.5, 30, 1000000, 500000, 120000000, 4800, 2200, 1900,
                        'Ethereum test cache', ?, 'test', ?)
                """,
                arguments: [MarketPoint.codec.encode(points), now]
            )
            try db.execute(
                sql: """
                INSERT INTO market_chart_cache
                (cache_key, symbol, range_raw, currency_code, samples_json, source, updated_at_ms)
                VALUES (?, 'ETH', ?, 'USD', ?, 'test', ?)
                """,
                arguments: [
                    MarketChartCacheRecord.key(symbol: "ETH", range: .oneDay, currencyCode: "USD"),
                    MarketChartRange.oneDay.rawValue,
                    MarketPoint.codec.encode(points),
                    now
                ]
            )
        }
    }

    private func cleanup(database: AppDatabase) {
        if let ids = try? WalletRepository(database: database).allWalletIds() {
            for id in ids {
                try? SeedVault.deleteSeed(for: id)
                try? MnemonicVault.deleteMnemonic(for: id)
                try? MnemonicVault.deletePrivateKey(for: id)
            }
        }
        TestAppDatabaseFactory.cleanup(database)
    }
}
