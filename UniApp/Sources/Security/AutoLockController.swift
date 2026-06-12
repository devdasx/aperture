import SwiftUI
import OSLog

/// Tracks the app's `ScenePhase` transitions so the wallet home can
/// present the lock screen after the configured auto-lock duration of
/// inactivity. Only activates when the user has a PIN set
/// (`PinCodePreference.isPinEnabled()`); when PIN is disabled, this
/// controller stays idle and the wallet remains accessible whenever the
/// scene is active.
///
/// **Mechanism.** When the scene transitions to `.background`, capture
/// `Date()`. When the scene returns to `.active`, compare the elapsed
/// time against the stored auto-lock duration; if it exceeded the
/// threshold, set `isLocked = true`. The lock overlay window (see
/// `LockOverlayRoot` in `UniAppApp.swift`) renders `AppLockView` above
/// the untouched content tree while `isLocked` is true; the user
/// authenticates (PIN or biometric), and on success `isLocked` flips
/// back to `false` and the overlay fades away — the content underneath
/// keeps every bit of its navigation and presentation state.
///
/// **`.inactive` is NOT a departure (2026-06-13).** System UI — the
/// paste-permission prompt, the Face ID sheet, in-app alerts, Control
/// Center, notification pulls, app-switcher peeks — drives the scene
/// to `.inactive` without the app ever leaving the foreground.
/// Stamping the departure there armed the lock on every system prompt
/// when the timer was "Immediately": tapping Paste in the import flow
/// fired the passcode and threw the user out of the flow (user report
/// 2026-06-13). `.inactive` only feeds the privacy mask via
/// `isSceneActive`; the lock arms exclusively on a real `.background`
/// transition.
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

    /// Mirrors the scene's activation state for surfaces hosted outside
    /// the main window — the lock overlay window's `UIHostingController`
    /// does not receive `\.scenePhase` updates from the SwiftUI scene
    /// machinery, so the privacy mask reads this instead. `true` iff the
    /// most recently reported phase was `.active`.
    private(set) var isSceneActive: Bool = true

    /// `true` while the cold-launch splash is still the active surface.
    /// Flipped to `false` by `AppRoot`'s `onSplashComplete`. The lock
    /// overlay keeps `AppLockView` invisible while the splash plays, so
    /// a locked cold launch still shows the full splash animation before
    /// the passcode surface takes over.
    var isSplashActive: Bool = true

    /// When the scene most recently entered `.background`. Nil while the
    /// scene has not actually left the foreground — `.inactive` bounces
    /// (system prompts, Face ID sheets) never set this.
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
        isSceneActive = (phase == .active)

        let pinEnabled = UserDefaults.standard.bool(forKey: "pinEnabled")
        guard pinEnabled else {
            // No PIN configured: never lock.
            isLocked = false
            backgroundedAt = nil
            return
        }

        switch phase {
        case .background:
            // Stamp the moment the app actually left the foreground.
            // Only stamp once per departure (first one wins). The stamp
            // survives the `.inactive` hop on the way back to `.active`,
            // so elapsed time is measured from the real background entry.
            if backgroundedAt == nil {
                backgroundedAt = Date()
                log.debug("Scene backgrounded at \(Date(), privacy: .public)")
            }
        case .inactive:
            // Deliberately a no-op for the lock (see the type doc):
            // system prompts hold the scene `.inactive` without leaving
            // the app. Arming here would also let the unlock Face ID
            // prompt re-arm the very lock it is unlocking — its own
            // sheet bounces `.inactive`, never `.background`.
            break
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
