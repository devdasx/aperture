import Foundation
import GRDB

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private var database: AppDatabase?
    private var observer: NSObjectProtocol?

    private init() {}

    func start(database: AppDatabase) {
        self.database = database
        syncFromAppStorage()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFromAppStorage() }
        }
    }

    func syncFromAppStorage() {
        guard let database else { return }
        let defaults = UserDefaults.standard
        func str(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }

        let activeWalletRaw = str("activeWalletId", "")
        let canonicalActive = UUID(uuidString: activeWalletRaw.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString ?? ""
        let now = Date.databaseMilliseconds
        try? database.write { db in
            try db.execute(
                sql: """
                INSERT INTO app_settings
                (id, theme_preference, language_preference, pin_enabled, biometric_enabled,
                 auto_lock_seconds, currency_preference, haptic_feedback_enabled,
                 background_balance_refresh, wallet_home_balance_history_range,
                 selected_tab, active_wallet_id, settings_deep_link,
                 has_unbackedup_wallet, hide_import_key_warning, updated_at_ms)
                VALUES ('app-settings-singleton', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    theme_preference = excluded.theme_preference,
                    language_preference = excluded.language_preference,
                    pin_enabled = excluded.pin_enabled,
                    biometric_enabled = excluded.biometric_enabled,
                    auto_lock_seconds = excluded.auto_lock_seconds,
                    currency_preference = excluded.currency_preference,
                    haptic_feedback_enabled = excluded.haptic_feedback_enabled,
                    background_balance_refresh = excluded.background_balance_refresh,
                    wallet_home_balance_history_range = excluded.wallet_home_balance_history_range,
                    selected_tab = excluded.selected_tab,
                    active_wallet_id = excluded.active_wallet_id,
                    settings_deep_link = excluded.settings_deep_link,
                    has_unbackedup_wallet = excluded.has_unbackedup_wallet,
                    hide_import_key_warning = excluded.hide_import_key_warning,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    str("themePreference", ThemePreference.defaultRaw),
                    str("languagePreference", LanguagePreference.systemCode),
                    bool("pinEnabled", false),
                    bool("biometricEnabled", false),
                    int("autoLockSeconds", 0),
                    str(CurrencyPreference.storageKey, CurrencyPreference.defaultCode),
                    bool(HapticPreference.storageKey, true),
                    bool("backgroundBalanceRefresh", true),
                    str("walletHomeBalanceHistoryRange", BalanceHistoryRange.all.rawValue),
                    int("selectedTab", 0),
                    canonicalActive,
                    str("settingsDeepLink", ""),
                    bool("hasUnbackedupWallet", false),
                    bool("hideImportKeyWarning", false),
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO active_wallet (id, wallet_id, updated_at_ms)
                VALUES ('active-wallet-singleton', ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    wallet_id = excluded.wallet_id,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [canonicalActive.isEmpty ? nil : canonicalActive, now]
            )
        }
    }
}
