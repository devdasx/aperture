import Foundation

/// One address the wallet has sent to before, with how many times and
/// when last. Drives the recipient step's "recent" list AND the
/// first-send warning / send-count badge.
struct RecentRecipient: Sendable, Equatable, Identifiable {
    let address: String
    let sendCount: Int
    let lastSentAt: Date
    var id: String { address }
}

/// A `Sendable` snapshot of every address the active wallet has sent to,
/// per chain, derived from real outgoing `TransactionRecord`s. Built once
/// off the render path (like `AssetPickerHoldings`); the recipient screen
/// reads it for the recent list and the first-send check.
///
/// EVM addresses are compared case-insensitively (the chain treats them
/// that way); every other family keeps the address verbatim.
struct RecentRecipientsIndex: Sendable, Equatable {

    /// chainRaw → [normalizedAddress → RecentRecipient].
    private let byChain: [String: [String: RecentRecipient]]

    static let empty = RecentRecipientsIndex(byChain: [:])

    private static func normalize(_ address: String, chain: SupportedChain) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return chain.family == .evm ? trimmed.lowercased() : trimmed
    }

    /// Recent recipients for `chain`, most-sent first then most-recent.
    func recents(for chain: SupportedChain) -> [RecentRecipient] {
        (byChain[chain.rawValue]?.values).map { values in
            values.sorted { a, b in
                if a.sendCount != b.sendCount { return a.sendCount > b.sendCount }
                return a.lastSentAt > b.lastSentAt
            }
        } ?? []
    }

    /// How many times we've sent to `address` on `chain` (0 = first send).
    func sendCount(to address: String, chain: SupportedChain) -> Int {
        byChain[chain.rawValue]?[Self.normalize(address, chain: chain)]?.sendCount ?? 0
    }
}

extension RecentRecipientsIndex {
    /// Build from the active wallet's outgoing transactions. `@MainActor`
    /// because it reads the SwiftData graph; called from a `.task(id:)`
    /// so it's off the synchronous render path (Rule #28).
    @MainActor
    init(wallet: WalletRecord?) {
        guard let wallet else { self = .empty; return }
        var byChain: [String: [String: RecentRecipient]] = [:]

        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for tx in address.transactions where tx.directionRaw == TransactionDirection.outgoing.rawValue {
                let counterparty = tx.counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !counterparty.isEmpty else { continue }
                let key = RecentRecipientsIndex.normalize(counterparty, chain: chain)
                var bucket = byChain[address.chainRaw] ?? [:]
                if let existing = bucket[key] {
                    bucket[key] = RecentRecipient(
                        address: existing.address,
                        sendCount: existing.sendCount + 1,
                        lastSentAt: max(existing.lastSentAt, tx.occurredAt)
                    )
                } else {
                    bucket[key] = RecentRecipient(
                        address: counterparty,
                        sendCount: 1,
                        lastSentAt: tx.occurredAt
                    )
                }
                byChain[address.chainRaw] = bucket
            }
        }
        self.byChain = byChain
    }
}
