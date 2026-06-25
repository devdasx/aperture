import Foundation
import CloudKit
import OSLog

/// Stores and retrieves the **encrypted** wallet-backup blob in the user's
/// private CloudKit database (2026-06-19 backup handoff; CloudKit chosen
/// 2026-06-19). The blob is already end-to-end encrypted by
/// `WalletBackupCrypto` before it gets here — CloudKit only ever sees
/// ciphertext + non-secret metadata in the user's private iCloud database.
/// Apple operates CloudKit; the recovery phrase remains protected by
/// app-side encryption before upload.
///
/// **Capability (one-time, owner step).** This requires the **iCloud →
/// CloudKit** capability on the app target, container
/// `iCloud.com.aperture.wallet`, enabled in Xcode signing for team
/// C5T44SZNQX. The container + record type auto-create in the Development
/// environment on first save; deploy the schema to Production before
/// shipping. Without the capability every call fails with a real,
/// surfaced error (never a silent success).
///
/// One record per wallet, `recordName == walletId`, so re-backing-up a
/// wallet cleanly overwrites its prior blob rather than duplicating it.
struct CloudKitBackupStore: Sendable {
    static let containerIdentifier = "iCloud.com.aperture.wallet"
    static let recordType = "WalletBackup"
    private static let blobKey = "blob"
    private static let versionKey = "version"

    // A single, fixed-recordID "index" record listing every backed-up wallet
    // id. Restore reads THIS by recordID (no `CKQuery`), so it never needs a
    // server-side Queryable index on `recordName` — the gotcha that made
    // `list()`'s query fail with CloudKit 12 even though backups existed.
    // Auto-created on first save (Development auto-schema); maintained
    // best-effort so a backup never fails because an index write did.
    private static let indexRecordType = "WalletBackupIndex"
    private static let indexRecordName = "wallet-backup-index"
    private static let indexIdsKey = "walletIds"

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "backup-cloudkit")

    /// Human-surfaceable failure. Every case maps to a real CloudKit / account
    /// condition so the UI can show an honest message + Retry (handoff:
    /// "surface the true error string … never a silent success").
    enum StoreError: Error, Equatable, Sendable {
        case iCloudUnavailable      // no account / restricted / could-not-determine
        case notSignedIn            // signed out of iCloud
        case networkUnavailable
        case quotaExceeded
        case notFound
        case cloudKit(code: Int, message: String)
        case unknown(String)

        var isRetryable: Bool {
            switch self {
            case .networkUnavailable, .cloudKit, .unknown: return true
            case .iCloudUnavailable, .notSignedIn, .quotaExceeded, .notFound: return false
            }
        }
    }

    private var database: CKDatabase {
        CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
    }

    private var indexRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.indexRecordName)
    }

    // MARK: - Account

    /// Whether the device has a usable iCloud account. Call before the
    /// password screen so we can route to a "Sign in to iCloud" state
    /// instead of failing mid-upload.
    func ensureAccountAvailable() async throws {
        let status: CKAccountStatus
        do {
            status = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
        } catch {
            throw Self.map(error)
        }
        switch status {
        case .available: return
        case .noAccount: throw StoreError.notSignedIn
        case .restricted, .couldNotDetermine, .temporarilyUnavailable: throw StoreError.iCloudUnavailable
        @unknown default: throw StoreError.iCloudUnavailable
        }
    }

    // MARK: - Save (with real upload progress)

    /// Upload the encrypted blob, overwriting any prior backup for the same
    /// wallet. `onProgress` reports real per-record upload fraction (0…1)
    /// so the UI ring reflects actual bytes, not a timer.
    func save(_ blob: WalletBackupBlob, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let recordID = CKRecord.ID(recordName: blob.walletId.uuidString)
        // Reuse the existing record (with its change tag) when present so the
        // overwrite never conflicts; otherwise create a fresh one.
        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        }
        do {
            record[Self.blobKey] = try blob.encoded() as NSData
            record[Self.versionKey] = blob.version as NSNumber
        } catch {
            throw StoreError.unknown("Could not encode the backup.")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .allKeys
            op.qualityOfService = .userInitiated
            if let onProgress {
                op.perRecordProgressBlock = { _, fraction in onProgress(fraction) }
            }
            op.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    onProgress?(1.0)
                    cont.resume()
                case .failure(let error):
                    cont.resume(throwing: Self.map(error))
                }
            }
            database.add(op)
        }
        // Backup is safely uploaded — now record it in the query-free index
        // (best-effort: never let an index hiccup undo a successful backup).
        await addToIndex(blob.walletId)
    }

    // MARK: - Verify / fetch

    /// Re-fetch the just-saved blob from the server (handoff: the success
    /// seal appears ONLY after a real verify fetch). Throws `.notFound`
    /// if the server doesn't have it.
    func verify(walletId: UUID) async throws -> WalletBackupBlob {
        try await fetch(walletId: walletId)
    }

    func fetch(walletId: UUID) async throws -> WalletBackupBlob {
        let recordID = CKRecord.ID(recordName: walletId.uuidString)
        do {
            let record = try await database.record(for: recordID)
            let blob = try Self.decode(record)
            // Self-heal: any confirmed backup gets listed in the index, so a
            // backup made BEFORE the index existed becomes restorable the next
            // time the app checks its status (e.g. opening the wallet detail) —
            // no re-backup, no Console step. Cheap: a no-op once it's listed.
            await addToIndex(walletId)
            return blob
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - List (restore picker)

    /// All of the user's wallet backups, newest first. Decodes only the
    /// clear envelope (no password needed) so the restore screen can list
    /// them before the user enters a password.
    ///
    /// **Query-free.** Reads the fixed-recordID index, then fetches each
    /// listed backup by recordID — no `CKQuery`, so no server-side Queryable
    /// index on `recordName` is required. Only if the index record doesn't
    /// exist yet (a brand-new install that never wrote one) does it fall back
    /// to a query.
    func list() async throws -> [WalletBackupBlob] {
        if let indexed = try await listFromIndex(), !indexed.isEmpty {
            return indexed
        }
        return try await listViaQuery()
    }

    /// Read the index record by recordID and fetch each listed backup. Returns
    /// `nil` when there is no index record yet (→ caller tries the query),
    /// `[]` when the index exists but every listed backup is gone.
    private func listFromIndex() async throws -> [WalletBackupBlob]? {
        guard let index = try? await database.record(for: indexRecordID) else {
            return nil // no index record yet
        }
        let ids = (index[Self.indexIdsKey] as? [String]) ?? []
        guard !ids.isEmpty else { return [] }
        var blobs: [WalletBackupBlob] = []
        for idString in ids {
            let recordID = CKRecord.ID(recordName: idString)
            if let record = try? await database.record(for: recordID),
               let blob = try? Self.decode(record) {
                blobs.append(blob)
            }
        }
        return blobs.sorted { $0.createdAt > $1.createdAt }
    }

    /// Legacy fallback: enumerate via `CKQuery` (needs a Queryable index on
    /// `recordName` in the CloudKit schema). Only reached when no index record
    /// exists yet; the index path is the norm.
    private func listViaQuery() async throws -> [WalletBackupBlob] {
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        do {
            let (matchResults, _) = try await database.records(matching: query)
            var blobs: [WalletBackupBlob] = []
            for (_, result) in matchResults {
                if case .success(let record) = result, let blob = try? Self.decode(record) {
                    blobs.append(blob)
                }
            }
            return blobs.sorted { $0.createdAt > $1.createdAt }
        } catch {
            let mapped = Self.map(error)
            // An empty private DB before the record type exists reports as a
            // CloudKit "unknown item" — treat that as simply no backups yet.
            if case .cloudKit(let code, _) = mapped, code == CKError.unknownItem.rawValue {
                return []
            }
            throw mapped
        }
    }

    // MARK: - Delete

    func delete(walletId: UUID) async throws {
        let recordID = CKRecord.ID(recordName: walletId.uuidString)
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch {
            let mapped = Self.map(error)
            if case .notFound = mapped {
                await removeFromIndex(walletId) // keep the index honest
                return // already gone — idempotent
            }
            throw mapped
        }
        await removeFromIndex(walletId)
    }

    // MARK: - Reconcile (auto-heal the index for pre-index backups)

    /// Best-effort: ensure every locally-present wallet that actually has an
    /// iCloud backup is listed in the query-free index. This is what makes a
    /// backup created BEFORE the index existed restorable with NO Console step
    /// and NO manual re-backup — the moment any device running this build sees
    /// the wallet, the CloudKit-side index record is populated, and it persists
    /// in iCloud for a later fresh-install restore. Runs silently; per-wallet
    /// failures (no backup for that wallet, offline) are ignored.
    func reconcileIndex(walletIds: [UUID]) async {
        for id in walletIds {
            // `fetch` self-heals the index on success (addToIndex); a wallet
            // with no backup simply throws and is skipped.
            _ = try? await fetch(walletId: id)
        }
    }

    // MARK: - Index maintenance (query-free restore)

    /// Best-effort: ensure `walletId` appears in the index record. NEVER
    /// throws — a backup (or a status fetch) must succeed even if the index
    /// write fails. A no-op once the id is already listed.
    private func addToIndex(_ walletId: UUID) async {
        let key = walletId.uuidString
        do {
            let record: CKRecord
            if let existing = try? await database.record(for: indexRecordID) {
                record = existing
            } else {
                record = CKRecord(recordType: Self.indexRecordType, recordID: indexRecordID)
            }
            var ids = (record[Self.indexIdsKey] as? [String]) ?? []
            guard !ids.contains(key) else { return } // already listed — no write
            ids.append(key)
            record[Self.indexIdsKey] = ids as NSArray
            _ = try await database.save(record)
        } catch {
            Self.log.error("Backup index add failed (non-fatal): \(String(describing: error), privacy: .public)")
        }
    }

    /// Best-effort: drop `walletId` from the index record. Never throws.
    private func removeFromIndex(_ walletId: UUID) async {
        let key = walletId.uuidString
        do {
            guard let record = try? await database.record(for: indexRecordID) else { return }
            var ids = (record[Self.indexIdsKey] as? [String]) ?? []
            guard ids.contains(key) else { return }
            ids.removeAll { $0 == key }
            record[Self.indexIdsKey] = ids as NSArray
            _ = try await database.save(record)
        } catch {
            Self.log.error("Backup index remove failed (non-fatal): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Decode

    private static func decode(_ record: CKRecord) throws -> WalletBackupBlob {
        guard let data = record[blobKey] as? Data else {
            throw StoreError.unknown("Backup record is missing its data.")
        }
        return try WalletBackupBlob.decode(data)
    }

    // MARK: - Error mapping

    private static func map(_ error: Error) -> StoreError {
        guard let ck = error as? CKError else {
            return .unknown(error.localizedDescription)
        }
        switch ck.code {
        case .notAuthenticated:
            return .notSignedIn
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return .networkUnavailable
        case .quotaExceeded:
            return .quotaExceeded
        case .unknownItem:
            return .notFound
        case .accountTemporarilyUnavailable:
            return .iCloudUnavailable
        default:
            log.error("CloudKit error code=\(ck.errorCode) \(ck.localizedDescription, privacy: .public)")
            return .cloudKit(code: ck.errorCode, message: ck.localizedDescription)
        }
    }
}
