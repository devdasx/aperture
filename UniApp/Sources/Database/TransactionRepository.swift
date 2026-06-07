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

    // MARK: - Transactions

    /// Upsert a transaction by `(txHash, addressId)`. If a row with the
    /// same hash on the same address exists, its status / block / fee
    /// are updated in place; otherwise a new row is inserted. Idempotent
    /// — safe to call from a scanner that polls.
    func upsertTransaction(
        addressId: UUID,
        txHash: String,
        direction: TransactionDirection,
        amountRaw: String,
        tokenSymbol: String,
        tokenContract: String? = nil,
        blockNumber: Int64?,
        occurredAt: Date,
        status: TransactionStatus,
        counterparty: String,
        feeRaw: String?
    ) throws {
        var addrDescriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.id == addressId }
        )
        addrDescriptor.fetchLimit = 1
        guard let address = try modelContext.fetch(addrDescriptor).first else { return }

        var txDescriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.txHash == txHash && $0.address?.id == addressId }
        )
        txDescriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(txDescriptor).first {
            existing.statusRaw = status.rawValue
            existing.blockNumber = blockNumber
            existing.feeRaw = feeRaw
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
            record.address = address
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    /// Delete all transactions for a given address. Used when a watch-only
    /// wallet is re-derived or when a user explicitly clears history from
    /// a future Settings → Wallet row.
    func clearTransactions(for addressId: UUID) throws {
        let descriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.address?.id == addressId }
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
        var addrDescriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.id == addressId }
        )
        addrDescriptor.fetchLimit = 1
        guard let address = try modelContext.fetch(addrDescriptor).first else { return }

        var balDescriptor = FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.address?.id == addressId
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
