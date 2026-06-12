import SwiftUI
import OSLog

/// Tracks the app's `ScenePhase` transitions so the wallet home can
/// present the lock screen after the configured auto-lock duration of
/// inactivity. Only activates when the user has a PIN set
/// (`PinCodePreference.isPinEnabled()`); when PIN is disabled, this
/// controller stays idle and the wallet remains accessible whenever the
/// scene is active.
///
/// **Mechanism.** When the scene transitions to `.background` or
/// `.inactive`, capture `Date()`. When the scene returns to `.active`,
/// compare the elapsed time against the stored auto-lock duration; if
/// it exceeded the threshold, set `isLocked = true`. The wallet-home
/// surfaces a `.fullScreenCover` of `AppLockView` when `isLocked` is
/// true; the user authenticates (PIN or biometric), and on success
/// `isLocked` flips back to `false` and the cover dismisses.
///
/// **Cold-launch policy.** A fresh cold launch with a PIN enabled
/// always starts locked — the user has not authenticated in this scene
/// yet. The controller initializes with `isLocked = pinEnabled`.
///
/// Per `CLAUDE.md` Rule #17 (one PIN component): the unlock UI reuses
/// `PinCodeView(mode: .verify)`; no second PIN UI is built.
@MainActor
@Observable
final class AutoLockController {
    /// `true` ⇒ wallet UI is gated by `AppLockView`. Bound by views via
    /// `@Environment` (after the controller is injected at the app root).
    var isLocked: Bool

    /// When the scene most recently became inactive / background. Nil
    /// when the scene has been continuously active since launch.
    private var backgroundedAt: Date?

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "auto-lock")

    init() {
        // Cold launch: locked iff PIN is set. Reads from UserDefaults
        // directly because @AppStorage requires a View context.
        let pinEnabled = UserDefaults.standard.bool(forKey: "pinEnabled")
        self.isLocked = pinEnabled
    }

    /// Called from `UniAppApp`'s `.onChange(of: scenePhase)` with the
    /// new phase. Reads the auto-lock duration + pinEnabled flag from
    /// `UserDefaults` at call time so the controller doesn't need a
    /// View context for storage.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        let pinEnabled = UserDefaults.standard.bool(forKey: "pinEnabled")
        guard pinEnabled else {
            // No PIN configured: never lock.
            isLocked = false
            backgroundedAt = nil
            return
        }

        switch phase {
        case .background, .inactive:
            // Stamp the moment of departure. Only stamp once per
            // departure (multiple `.inactive` events during a single
            // background can fire; first one wins).
            if backgroundedAt == nil {
                backgroundedAt = Date()
                log.debug("Scene backgrounded at \(Date(), privacy: .public)")
            }
        case .active:
            if let stamp = backgroundedAt {
                let elapsed = Date().timeIntervalSince(stamp)
                let raw = UserDefaults.standard.integer(forKey: AutoLockPreference.storageKey)
                // `UserDefaults.integer(forKey:)` returns 0 for missing
                // keys — which is "lock immediately" semantically. To
                // honor the documented default of 30s when no value
                // has been written, check existence explicitly.
                let threshold: TimeInterval
                if UserDefaults.standard.object(forKey: AutoLockPreference.storageKey) == nil {
                    threshold = TimeInterval(AutoLockPreference.defaultValue)
                } else if let resolved = AutoLockPreference.resolvedDuration(raw) {
                    threshold = resolved
                } else {
                    // "Never" sentinel — don't lock on phase change.
                    backgroundedAt = nil
                    return
                }
                if elapsed >= threshold {
                    log.info("Auto-lock triggered after \(elapsed, privacy: .public)s (threshold \(threshold, privacy: .public)s)")
                    isLocked = true
                }
                backgroundedAt = nil
            }
        @unknown default:
            break
        }
    }

    /// Mark the wallet unlocked. Called by `AppLockView` after a
    /// successful PIN / biometric authentication.
    func unlock() {
        isLocked = false
        backgroundedAt = nil
    }

    /// Manually re-lock the wallet (e.g. a future "Lock now" button in
    /// Settings → Security). Idempotent.
    func lockNow() {
        guard UserDefaults.standard.bool(forKey: "pinEnabled") else { return }
        isLocked = true
    }
}

// MARK: - Environment plumbing

private struct AutoLockControllerKey: EnvironmentKey {
    /// `nonisolated(unsafe)` because `EnvironmentKey.defaultValue` is
    /// resolved in a non-MainActor context, but `AutoLockController`
    /// is `@MainActor`. The default value is only ever read in
    /// previews / contexts where the app root didn't inject a
    /// controller — production always overrides via `.environment(\.autoLockController, …)`
    /// in `UniAppApp.body`. `AutoLockController` is `Sendable`, so a
    /// plain `static let` is concurrency-safe without any annotation.
    static let defaultValue: AutoLockController = {
        MainActor.assumeIsolated { AutoLockController() }
    }()
}

extension EnvironmentValues {
    /// Wallet-home / Settings views read the shared controller via
    /// `@Environment(\.autoLockController)`. Injected at the app root
    /// in `UniAppApp.body` via `.environment(\.autoLockController, …)`.
    var autoLockController: AutoLockController {
        get { self[AutoLockControllerKey.self] }
        set { self[AutoLockControllerKey.self] = newValue }
    }
}
