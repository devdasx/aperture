import Testing
import Foundation
import SwiftData
@testable import Aperture

/// Factory-reset completeness contract (user direction 2026-06-13:
/// *"when resetting the app everything in the app should be removed
/// like we've installed the app now for the first time"*).
///
/// **What is tested here.** The SwiftData tier of the wipe —
/// `FactoryReset.wipeAllModels(in:)`, the exact helper
/// `AdvancedSettingsView.resetAll()` calls. One representative row of
/// EVERY model type in `ApertureSchemaV1.models` is inserted, the
/// structural wipe runs, and every table must come back empty. The
/// factory lookup is itself structural: a model type added to the
/// schema without a representative factory FAILS the test — so wipe
/// coverage and test coverage grow in lockstep.
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
/// - **WKWebsiteDataStore / TipKit datastore / CoinMarkCache disk
///   directory** — sandbox-global singletons; same reasoning.
/// Those tiers are pinned here at the *inventory* level (the
/// FreshInstallGuard service audit + the schema tripwire), and their
/// wiring is verified on-device.
@Suite struct ResetCompletenessTests {

    // MARK: - Container

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ApertureSchemaV1.models)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Representative factories

    /// Insert one representative row for `model`. Returns `false` when
    /// no factory exists — which is the test's structural tripwire: a
    /// model added to `ApertureSchemaV1.models` without a factory here
    /// fails `wipeAllModelsEmptiesEveryTable` with a named message.
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
        } else if model == BrowserHistoryRecord.self {
            context.insert(BrowserHistoryRecord(
                url: "https://example.org",
                title: "Example",
                host: "example.org"
            ))
        } else if model == BrowserBookmarkRecord.self {
            context.insert(BrowserBookmarkRecord(
                url: "https://example.org",
                title: "Example",
                host: "example.org"
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

    @Test("FactoryReset.wipeAllModels empties every table in ApertureSchemaV1.models")
    func wipeAllModelsEmptiesEveryTable() throws {
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

        // 3. The same structural wipe `resetAll()` runs.
        try FactoryReset.wipeAllModels(in: context)

        // 4. Factory state: every table empty.
        for model in ApertureSchemaV1.models {
            #expect(
                try rowCount(of: model, in: context) == 0,
                "\(String(describing: model)) still has rows after FactoryReset.wipeAllModels — the reset is incomplete."
            )
        }
    }

    @Test("wipeAllModels on an already-empty store is a no-op, not an error")
    func wipeAllModelsIdempotentOnEmptyStore() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try FactoryReset.wipeAllModels(in: context)
        try FactoryReset.wipeAllModels(in: context)
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
            "WalletAddressRecord",
            "TransactionRecord",
            "TokenBalanceRecord",
            "CachedPriceRecord",
            "BiometricEnrollmentRecord",
            "AppMetadataRecord",
            "CustomTokenRecord",
            "BrowserHistoryRecord",
            "BrowserBookmarkRecord",
            "HistoricalPriceRecord",
            "PriceSnapshotRecord",
            "WalletChartSnapshotRecord",
            "SyncStatusRecord",
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
            "com.thuglife.aperture.wallet-manifest",   // WalletManifestStore
            "com.thuglife.aperture.pin",               // PinCodeStorage
            "com.thuglife.aperture.pin.smoketest",     // PinCodeStorage (DEBUG)
        ]
        let actual = Set(FreshInstallGuard.knownServicesForAudit)
        #expect(
            actual == expected,
            "FreshInstallGuard.knownServices diverged from the audited Keychain service inventory — reconcile both or reinstalls will leak prior-owner data."
        )
    }
}
