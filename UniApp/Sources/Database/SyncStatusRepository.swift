import Foundation
import SwiftData

/// Background-safe writer for the freshness ledger (`SyncStatusRecord`).
/// The sync layer (`WalletRefreshCoordinator` / `SyncCoordinator`) calls
/// these to stamp when each domain last synced, is syncing, or failed —
/// the data the UI's honest "Updated · Syncing…" footer reads via
/// `@Query` (Rule #27 §B).
///
/// Per Rule #2 §C — actor-isolated repository on its own `ModelContext`.
/// All writes are no-op-skipped when nothing changed so the 10 s poll
/// doesn't churn `@Query` (mirrors `TransactionRepository`).
@ModelActor
actor SyncStatusRepository {

    /// Whether stamps actually persist. Defaults to `true` (so the
    /// repository's own tests exercise the real write path), but the
    /// production caller — `WalletRefreshCoordinator` — flips it to `false`
    /// via `disableLedger()`.
    ///
    /// **Why disable in production (2026-06-18 lag fix).** Nothing reads
    /// `SyncStatusRecord`: the "Updated · Syncing…" footer that consumed it
    /// via `@Query` was removed per user direction, and the failure surface
    /// reads `WalletRefreshState`. Yet every refresh stamped this ledger ~8
    /// times, and each stamp is a `modelContext.save()` → main-context merge —
    /// pure work (and `@Query` churn) for a table no screen observes. Disabling
    /// the writes removes those saves; re-enable by not calling
    /// `disableLedger()` if a freshness UI ever returns.
    private var ledgerEnabled = true

    /// Stop persisting stamps (production — the ledger has no reader).
    func disableLedger() { ledgerEnabled = false }

    /// Mark a domain/scope as actively syncing. Sets `lastAttemptAt`
    /// and clears any stale error so the UI shows "Syncing…".
    func markSyncing(domain: SyncDomain, scopeId: String) throws {
        try update(domain: domain, scopeId: scopeId) { row, now in
            guard !row.isSyncing || row.lastErrorMessage != nil else { return false }
            row.isSyncing = true
            row.lastAttemptAt = now
            row.lastErrorMessage = nil
            return true
        }
    }

    /// Mark a domain/scope synced successfully — stamps `lastSyncedAt`
    /// (the value the freshness footer shows) and clears syncing/error.
    func markSynced(domain: SyncDomain, scopeId: String) throws {
        try update(domain: domain, scopeId: scopeId) { row, now in
            row.lastSyncedAt = now
            row.lastAttemptAt = now
            row.isSyncing = false
            row.lastErrorMessage = nil
            return true
        }
    }

    /// Mark a domain/scope's most recent attempt as failed. Preserves
    /// `lastSyncedAt` (the last KNOWN-good time stays honest) and records
    /// a redacted error string for the offline/failure surface.
    func markFailed(domain: SyncDomain, scopeId: String, error: String) throws {
        let redacted = String(error.prefix(200))
        try update(domain: domain, scopeId: scopeId) { row, now in
            row.isSyncing = false
            row.lastAttemptAt = now
            row.lastErrorMessage = redacted
            return true
        }
    }

    // MARK: - Upsert core

    /// Fetch-or-create the row for `(domain, scope)` and apply `mutate`.
    /// `mutate` returns `false` to signal a no-op (skip the save), so a
    /// steady-state poll that changes nothing writes nothing — no
    /// `@Query` churn (the idle-lag discipline from `TransactionRepository`).
    private func update(
        domain: SyncDomain,
        scopeId: String,
        _ mutate: (SyncStatusRecord, Date) -> Bool
    ) throws {
        // No reader in production → skip the save (and its @Query churn).
        // See `ledgerEnabled`. Tests leave it enabled to verify the writes.
        guard ledgerEnabled else { return }
        let key = SyncStatusRecord.makeKey(domain: domain, scopeId: scopeId)
        var descriptor = FetchDescriptor<SyncStatusRecord>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        let now = Date()

        if let existing = try modelContext.fetch(descriptor).first {
            guard mutate(existing, now) else { return }
            existing.updatedAt = now
        } else {
            let record = SyncStatusRecord(
                key: key,
                domainRaw: domain.rawValue,
                scopeId: scopeId
            )
            _ = mutate(record, now)
            record.updatedAt = now
            modelContext.insert(record)
        }
        try modelContext.save()
    }
}
