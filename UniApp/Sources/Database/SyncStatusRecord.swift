import Foundation
import SwiftData

/// The freshness ledger — the spine of Rule #27 (local-first). One row
/// per `(domain, scope)` records when the sync layer last successfully
/// wrote that domain's data into the store, whether a sync is in
/// flight, and the last error if any.
///
/// The UI reads this via `@Query` to render an honest "Updated 14:31 ·
/// Syncing…" stamp (Rule #16 §B): a value served from the database is
/// only as trustworthy as its age, so the age is shown. The sync layer
/// (`WalletRefreshCoordinator` / `SyncCoordinator`) is the only writer.
///
/// **Additive, migration-safe.** A brand-new entity with a `.unique`
/// key and otherwise defaulted/optional columns — SwiftData registers
/// it via lightweight migration without touching existing rows.
@Model
final class SyncStatusRecord {

    /// Stable identity: `"<domain>|<scope>"` — e.g. `"balances|<walletUUID>"`,
    /// `"prices|global"`. Unique so each domain/scope has exactly one row
    /// the sync layer upserts.
    @Attribute(.unique) var key: String

    /// `SyncDomain.rawValue` — which kind of data this row tracks.
    var domainRaw: String

    /// Scope the sync covered: a wallet's UUID string, or `"global"` for
    /// app-wide domains (prices, FX, historical closes).
    var scopeId: String

    /// Last SUCCESSFUL sync. `nil` = this domain/scope has never synced
    /// (a fresh wallet before its first refresh). The freshness stamp
    /// reads this.
    var lastSyncedAt: Date?

    /// Last attempt, success or failure — distinguishes "never tried"
    /// from "tried and failed" for honest offline messaging.
    var lastAttemptAt: Date?

    /// `true` while a sync for this domain/scope is in flight, so the UI
    /// can show "Syncing…" instead of a stale stamp.
    var isSyncing: Bool

    /// Human-readable last error (redacted, no secrets) when the most
    /// recent attempt failed; `nil` after a success. Surfaces the honest
    /// offline / failure state.
    var lastErrorMessage: String?

    /// Row bookkeeping.
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

    /// Compose the unique key from a domain + scope.
    static func makeKey(domain: SyncDomain, scopeId: String) -> String {
        "\(domain.rawValue)|\(scopeId)"
    }
}

/// The domains the sync layer keeps fresh in the store. Each maps to a
/// writer in `WalletRefreshCoordinator` / `SyncCoordinator`.
enum SyncDomain: String, Sendable, CaseIterable {
    /// Native + token balances (`TokenBalanceRecord`). Wallet-scoped.
    case balances
    /// Transaction history (`TransactionRecord`). Wallet-scoped.
    case transactions
    /// Spot prices / fiat values (`CachedPriceRecord`). Global-scoped.
    case prices
    /// Daily-close history (`HistoricalPriceRecord`). Global-scoped.
    case historical
    /// Per-wallet portfolio-value chart points
    /// (`WalletChartSnapshotRecord`). Wallet-scoped.
    case chart

    /// Conventional scope id for app-wide (non-wallet) domains.
    static let globalScope = "global"
}
