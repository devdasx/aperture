import Foundation
import SwiftData

/// Keeps the authoritative `AppSettingsRecord` (the settings row in the
/// database) continuously in sync with the legacy `@AppStorage` keys
/// (Rule #27 §D — settings live in the store).
///
/// **Design for safety.** Several preferences (`languagePreference`,
/// `activeWalletId`, `themePreference`, the lock keys) are read by the
/// deeply-woven env / navigation / RTL / lock plumbing through
/// `@AppStorage`'s zero-cost reactivity (Rules #11/#12/#17) — across
/// ~30 files. Rewiring those to read SwiftData would be a launch- and
/// security-critical change. So instead: the DB row is the authoritative
/// settings copy, and `@AppStorage` stays as the synchronized reactive
/// mirror those readers consume — UNTOUCHED, zero blast radius. One
/// `UserDefaults.didChange` observer keeps the DB row equal to
/// `@AppStorage` live (any toggle the user flips reflects into the DB
/// immediately), so a surface reading the DB record (e.g. the
/// background-refresh gate) sees current values. No-op-skip on save, so
/// the frequent `didChange` notification never churns `@Query`.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private var container: ModelContainer?
    private var observer: NSObjectProtocol?

    private init() {}

    /// Begin syncing. Seeds the record from current `@AppStorage` and
    /// installs the live observer. Idempotent — safe to call once at
    /// launch from `ApertureDatabase.bootstrap()`.
    func start(container: ModelContainer) {
        self.container = container
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

    /// Fetch-or-create the singleton settings row.
    static func fetchOrCreate(in context: ModelContext) -> AppSettingsRecord {
        // Capture the id in a local — `#Predicate` can't resolve a static
        // member reference (it mis-parses it as a key path on the type).
        let targetId = AppSettingsRecord.singletonId
        var descriptor = FetchDescriptor<AppSettingsRecord>(
            predicate: #Predicate { $0.id == targetId }
        )
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first { return existing }
        let record = AppSettingsRecord()
        context.insert(record)
        return record
    }

    /// Copy current `@AppStorage` values into the singleton record, using
    /// each key's true default for an absent key (the `@AppStorage`
    /// default-not-in-UserDefaults gotcha). Only saves when something
    /// changed.
    func syncFromAppStorage() {
        guard let container else { return }
        let d = UserDefaults.standard
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }

        let theme = str("themePreference", ThemePreference.defaultRaw)
        let lang = str("languagePreference", LanguagePreference.systemCode)
        let pin = bool("pinEnabled", false)
        let bio = bool("biometricEnabled", false)
        let autoLock = int("autoLockSeconds", 0)
        let currency = str("currencyPreference", CurrencyPreference.defaultCode)
        let haptics = bool("hapticFeedbackEnabled", true)
        let bgRefresh = bool("backgroundBalanceRefresh", true)
        let chartRange = str("walletHomeBalanceHistoryRange", BalanceHistoryRange.all.rawValue)
        let testMode = bool("isTestMode", false)
        let tab = int("selectedTab", 0)
        let activeWallet = str("activeWalletId", "")
        let deepLink = str("settingsDeepLink", "")
        let unbacked = bool("hasUnbackedupWallet", false)
        let hideImport = bool("hideImportKeyWarning", false)

        let context = ModelContext(container)
        let r = Self.fetchOrCreate(in: context)
        let changed = r.themePreference != theme
            || r.languagePreference != lang
            || r.pinEnabled != pin
            || r.biometricEnabled != bio
            || r.autoLockSeconds != autoLock
            || r.currencyPreference != currency
            || r.hapticFeedbackEnabled != haptics
            || r.backgroundBalanceRefresh != bgRefresh
            || r.walletHomeBalanceHistoryRange != chartRange
            || r.isTestMode != testMode
            || r.selectedTab != tab
            || r.activeWalletId != activeWallet
            || r.settingsDeepLink != deepLink
            || r.hasUnbackedupWallet != unbacked
            || r.hideImportKeyWarning != hideImport
        guard changed else { return }

        r.themePreference = theme
        r.languagePreference = lang
        r.pinEnabled = pin
        r.biometricEnabled = bio
        r.autoLockSeconds = autoLock
        r.currencyPreference = currency
        r.hapticFeedbackEnabled = haptics
        r.backgroundBalanceRefresh = bgRefresh
        r.walletHomeBalanceHistoryRange = chartRange
        r.isTestMode = testMode
        r.selectedTab = tab
        r.activeWalletId = activeWallet
        r.settingsDeepLink = deepLink
        r.hasUnbackedupWallet = unbacked
        r.hideImportKeyWarning = hideImport
        r.updatedAt = Date()
        try? context.save()
    }
}
