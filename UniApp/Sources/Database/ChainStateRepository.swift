import Foundation
import SwiftData
import OSLog

/// Background-safe mutation + query surface for `ChainStateRecord` and
/// `ChainUTXORecord` — the per-chain aggregate the balance card reads.
///
/// **Source of truth is still the normalized tables.** This repository
/// never invents data: `rebuild(...)` recomputes each chain's aggregate
/// row purely from the persisted `TokenBalanceRecord` (balances),
/// `TransactionRecord` (per-category tx counts) and `ChainUTXORecord`
/// (UTXO summary) rows that the scanners already wrote. It's the
/// denormalized read-model the UI consumes so a `@Query` notification
/// re-renders one indexed row per chain instead of summing dozens on the
/// main thread.
///
/// Per `CLAUDE.md` Rule #2 §C (actor-isolated repositories).
@ModelActor
actor ChainStateRepository {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "chain-state-repo")

    // MARK: - Sendable snapshot (cross-actor reads)

    /// One chain's aggregate flattened to a `Sendable` value — `@Model`
    /// instances must not cross the actor boundary.
    struct ChainStateSnapshot: Sendable {
        let chainRaw: String
        let address: String
        let nativeBalanceRaw: String
        let nativeFiat: Decimal
        let totalFiat: Decimal
        let tokenCount: Int
        let txSentCount: Int
        let txReceivedCount: Int
        let txSelfTransferCount: Int
        let txBridgeCount: Int
        let txFailedCount: Int
        let txPendingCount: Int
        let txTotalCount: Int
        let utxoCount: Int
        let utxoTotalSats: Int64
        let isUsed: Bool
        let hasEncryptedKey: Bool
        let syncStateRaw: String
    }

    // MARK: - Rebuild (recompute every chain's aggregate from the store)

    /// Recompute and upsert the aggregate row for EVERY chain the wallet
    /// has an address on, from the currently-persisted balance / tx /
    /// UTXO rows. Called by the refresh coordinator after the balance
    /// flush (balances land first) and again after the history flush
    /// (tx counts fill in) — each call updates the `@Query`-backed UI
    /// live. Returns the number of chains rebuilt.
    /// - Parameters:
    ///   - failedChains: chains whose live read failed this refresh — their
    ///     row keeps its last-known balances (honest) but is stamped
    ///     `.failed`. Ignored when `interim` is `true`.
    ///   - interim: a mid-refresh rebuild (balances landed, history still
    ///     in flight) — every row is stamped `.syncing` so the UI shows a
    ///     per-chain spinner until the final rebuild stamps the outcome.
    /// - Parameter onlyChains: when non-nil, recompute ONLY these chains
    ///   (the live per-domain path — a chain's balance or history just
    ///   landed, so rebuild that one chain's aggregate and leave the rest
    ///   untouched). `nil` rebuilds every chain the wallet has.
    @discardableResult
    func rebuild(
        walletId: UUID,
        fiatCurrencyCode: String,
        onlyChains: Set<SupportedChain>? = nil,
        failedChains: Set<SupportedChain> = [],
        interim: Bool = false
    ) throws -> Int {
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        guard let wallet = try modelContext.fetch(walletDescriptor).first else { return 0 }

        // **Balance-$0 fix (2026-06-17).** TokenBalanceRecord + TransactionRecord
        // are written by `TransactionRepository`, a SEPARATE `@ModelActor` with
        // its OWN context. This actor's long-lived `modelContext` caches those
        // rows the first time it fetches them (during an early interim/live
        // rebuild, when the native fiat is still nil/0), and SwiftData does NOT
        // refresh a cached object's scalars on a later re-fetch — so the final
        // rebuild kept reading fiat=0 and `ChainStateRecord.totalFiat` was stuck
        // at 0 (the hero showed $0 even though balances + prices were persisted).
        // Read the balance + tx rows from a FRESH context per rebuild so we
        // always see exactly what `txRepo` committed to the store.
        let readContext = ModelContext(modelContainer)

        var rebuilt = 0
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            // Data is disabled for some chains (2026-06-21 — EVM + Bitcoin
            // family + Tron) — never build a per-chain aggregate row for them,
            // so they never appear in the balance card / holdings.
            if chain.fetchingDisabled { continue }
            if let onlyChains, !onlyChains.contains(chain) { continue }
            let state: ChainSyncState = interim
                ? .syncing
                : (failedChains.contains(chain) ? .failed : .synced)
            try recomputeRow(
                readContext: readContext,
                walletId: walletId,
                chain: chain,
                addressId: address.id,
                address: address.address,
                derivationPath: address.derivationPath,
                isUsed: address.isUsed,
                fiatCurrencyCode: fiatCurrencyCode,
                syncState: state,
                save: false
            )
            rebuilt += 1
        }
        if modelContext.hasChanges { try modelContext.save() }
        return rebuilt
    }

    /// Recompute one chain's aggregate from its persisted rows and upsert
    /// the `ChainStateRecord`. Preserves the encrypted-key blob (only
    /// `storeEncryptedKeys` writes that).
    private func recomputeRow(
        readContext: ModelContext,
        walletId: UUID,
        chain: SupportedChain,
        addressId: UUID,
        address: String,
        derivationPath: String,
        isUsed: Bool,
        fiatCurrencyCode: String,
        syncState: ChainSyncState,
        save: Bool
    ) throws {
        // --- Balances (native + tokens) --- read from the fresh `readContext`
        // (see the rebuild() comment): the priced fiat `txRepo` committed is
        // only visible to a context that hasn't already cached these rows at 0.
        let balanceDescriptor = FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        )
        let balances = try readContext.fetch(balanceDescriptor)
        let nativeTicker = chain.ticker
        var nativeBalanceRaw = "0"
        var nativeDecimals = 0
        var nativeFiat: Decimal = 0
        var totalFiat: Decimal = 0
        var tokenCount = 0
        for row in balances {
            // Only fiat denominated in the active currency counts toward the
            // totals — a row still carrying the previous currency's value
            // (the brief window before `repriceWallet` re-denominates it)
            // would otherwise render e.g. 35 JOD as "$35". This mirrors
            // `WalletHomeView.totalFiat`'s currency filter so the per-chain
            // aggregate and the hero agree exactly. Holdings COUNT regardless
            // of currency (a held token is held whatever its cached fiat).
            let inCurrency = row.fiatCurrencyCode == fiatCurrencyCode
            if inCurrency { totalFiat += row.fiatValueCached }
            if row.tokenContract == nil && row.tokenSymbol == nativeTicker {
                nativeBalanceRaw = row.rawBalance
                nativeDecimals = row.decimals
                nativeFiat = inCurrency ? row.fiatValueCached : 0
            } else {
                tokenCount += 1
            }
        }

        // --- Transactions (per-category counts) ---
        let txDescriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        )
        let txs = try readContext.fetch(txDescriptor)
        var sent = 0, received = 0, selfT = 0, bridge = 0, failed = 0, pending = 0
        for tx in txs {
            let status = TransactionStatus(rawValue: tx.statusRaw) ?? .confirmed
            if status == .failed { failed += 1 }
            if status == .pending { pending += 1 }
            let kind = TransactionKind.effectiveKind(kindRaw: tx.kindRaw, directionRaw: tx.directionRaw)
            let direction = TransactionDirection(rawValue: tx.directionRaw) ?? .incoming
            switch kind {
            case .bridge: bridge += 1
            case .selfTransfer: selfT += 1
            case .transfer:
                if direction == .outgoing { sent += 1 }
                else if direction == .incoming { received += 1 }
                else { selfT += 1 } // .internal transfer with no explicit kind
            }
        }

        // --- UTXOs (UTXO chains) ---
        let chainRaw = chain.rawValue
        let utxoDescriptor = FetchDescriptor<ChainUTXORecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        )
        let utxos = try readContext.fetch(utxoDescriptor)
        // Saturating sum — a hostile / corrupted UTXO provider could return
        // values whose total overflows Int64 and traps. Honest data can never
        // approach Int64.max sats (total BTC supply is ~2.1e15 sats vs Int64
        // max ~9.2e18), so saturation never affects real wallets; it's a crash
        // guard against malformed provider responses.
        let utxoTotal = utxos.reduce(Int64(0)) { acc, utxo in
            let (sum, overflow) = acc.addingReportingOverflow(utxo.valueSats)
            return overflow ? Int64.max : sum
        }

        // --- Upsert the aggregate row ---
        let (record, isNew) = try fetchOrCreateRow(walletId: walletId, chainRaw: chainRaw, address: address)
        let resolvedIsUsed = isUsed || totalFiat > 0 || !txs.isEmpty
        let utxoTotalRaw = String(utxoTotal)
        let txTotalCount = txs.count
        let utxoCount = utxos.count

        // **2026-06-18 — skip no-op rebuilds (idle-lag fix).** The live
        // committer rebuilds dirty chains on a ~300ms cadence and the app
        // re-scans every chain every ~10s. Re-assigning identical aggregates
        // (and bumping `lastSyncedAt = Date()`) still dirties the SwiftData row
        // → fires the `chainStateRecords` @Query → re-renders the balance card
        // on every commit/poll even when nothing moved. This is the same
        // idle-churn class `TransactionRepository.upsertBalance` already guards.
        // Only write when an aggregate actually changed; a freshly inserted row
        // always writes. `lastSyncedAt` therefore advances only on a real
        // change — so a steady-state poll writes nothing and the UI does zero
        // work (the freshness ledger lives in `SyncStatusRecord`, stamped once
        // per refresh, not here).
        let unchanged = !isNew
            && record.address == address
            && record.derivationPath == derivationPath
            && record.nativeBalanceRaw == nativeBalanceRaw
            && record.nativeDecimals == nativeDecimals
            && record.nativeFiat == nativeFiat
            && record.totalFiat == totalFiat
            && record.tokenCount == tokenCount
            && record.fiatCurrencyCode == fiatCurrencyCode
            && record.txSentCount == sent
            && record.txReceivedCount == received
            && record.txSelfTransferCount == selfT
            && record.txBridgeCount == bridge
            && record.txFailedCount == failed
            && record.txPendingCount == pending
            && record.txTotalCount == txTotalCount
            && record.utxoCount == utxoCount
            && record.utxoTotalRaw == utxoTotalRaw
            && record.isUsed == resolvedIsUsed
            && record.syncStateRaw == syncState.rawValue
        if unchanged { return }

        record.address = address
        record.derivationPath = derivationPath
        record.nativeBalanceRaw = nativeBalanceRaw
        record.nativeDecimals = nativeDecimals
        record.nativeFiat = nativeFiat
        record.totalFiat = totalFiat
        record.tokenCount = tokenCount
        record.fiatCurrencyCode = fiatCurrencyCode
        record.txSentCount = sent
        record.txReceivedCount = received
        record.txSelfTransferCount = selfT
        record.txBridgeCount = bridge
        record.txFailedCount = failed
        record.txPendingCount = pending
        record.txTotalCount = txTotalCount
        record.utxoCount = utxoCount
        record.utxoTotalRaw = utxoTotalRaw
        record.isUsed = resolvedIsUsed
        record.lastSyncedAt = Date()
        record.syncStateRaw = syncState.rawValue

        if save, modelContext.hasChanges { try modelContext.save() }
    }

    // MARK: - UTXO persistence

    /// Replace the persisted UTXO set for `(walletId, chain)` with
    /// `utxos`. UTXOs are a snapshot — spent ones must disappear — so this
    /// deletes the chain's existing rows and inserts the fresh set.
    /// Returns the new count + total value (sats) for convenience.
    @discardableResult
    func replaceUTXOs(
        walletId: UUID,
        chain: SupportedChain,
        address: String,
        utxos: [SelectedUTXO]
    ) throws -> (count: Int, totalSats: Int64) {
        let chainRaw = chain.rawValue
        let existingDescriptor = FetchDescriptor<ChainUTXORecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        )
        for stale in try modelContext.fetch(existingDescriptor) {
            modelContext.delete(stale)
        }
        var total: Int64 = 0
        for utxo in utxos {
            total += utxo.valueSats
            modelContext.insert(ChainUTXORecord(
                walletId: walletId,
                chainRaw: chainRaw,
                address: address,
                txid: utxo.txid,
                vout: utxo.vout,
                valueSatsRaw: String(utxo.valueSats),
                scriptHex: utxo.scriptHex,
                confirmed: utxo.confirmed
            ))
        }
        try modelContext.save()
        return (utxos.count, total)
    }

    // MARK: - Encrypted key blobs

    /// Persist the AES-GCM-sealed private-key blob for each chain into its
    /// aggregate row (creating a minimal row if the rebuild hasn't run
    /// yet). Only overwrites a stored blob when a fresh one is supplied.
    func storeEncryptedKeys(walletId: UUID, blobs: [SupportedChain: Data]) throws {
        guard !blobs.isEmpty else { return }
        for (chain, blob) in blobs {
            let (record, _) = try fetchOrCreateRow(walletId: walletId, chainRaw: chain.rawValue, address: "")
            record.encryptedPrivateKey = blob
            record.keyEncryptionScheme = ChainKeyVault.scheme
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// Chains for this wallet that still lack a stored encrypted key — the
    /// coordinator derives only these (one-time population; watch-only
    /// wallets never get one).
    func chainsMissingKey(walletId: UUID, candidates: Set<SupportedChain>) throws -> Set<SupportedChain> {
        let descriptor = FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId }
        )
        let rows = try modelContext.fetch(descriptor)
        let haveKey = Set(rows.compactMap { $0.encryptedPrivateKey != nil ? $0.chain : nil })
        return candidates.subtracting(haveKey)
    }

    // MARK: - Sync state

    /// Stamp every existing chain row for the wallet as `.syncing` at the
    /// start of a refresh so the UI can show a per-chain spinner.
    func markSyncing(walletId: UUID) throws {
        let descriptor = FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId }
        )
        let rows = try modelContext.fetch(descriptor)
        for row in rows { row.syncStateRaw = ChainSyncState.syncing.rawValue }
        if modelContext.hasChanges { try modelContext.save() }
    }

    // MARK: - Queries (Sendable snapshots)

    func chainStates(walletId: UUID) throws -> [ChainStateSnapshot] {
        let descriptor = FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId }
        )
        return try modelContext.fetch(descriptor).map(snapshot(from:))
    }

    func chainState(walletId: UUID, chain: SupportedChain) throws -> ChainStateSnapshot? {
        let chainRaw = chain.rawValue
        var descriptor = FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(snapshot(from:))
    }

    // MARK: - Helpers

    /// Find the `(walletId, chainRaw)` row or create a fresh one. Does NOT
    /// save — the caller batches the save. Returns `isNew` so `recomputeRow`
    /// can force the first write on a freshly inserted row while skipping
    /// no-op rewrites of an existing one.
    private func fetchOrCreateRow(walletId: UUID, chainRaw: String, address: String) throws -> (record: ChainStateRecord, isNew: Bool) {
        var descriptor = FetchDescriptor<ChainStateRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            return (existing, false)
        }
        let record = ChainStateRecord(walletId: walletId, chainRaw: chainRaw, address: address)
        modelContext.insert(record)
        return (record, true)
    }

    private func snapshot(from record: ChainStateRecord) -> ChainStateSnapshot {
        ChainStateSnapshot(
            chainRaw: record.chainRaw,
            address: record.address,
            nativeBalanceRaw: record.nativeBalanceRaw,
            nativeFiat: record.nativeFiat,
            totalFiat: record.totalFiat,
            tokenCount: record.tokenCount,
            txSentCount: record.txSentCount,
            txReceivedCount: record.txReceivedCount,
            txSelfTransferCount: record.txSelfTransferCount,
            txBridgeCount: record.txBridgeCount,
            txFailedCount: record.txFailedCount,
            txPendingCount: record.txPendingCount,
            txTotalCount: record.txTotalCount,
            utxoCount: record.utxoCount,
            utxoTotalSats: Int64(record.utxoTotalRaw) ?? 0,
            isUsed: record.isUsed,
            hasEncryptedKey: record.encryptedPrivateKey != nil,
            syncStateRaw: record.syncStateRaw
        )
    }
}
