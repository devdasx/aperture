import Testing
import Foundation
import SwiftData
@testable import Aperture

/// Reset completeness contract.
///
/// **What is tested here.** The SwiftData tier of the wipe —
/// `FactoryReset.wipeResettableModels(in:)`, the exact SwiftData helper
/// Reset Aperture calls after the wallet repository drops wallet rows.
/// One representative row of EVERY model type in `ApertureSchemaV1.models`
/// is inserted. Resettable/private rows must be deleted; public market /
/// price / catalog rows must survive. The factory lookup is itself
/// structural: a model type added to the schema without a representative
/// factory FAILS the test, so reset policy and schema coverage grow in
/// lockstep.
///
/// **What CANNOT be tested in-memory (the honest boundary).** The
/// non-SwiftData tiers of `resetAll()` are real-device state with no
/// in-memory seam:
/// - **Keychain** (SeedVault / MnemonicVault / PinCodeStorage /
///   WalletManifestStore) — the test bundle shares the host app's
///   Keychain; asserting emptiness would race (and wipe) a parallel
///   dev session. Covered instead by `FreshInstallGuardTests` (marker
///   state machine) + the service-inventory pin below.
/// - **UserDefaults** (`removePersistentDomain`) — wiping the real
///   standard domain mid-test-run would destroy the host's state.
/// - **WKWebsiteDataStore / TipKit datastore / asset-logo disk
///   directory** — sandbox-global singletons; same reasoning.
/// Those tiers are pinned here at the *inventory* level (the
/// FreshInstallGuard service audit + the schema tripwire), and their
/// wiring is verified on-device.
@Suite struct ResetCompletenessTests {

    // MARK: - Container

    private func makeContainer() throws -> ModelContainer {
        try TestModelContainerFactory.makeContainer()
    }

    // MARK: - Representative factories

    /// Insert one representative row for `model`. Returns `false` when
    /// no factory exists — which is the test's structural tripwire: a
    /// model added to `ApertureSchemaV1.models` without a factory here
    /// fails the reset-policy test with a named message.
    ///
    /// Rows are deliberately UNRELATED to each other (no
    /// relationships set) so no cascade fires during the wipe and
    /// every table's emptiness is proven by its own deletion.
    private func insertRepresentativeRow(
        for model: any PersistentModel.Type,
        into context: ModelContext
    ) -> Bool {
        if model == WalletRecord.self {
            context.insert(WalletRecord(
                name: "Reset Test",
                kind: .watchOnly,
                mnemonicWordCount: nil,
                hasPassphrase: false,
                colorTag: "default",
                sortOrder: 0,
                requiresBackup: false
            ))
        } else if model == WalletSecretRecord.self {
            context.insert(WalletSecretRecord(
                walletId: UUID(),
                kind: .mnemonic,
                cipherData: Data([0x01])
            ))
        } else if model == WalletAddressRecord.self {
            context.insert(WalletAddressRecord(
                chainRaw: "ethereum",
                address: "0x0000000000000000000000000000000000000001"
            ))
        } else if model == TransactionRecord.self {
            context.insert(TransactionRecord(
                txHash: "0xreset",
                direction: .incoming,
                amountRaw: "1",
                tokenSymbol: "ETH",
                occurredAt: Date(),
                status: .confirmed,
                counterparty: "0x0000000000000000000000000000000000000002"
            ))
        } else if model == TokenBalanceRecord.self {
            context.insert(TokenBalanceRecord(
                tokenSymbol: "ETH",
                decimals: 18,
                rawBalance: "1000000000000000000"
            ))
        } else if model == CachedPriceRecord.self {
            context.insert(CachedPriceRecord(
                symbol: "BTC",
                fiat: "USD",
                price: 1,
                source: "test"
            ))
        } else if model == BiometricEnrollmentRecord.self {
            context.insert(BiometricEnrollmentRecord(domainStateSnapshot: nil))
        } else if model == AppMetadataRecord.self {
            context.insert(AppMetadataRecord())
        } else if model == CustomTokenRecord.self {
            context.insert(CustomTokenRecord(
                chainRaw: "ethereum",
                contract: "0x0000000000000000000000000000000000000003",
                symbol: "TST",
                name: "Test Token",
                decimals: 18
            ))
        } else if model == HistoricalPriceRecord.self {
            context.insert(HistoricalPriceRecord(
                symbol: "BTC",
                fiat: "USD",
                dayKey: 20260101,
                price: 1
            ))
        } else if model == PriceSnapshotRecord.self {
            context.insert(PriceSnapshotRecord(
                symbol: "BTC",
                currencyCode: "USD",
                price: 1,
                source: "test"
            ))
        } else if model == WalletChartSnapshotRecord.self {
            context.insert(WalletChartSnapshotRecord(
                walletId: UUID(),
                currencyCode: "USD",
                fiatValue: 1
            ))
        } else if model == SyncStatusRecord.self {
            context.insert(SyncStatusRecord(
                key: "balances|test",
                domainRaw: SyncDomain.balances.rawValue,
                scopeId: "test"
            ))
        } else if model == MarketAssetRecord.self {
            context.insert(MarketAssetRecord(asset: MarketAsset(
                symbol: "BTC",
                name: "Bitcoin",
                providerId: "bitcoin",
                rank: 1,
                price: 1,
                currencyCode: "USD",
                priceChange24hPercent: 0,
                priceChange24hAmount: 0,
                marketCap: 1,
                volume24h: 1,
                circulatingSupply: 1,
                ath: 1,
                high24h: 1,
                low24h: 1,
                about: "Test market row",
                sparkline: [MarketPoint(date: Date(), price: 1)],
                source: "test",
                lastUpdatedAt: Date()
            )))
        } else if model == MarketChartCacheRecord.self {
            context.insert(MarketChartCacheRecord(
                symbol: "BTC",
                range: .oneDay,
                currencyCode: "USD",
                samples: [MarketPoint(date: Date(), price: 1)],
                source: "test"
            ))
        } else if model == MarketWatchlistRecord.self {
            context.insert(MarketWatchlistRecord(symbol: "BTC"))
        } else if model == ChainRecord.self {
            context.insert(ChainRecord(
                chainRaw: "ethereum",
                ticker: "ETH",
                displayName: "Ethereum",
                sortIndex: 0
            ))
        } else if model == AssetRecord.self {
            context.insert(AssetRecord(
                catalogId: "evm.ethereum.0xresettest",
                chainRaw: "ethereum",
                symbol: "TST",
                name: "Reset Test Token",
                contract: "0xresettest",
                decimals: 18
            ))
        } else if model == AppSettingsRecord.self {
            context.insert(AppSettingsRecord())
        } else if model == ChainStateRecord.self {
            context.insert(ChainStateRecord(
                walletId: UUID(),
                chainRaw: "ethereum",
                address: "0x0000000000000000000000000000000000000004"
            ))
        } else if model == ChainUTXORecord.self {
            context.insert(ChainUTXORecord(
                walletId: UUID(),
                chainRaw: "bitcoin",
                address: "bc1qresettest",
                txid: "resettxid",
                vout: 0,
                valueSatsRaw: "1000"
            ))
        } else {
            return false
        }
        return true
    }

    /// Generic row count, opening the schema's existential model type.
    private func rowCount(
        of model: any PersistentModel.Type,
        in context: ModelContext
    ) throws -> Int {
        try countRows(of: model, in: context)
    }

    private func countRows<T: PersistentModel>(
        of type: T.Type,
        in context: ModelContext
    ) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    // MARK: - The wipe contract

    @Test("FactoryReset deletes private rows and preserves public cache rows")
    func resetPolicyDeletesPrivateRowsAndPreservesPublicCaches() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // 1. One representative row per schema model. A model without
        //    a factory fails HERE, by name — the tripwire that keeps
        //    wipe coverage and schema in lockstep.
        for model in ApertureSchemaV1.models {
            let inserted = insertRepresentativeRow(for: model, into: context)
            #expect(
                inserted,
                "No representative factory for \(String(describing: model)) — add one to ResetCompletenessTests so the reset wipe stays provably complete."
            )
        }

        // Extra SyncStatus rows prove the partial retention policy:
        // wallet-scoped rows are private and deleted; global price/history
        // freshness rows are public-cache metadata and retained.
        context.insert(SyncStatusRecord(
            key: "prices|\(SyncDomain.globalScope)",
            domainRaw: SyncDomain.prices.rawValue,
            scopeId: SyncDomain.globalScope
        ))
        context.insert(SyncStatusRecord(
            key: "historical|\(SyncDomain.globalScope)",
            domainRaw: SyncDomain.historical.rawValue,
            scopeId: SyncDomain.globalScope
        ))
        try context.save()

        // 2. Sanity: every table is non-empty before the wipe (an
        //    empty-before table would make the post-wipe assertion
        //    vacuous).
        for model in ApertureSchemaV1.models {
            #expect(
                try rowCount(of: model, in: context) > 0,
                "\(String(describing: model)) had no rows before the wipe — factory broken?"
            )
        }

        // 3. The same SwiftData reset helper Reset Aperture runs.
        try FactoryReset.wipeResettableModels(in: context)

        let resettable = Set(FactoryReset.resettableSwiftDataModels.map { String(describing: $0) })
        let preserved = Set(FactoryReset.preservedSwiftDataModels.map { String(describing: $0) })

        // 4. Private state is gone; public cache/reference state remains.
        for model in ApertureSchemaV1.models {
            let name = String(describing: model)
            if name == "SyncStatusRecord" {
                #expect(try rowCount(of: model, in: context) == 2)
            } else if resettable.contains(name) {
                #expect(
                    try rowCount(of: model, in: context) == 0,
                    "\(name) still has rows after FactoryReset.wipeResettableModels — private reset is incomplete."
                )
            } else if preserved.contains(name) {
                #expect(
                    try rowCount(of: model, in: context) > 0,
                    "\(name) was removed by reset even though it is public cache/reference data."
                )
            } else {
                Issue.record("\(name) has no reset policy — add it to resettableSwiftDataModels or preservedSwiftDataModels.")
            }
        }

        let remainingSyncRows = try context.fetch(FetchDescriptor<SyncStatusRecord>())
        #expect(Set(remainingSyncRows.map(\.key)) == [
            "prices|\(SyncDomain.globalScope)",
            "historical|\(SyncDomain.globalScope)"
        ])
    }

    @Test("wipeResettableModels on an already-empty store is a no-op, not an error")
    func wipeResettableModelsIdempotentOnEmptyStore() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try FactoryReset.wipeResettableModels(in: context)
        try FactoryReset.wipeResettableModels(in: context)
        for model in ApertureSchemaV1.models {
            #expect(try rowCount(of: model, in: context) == 0)
        }
    }

    // MARK: - Schema tripwire

    /// Pins the exact model inventory the wipe enumerates. Adding a
    /// 14th model to `ApertureSchemaV1.models` fails this test until
    /// the new name is added here AND a representative factory exists
    /// above — the deliberate two-key turn for reset completeness.
    @Test("ApertureSchemaV1.models inventory is pinned")
    func schemaModelInventoryIsCurrent() {
        let names = Set(ApertureSchemaV1.models.map { String(describing: $0) })
        let expected: Set<String> = [
            "WalletRecord",
            "WalletSecretRecord",
            "WalletAddressRecord",
            "TransactionRecord",
            "TokenBalanceRecord",
            "CachedPriceRecord",
            "BiometricEnrollmentRecord",
            "AppMetadataRecord",
            "CustomTokenRecord",
            "HistoricalPriceRecord",
            "PriceSnapshotRecord",
            "WalletChartSnapshotRecord",
            "SyncStatusRecord",
            "ChainRecord",
            "AssetRecord",
            "AppSettingsRecord",
            "MarketAssetRecord",
            "MarketChartCacheRecord",
            "MarketWatchlistRecord",
            "ChainStateRecord",
            "ChainUTXORecord",
        ]
        #expect(
            names == expected,
            "ApertureSchemaV1.models changed — update this inventory AND add a representative factory + wipe verification for any new model."
        )
    }

    // MARK: - FreshInstallGuard service inventory

    /// The reinstall-zero-data contract: every Keychain service
    /// Aperture writes under must be in `FreshInstallGuard`'s purge
    /// list, or wallets resurrect after delete + reinstall. The
    /// literals here mirror the (private) service constants in
    /// `SeedVault` / `MnemonicVault` / `WalletManifestStore` /
    /// `PinCodeStorage`; a new vault must extend BOTH the guard's
    /// `knownServices` and this set.
    @Test("FreshInstallGuard purges every Keychain service Aperture writes")
    func freshInstallGuardCoversEveryKnownKeychainService() {
        let expected: Set<String> = [
            "com.thuglife.aperture.seed.cipher",       // SeedVault
            "com.thuglife.aperture.seed.key",          // SeedVault
            "com.thuglife.aperture.mnemonic.cipher",   // MnemonicVault
            "com.thuglife.aperture.mnemonic.key",      // MnemonicVault
            "com.thuglife.aperture.privatekey.cipher", // MnemonicVault
            "com.thuglife.aperture.privatekey.key",    // MnemonicVault
            "com.thuglife.aperture.wallet-secret.master-key", // WalletSecretCrypto
            "com.thuglife.aperture.wallet-manifest",   // WalletManifestStore
            "com.thuglife.aperture.pin",               // PinCodeStorage
            "com.thuglife.aperture.pin.smoketest",     // PinCodeStorage (DEBUG)
            "com.thuglife.aperture.chainkey.master",   // ChainKeyVault
        ]
        let actual = Set(FreshInstallGuard.knownServicesForAudit)
        #expect(
            actual == expected,
            "FreshInstallGuard.knownServices diverged from the audited Keychain service inventory — reconcile both or reinstalls will leak prior-owner data."
        )
    }
}
