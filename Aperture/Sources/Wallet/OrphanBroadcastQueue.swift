import Foundation

/// Durable local queue for broadcasts that succeeded on-chain but failed
/// to write the pending outbox row (P2-001).
///
/// Source of truth for funds is the chain; this queue only restores Activity
/// tracking + `PendingTransactionMonitor` confirmation polling.
enum OrphanBroadcastQueue {
    private static let defaultsKey = "aperture.orphanBroadcasts.v1"
    private static let lock = NSLock()

    struct Entry: Codable, Sendable, Equatable, Hashable {
        let txHash: String
        let chainRaw: String
        let addressId: UUID
        let amountRaw: String
        let feeRaw: String
        let tokenSymbol: String
        let tokenContract: String?
        let counterparty: String
        let enqueuedAt: Date

        init(
            txHash: String,
            chainRaw: String,
            addressId: UUID,
            amountRaw: String,
            feeRaw: String,
            tokenSymbol: String,
            tokenContract: String?,
            counterparty: String,
            enqueuedAt: Date = Date()
        ) {
            self.txHash = txHash
            self.chainRaw = chainRaw
            self.addressId = addressId
            self.amountRaw = amountRaw
            self.feeRaw = feeRaw
            self.tokenSymbol = tokenSymbol
            self.tokenContract = tokenContract
            self.counterparty = counterparty
            self.enqueuedAt = enqueuedAt
        }
    }

    static func enqueue(_ entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        // De-dupe by (chain, hash).
        items.removeAll {
            $0.txHash.caseInsensitiveCompare(entry.txHash) == .orderedSame
                && $0.chainRaw == entry.chainRaw
        }
        items.append(entry)
        // Cap blast radius.
        if items.count > 50 {
            items = Array(items.suffix(50))
        }
        saveUnlocked(items)
    }

    static func all() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    static func remove(txHash: String, chainRaw: String) {
        lock.lock()
        defer { lock.unlock() }
        var items = loadUnlocked()
        items.removeAll {
            $0.txHash.caseInsensitiveCompare(txHash) == .orderedSame
                && $0.chainRaw == chainRaw
        }
        saveUnlocked(items)
    }

    /// Re-upsert every orphan as a pending transaction row. Successfully
    /// written entries are removed from the queue.
    @discardableResult
    static func flush(into database: AppDatabase) -> Int {
        let pending = all()
        guard !pending.isEmpty else { return 0 }
        let repository = TransactionRepository(database: database)
        var written = 0
        for entry in pending {
            do {
                try repository.upsertTransaction(
                    addressId: entry.addressId,
                    txHash: entry.txHash,
                    direction: .outgoing,
                    amountRaw: entry.amountRaw,
                    tokenSymbol: entry.tokenSymbol,
                    tokenContract: entry.tokenContract,
                    kind: nil,
                    blockNumber: nil,
                    occurredAt: entry.enqueuedAt,
                    status: .pending,
                    counterparty: entry.counterparty,
                    feeRaw: entry.feeRaw,
                    id: UUID(),
                    save: true
                )
                remove(txHash: entry.txHash, chainRaw: entry.chainRaw)
                written += 1
            } catch {
                // Leave in queue for next kick.
                continue
            }
        }
        return written
    }

    // MARK: - Storage

    private static func loadUnlocked() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveUnlocked(_ items: [Entry]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    #if DEBUG
    static func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
    #endif
}
