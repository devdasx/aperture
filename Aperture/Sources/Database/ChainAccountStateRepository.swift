import Foundation
import GRDB

/// Persisted per-address account fields required for spendable / MAX math
/// (P0-004 / P0-005). Scanners write after live RPC; Send compose reads
/// from GRDB (local-first).
///
/// Money fields are **base-unit integer strings** (drops, stroops, yocto,
/// plancks, lamports) so they never lose precision to Double.
struct ChainAccountStateSnapshot: Sendable, Hashable, Equatable {
    var ownerCount: Int
    var subentryCount: Int
    var numSponsoring: Int
    var numSponsored: Int
    /// Stellar selling liabilities on native, **base units** (stroops string).
    var sellingLiabilitiesRaw: String
    /// Polkadot frozen balance, **base units**.
    var frozenRaw: String
    /// Polkadot reserved balance, **base units**.
    var reservedRaw: String
    /// NEAR storage_usage (bytes).
    var storageUsageBytes: Int
    /// NEAR locked stake, **base units** (yocto).
    var lockedRaw: String
    /// Free/spendable native when distinct from total (DOT free), **base units**.
    /// Empty means “use token_balances.raw_balance as free”.
    var freeRaw: String

    static let empty = ChainAccountStateSnapshot(
        ownerCount: 0,
        subentryCount: 0,
        numSponsoring: 0,
        numSponsored: 0,
        sellingLiabilitiesRaw: "0",
        frozenRaw: "0",
        reservedRaw: "0",
        storageUsageBytes: 0,
        lockedRaw: "0",
        freeRaw: ""
    )

    /// Map into compose `SendAmountMath.AccountState` (display units).
    func toComposeAccountState(
        nativeBalanceDisplay: Decimal,
        decimals: Int
    ) -> SendAmountMath.AccountState {
        var state = SendAmountMath.AccountState()
        state.balance = nativeBalanceDisplay
        state.ownerCount = max(0, ownerCount)
        state.subentryCount = max(0, subentryCount)
        state.numSponsoring = max(0, numSponsoring)
        state.numSponsored = max(0, numSponsored)
        state.sellingLiabilities = display(fromBase: sellingLiabilitiesRaw, decimals: decimals)
        state.frozen = display(fromBase: frozenRaw, decimals: decimals)
        state.reserved = display(fromBase: reservedRaw, decimals: decimals)
        state.storageUsageBytes = max(0, storageUsageBytes)
        state.locked = display(fromBase: lockedRaw, decimals: decimals)
        return state
    }

    private func display(fromBase raw: String, decimals: Int) -> Decimal {
        guard let base = Decimal(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              base > 0 else { return 0 }
        return ComposeDecimal.toDisplay(base, decimals: decimals)
    }
}

final class ChainAccountStateRepository {
    private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    func upsert(
        addressId: UUID,
        chain: SupportedChain,
        state: ChainAccountStateSnapshot
    ) throws {
        let now = Date.databaseMilliseconds
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO chain_account_states (
                    address_id, chain_raw,
                    owner_count, subentry_count, num_sponsoring, num_sponsored,
                    selling_liabilities_raw, frozen_raw, reserved_raw,
                    storage_usage_bytes, locked_raw, free_raw, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(address_id) DO UPDATE SET
                    chain_raw = excluded.chain_raw,
                    owner_count = excluded.owner_count,
                    subentry_count = excluded.subentry_count,
                    num_sponsoring = excluded.num_sponsoring,
                    num_sponsored = excluded.num_sponsored,
                    selling_liabilities_raw = excluded.selling_liabilities_raw,
                    frozen_raw = excluded.frozen_raw,
                    reserved_raw = excluded.reserved_raw,
                    storage_usage_bytes = excluded.storage_usage_bytes,
                    locked_raw = excluded.locked_raw,
                    free_raw = excluded.free_raw,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    addressId.uuidString,
                    chain.rawValue,
                    state.ownerCount,
                    state.subentryCount,
                    state.numSponsoring,
                    state.numSponsored,
                    state.sellingLiabilitiesRaw,
                    state.frozenRaw,
                    state.reservedRaw,
                    state.storageUsageBytes,
                    state.lockedRaw,
                    state.freeRaw,
                    now,
                ]
            )
        }
    }

    func load(addressId: UUID) throws -> ChainAccountStateSnapshot? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT owner_count, subentry_count, num_sponsoring, num_sponsored,
                       selling_liabilities_raw, frozen_raw, reserved_raw,
                       storage_usage_bytes, locked_raw, free_raw
                FROM chain_account_states
                WHERE address_id = ?
                LIMIT 1
                """,
                arguments: [addressId.uuidString]
            ) else { return nil }

            return ChainAccountStateSnapshot(
                ownerCount: row["owner_count"] as Int? ?? 0,
                subentryCount: row["subentry_count"] as Int? ?? 0,
                numSponsoring: row["num_sponsoring"] as Int? ?? 0,
                numSponsored: row["num_sponsored"] as Int? ?? 0,
                sellingLiabilitiesRaw: row["selling_liabilities_raw"] as String? ?? "0",
                frozenRaw: row["frozen_raw"] as String? ?? "0",
                reservedRaw: row["reserved_raw"] as String? ?? "0",
                storageUsageBytes: row["storage_usage_bytes"] as Int? ?? 0,
                lockedRaw: row["locked_raw"] as String? ?? "0",
                freeRaw: row["free_raw"] as String? ?? ""
            )
        }
    }

    /// Load state for `(wallet, chain)`.
    ///
    /// **M-001:** Prefer the send-from address when it has a row; if that
    /// exact address has no `chain_account_states` row yet, fall back to
    /// any address on the chain that does (preferred first). EVM address
    /// match is case-insensitive. Returns `nil` only when **no** scanner
    /// has written account-state for this wallet+chain (compose then uses
    /// empty defaults + static reserve copy — never invents OwnerCount).
    func load(
        walletId: UUID,
        chain: SupportedChain,
        preferredAddress: String?
    ) throws -> ChainAccountStateSnapshot? {
        try database.read { db in
            if let preferredAddress, !preferredAddress.isEmpty {
                if let exact = try fetchSnapshot(
                    db: db,
                    walletId: walletId,
                    chain: chain,
                    preferredAddress: preferredAddress,
                    caseInsensitive: chain.family == .evm
                ) {
                    return exact
                }
            }
            // Fall back: any address on this chain with a state row.
            return try fetchSnapshot(
                db: db,
                walletId: walletId,
                chain: chain,
                preferredAddress: nil,
                caseInsensitive: false
            )
        }
    }

    private func fetchSnapshot(
        db: Database,
        walletId: UUID,
        chain: SupportedChain,
        preferredAddress: String?,
        caseInsensitive: Bool
    ) throws -> ChainAccountStateSnapshot? {
        var sql = """
        SELECT s.owner_count, s.subentry_count, s.num_sponsoring, s.num_sponsored,
               s.selling_liabilities_raw, s.frozen_raw, s.reserved_raw,
               s.storage_usage_bytes, s.locked_raw, s.free_raw
        FROM chain_account_states s
        JOIN wallet_addresses a ON a.id = s.address_id
        WHERE a.wallet_id = ? AND a.chain_raw = ?
        """
        var args: [any DatabaseValueConvertible] = [walletId.uuidString, chain.rawValue]
        if let preferredAddress, !preferredAddress.isEmpty {
            if caseInsensitive {
                sql += " AND LOWER(a.address) = LOWER(?)"
            } else {
                sql += " AND a.address = ?"
            }
            args.append(preferredAddress)
        }
        sql += """
         ORDER BY a.is_receive_preferred DESC
         LIMIT 1
        """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: StatementArguments(args)) else {
            return nil
        }
        return ChainAccountStateSnapshot(
            ownerCount: row["owner_count"] as Int? ?? 0,
            subentryCount: row["subentry_count"] as Int? ?? 0,
            numSponsoring: row["num_sponsoring"] as Int? ?? 0,
            numSponsored: row["num_sponsored"] as Int? ?? 0,
            sellingLiabilitiesRaw: row["selling_liabilities_raw"] as String? ?? "0",
            frozenRaw: row["frozen_raw"] as String? ?? "0",
            reservedRaw: row["reserved_raw"] as String? ?? "0",
            storageUsageBytes: row["storage_usage_bytes"] as Int? ?? 0,
            lockedRaw: row["locked_raw"] as String? ?? "0",
            freeRaw: row["free_raw"] as String? ?? ""
        )
    }
}

extension AppDatabase {
    nonisolated static let chainAccountStatesSQL = """
    CREATE TABLE IF NOT EXISTS chain_account_states (
        address_id TEXT PRIMARY KEY REFERENCES wallet_addresses(id) ON DELETE CASCADE,
        chain_raw TEXT NOT NULL,
        owner_count INTEGER NOT NULL DEFAULT 0,
        subentry_count INTEGER NOT NULL DEFAULT 0,
        num_sponsoring INTEGER NOT NULL DEFAULT 0,
        num_sponsored INTEGER NOT NULL DEFAULT 0,
        selling_liabilities_raw TEXT NOT NULL DEFAULT '0',
        frozen_raw TEXT NOT NULL DEFAULT '0',
        reserved_raw TEXT NOT NULL DEFAULT '0',
        storage_usage_bytes INTEGER NOT NULL DEFAULT 0,
        locked_raw TEXT NOT NULL DEFAULT '0',
        free_raw TEXT NOT NULL DEFAULT '',
        updated_at_ms INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_chain_account_states_chain
        ON chain_account_states(chain_raw);
    """
}
