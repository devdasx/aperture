import Foundation
import CloudKit
import OSLog

/// Stores and retrieves the **encrypted** wallet-backup blob in the user's
/// private CloudKit database (2026-06-19 backup handoff; CloudKit chosen
/// 2026-06-19). The blob is already end-to-end encrypted by
/// `WalletBackupCrypto` before it gets here — CloudKit only ever sees
/// ciphertext + non-secret metadata, and the private database is the user's
/// own iCloud, readable by no one else (not Apple, not Aperture).
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
            return try Self.decode(record)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - List (restore picker)

    /// All of the user's wallet backups, newest first. Decodes only the
    /// clear envelope (no password needed) so the restore screen can list
    /// them before the user enters a password.
    func list() async throws -> [WalletBackupBlob] {
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
            if case .notFound = mapped { return } // already gone — idempotent
            throw mapped
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
