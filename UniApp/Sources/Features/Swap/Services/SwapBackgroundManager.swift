import Foundation
import SwiftData

/// Owns in-flight swaps so they survive leaving the swap screen (user
/// direction 2026-06-17).
///
/// **Why this exists.** A swap — especially the ERC-20 *approval* leg — can
/// take minutes on a congested chain. The old flow ran the swap inside the
/// Review screen's own `Task`, cancelled the instant the screen disappeared,
/// and hard-failed the approval after a 60-second poll window with "the token
/// approval is taking longer than expected." Both are wrong: the approval is
/// almost always still pending and will confirm, and the user should never be
/// trapped behind a spinner. Now the swap runs **here**, decoupled from any
/// view. The user can tap "Run in the background", leave, and watch a live
/// banner on the wallet home; the job runs to its honest terminal regardless
/// of which screen is on top.
///
/// In-session only: a job lives for the app session. Mid-swap signing can't be
/// resumed across a cold launch, so we don't pretend to persist it — but
/// leaving the *screen* (the actual ask) keeps it running.
@MainActor
@Observable
final class SwapBackgroundManager {
    static let shared = SwapBackgroundManager()
    private init() {}

    /// Active + recently-finished jobs (oldest first). A finished job lingers
    /// so the home banner can show its outcome until the user dismisses it or
    /// opens the status.
    private(set) var jobs: [SwapJob] = []

    /// Jobs still executing.
    var activeJobs: [SwapJob] { jobs.filter { $0.status == .running } }

    /// The most relevant job to surface in the home banner: a running one if
    /// any, otherwise the most recent finished one.
    var bannerJob: SwapJob? { activeJobs.last ?? jobs.last }

    func job(_ id: SwapJob.ID) -> SwapJob? { jobs.first { $0.id == id } }

    /// Begin a swap. Returns the job id so a screen can observe it. The
    /// execution `Task` is owned HERE, not by any view, so dismissing the swap
    /// screen never cancels the swap.
    @discardableResult
    func start(summary: SwapReviewSummary, walletId: UUID, passphrase: String?) -> SwapJob.ID {
        let job = SwapJob(summary: summary, startedAt: Date())
        let id = job.id
        jobs.append(job)
        let executor = SwapExecutor()
        Task { @MainActor in
            let result = await executor.execute(
                summary: summary,
                walletId: walletId,
                passphrase: passphrase,
                onPhase: { [weak self] phase in
                    self?.apply(id) { $0.execPhase = phase }
                }
            )
            self.apply(id) { job in
                switch result {
                case .success(let executed):
                    job.executed = executed
                    job.status = .done
                case .failure(let error):
                    job.error = error
                    job.status = .failed
                }
            }
        }
        return id
    }

    /// Remove a finished job (banner dismiss / "Close" / handled).
    func dismiss(_ id: SwapJob.ID) {
        jobs.removeAll { $0.id == id }
    }

    private func apply(_ id: SwapJob.ID, _ mutate: (inout SwapJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs[idx]
        mutate(&job)
        jobs[idx] = job   // struct replace → @Observable publishes the change
    }
}

/// One tracked swap. A value type replaced wholesale in the manager's array so
/// SwiftUI observation fires on every phase tick.
struct SwapJob: Identifiable {
    let id = UUID()
    let summary: SwapReviewSummary
    var execPhase: SwapExecutor.Phase = .preparing
    var status: Status = .running
    var executed: SwapExecutor.Executed?
    var error: SwapExecutor.ExecError?
    let startedAt: Date

    enum Status: Equatable { case running, done, failed }

    var isBridge: Bool { summary.isCrossChain }

    /// `true` once the broadcast confirmed on the source chain (a same-chain
    /// swap is then complete; a bridge has deposited and is still in flight).
    var didConfirm: Bool { executed?.confirmed == true }
    /// `true` when the source receipt came back reverted (0x0).
    var didRevert: Bool { executed?.confirmed == false }
}
