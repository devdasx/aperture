import Foundation
import SwiftData

/// The local-first settings store (Rule #27 §D). A single row holding
/// every user preference, so settings live in the database alongside the
/// rest of the app's state.
///
/// **Why `@AppStorage` still exists alongside it.** Several preferences
/// (`languagePreference` — 17 files, `activeWalletId` — 18 files,
/// `themePreference`, the lock keys) are read directly by the deeply-
/// woven env / navigation / RTL / lock plumbing via `@AppStorage`'s
/// zero-cost reactivity (Rules #11, #12, #17). Ripping that out is a
/// launch- and security-critical rewrite. Instead `SettingsStore` keeps
/// this record and `@AppStorage` **perfectly in sync**: the DB is the
/// authoritative copy, `@AppStorage` is the synchronized reactive mirror
/// those readers consume. New / safe reads go straight to the DB.
///
/// Singleton: exactly one row, fetched-or-created by `SettingsStore`.
/// Brand-new entity → additive lightweight migration.
@Model
final class AppSettingsRecord {
    /// Pins the singleton — always `AppSettingsRecord.singletonId`.
    @Attribute(.unique) var id: String

    // Appearance / locale (mirrored to @AppStorage for the env plumbing).
    var themePreference: String
    var languagePreference: String

    // Security (mirrored; read by the lock plumbing via @AppStorage).
    var pinEnabled: Bool
    var biometricEnabled: Bool
    var autoLockSeconds: Int

    // Functional preferences.
    var currencyPreference: String
    var hapticFeedbackEnabled: Bool
    var backgroundBalanceRefresh: Bool
    var walletHomeBalanceHistoryRange: String
    var isTestMode: Bool

    // Navigation / session.
    var selectedTab: Int
    var activeWalletId: String
    var settingsDeepLink: String

    // Onboarding / one-shot flags.
    var hasUnbackedupWallet: Bool
    var hideImportKeyWarning: Bool

    var updatedAt: Date

    static let singletonId = "app-settings-singleton"

    init(
        id: String = AppSettingsRecord.singletonId,
        themePreference: String = "",
        languagePreference: String = "",
        pinEnabled: Bool = false,
        biometricEnabled: Bool = false,
        autoLockSeconds: Int = 0,
        currencyPreference: String = "",
        hapticFeedbackEnabled: Bool = true,
        backgroundBalanceRefresh: Bool = true,
        walletHomeBalanceHistoryRange: String = "",
        isTestMode: Bool = false,
        selectedTab: Int = 0,
        activeWalletId: String = "",
        settingsDeepLink: String = "",
        hasUnbackedupWallet: Bool = false,
        hideImportKeyWarning: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.themePreference = themePreference
        self.languagePreference = languagePreference
        self.pinEnabled = pinEnabled
        self.biometricEnabled = biometricEnabled
        self.autoLockSeconds = autoLockSeconds
        self.currencyPreference = currencyPreference
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.backgroundBalanceRefresh = backgroundBalanceRefresh
        self.walletHomeBalanceHistoryRange = walletHomeBalanceHistoryRange
        self.isTestMode = isTestMode
        self.selectedTab = selectedTab
        self.activeWalletId = activeWalletId
        self.settingsDeepLink = settingsDeepLink
        self.hasUnbackedupWallet = hasUnbackedupWallet
        self.hideImportKeyWarning = hideImportKeyWarning
        self.updatedAt = updatedAt
    }
}
