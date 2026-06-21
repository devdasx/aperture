import Foundation
import SwiftData

/// One-shot cleanup that removes any persisted EVM chain data — balances,
/// transaction history, and per-chain aggregate rows (2026-06-21 user
/// direction: zero EVM balances / history anywhere in the app).
///
/// EVM fetching is already disabled at the scanners + rebuild, so no NEW EVM
/// rows are ever written; this clears rows that were persisted BEFORE the
/// cutover so a user who already held EVM data sees it disappear. EVM
/// addresses themselves are untouched — the user keeps receiving, and Send /
/// Swap / dApp keep their keys.
///
/// Gated by a one-time flag so it runs at most once. Idempotent regardless:
/// re-running on an already-clean store deletes nothing.
enum EVMDataPurge {
    private static let doneKey = "apertureEVMDataPurged.v1"

    /// Runs the purge once, off the main thread. Safe to call on every launch.
    static func runIfNeeded(container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let evmRaws = Set(
            SupportedChain.allCases.filter { $0.family == .evm }.map { $0.rawValue }
        )
        guard !evmRaws.isEmpty else { return }

        let context = ModelContext(container)

        // EVM address ids → their balance + transaction rows link by addressId.
        let evmAddressIds = Set(
            (((try? context.fetch(FetchDescriptor<WalletAddressRecord>())) ?? [])
                .filter { evmRaws.contains($0.chainRaw) })
                .map { $0.id }
        )

        var changed = false
        if !evmAddressIds.isEmpty {
            for row in ((try? context.fetch(FetchDescriptor<TokenBalanceRecord>())) ?? [])
            where row.addressId.map(evmAddressIds.contains) ?? false {
                context.delete(row)
                changed = true
            }
            for row in ((try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [])
            where row.addressId.map(evmAddressIds.contains) ?? false {
                context.delete(row)
                changed = true
            }
        }
        // ChainStateRecord carries the chain directly.
        for row in ((try? context.fetch(FetchDescriptor<ChainStateRecord>())) ?? [])
        where evmRaws.contains(row.chainRaw) {
            context.delete(row)
            changed = true
        }

        if changed {
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
