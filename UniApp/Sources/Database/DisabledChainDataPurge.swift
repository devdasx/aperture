import Foundation
import SwiftData

/// One-shot cleanup that removes persisted data for every chain whose fetching
/// is disabled (`SupportedChain.fetchingDisabled` — EVM + Bitcoin family +
/// Tron, 2026-06-21 user direction): native + token balances, transaction
/// history, per-chain aggregate rows, and UTXO summaries.
///
/// Fetching is already disabled at the scanners + rebuild, so no NEW rows are
/// written; this clears rows persisted BEFORE the cutover so a user who already
/// held that data sees it disappear. Addresses themselves are untouched — the
/// user keeps receiving, and Send keeps its keys.
///
/// Gated by a versioned flag so it runs at most once per version (the version
/// bumps whenever the disabled set grows). Idempotent regardless: re-running on
/// an already-clean store deletes nothing.
enum DisabledChainDataPurge {
    /// `.v2` — the disabled set grew from EVM-only to EVM + Bitcoin family +
    /// Tron. Bumping the suffix re-runs the purge once for users who already
    /// ran the EVM-only `.v1` pass.
    private static let doneKey = "apertureDisabledChainDataPurged.v2"

    /// Runs the purge once, off the main thread. Safe to call on every launch.
    static func runIfNeeded(container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let disabledRaws = Set(
            SupportedChain.allCases.filter { $0.fetchingDisabled }.map { $0.rawValue }
        )
        guard !disabledRaws.isEmpty else { return }

        let context = ModelContext(container)

        // Disabled-chain address ids → their balance + transaction rows link
        // by addressId.
        let disabledAddressIds = Set(
            (((try? context.fetch(FetchDescriptor<WalletAddressRecord>())) ?? [])
                .filter { disabledRaws.contains($0.chainRaw) })
                .map { $0.id }
        )

        var changed = false
        if !disabledAddressIds.isEmpty {
            for row in ((try? context.fetch(FetchDescriptor<TokenBalanceRecord>())) ?? [])
            where row.addressId.map(disabledAddressIds.contains) ?? false {
                context.delete(row)
                changed = true
            }
            for row in ((try? context.fetch(FetchDescriptor<TransactionRecord>())) ?? [])
            where row.addressId.map(disabledAddressIds.contains) ?? false {
                context.delete(row)
                changed = true
            }
        }
        // ChainStateRecord + ChainUTXORecord carry the chain directly.
        for row in ((try? context.fetch(FetchDescriptor<ChainStateRecord>())) ?? [])
        where disabledRaws.contains(row.chainRaw) {
            context.delete(row)
            changed = true
        }
        for row in ((try? context.fetch(FetchDescriptor<ChainUTXORecord>())) ?? [])
        where disabledRaws.contains(row.chainRaw) {
            context.delete(row)
            changed = true
        }

        if changed {
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
