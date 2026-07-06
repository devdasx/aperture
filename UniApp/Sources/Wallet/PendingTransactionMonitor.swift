import Foundation
import OSLog

/// Database-backed confirmation monitor for locally stored pending
/// transactions. It is intentionally owned by the wallet data layer rather
/// than a view: every pending send/receive row in GRDB gets the same treatment
/// whether the detail screen is open or not.
actor PendingTransactionMonitor {
    static let shared = PendingTransactionMonitor()

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "pending-tx")
    private let tonClient = TonBalanceHistoryClient()
    private var task: Task<Void, Never>?
    private var restartRequested = false

    func kick(database: AppDatabase = .shared) {
        if task != nil {
            restartRequested = true
            return
        }
        task = Task(priority: .utility) { [weak self] in
            await self?.run(database: database)
        }
    }

    private func run(database: AppDatabase) async {
        defer {
            task = nil
            restartRequested = false
        }

        repeat {
            restartRequested = false
            await pollUntilIdle(database: database)
        } while restartRequested && !Task.isCancelled
    }

    private func pollUntilIdle(database: AppDatabase) async {
        while !Task.isCancelled {
            let repository = TransactionRepository(database: database)
            let pending: [TransactionRepository.PendingTransactionSnapshot]
            do {
                pending = try repository.pendingTransactions()
            } catch {
                log.error("Pending transaction query failed: \(String(describing: error), privacy: .public)")
                return
            }

            guard !pending.isEmpty else { return }

            for transaction in pending {
                if Task.isCancelled { return }
                await resolve(transaction, database: database)
            }

            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func resolve(
        _ transaction: TransactionRepository.PendingTransactionSnapshot,
        database: AppDatabase
    ) async {
        guard !transaction.txHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let detail = await TransactionDetailService.detail(
            chain: transaction.chain,
            txHash: transaction.txHash,
            tokenContract: transaction.tokenContract,
            address: transaction.address,
            counterparty: transaction.counterparty
        ), detail.status != .pending {
            persist(
                transaction,
                status: detail.status,
                blockNumber: detail.blockNumber,
                occurredAt: detail.blockTime,
                feeRaw: detail.feeNative.map { NSDecimalNumber(decimal: $0).stringValue },
                database: database,
                source: "detail"
            )
            return
        }

        if transaction.chain == .ton,
           let event = await resolveTONEvent(for: transaction),
           event.status != .pending {
            persist(
                transaction,
                status: event.status,
                blockNumber: event.blockNumber,
                occurredAt: event.occurredAt,
                feeRaw: event.fee,
                database: database,
                source: "ton-events"
            )
        }
    }

    private func persist(
        _ transaction: TransactionRepository.PendingTransactionSnapshot,
        status: TransactionStatus,
        blockNumber: Int64?,
        occurredAt: Date?,
        feeRaw: String?,
        database: AppDatabase,
        source: String
    ) {
        do {
            let repository = TransactionRepository(database: database)
            try repository.resolvePendingTransaction(
                transaction,
                status: status,
                blockNumber: blockNumber,
                occurredAt: occurredAt,
                feeRaw: feeRaw
            )
            let currencyCode = AppPreferenceStore.shared.string(
                CurrencyPreference.storageKey,
                default: CurrencyPreference.defaultCode
            )
            _ = try? ChainStateRepository(database: database).rebuild(
                walletId: transaction.walletId,
                fiatCurrencyCode: currencyCode,
                onlyChains: [transaction.chain],
                failedChains: [],
                interim: false
            )
            log.debug(
                "Pending transaction resolved id=\(transaction.id.uuidString, privacy: .public) chain=\(transaction.chain.rawValue, privacy: .public) status=\(status.rawValue, privacy: .public) source=\(source, privacy: .public)"
            )
        } catch {
            log.error("Pending transaction resolve write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// TON can expose a broadcast through an account event before a direct
    /// hash lookup can be hydrated. Prefer exact hash matches; if the provider
    /// uses a different hash shape, accept only one strongly matching outgoing
    /// event with the same asset, amount, counterparty, and nearby timestamp.
    private func resolveTONEvent(
        for transaction: TransactionRepository.PendingTransactionSnapshot
    ) async -> TonHistoryEvent? {
        do {
            let events = try await tonClient.recentEvents(
                address: transaction.address,
                supportedTokens: TONJettonRegistry.tokens
            )
            let cleanHash = transaction.txHash.components(separatedBy: "#").first ?? transaction.txHash
            if let exact = events.first(where: { sameHash($0.txHash, cleanHash) }) {
                return exact
            }

            let candidates = events.filter { event in
                event.direction == transaction.direction
                    && event.tokenSymbol.caseInsensitiveCompare(transaction.tokenSymbol) == .orderedSame
                    && sameContract(event.tokenContract, transaction.tokenContract)
                    && sameAmount(event.amount, transaction.amountRaw)
                    && sameCounterparty(event.counterparty, transaction.counterparty)
                    && abs(event.occurredAt.timeIntervalSince(transaction.occurredAt)) <= 6 * 60 * 60
            }
            return candidates.count == 1 ? candidates[0] : nil
        } catch {
            log.debug("TON pending event lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func sameHash(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func sameContract(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare((rhs ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func sameAmount(_ lhs: String, _ rhs: String) -> Bool {
        if let left = Decimal(string: lhs), let right = Decimal(string: rhs) {
            return left == right
        }
        return lhs == rhs
    }

    private func sameCounterparty(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return true }
        return left.caseInsensitiveCompare(right) == .orderedSame
    }
}
