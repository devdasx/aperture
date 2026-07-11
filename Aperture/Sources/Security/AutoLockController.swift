import SwiftUI
import OSLog

/// Tracks the app's `ScenePhase` transitions so the wallet home can
/// present the lock screen after the configured auto-lock duration of
/// inactivity. Only activates when the user has PIN protection set
/// (the preference flag or the actual `PinCodeStorage` material); when PIN is disabled, this
/// controller stays idle and the wallet remains accessible whenever the
/// scene is active.
///
/// **Mechanism.** When the scene transitions to `.background`, capture
/// `Date()`. When the scene returns to `.active`, compare the elapsed
/// time against the stored auto-lock duration; if it exceeded the
/// threshold, set `isLocked = true`. The lock is an **overlay-only**
/// surface (`LockOverlayRoot` in `ApertureApp.swift`): `AppLockView`
/// sits in a dedicated `UIWindow` above the untouched content tree.
/// The content underneath is never unmounted; unlock fades the overlay
/// and restores the exact navigation/presentation state.
///
/// **`.inactive` is NOT a departure (2026-06-13).** System UI — the
/// paste-permission prompt, biometric sheets, in-app alerts, Control
/// Center, notification pulls, app-switcher peeks — drives the scene
/// to `.inactive` without the app ever leaving the foreground.
/// Stamping the departure there armed the lock on every system prompt
/// when the timer was "Immediately". `.inactive` only updates
/// `isSceneActive` (used by the overlay to dim / show a privacy
/// blur while system UI is up); the lock arms exclusively on a real
/// `.background` transition.
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

    /// Mirrors the scene's activation state for the **lock overlay
    /// window** (it does not receive `\.scenePhase` from the main scene).
    /// Used to show a privacy blur while inactive; not a separate full
    /// lock. `true` iff the most recently reported phase was `.active`.
    private(set) var isSceneActive: Bool = true

    /// `true` while the cold-launch splash is still the active surface.
    /// Flipped to `false` by `AppRoot`'s `onSplashComplete`. The lock
    /// overlay keeps `AppLockView` invisible while the splash plays, so
    /// a locked cold launch still shows the full splash animation before
    /// the passcode surface takes over.
    var isSplashActive: Bool = true

    /// When the scene most recently entered `.background`. Nil while the
    /// scene has not actually left the foreground — `.inactive` bounces
    /// (system prompts, biometric sheets) never set this.
    private var backgroundedAt: Date?

    private let log = Logger(subsystem: "com.thuglife.aperture", category: "auto-lock")

    init() {
        // Cold launch: locked iff PIN is set.
        let pinEnabled = PinCodePreference.isPinEnabled()
        self.isLocked = pinEnabled
    }

    /// Called after app bootstrap, once GRDB preferences are configured.
    /// `AutoLockController` is created as SwiftUI `@State` before
    /// `ApertureApp.init()` completes, so an initial preference read can
    /// legitimately observe the default. The actual PIN material is the
    /// authoritative security source: if either the flag or PIN blobs exist,
    /// a fresh launch must require unlock.
    func refreshLaunchLockState() {
        guard isPinProtectionActive() else {
            isLocked = false
            backgroundedAt = nil
            return
        }
        isLocked = true
    }

    /// Called from `ApertureApp`'s `.onChange(of: scenePhase)` with the
    /// new phase. Reads the auto-lock duration + current PIN-protection state
    /// from GRDB at call time so the controller doesn't need a View context.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        isSceneActive = (phase == .active)

        guard isPinProtectionActive() else {
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
            }
        case .inactive:
            // Deliberately a no-op for the lock (see the type doc):
            // system prompts hold the scene `.inactive` without leaving
            // the app. Arming here would also let the unlock biometric
            // prompt re-arm the very lock it is unlocking — its own
            // sheet bounces `.inactive`, never `.background`.
            break
        case .active:
            if let stamp = backgroundedAt {
                let elapsed = Date().timeIntervalSince(stamp)
                let raw = AppPreferenceStore.shared.int(
                    AutoLockPreference.storageKey,
                    default: AutoLockPreference.defaultValue
                )
                // The preference store returns the documented default
                // when no row has been written.
                let threshold: TimeInterval
                if let resolved = AutoLockPreference.resolvedDuration(raw) {
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
        guard isPinProtectionActive() else { return }
        isLocked = true
    }

    private func isPinProtectionActive() -> Bool {
        PinCodePreference.isPinEnabled() || PinCodeStorage.hasPin
    }
}

// MARK: - Environment plumbing

private struct AutoLockControllerKey: EnvironmentKey {
    /// Production always injects a real controller in `ApertureApp.body`.
    /// This default is for previews / incomplete trees only.
    ///
    /// P3-005: never `MainActor.assumeIsolated` unconditionally — that
    /// traps if `defaultValue` is first touched off the main actor.
    /// Hop to main safely instead (deadlock-free when already on main).
    static let defaultValue: AutoLockController = {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { AutoLockController() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { AutoLockController() }
        }
    }()
}

extension EnvironmentValues {
    /// Wallet-home / Settings views read the shared controller via
    /// `@Environment(\.autoLockController)`. Injected at the app root
    /// in `ApertureApp.body` via `.environment(\.autoLockController, …)`.
    var autoLockController: AutoLockController {
        get { self[AutoLockControllerKey.self] }
        set { self[AutoLockControllerKey.self] = newValue }
    }
}
