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
    /// hash — a contract interaction can be an outgoing leg in one asset
    /// AND an incoming leg in another (`EVMTransactionAdapter` returns the
    /// native txlist entry plus every tokentx entry for the same hash) — so
    /// the asset
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
    /// **Taxonomy (2026-06-13).** `kind` persists the transaction taxonomy
    /// (`TransactionKind`). When the caller passes `nil` — every chain adapter
    /// — `classifyKind` derives it from direction: a `.internal` leg →
    /// `.selfTransfer`, everything else → `.transfer`. An explicit non-nil
    /// `kind` overwrites the stored value; a nil-kind re-scan backfills a
    /// `nil` row only.
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
        feeRaw: String?,
        id: UUID = UUID(),
        save: Bool = true
    ) throws {
        try ensureLegacyAddressIdBackfill()

        var addrDescriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.id == addressId }
        )
        addrDescriptor.fetchLimit = 1
        guard let address = try modelContext.fetch(addrDescriptor).first else { return }

        // **EVM contract-casing normalization (2026-06-15).** EVM token
        // contracts arrive checksummed from one path (the send executor /
        // AssetCatalog) and lowercase from another (the history scanner's
        // log decoding). If the pending row and the confirmed row carry
        // different casing for the same contract they never match → a
        // duplicate / stuck-pending row. Normalize EVM contracts to
        // lowercase at this single identity boundary (both the match
        // predicate AND the stored value) so both writers share one
        // identity. Non-EVM contracts (case-sensitive on their chains)
        // are left verbatim.
        let isEVM = SupportedChain(rawValue: address.chainRaw)?.family == .evm
        let normalizedContract = isEVM ? tokenContract?.lowercased() : tokenContract

        // **Self-transfer reclassification (2026-06-16, Rule #24).** A
        // genuine self-transfer is classified `.internal` for BOTH legs by
        // the scanner (the spend AND the receive). But `directionRaw` is
        // part of the leg identity (a contract call can be `.outgoing` in asset A +
        // `.incoming` in asset B for the same hash) — so a row written by
        // the PRE-2026-06-12 code as `.outgoing`/`.incoming` for a
        // self-send has a DIFFERENT identity than the now-correct
        // `.internal` event, and a naive upsert would insert a duplicate
        // `.internal` row while the stale row lingered (exactly the
        // user's BTC repro: one stored `.outgoing` leg + one `.internal`
        // leg, same hash `d258f57fba…`). For a SINGLE asset at a SINGLE
        // address in a SINGLE tx there is only ever ONE correct direction,
        // so when the incoming classification is `.internal` we first
        // relabel any same-asset, same-(hash,address) row that is NOT yet
        // `.internal` — in place — instead of inserting a second row. This
        // overwrites the stale `directionRaw` (the existing-record
        // correction the user requires) and clears its counterparty.
        if direction == .internal {
            let internalRaw = TransactionDirection.internal.rawValue
            let staleDescriptor = FetchDescriptor<TransactionRecord>(
                predicate: #Predicate {
                    $0.txHash == txHash
                        && $0.addressId == addressId
                        && $0.tokenContract == normalizedContract
                        && $0.tokenSymbol == tokenSymbol
                        && $0.directionRaw != internalRaw
                }
            )
            for stale in try modelContext.fetch(staleDescriptor) {
                // Relabel the stale leg fully to the now-correct
                // self-transfer shape: direction, the corrected amount the
                // scanner just computed (the stale `.outgoing` leg carried
                // a different amount — the user saw −0.00145708 vs the
                // correct 0.00145755), an empty counterparty, the
                // self-transfer kind, and the fee. After this, the stale
                // row IS the canonical `.internal` row; the exact-identity
                // fetch below finds it and the dedupe guard removes any
                // second one.
                stale.directionRaw = internalRaw
                stale.amountRaw = amountRaw
                stale.counterparty = ""
                stale.kindRaw = TransactionKind.selfTransfer.rawValue
                stale.feeRaw = feeRaw
            }
        }

        // Predicate on the stored `addressId` primitive — the legacy
        // backfill above guarantees every reachable row has it set, so
        // no relationship-traversal fallback is needed. The full leg
        // identity (hash + address + asset + direction) keeps distinct
        // legs of one transaction as distinct rows.
        let directionValue = direction.rawValue
        let txDescriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate {
                $0.txHash == txHash
                    && $0.addressId == addressId
                    && $0.tokenContract == normalizedContract
                    && $0.tokenSymbol == tokenSymbol
                    && $0.directionRaw == directionValue
            }
        )
        // Fetch ALL matching legs (not just the first): the self-transfer
        // relabel above can collapse two stale rows (a `.outgoing` + an
        // `.incoming` of the same self-send) onto the same `.internal`
        // identity. Keep the first as the canonical row; delete the rest
        // so no duplicate `.internal` leg lingers (2026-06-16).
        let matches = try modelContext.fetch(txDescriptor)
        let existing = matches.first
        if matches.count > 1 {
            for duplicate in matches.dropFirst() {
                modelContext.delete(duplicate)
            }
        }

        // When the adapter doesn't supply a kind, fall back to the
        // direction-derived default (`.selfTransfer` / `.transfer`).
        let resolvedKind = kind ?? Self.classifyKind(direction: direction)

        if let existing {
            // **2026-06-13 — skip no-op writes.** The 10s poll re-finds
            // the same confirmed transactions every cycle. Re-assigning
            // identical values still dirties the row → `@Query` churn →
            // UI re-render every 10s. Mutate only when status / block /
            // fee / kind actually changed (a pending tx confirming, a
            // backfill). Everything else is immutable once on-chain.
            // The kind this upsert settles on for the existing row: an
            // explicit caller kind reclassifies; a nil-kind touch backfills a
            // pre-column row; otherwise the stored kind is kept.
            let targetKindRaw: String? = {
                if let kind { return kind.rawValue }
                if existing.kindRaw == nil { return resolvedKind.rawValue }
                return existing.kindRaw
            }()
            let kindWouldChange = existing.kindRaw != targetKindRaw
            let unchanged = existing.statusRaw == status.rawValue
                && existing.blockNumber == blockNumber
                && existing.feeRaw == feeRaw
                && !kindWouldChange
            // Early-out only when this row is unchanged AND the
            // self-transfer relabel/dedupe above didn't already dirty the
            // context. Returning early after a relabel would drop those
            // pending mutations on a `save: true` caller (2026-06-16).
            if unchanged, !modelContext.hasChanges { return }
            if unchanged, modelContext.hasChanges {
                if save { try modelContext.save() }
                return
            }
            existing.statusRaw = status.rawValue
            existing.blockNumber = blockNumber
            existing.feeRaw = feeRaw
            // Taxonomy: settle on the kind computed above (an explicit caller
            // kind, or a nil-row backfill — never a downgrade).
            existing.kindRaw = targetKindRaw
            // Don't touch direction / amount / counterparty / occurredAt —
            // those are immutable once a tx is on-chain.
        } else {
            let record = TransactionRecord(
                id: id,
                txHash: txHash,
                direction: direction,
                amountRaw: amountRaw,
                tokenSymbol: tokenSymbol,
                tokenContract: normalizedContract,
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
        // Batched-write support (2026-06-14): the refresh pipeline passes
        // `save: false` and flushes ONCE at the end, so a pull-to-refresh
        // writing dozens of rows fires ONE main-context merge / @Query
        // invalidation instead of dozens (the per-record save storm that
        // froze the UI). Default `true` keeps every other caller's
        // save-per-call semantics unchanged.
        if save { try modelContext.save() }
    }

    /// Resolve a leg's `TransactionKind` when the adapter didn't supply one:
    /// the direction-derived default (`.internal` → `.selfTransfer`, else
    /// `.transfer`).
    ///
    /// 2026-06-23 — the counterparty-based swap/bridge router classifier was
    /// removed with the swap feature, so a transfer is never relabelled to
    /// `.swap` / `.bridge` anymore.
    static func classifyKind(
        direction: TransactionDirection
    ) -> TransactionKind {
        TransactionKind.defaultKind(for: direction)
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
    /// - bridge / self-transfer → `kind:`
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
    ///
    /// **`fiatValueCached` is `Decimal?` — `nil` means "price unknown
    /// right now", NOT "zero".** The scanner streams balance-first /
    /// price-second: the first yield for every row carries `fiat: nil`
    /// (so the balance renders the instant it lands), and a second,
    /// corrective yield carries the real fiat once the shared price
    /// batch resolves. That batch can be CANCELLED mid-flight (a
    /// pull-to-refresh / wallet-switch / scene-phase change tears down
    /// the scan stream, which cancels the price task) — so the second
    /// yield doesn't always arrive. Writing `0` on the `nil` yield used
    /// to stomp a perfectly good last-known price down to "Price
    /// unavailable" and leave it there until some later, fully-
    /// completing batch happened to re-resolve that exact symbol (the
    /// 2026-06-13 BTC/ETH bug: majors flickered to "Price unavailable"
    /// while stablecoins kept their price). The contract now: **a `nil`
    /// fiat NEVER overwrites an existing known-good price** — the row
    /// keeps the last price we have (Rule #16 honesty + the user's
    /// explicit "use the old price in the database" direction) until a
    /// real new quote arrives. A genuine zero balance still arrives as
    /// a NON-nil `0` (balance 0 × a known unit price), so it writes
    /// honestly; only "price unknown" is preserved.
    func upsertBalance(
        addressId: UUID,
        tokenSymbol: String,
        tokenContract: String?,
        decimals: Int,
        rawBalance: String,
        fiatValueCached: Decimal?,
        fiatCurrencyCode: String,
        save: Bool = true
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
            // Preserve the last-known price when the incoming fiat is
            // `nil` ("price unknown right now" — see the doc comment).
            // Only a non-nil quote updates `fiatValueCached` /
            // `fiatCurrencyCode`; a nil yield keeps whatever the row
            // already holds, so a cancelled/partial price batch can
            // never blank a good price to "Price unavailable".
            let resolvedFiat = fiatValueCached ?? existing.fiatValueCached
            let resolvedCurrency = fiatValueCached != nil ? fiatCurrencyCode : existing.fiatCurrencyCode

            // **2026-06-13 — skip no-op writes.** The app-level 10s
            // poll re-scans every token on every chain. If a token's
            // balance hasn't changed, re-assigning the same values still
            // marks the SwiftData object dirty → fires a `@Query`
            // notification → re-renders the wallet home — every 10s,
            // for every unchanged token, causing the idle lag the user
            // reported. Only mutate (and save) when something actually
            // changed, so a steady-state poll writes nothing and the UI
            // does zero work. (Compares against the RESOLVED values so a
            // nil-fiat re-yield of an unchanged row is correctly a no-op.)
            let unchanged = existing.rawBalance == rawBalance
                && existing.decimals == decimals
                && existing.fiatValueCached == resolvedFiat
                && existing.fiatCurrencyCode == resolvedCurrency
            if unchanged { return }
            existing.decimals = decimals
            existing.rawBalance = rawBalance
            existing.fiatValueCached = resolvedFiat
            existing.fiatCurrencyCode = resolvedCurrency
            existing.updatedAt = now
        } else {
            // Brand-new row with no prior price to preserve — an unknown
            // (nil) fiat lands as 0 and is corrected by the next priced
            // yield / refresh.
            let record = TokenBalanceRecord(
                tokenSymbol: tokenSymbol,
                tokenContract: tokenContract,
                decimals: decimals,
                rawBalance: rawBalance,
                fiatValueCached: fiatValueCached ?? 0,
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

        if save { try modelContext.save() }
    }

    /// Mark a scan-attempted address as "fresh" — the scan succeeded but
    /// returned zero balances (no tokens held). Updates `lastScannedAt`
    /// without inserting balance rows.
    func markScanComplete(addressId: UUID, isUsed: Bool, save: Bool = true) throws {
        var descriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.id == addressId }
        )
        descriptor.fetchLimit = 1
        guard let address = try modelContext.fetch(descriptor).first else { return }

        // **2026-06-18 — skip no-op churn (idle-lag fix).** The ~10s re-poll
        // calls this for every address every scan. Advancing `lastScannedAt`
        // on an otherwise-unchanged address still dirties the row → fires the
        // wallet-home `allWallets` @Query (the footer reads
        // `wallet.addresses.lastScannedAt`) → re-renders the home every poll,
        // for every address, even when nothing was found. Only write on a real
        // change: `isUsed` flipping, or the very first scan (no prior
        // `lastScannedAt`). A balance change advances `lastScannedAt` through
        // `upsertBalance` instead — so the freshness footer still moves when
        // holdings move, and a steady-state poll writes nothing.
        let isFirstScan = address.lastScannedAt == nil
        guard isFirstScan || address.isUsed != isUsed else { return }
        address.isUsed = isUsed
        address.lastScannedAt = Date()
        if save { try modelContext.save() }
    }

    /// Commit any pending batched writes accumulated with `save: false`.
    /// Called once at the end of a refresh so the whole pipeline's
    /// inserts/updates land in a SINGLE main-context merge (one @Query
    /// invalidation, one UI re-render) instead of one per record.
    func flush() throws {
        if modelContext.hasChanges { try modelContext.save() }
    }
}
