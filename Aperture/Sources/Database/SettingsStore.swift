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

    /// Re-bind after a wipe without re-seeding preferences (avoids nested GRDB writes).
    func rebind(database: AppDatabase) {
        self.database = database
        AppPreferenceStore.shared.bindDatabase(database)
    }

    func synchronizePreferences() {
        guard let database else {
            AppPreferenceStore.shared.configure(database: .shared)
            return
        }
        AppPreferenceStore.shared.configure(database: database)
    }
}
