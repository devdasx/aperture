import Testing
import Foundation
@testable import Aperture

/// **Part 1 verification (2026-06-18) — the single-flight contract.**
///
/// Proves `WalletRefreshRegistry` coalesces overlapping refresh triggers for
/// the same wallet into ONE pipeline: the import's post-persist
/// `refreshWallet` and the home's `.task(id: activeWalletIdRaw)` auto-refresh
/// fire near-simultaneously for the same `walletId`, and must NOT double-scan
/// (the spec's claim 1). These exercise `joinOrStart` directly — the
/// load-bearing dedup primitive — without standing up the whole coordinator.
///
/// `@MainActor` because the registry is `@MainActor` (it serializes its
/// `inFlight` dictionary there). Each test uses a fresh random `walletId`, so
/// they never collide with each other or a running app's state.
@MainActor
struct WalletRefreshRegistryTests {

    private actor Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    @Test("Overlapping refreshes for the same wallet run the pipeline exactly once")
    func overlappingCoalesce() async {
        let walletId = UUID()
        let counter = Counter()
        let op: @Sendable () async -> Set<SupportedChain> = {
            await counter.bump()
            try? await Task.sleep(for: .milliseconds(80))
            return []
        }
        // Two near-simultaneous triggers (import + home .task), same wallet.
        let t1 = WalletRefreshRegistry.joinOrStart(walletId: walletId, operation: op)
        let t2 = WalletRefreshRegistry.joinOrStart(walletId: walletId, operation: op)
        _ = await t1.value
        _ = await t2.value
        #expect(await counter.count == 1, "overlapping same-wallet refreshes must share ONE pipeline")
    }

    @Test("Different wallets refresh independently")
    func differentWalletsRunSeparately() async {
        let counter = Counter()
        let op: @Sendable () async -> Set<SupportedChain> = {
            await counter.bump()
            try? await Task.sleep(for: .milliseconds(40))
            return []
        }
        let a = WalletRefreshRegistry.joinOrStart(walletId: UUID(), operation: op)
        let b = WalletRefreshRegistry.joinOrStart(walletId: UUID(), operation: op)
        _ = await a.value
        _ = await b.value
        #expect(await counter.count == 2)
    }

    @Test("A healthy in-flight refresh is JOINED by a user pull, not double-run")
    func userPullJoinsHealthyRun() async {
        let walletId = UUID()
        let counter = Counter()
        let op: @Sendable () async -> Set<SupportedChain> = {
            await counter.bump()
            try? await Task.sleep(for: .milliseconds(80))
            return []
        }
        let bg = WalletRefreshRegistry.joinOrStart(walletId: walletId, operation: op)
        // A pull-to-refresh (cancelExisting: true) arriving while the bg run is
        // young (< wedgeThreshold) must JOIN it, not start a second scan.
        let pull = WalletRefreshRegistry.joinOrStart(
            walletId: walletId, cancelExisting: true, operation: op
        )
        _ = await bg.value
        _ = await pull.value
        #expect(await counter.count == 1, "a young in-flight run must be joined, never replaced")
    }
}
