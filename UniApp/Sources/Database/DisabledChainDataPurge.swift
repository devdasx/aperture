import Foundation

enum DisabledChainDataPurge {
    static func runIfNeeded(database: AppDatabase = .shared) async {
        _ = database
    }
}
