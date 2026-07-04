import Foundation
import Testing
@testable import Aperture

@Suite struct GRDBFreshWipeTests {
    @Test("one-time GRDB transition wipe removes old SQLite files and wallet session defaults while preserving display preferences")
    func transitionWipeDeletesLegacyStoreAndKeepsDisplayPreferences() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-fresh-wipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("aperture.sqlite", isDirectory: false)
        let files = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-journal"),
            URL(fileURLWithPath: storeURL.path + "-SwiftDataMetadata")
        ]
        for file in files {
            FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3]))
        }

        let suite = "aperture.freshwipe.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let wipeKey = "aperture.grdb.test.freshWipeCompleted"
        defaults.set("dark", forKey: "themePreference")
        defaults.set("vi", forKey: "languagePreference")
        defaults.set("EUR", forKey: CurrencyPreference.storageKey)
        defaults.set(false, forKey: HapticPreference.storageKey)
        defaults.set(false, forKey: "backgroundBalanceRefresh")
        defaults.set(BalanceHistoryRange.month.rawValue, forKey: "walletHomeBalanceHistoryRange")
        defaults.set(UUID().uuidString, forKey: ActiveWalletPointer.storageKey)
        defaults.set(true, forKey: "pinEnabled")
        defaults.set(true, forKey: "biometricEnabled")
        defaults.set("wallets", forKey: "settingsDeepLink")
        defaults.set("session-token", forKey: "onboardingSession")

        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            defaults: defaults,
            transitionWipeKey: wipeKey
        )

        for file in files {
            #expect(!FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) survived fresh wipe")
        }
        #expect(defaults.bool(forKey: wipeKey))
        #expect(defaults.string(forKey: "themePreference") == "dark")
        #expect(defaults.string(forKey: "languagePreference") == "vi")
        #expect(defaults.string(forKey: CurrencyPreference.storageKey) == "EUR")
        #expect(defaults.object(forKey: HapticPreference.storageKey) as? Bool == false)
        #expect(defaults.object(forKey: "backgroundBalanceRefresh") as? Bool == false)
        #expect(defaults.string(forKey: "walletHomeBalanceHistoryRange") == BalanceHistoryRange.month.rawValue)
        #expect(defaults.string(forKey: ActiveWalletPointer.storageKey) == nil)
        #expect(defaults.object(forKey: "pinEnabled") == nil)
        #expect(defaults.object(forKey: "biometricEnabled") == nil)
        #expect(defaults.object(forKey: "settingsDeepLink") == nil)
        #expect(defaults.object(forKey: "onboardingSession") == nil)

        FileManager.default.createFile(atPath: storeURL.path, contents: Data([4, 5, 6]))
        try AppDatabase.runFreshGRDBTransitionWipeForTesting(
            storeURL: storeURL,
            defaults: defaults,
            transitionWipeKey: wipeKey
        )
        #expect(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
