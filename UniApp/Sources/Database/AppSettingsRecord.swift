import Foundation

final class AppSettingsRecord: Identifiable {
    var id: String
    var themePreference: String
    var languagePreference: String
    var pinEnabled: Bool
    var biometricEnabled: Bool
    var autoLockSeconds: Int
    var currencyPreference: String
    var hapticFeedbackEnabled: Bool
    var backgroundBalanceRefresh: Bool
    var selectedTab: Int
    var activeWalletId: String
    var settingsDeepLink: String
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
        self.selectedTab = selectedTab
        self.activeWalletId = activeWalletId
        self.settingsDeepLink = settingsDeepLink
        self.hasUnbackedupWallet = hasUnbackedupWallet
        self.hideImportKeyWarning = hideImportKeyWarning
        self.updatedAt = updatedAt
    }
}

final class ActiveWalletRecord: Identifiable {
    var id: String
    var walletID: UUID?
    var updatedAt: Date

    static let singletonId = "active-wallet-singleton"

    init(id: String = ActiveWalletRecord.singletonId, walletID: UUID? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.walletID = walletID
        self.updatedAt = updatedAt
    }
}
