import Foundation

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private var database: AppDatabase?

    private init() {}

    func start(database: AppDatabase) {
        self.database = database
        AppPreferenceStore.shared.configure(database: database)
    }

    func synchronizePreferences() {
        guard let database else {
            AppPreferenceStore.shared.configure(database: .shared)
            return
        }
        AppPreferenceStore.shared.configure(database: database)
    }
}
