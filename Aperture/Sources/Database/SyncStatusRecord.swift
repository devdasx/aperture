import Foundation

final class SyncStatusRecord: Identifiable, Hashable {
    var id: String { key }
    var key: String
    var domainRaw: String
    var scopeId: String
    var lastSyncedAt: Date?
    var lastAttemptAt: Date?
    var isSyncing: Bool
    var lastErrorMessage: String?
    var updatedAt: Date

    init(
        key: String,
        domainRaw: String,
        scopeId: String,
        lastSyncedAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        isSyncing: Bool = false,
        lastErrorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.domainRaw = domainRaw
        self.scopeId = scopeId
        self.lastSyncedAt = lastSyncedAt
        self.lastAttemptAt = lastAttemptAt
        self.isSyncing = isSyncing
        self.lastErrorMessage = lastErrorMessage
        self.updatedAt = updatedAt
    }

    static func == (lhs: SyncStatusRecord, rhs: SyncStatusRecord) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }

    static func makeKey(domain: SyncDomain, scopeId: String) -> String {
        "\(domain.rawValue)|\(scopeId)"
    }
}

enum SyncDomain: String, Sendable, CaseIterable {
    case balances
    case transactions
    case prices
    case historical
    case chart

    static let globalScope = "global"
}
