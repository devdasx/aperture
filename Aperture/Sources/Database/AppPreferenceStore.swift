import Combine
import Foundation
import GRDB
import SwiftUI

protocol GRDBPreferenceValue: Equatable, Sendable {
    static var preferenceType: String { get }
    static func decodePreference(row: Row) -> Self?
    func encodedPreference() -> StoredPreferenceValue
}

struct StoredPreferenceValue: Sendable {
    let valueType: String
    let stringValue: String?
    let intValue: Int64?
    let doubleValue: Double?
    let boolValue: Int?
    let dataValue: Data?

    static func string(_ value: String) -> StoredPreferenceValue {
        StoredPreferenceValue(valueType: "string", stringValue: value, intValue: nil, doubleValue: nil, boolValue: nil, dataValue: nil)
    }

    static func int(_ value: Int) -> StoredPreferenceValue {
        StoredPreferenceValue(valueType: "int", stringValue: nil, intValue: Int64(value), doubleValue: nil, boolValue: nil, dataValue: nil)
    }

    static func bool(_ value: Bool) -> StoredPreferenceValue {
        StoredPreferenceValue(valueType: "bool", stringValue: nil, intValue: nil, doubleValue: nil, boolValue: value ? 1 : 0, dataValue: nil)
    }

    static func double(_ value: Double) -> StoredPreferenceValue {
        StoredPreferenceValue(valueType: "double", stringValue: nil, intValue: nil, doubleValue: value, boolValue: nil, dataValue: nil)
    }

    static func data(_ value: Data) -> StoredPreferenceValue {
        StoredPreferenceValue(valueType: "data", stringValue: nil, intValue: nil, doubleValue: nil, boolValue: nil, dataValue: value)
    }
}

extension String: GRDBPreferenceValue {
    static let preferenceType = "string"

    static func decodePreference(row: Row) -> String? {
        row["string_value"]
    }

    func encodedPreference() -> StoredPreferenceValue {
        .string(self)
    }
}

extension Bool: GRDBPreferenceValue {
    static let preferenceType = "bool"

    static func decodePreference(row: Row) -> Bool? {
        guard let raw: Int = row["bool_value"] else { return nil }
        return raw != 0
    }

    func encodedPreference() -> StoredPreferenceValue {
        .bool(self)
    }
}

extension Int: GRDBPreferenceValue {
    static let preferenceType = "int"

    static func decodePreference(row: Row) -> Int? {
        if let raw: Int64 = row["int_value"] { return Int(raw) }
        return row["int_value"] as Int?
    }

    func encodedPreference() -> StoredPreferenceValue {
        .int(self)
    }
}

extension Double: GRDBPreferenceValue {
    static let preferenceType = "double"

    static func decodePreference(row: Row) -> Double? {
        row["double_value"]
    }

    func encodedPreference() -> StoredPreferenceValue {
        .double(self)
    }
}

extension Data: GRDBPreferenceValue {
    static let preferenceType = "data"

    static func decodePreference(row: Row) -> Data? {
        row["data_value"]
    }

    func encodedPreference() -> StoredPreferenceValue {
        .data(self)
    }
}

final class AppPreferenceStore: @unchecked Sendable {
    static let shared = AppPreferenceStore()

    static let didChangeNotification = Notification.Name("ApertureAppPreferenceDidChange")
    static let changedKeyUserInfoKey = "key"

    private let lock = NSLock()
    private var database: AppDatabase?

    private init() {}

    func configure(database: AppDatabase) {
        lock.withLock {
            self.database = database
        }
        do {
            try database.write { db in
                try seedDefaults(db)
                try synchronizeAppSettingsProjection(db)
            }
        } catch {
            DiagnosticsLogStore.shared.record(
                .error,
                category: "database",
                message: "GRDB preferences bootstrap failed",
                metadata: ["error": String(describing: error)]
            )
        }
    }

    func value<Value: GRDBPreferenceValue>(_ key: String, default defaultValue: Value) -> Value {
        guard let database = configuredDatabase() else { return defaultValue }
        return (try? database.read { db in
            try fetchValue(key, default: defaultValue, db: db)
        }) ?? defaultValue
    }

    func string(_ key: String, default defaultValue: String = "") -> String {
        value(key, default: defaultValue)
    }

    func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        value(key, default: defaultValue)
    }

    func int(_ key: String, default defaultValue: Int = 0) -> Int {
        value(key, default: defaultValue)
    }

    func double(_ key: String, default defaultValue: Double = 0) -> Double {
        value(key, default: defaultValue)
    }

    func data(_ key: String) -> Data? {
        guard let database = configuredDatabase() else { return nil }
        return try? database.read { db in
            try fetchOptionalValue(key, db: db)
        }
    }

    func contains(_ key: String) -> Bool {
        guard let database = configuredDatabase() else { return false }
        return (try? database.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM app_preferences WHERE key = ? LIMIT 1", arguments: [key]) != nil
        }) ?? false
    }

    func set<Value: GRDBPreferenceValue>(_ value: Value, forKey key: String) {
        guard let database = configuredDatabase() else { return }
        do {
            try database.write { db in
                try Self.upsert(value.encodedPreference(), forKey: key, db: db)
                try Self.mirrorAppSettingsPreference(key: key, stored: value.encodedPreference(), db: db)
            }
            postChange(forKey: key)
        } catch {
            DiagnosticsLogStore.shared.record(
                .error,
                category: "database",
                message: "GRDB preference write failed",
                metadata: ["key": key, "error": String(describing: error)]
            )
        }
    }

    func remove(_ key: String) {
        guard let database = configuredDatabase() else { return }
        do {
            try database.write { db in
                try db.execute(sql: "DELETE FROM app_preferences WHERE key = ?", arguments: [key])
                try Self.clearMirroredAppSettingsPreference(key: key, db: db)
            }
            postChange(forKey: key)
        } catch {
            DiagnosticsLogStore.shared.record(
                .error,
                category: "database",
                message: "GRDB preference delete failed",
                metadata: ["key": key, "error": String(describing: error)]
            )
        }
    }

    static func upsert(_ stored: StoredPreferenceValue, forKey key: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO app_preferences
            (key, value_type, string_value, int_value, double_value, bool_value, data_value, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value_type = excluded.value_type,
                string_value = excluded.string_value,
                int_value = excluded.int_value,
                double_value = excluded.double_value,
                bool_value = excluded.bool_value,
                data_value = excluded.data_value,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                key,
                stored.valueType,
                stored.stringValue,
                stored.intValue,
                stored.doubleValue,
                stored.boolValue,
                stored.dataValue,
                Date.databaseMilliseconds
            ]
        )
    }

    static func upsertAndMirror(_ stored: StoredPreferenceValue, forKey key: String, db: Database) throws {
        try upsert(stored, forKey: key, db: db)
        try mirrorAppSettingsPreference(key: key, stored: stored, db: db)
    }

    static func delete(_ key: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM app_preferences WHERE key = ?", arguments: [key])
    }

    private func configuredDatabase() -> AppDatabase? {
        lock.withLock { database }
    }

    private func fetchValue<Value: GRDBPreferenceValue>(_ key: String, default defaultValue: Value, db: Database) throws -> Value {
        try fetchOptionalValue(key, db: db) ?? defaultValue
    }

    private func fetchOptionalValue<Value: GRDBPreferenceValue>(_ key: String, db: Database) throws -> Value? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT value_type, string_value, int_value, double_value, bool_value, data_value
            FROM app_preferences
            WHERE key = ?
            """,
            arguments: [key]
        ) else { return nil }
        guard (row["value_type"] as String?) == Value.preferenceType else { return nil }
        return Value.decodePreference(row: row)
    }

    private func seedDefaults(_ db: Database) throws {
        for (key, stored) in Self.defaultPreferences {
            let exists = try Int.fetchOne(db, sql: "SELECT 1 FROM app_preferences WHERE key = ? LIMIT 1", arguments: [key]) != nil
            if !exists {
                try Self.upsert(stored, forKey: key, db: db)
            }
        }
    }

    private func synchronizeAppSettingsProjection(_ db: Database) throws {
        for (key, _) in Self.defaultPreferences {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT value_type, string_value, int_value, double_value, bool_value, data_value FROM app_preferences WHERE key = ?",
                arguments: [key]
            ) else { continue }
            let stored = StoredPreferenceValue(
                valueType: row["value_type"] as String? ?? "",
                stringValue: row["string_value"],
                intValue: row["int_value"] as Int64?,
                doubleValue: row["double_value"] as Double?,
                boolValue: row["bool_value"] as Int?,
                dataValue: row["data_value"] as Data?
            )
            try Self.mirrorAppSettingsPreference(key: key, stored: stored, db: db)
        }
    }

    private static func mirrorAppSettingsPreference(key: String, stored: StoredPreferenceValue, db: Database) throws {
        let now = Date.databaseMilliseconds
        switch key {
        case "themePreference":
            try updateSetting("theme_preference", value: stored.stringValue ?? ThemePreference.defaultRaw, now: now, db: db)
        case "languagePreference":
            try updateSetting("language_preference", value: stored.stringValue ?? LanguagePreference.systemCode, now: now, db: db)
        case PinCodePreference.pinEnabledKey:
            try updateSetting("pin_enabled", value: stored.boolValue ?? 0, now: now, db: db)
        case PinCodePreference.biometricEnabledKey:
            try updateSetting("biometric_enabled", value: stored.boolValue ?? 0, now: now, db: db)
        case PinCodePreference.requireBiometricForSendKey:
            try updateSetting("require_biometric_for_send", value: stored.boolValue ?? 1, now: now, db: db)
        case "eraseDataAfterFailedAttempts":
            try updateSetting("erase_data_after_failed_attempts", value: stored.boolValue ?? 0, now: now, db: db)
        case AutoLockPreference.storageKey:
            try updateSetting("auto_lock_seconds", value: Int(stored.intValue ?? Int64(AutoLockPreference.defaultValue)), now: now, db: db)
        case CurrencyPreference.storageKey:
            try updateSetting("currency_preference", value: stored.stringValue ?? CurrencyPreference.defaultCode, now: now, db: db)
        case HapticPreference.storageKey:
            try updateSetting("haptic_feedback_enabled", value: stored.boolValue ?? 1, now: now, db: db)
        case "backgroundBalanceRefresh":
            try updateSetting("background_balance_refresh", value: stored.boolValue ?? 1, now: now, db: db)
        case MainTab.storageKey:
            let raw = stored.stringValue ?? MainTab.wallet.rawValue
            let index = MainTab.allCases.firstIndex { $0.rawValue == raw } ?? 0
            try updateSetting("selected_tab", value: index, now: now, db: db)
        case ActiveWalletPointer.storageKey:
            let canonical = UUID(uuidString: (stored.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString ?? ""
            try updateSetting("active_wallet_id", value: canonical, now: now, db: db)
            try db.execute(
                sql: """
                INSERT INTO active_wallet (id, wallet_id, updated_at_ms)
                VALUES ('active-wallet-singleton', ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    wallet_id = excluded.wallet_id,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [canonical.isEmpty ? nil : canonical, now]
            )
        case "settingsDeepLink":
            try updateSetting("settings_deep_link", value: stored.stringValue ?? "", now: now, db: db)
        case "hasUnbackedupWallet":
            try updateSetting("has_unbackedup_wallet", value: stored.boolValue ?? 0, now: now, db: db)
        case "hideImportKeyWarning":
            try updateSetting("hide_import_key_warning", value: stored.boolValue ?? 0, now: now, db: db)
        case HideBalancesPreference.hideBalanceOnHomeKey:
            try updateSetting("hide_balance_on_home", value: stored.boolValue ?? 0, now: now, db: db)
        case HideBalancesPreference.thresholdKey:
            try updateSetting("hide_small_balances_threshold", value: stored.doubleValue ?? HideBalancesPreference.defaultThreshold, now: now, db: db)
        case TransactionAmountDisplayPreference.storageKey:
            try updateSetting("transaction_amount_display", value: stored.boolValue ?? 1, now: now, db: db)
        case "CoinMarketCapAPIKey":
            try updateSetting("coin_market_cap_api_key", value: stored.stringValue ?? "", now: now, db: db)
        case ScreenRestoration.PreferenceKey.settingsPath:
            try updateSetting("restoration_settings_path", value: stored.dataValue as Data?, now: now, db: db)
        case ScreenRestoration.PreferenceKey.walletHomePath:
            try updateSetting("restoration_wallet_home_path", value: stored.dataValue as Data?, now: now, db: db)
        default:
            break
        }
    }

    private static func clearMirroredAppSettingsPreference(key: String, db: Database) throws {
        let fallback = Self.defaultPreferences[key]
        if let fallback {
            try mirrorAppSettingsPreference(key: key, stored: fallback, db: db)
            return
        }
        if key == ActiveWalletPointer.storageKey {
            try mirrorAppSettingsPreference(key: key, stored: .string(""), db: db)
        }
    }

    private static func updateSetting(_ column: String, value: DatabaseValueConvertible?, now: Int64, db: Database) throws {
        let sql = "UPDATE app_settings SET \(column) = ?, updated_at_ms = ? WHERE id = 'app-settings-singleton'"
        try db.execute(sql: sql, arguments: StatementArguments([value, now]))
    }

    private func postChange(forKey key: String) {
        let notification = {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: nil,
                userInfo: [Self.changedKeyUserInfoKey: key]
            )
        }
        if Thread.isMainThread {
            notification()
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.didChangeNotification,
                    object: nil,
                    userInfo: [Self.changedKeyUserInfoKey: key]
                )
            }
        }
    }

    private static let defaultPreferences: [String: StoredPreferenceValue] = [
        "themePreference": .string(ThemePreference.defaultRaw),
        "languagePreference": .string(LanguagePreference.systemCode),
        PinCodePreference.pinEnabledKey: .bool(PinCodePreference.defaultValue),
        PinCodePreference.biometricEnabledKey: .bool(PinCodePreference.defaultValue),
        PinCodePreference.requireBiometricForSendKey: .bool(true),
        PinCodePreference.forgotPasscodeResetEnabledKey: .bool(false),
        PinCodePreference.forgotPasscodeResetEducationSeenKey: .bool(false),
        "eraseDataAfterFailedAttempts": .bool(false),
        AutoLockPreference.storageKey: .int(AutoLockPreference.defaultValue),
        CurrencyPreference.storageKey: .string(CurrencyPreference.defaultForCurrentRegion()),
        HapticPreference.storageKey: .bool(HapticPreference.defaultValue),
        "backgroundBalanceRefresh": .bool(true),
        MainTab.storageKey: .string(MainTab.wallet.rawValue),
        ActiveWalletPointer.storageKey: .string(""),
        "settingsDeepLink": .string(""),
        "hasUnbackedupWallet": .bool(false),
        "hideImportKeyWarning": .bool(false),
        HideBalancesPreference.hideBalanceOnHomeKey: .bool(false),
        HideBalancesPreference.thresholdKey: .double(HideBalancesPreference.defaultThreshold),
        TransactionAmountDisplayPreference.storageKey: .bool(TransactionAmountDisplayPreference.defaultValue),
        "CoinMarketCapAPIKey": .string(""),
        WalletHomeFilterPreferences.viewModeKey: .string(WalletHomeFilterPreferences.defaultViewMode.rawValue),
        WalletHomeFilterPreferences.sortKeyKey: .string(WalletHomeFilterPreferences.defaultSortKey.rawValue),
        WalletHomeFilterPreferences.sortDirectionKey: .string(WalletHomeFilterPreferences.defaultSortDirection.rawValue),
        WalletHomeFilterPreferences.onlyWithBalanceKey: .bool(WalletHomeFilterPreferences.defaultOnlyWithBalance),
        WalletHomeFilterPreferences.hiddenAssetsKey: .string(WalletHomeFilterPreferences.defaultHiddenJSON),
        WalletHomeFilterPreferences.hiddenChainsKey: .string(WalletHomeFilterPreferences.defaultHiddenJSON),
        WalletHomeFilterPreferences.assetTypeKey: .string(WalletHomeFilterPreferences.defaultAssetType.rawValue),
        WalletHomeFilterPreferences.groupByKey: .string(WalletHomeFilterPreferences.defaultGroupBy.rawValue),
        WalletHomeFilterPreferences.minFiatThresholdKey: .double(WalletHomeFilterPreferences.defaultMinFiatThreshold),
        WalletHomeFilterPreferences.selectedNetworksKey: .string(WalletHomeFilterPreferences.defaultHiddenJSON),
        WalletHomeFilterPreferences.pinnedAssetsKey: .string(WalletHomeFilterPreferences.defaultHiddenJSON),
        WalletActivityFilterPreferences.sortKeyKey: .string(WalletActivityFilterPreferences.defaultSortKey.rawValue),
        WalletActivityFilterPreferences.directionKey: .string(WalletActivityFilterPreferences.defaultDirection.rawValue),
        WalletActivityFilterPreferences.statusKey: .string(WalletActivityFilterPreferences.defaultStatus.rawValue),
        WalletActivityFilterPreferences.kindKey: .string(WalletActivityFilterPreferences.defaultKind.rawValue),
        WalletActivityFilterPreferences.assetClassKey: .string(WalletActivityFilterPreferences.defaultAssetClass.rawValue),
        WalletActivityFilterPreferences.selectedNetworksKey: .string(WalletActivityFilterPreferences.defaultSelectedJSON),
        WalletActivityFilterPreferences.selectedSymbolsKey: .string(WalletActivityFilterPreferences.defaultSelectedJSON),
        WalletActivityFilterPreferences.timeRangeKey: .string(WalletActivityFilterPreferences.defaultTimeRange.rawValue),
        WalletActivityFilterPreferences.customStartKey: .double(0),
        WalletActivityFilterPreferences.customEndKey: .double(0),
        WalletActivityFilterPreferences.minFiatKey: .string(""),
        WalletActivityFilterPreferences.maxFiatKey: .string(""),
        AssetDetailFilterPreferences.sortKeyKey: .string(AssetDetailFilterPreferences.defaultSortKey.rawValue),
        AssetDetailFilterPreferences.directionKey: .string(AssetDetailFilterPreferences.defaultDirection.rawValue),
        AssetDetailFilterPreferences.selectedNetworksKey: .string(AssetDetailFilterPreferences.defaultSelectedNetworksJSON),
        AssetDetailFilterPreferences.timeRangeKey: .string(AssetDetailFilterPreferences.defaultTimeRange.rawValue),
        AssetDetailFilterPreferences.hideZeroNetworksKey: .bool(AssetDetailFilterPreferences.defaultHideZeroNetworks),
        AllSupportedFilterPreferences.sortKeyKey: .string(AllSupportedFilterPreferences.defaultSortKey.rawValue),
        AllSupportedFilterPreferences.assetTypeKey: .string(AllSupportedFilterPreferences.defaultAssetType.rawValue),
        AllSupportedFilterPreferences.selectedNetworksKey: .string(AllSupportedFilterPreferences.defaultSelectedNetworksJSON),
        AllSupportedFilterPreferences.onlyWithBalanceKey: .bool(AllSupportedFilterPreferences.defaultOnlyWithBalance),
        "pendingWalletCompletionNotice": .string(""),
        WalletFirstRefreshPresentationCenter.walletIdKey: .string(""),
        WalletFirstRefreshPresentationCenter.startedAtKey: .double(0),
        WalletFirstRefreshPresentationCenter.completionDismissedAtKey: .double(0),
        WalletFirstRefreshPresentationCenter.kindKey: .string(""),
        ScreenRestoration.PreferenceKey.settingsPath: .data(Data()),
        ScreenRestoration.PreferenceKey.walletHomePath: .data(Data())
    ]

}

final class WalletPreferenceStore: @unchecked Sendable {
    static let shared = WalletPreferenceStore()

    private init() {}

    func value<Value: GRDBPreferenceValue>(
        _ key: String,
        walletID: UUID,
        default defaultValue: Value,
        database: AppDatabase = .shared
    ) -> Value {
        (try? database.read { db in
            try fetchValue(key, walletID: walletID, default: defaultValue, db: db)
        }) ?? defaultValue
    }

    func set<Value: GRDBPreferenceValue>(
        _ value: Value,
        forKey key: String,
        walletID: UUID,
        database: AppDatabase = .shared
    ) {
        do {
            try database.write { db in
                try Self.upsert(value.encodedPreference(), forKey: key, walletID: walletID, db: db)
            }
        } catch {
            DiagnosticsLogStore.shared.record(
                .error,
                category: "database",
                message: "GRDB wallet preference write failed",
                metadata: ["walletId": walletID.uuidString, "key": key, "error": String(describing: error)]
            )
        }
    }

    static func upsert(_ stored: StoredPreferenceValue, forKey key: String, walletID: UUID, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO wallet_preferences
            (wallet_id, key, value_type, string_value, int_value, double_value, bool_value, data_value, updated_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(wallet_id, key) DO UPDATE SET
                value_type = excluded.value_type,
                string_value = excluded.string_value,
                int_value = excluded.int_value,
                double_value = excluded.double_value,
                bool_value = excluded.bool_value,
                data_value = excluded.data_value,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                walletID.uuidString,
                key,
                stored.valueType,
                stored.stringValue,
                stored.intValue,
                stored.doubleValue,
                stored.boolValue,
                stored.dataValue,
                Date.databaseMilliseconds
            ]
        )
    }

    private func fetchValue<Value: GRDBPreferenceValue>(
        _ key: String,
        walletID: UUID,
        default defaultValue: Value,
        db: Database
    ) throws -> Value {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT value_type, string_value, int_value, double_value, bool_value, data_value
            FROM wallet_preferences
            WHERE wallet_id = ? AND key = ?
            """,
            arguments: [walletID.uuidString, key]
        ) else { return defaultValue }
        guard (row["value_type"] as String?) == Value.preferenceType else { return defaultValue }
        return Value.decodePreference(row: row) ?? defaultValue
    }
}

@MainActor
@propertyWrapper
struct GRDBStorage<Value: GRDBPreferenceValue>: DynamicProperty {
    @StateObject private var model: GRDBStorageModel<Value>

    init(wrappedValue defaultValue: Value, _ key: String) {
        _model = StateObject(wrappedValue: GRDBStorageModel(key: key, defaultValue: defaultValue))
    }

    var wrappedValue: Value {
        get { model.value }
        nonmutating set { model.set(newValue) }
    }

    var projectedValue: Binding<Value> {
        Binding(
            get: { model.value },
            set: { model.set($0) }
        )
    }
}

@MainActor
private final class GRDBStorageModel<Value: GRDBPreferenceValue>: ObservableObject {
    @Published private(set) var value: Value

    private let key: String
    private let defaultValue: Value
    private var cancellable: AnyCancellable?

    init(key: String, defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
        value = AppPreferenceStore.shared.value(key, default: defaultValue)
        cancellable = NotificationCenter.default.publisher(for: AppPreferenceStore.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard notification.userInfo?[AppPreferenceStore.changedKeyUserInfoKey] as? String == self.key else { return }
                self.reload()
            }
    }

    func set(_ newValue: Value) {
        if value != newValue {
            value = newValue
        }
        AppPreferenceStore.shared.set(newValue, forKey: key)
    }

    private func reload() {
        let next = AppPreferenceStore.shared.value(key, default: defaultValue)
        if next != value {
            value = next
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
