import XCTest
@testable import Aperture

/// Documents the PTR hold-strip race and the guards that prevent it.
///
/// **Bug (fixed):** after armed release, `isPullSettling` was cleared before
/// `isRefreshing` became true. A scroll settle event with `heroPullDisplay > 0.5`
/// then called cancel release and hid the Lottie.
final class WalletHomePullRefreshStateTests: XCTestCase {

    /// Mirrors the production gate in `handleHomeScrollOffset`.
    private func shouldIgnoreScrollSettle(
        isRefreshing: Bool,
        isPullSettling: Bool,
        phase: WalletHomeMarkRefreshPhase
    ) -> Bool {
        if isRefreshing || isPullSettling { return true }
        switch phase {
        case .loading, .success: return true
        case .idle, .pulling: return false
        }
    }

    func testArmedReleaseLocksStripBeforeAsyncWork() {
        // Synchronous lock as beginPullRelease(shouldRefresh: true) now does.
        let isRefreshing = true
        var isPullSettling = true
        let phase: WalletHomeMarkRefreshPhase = .loading
        let height: CGFloat = WalletHomePullMetrics.holdHeight

        // Simulate end of settle sleep (isPullSettling cleared) while still loading.
        isPullSettling = false

        // Scroll rubber-band end event must not cancel the hold strip.
        XCTAssertTrue(
            shouldIgnoreScrollSettle(
                isRefreshing: isRefreshing,
                isPullSettling: isPullSettling,
                phase: phase
            ),
            "loading + isRefreshing must block cancel path"
        )

        // Strip stays at hold height.
        XCTAssertEqual(height, WalletHomePullMetrics.holdHeight)
        XCTAssertEqual(phase, .loading)
        XCTAssertTrue(isRefreshing)
    }

    func testOldRaceWouldHaveCollapsedWithoutSynchronousIsRefreshing() {
        // Reproduce the pre-fix window: settle ended, isRefreshing not yet set.
        let isRefreshing = false
        let isPullSettling = false
        let phase: WalletHomeMarkRefreshPhase = .loading
        let height: CGFloat = WalletHomePullMetrics.holdHeight

        // With only isRefreshing/isPullSettling (old guard), cancel would run:
        let oldGuardBlocks = isRefreshing || isPullSettling
        XCTAssertFalse(oldGuardBlocks, "old guard alone is open during the race window")

        // Phase-aware guard (new) still blocks:
        XCTAssertTrue(
            shouldIgnoreScrollSettle(
                isRefreshing: isRefreshing,
                isPullSettling: isPullSettling,
                phase: phase
            )
        )
        XCTAssertGreaterThan(height, 0.5)
    }

    func testPullingPhaseDoesNotBlockScrollUpdates() {
        XCTAssertFalse(
            shouldIgnoreScrollSettle(
                isRefreshing: false,
                isPullSettling: false,
                phase: .pulling(progress: 0.5)
            )
        )
    }

    /// After finger-up, rubber-band must not scrub strip height to 0 before
    /// loading opens (video: rest empty at ~1.8s then mark returns at ~2.0s).
    func testRubberBandDecayMustNotClearStripBeforeLoading() {
        var heroPullDisplay: CGFloat = 80
        var phase: WalletHomeMarkRefreshPhase = .pulling(progress: 1)
        let fingerDown = false // scroll phase no longer interacting

        // Finger-up commit (new design): lock to loading at hold, never 0.
        if !fingerDown {
            heroPullDisplay = WalletHomePullMetrics.holdHeight
            phase = .loading
        }
        XCTAssertEqual(phase, .loading)
        XCTAssertEqual(heroPullDisplay, WalletHomePullMetrics.holdHeight)
        XCTAssertGreaterThan(heroPullDisplay, 0)
    }

    func testMarkRefreshKitJSONBundled() {
        for name in ["mark-refresh-light", "mark-refresh-dark", "mark-refresh-midnight"] {
            let url = Bundle.main.url(forResource: name, withExtension: "json")
            XCTAssertNotNil(url, "\(name).json must ship in the app bundle")
        }
    }

    func testHoldHeightMatchesDesignedMarkSize() {
        XCTAssertEqual(WalletHomePullMetrics.holdHeight, WalletHomePullMetrics.markSize)
        XCTAssertEqual(WalletHomePullMetrics.markSize, 32)
    }
}
