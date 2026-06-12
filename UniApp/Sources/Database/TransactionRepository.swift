import Foundation
import SwiftData

/// Background-safe mutation surface for `TransactionRecord` and
/// `TokenBalanceRecord`. Used by the future balance/history scanners
/// (T-037..T-040) to upsert per-address ledger state without blocking
/// the main actor.
///
/// Per `CLAUDE.md` Rule #2 §C (actor-isolated repositories).
@ModelActor
actor TransactionRepository {

    // MARK: - Legacy addressId backfill

    /// One-time (per actor instance) backfill of the stored `addressId`
    /// primitive on rows written before the column existed — they
    /// decode it as `nil` and are reachable only through the optional
    /// `address` relationship. Running the backfill once up front lets
    /// every upsert predicate stay on the primitive column:
    /// `#Predicate` traversal of the optional relationship can degrade
    /// to an in-memory full scan, and paying a fallback fetch on EVERY
    /// brand-new insert (the common case during a history scan) was
    /// wasted work on stores with no legacy rows.
    private var didBackfillLegacyAddressIds = false

    private func ensureLegacyAddressIdBackfill() throws {
        guard !didBackfillLegacyAddressIds else { return }
        didBackfillLegacyAddressIds = true

        let txDescriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == nil }
        )
        for row in try modelContext.fetch(txDescriptor) {
            row.addressId = row.address?.id
        }

        let balDescriptor = FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == nil }
        )
        for row in try modelContext.fetch(balDescriptor) {
            row.addressId = row.address?.id
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    // MARK: - Transactions

    /// Upsert a transaction leg by `(txHash, addressId, tokenContract,
    /// tokenSymbol, direction)`. One on-chain transaction routinely
    /// produces SEVERAL ledger legs for the same address under the same
    /// hash — a swap is an outgoing leg in one asset AND an incoming leg
    /// in another (`EVMTransactionAdapter` returns the native txlist
    /// entry plus every tokentx entry for the same hash) — so the asset
    /// and direction are part of the row identity. Matching on
    /// `(txHash, addressId)` alone would collapse the legs into
    /// whichever arrived first and freeze its amount forever. If a row
    /// with the same leg identity exists, its status / block / fee are
    /// updated in place; otherwise a new row is inserted. Idempotent —
    /// safe to call from a scanner that polls. (Several same-direction
    /// transfers of the same token inside one tx still collapse to one
    /// row — distinguishing those needs a per-leg log index the
    /// adapters don't surface yet.)
    ///
    /// **Taxonomy (2026-06-13).** `kind` persists the transaction
    /// taxonomy (`TransactionKind`). When the caller passes `nil` —
    /// every adapter today; swap/bridge classification is T-067 — the
    /// kind derives from the direction: `.internal` → `.selfTransfer`,
    /// everything else → `.transfer`. An explicit non-nil `kind`
    /// overwrites an existing row's stored value (a later, smarter
    /// scan may reclassify a `.transfer` as `.swap`); legacy rows
    /// whose `kindRaw` is `nil` are backfilled on touch.
    func upsertTransaction(
        addressId: UUID,
        txHash: String,
        direction: TransactionDirection,
        amountRaw: String,
        tokenSymbol: String,
        tokenContract: String? = nil,
        kind: TransactionKind? = nil,
        blockNumber: Int64?,
        occurredAt: Date,
        status: TransactionStatus,
        counterparty: String,
        feeRaw: String?
    ) throws {
        try ensureLegacyAddressIdBackfill()

        var addrDescriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.id == addressId }
        )
        addrDescriptor.fetchLimit = 1
        guard let address = try modelContext.fetch(addrDescriptor).first else { return }

        // Predicate on the stored `addressId` primitive — the legacy
        // backfill above guarantees every reachable row has it set, so
        // no relationship-traversal fallback is needed. The full leg
        // identity (hash + address + asset + direction) keeps distinct
        // legs of one transaction as distinct rows.
        let directionValue = direction.rawValue
        var txDescriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate {
                $0.txHash == txHash
                    && $0.addressId == addressId
                    && $0.tokenContract == tokenContract
                    && $0.tokenSymbol == tokenSymbol
                    && $0.directionRaw == directionValue
            }
        )
        txDescriptor.fetchLimit = 1
        let existing = try modelContext.fetch(txDescriptor).first

        let resolvedKind = kind ?? TransactionKind.defaultKind(for: direction)

        if let existing {
            existing.statusRaw = status.rawValue
            existing.blockNumber = blockNumber
            existing.feeRaw = feeRaw
            // Taxonomy: an explicit kind from the caller reclassifies;
            // a nil-kind touch only backfills rows that pre-date the
            // column (never downgrades an adapter's classification to
            // the direction-derived default).
            if let kind {
                existing.kindRaw = kind.rawValue
            } else if existing.kindRaw == nil {
                existing.kindRaw = resolvedKind.rawValue
            }
            // Don't touch direction / amount / counterparty / occurredAt —
            // those are immutable once a tx is on-chain.
        } else {
            let record = TransactionRecord(
                txHash: txHash,
                direction: direction,
                amountRaw: amountRaw,
                tokenSymbol: tokenSymbol,
                tokenContract: tokenContract,
                blockNumber: blockNumber,
                occurredAt: occurredAt,
                status: status,
                counterparty: counterparty,
                feeRaw: feeRaw
            )
            record.kindRaw = resolvedKind.rawValue
            record.address = address
            record.addressId = addressId
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // MARK: - Transaction queries (2026-06-13 taxonomy surface)

    /// One transaction leg flattened to a Sendable value for
    /// cross-actor reads — `@Model` instances must not cross the
    /// actor boundary.
    struct TransactionSnapshot: Sendable {
        let id: UUID
        let addressId: UUID
        let txHash: String
        let direction: TransactionDirection
        let kind: TransactionKind
        let status: TransactionStatus
        let amountRaw: String
        let tokenSymbol: String
        let tokenContract: String?
        let blockNumber: Int64?
        let occurredAt: Date
        let counterparty: String
        let feeRaw: String?
    }

    /// Query one wallet's transaction legs, newest first, with
    /// optional taxonomy filters. The three axes compose:
    ///
    /// - sending      → `direction: .outgoing`
    /// - receiving    → `direction: .incoming`
    /// - failed       → `status: .failed`
    /// - swap / bridge / self-transfer → `kind:`
    ///
    /// Status and direction filter in the store predicate (plain raw
    /// string equality). The `kind` filter resolves in memory via
    /// `TransactionKind.effectiveKind` because legacy rows persist
    /// `kindRaw == nil` whose effective kind depends on the direction
    /// column — a cross-column rule a store predicate can't express
    /// without force-unwrap gymnastics. Wallet histories are bounded
    /// (~25 legs per chain per scan), so the in-memory pass is cheap.
    ///
    /// `limit` caps the RESULT (applied after filtering); `0` = all.
    func transactions(
        walletId: UUID,
        kind: TransactionKind? = nil,
        status: TransactionStatus? = nil,
        direction: TransactionDirection? = nil,
        limit: Int = 0
    ) throws -> [TransactionSnapshot] {
        try ensureLegacyAddressIdBackfill()

        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        guard let wallet = try modelContext.fetch(walletDescriptor).first else { return [] }
        let addressIds = wallet.addresses.map { $0.id }

        // Optional status/direction filters run IN MEMORY after the
        // indexed addressId fetch — `#Predicate` cannot compare the
        // non-optional `row.statusRaw` against an optional capture
        // (the macro expansion fails to unwrap it), and the per-address
        // row count is bounded by the scanner's 1,000-tx cap, so the
        // in-memory pass is cheap. The `kind` filter below already
        // works the same way.
        let statusRaw: String? = status?.rawValue
        let directionRaw: String? = direction?.rawValue

        // One indexed fetch per address (≤ chain count) on the stored
        // `addressId` primitive. Avoids the optional-relationship
        // traversal AND collection-contains-on-optional predicate
        // shapes.
        var rows: [TransactionRecord] = []
        for addressId in addressIds {
            let descriptor = FetchDescriptor<TransactionRecord>(
                predicate: #Predicate { row in
                    row.addressId == addressId
                }
            )
            var fetched = try modelContext.fetch(descriptor)
            if let statusRaw {
                fetched = fetched.filter { $0.statusRaw == statusRaw }
            }
            if let directionRaw {
                fetched = fetched.filter { $0.directionRaw == directionRaw }
            }
            rows.append(contentsOf: fetched)
        }

        var snapshots = rows.compactMap { row -> TransactionSnapshot? in
            guard let rowAddressId = row.addressId else { return nil }
            let effectiveKind = TransactionKind.effectiveKind(
                kindRaw: row.kindRaw,
                directionRaw: row.directionRaw
            )
            if let kind, effectiveKind != kind { return nil }
            return TransactionSnapshot(
                id: row.id,
                addressId: rowAddressId,
                txHash: row.txHash,
                direction: TransactionDirection(rawValue: row.directionRaw) ?? .incoming,
                kind: effectiveKind,
                status: TransactionStatus(rawValue: row.statusRaw) ?? .pending,
                amountRaw: row.amountRaw,
                tokenSymbol: row.tokenSymbol,
                tokenContract: row.tokenContract,
                blockNumber: row.blockNumber,
                occurredAt: row.occurredAt,
                counterparty: row.counterparty,
                feeRaw: row.feeRaw
            )
        }
        snapshots.sort { $0.occurredAt > $1.occurredAt }
        if limit > 0 && snapshots.count > limit {
            snapshots.removeLast(snapshots.count - limit)
        }
        return snapshots
    }

    /// Convenience: one wallet's failed legs, newest first.
    func failedTransactions(walletId: UUID, limit: Int = 0) throws -> [TransactionSnapshot] {
        try transactions(walletId: walletId, status: .failed, limit: limit)
    }

    /// Delete all transactions for a given address. Used when a watch-only
    /// wallet is re-derived or when a user explicitly clears history from
    /// a future Settings → Wallet row. The predicate matches both the
    /// stored `addressId` primitive (fast path) and the relationship
    /// traversal so pre-column legacy rows (nil `addressId`) are still
    /// cleared.
    func clearTransactions(for addressId: UUID) throws {
        let descriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId || $0.address?.id == addressId }
        )
        let rows = try modelContext.fetch(descriptor)
        for row in rows { modelContext.delete(row) }
        try modelContext.save()
    }

    // MARK: - Balances

    /// Upsert a token balance by `(addressId, tokenSymbol, tokenContract)`.
    /// `nil` contract distinguishes the native coin from same-named
    /// tokens (e.g. native ETH vs WETH on Ethereum).
    func upsertBalance(
        addressId: UUID,
        tokenSymbol: String,
        tokenContract: String?,
        decimals: Int,
        rawBalance: String,
        fiatValueCached: Decimal,
        fiatCurrencyCode: String
    ) throws {
        try ensureLegacyAddressIdBackfill()

        var addrDescriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.id == addressId }
        )
        addrDescriptor.fetchLimit = 1
        guard let address = try modelContext.fetch(addrDescriptor).first else { return }

        // Predicate on the stored `addressId` primitive — traversing
        // the optional `address` relationship in `#Predicate` can
        // degrade to an in-memory full scan, and this runs dozens of
        // times per refresh. Legacy rows (pre-column) were backfilled
        // above.
        var balDescriptor = FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId
                && $0.tokenSymbol == tokenSymbol
                && $0.tokenContract == tokenContract }
        )
        balDescriptor.fetchLimit = 1

        let now = Date()
        if let existing = try modelContext.fetch(balDescriptor).first {
            existing.decimals = decimals
            existing.rawBalance = rawBalance
            existing.fiatValueCached = fiatValueCached
            existing.fiatCurrencyCode = fiatCurrencyCode
            existing.updatedAt = now
        } else {
            let record = TokenBalanceRecord(
                tokenSymbol: tokenSymbol,
                tokenContract: tokenContract,
                decimals: decimals,
                rawBalance: rawBalance,
                fiatValueCached: fiatValueCached,
                fiatCurrencyCode: fiatCurrencyCode,
                updatedAt: now
            )
            record.address = address
            record.addressId = addressId
            modelContext.insert(record)
        }

        // Touch the address's last-scanned marker so the UI can show a
        // "last synced" footer accurately.
        address.lastScannedAt = now

        try modelContext.save()
    }

    /// Mark a scan-attempted address as "fresh" — the scan succeeded but
    /// returned zero balances (no tokens held). Updates `lastScannedAt`
    /// without inserting balance rows.
    func markScanComplete(addressId: UUID, isUsed: Bool) throws {
        var descriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.id == addressId }
        )
        descriptor.fetchLimit = 1
        guard let address = try modelContext.fetch(descriptor).first else { return }
        address.isUsed = isUsed
        address.lastScannedAt = Date()
        try modelContext.save()
    }
}
