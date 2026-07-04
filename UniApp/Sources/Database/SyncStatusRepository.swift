import Foundation
import GRDB

final class SyncStatusRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func markSyncing(domain: SyncDomain, scopeId: String) throws {
        try upsert(domain: domain, scopeId: scopeId, synced: false, syncing: true, error: nil)
    }

    func markSynced(domain: SyncDomain, scopeId: String) throws {
        try upsert(domain: domain, scopeId: scopeId, synced: true, syncing: false, error: nil)
    }

    func markFailed(domain: SyncDomain, scopeId: String, error: String) throws {
        try upsert(domain: domain, scopeId: scopeId, synced: false, syncing: false, error: String(error.prefix(200)))
    }

    private func upsert(domain: SyncDomain, scopeId: String, synced: Bool, syncing: Bool, error: String?) throws {
        let now = Date.databaseMilliseconds
        let key = SyncStatusRecord.makeKey(domain: domain, scopeId: scopeId)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_statuses
                (key, domain_raw, scope_id, last_synced_at_ms, last_attempt_at_ms,
                 is_syncing, last_error_message, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    last_synced_at_ms = COALESCE(excluded.last_synced_at_ms, sync_statuses.last_synced_at_ms),
                    last_attempt_at_ms = excluded.last_attempt_at_ms,
                    is_syncing = excluded.is_syncing,
                    last_error_message = excluded.last_error_message,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    key,
                    domain.rawValue,
                    scopeId,
                    synced ? now : nil,
                    now,
                    syncing,
                    error,
                    now
                ]
            )
        }
    }
}
