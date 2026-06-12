import SwiftUI
import SwiftData
import TipKit
// UIKit is imported ONLY for the detached lock-overlay `UIWindow` +
// `UIHostingController` (see `AppRoot.mountLockOverlayWindowIfNeeded`).
// Rule #12 §B item 5 names a detached `UIWindow` as a legitimate
// presentation surface; there is no SwiftUI-native way to layer the
// privacy mask / lock above presented sheets and fullScreenCovers.
import UIKit

@main
struct UniAppApp: App {
    /// Shared auto-lock controller. Observes `ScenePhase` and flips
    /// `isLocked` after the configured idle threshold (measured from a
    /// real `.background` entry — `.inactive` bounces from system
    /// prompts never arm it). Cold-launch initializes locked iff PIN is
    /// enabled. The detached lock overlay window (see `LockOverlayRoot`
    /// below) renders `AppLockView` above the untouched content tree
    /// while locked — content navigation and presented sheets/covers
    /// survive a lock/unlock cycle intact.
    @State private var lockController = AutoLockController()

    @Environment(\.scenePhase) private var scenePhase


    /// App-launch initialization in dependency order. Runs synchronously
    /// from `init()` so every subsystem is warm before `WindowGroup`
    /// renders its first frame — the wallet screen's `@Query` reads
    /// resolve against an already-open SwiftData store, biometric drift
    /// has already been checked, and the device's natural currency is
    /// already seeded into `UserDefaults`. This is what makes "zero
    /// latency on open" honest rather than aspirational.
    ///
    /// **Order matters:**
    /// 1. Preference bootstrap (Locale-driven currency seed).
    /// 2. SwiftData container open + row bootstrap (AppMetadata + biometric).
    ///
    /// The biometric enrollment drift check is intentionally NOT here
    /// (2026-06-10): it performs blocking Keychain / LocalAuthentication
    /// I/O, and running it synchronously in `init()` stalled the first
    /// frame. It now runs from the root view's `.task` — after the
    /// first frame is on screen, before any biometric-gated surface
    /// can realistically be reached.
    init() {
        // 0) Fresh-install guard. iOS Keychain items survive app
        //    deletion by default; without this call a user who
        //    deletes Aperture and re-installs would see their old
        //    wallets, PIN hash, and seed manifest come back — which
        //    breaks the Rule #16 §A.5 contract ("your wallet only
        //    lives on this iPhone"). The guard checks a
        //    `UserDefaults` marker (which IS wiped on uninstall);
        //    if it's missing we delete every Keychain item under
        //    our known service identifiers. Runs BEFORE every other
        //    bootstrap call so vaults read against a known-empty
        //    Keychain on first launch after install.
        FreshInstallGuard.purgeKeychainIfFreshInstall()

        // 1) Locale-driven currency seed (Rule #16 — the user's iPhone
        //    configuration is the wallet's first impression).
        CurrencyPreference.bootstrapIfNeeded()

        // 2) SwiftData container — synchronous open. `shared` is a
        //    `static let`; first access constructs the container and
        //    opens the SQLite file. `bootstrap()` then writes the
        //    singleton AppMetadata + BiometricEnrollment rows on first
        //    install (idempotent on subsequent launches).
        ApertureDatabase.shared.bootstrap()

        // 3) TipKit data store for first-time-feature hints. The
        //    `WalletTabSwitcherTip` reads its eligibility rule against
        //    `MainTabView`'s `@Query` wallet count, then iOS 17+
        //    `TipKit` owns the popover chrome, the dismiss
        //    persistence, the accessibility tree. `.immediate` means
        //    a tip presents as soon as its `#Rule`s evaluate true;
        //    `.applicationDefault` data store lives in the app
        //    sandbox alongside SwiftData. Tip dismissals persist
        //    across launches — the *"only for first time"* contract.
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
        ])
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .uniAppEnvironment()
                // SwiftData injection per Rule #2 §C. Every descendant view
                // can now use `@Query`, `@Environment(\.modelContext)`, and
                // the `@ModelActor` repositories share the same store.
                .modelContainer(ApertureDatabase.shared.container)
                // Inject the shared auto-lock controller into the
                // environment so `WalletHomeView` can read its `isLocked`
                // flag and present `AppLockView` as a `.fullScreenCover`.
                .environment(\.autoLockController, lockController)
                .onChange(of: scenePhase) { _, newPhase in
                    lockController.handleScenePhaseChange(newPhase)
                }
                // Biometric drift detection per user direction
                // 2026-06-06. If the user changed their Face ID
                // enrollment in iOS Settings since their last
                // successful Aperture biometric authentication, flips
                // `biometricEnabled` to `false` and sets
                // `requiresBiometricReenrollment` so the next
                // biometric-gated surface knows to re-prompt.
                // Runs in `.task` (after the first frame) instead of
                // `App.init()` because the check does blocking
                // Keychain I/O (2026-06-10).
                .task {
                    BiometricEnrollmentTracker.checkForDrift(
                        in: ApertureDatabase.shared.container
                    )
                }
        }
    }
}

// MARK: - AppRoot

/// Root composition that orchestrates the splash → onboarding
/// shared-element logo transition per the 2026-06-07
/// `design_handoff_splash_to_onboarding/` spec.
///
/// **Why this view exists.** The previous architecture had
/// `UniAppApp` swap `SplashView` for `RootGate` via a `hasFinishedSplash`
/// flag. That meant the two views never coexisted in one view
/// hierarchy. SwiftUI's `matchedGeometryEffect` is the canonical
/// shared-element animation primitive, but it requires both the
/// source and destination views to share a `@Namespace` in the SAME
/// tree. So we restructure: `AppRoot` owns the namespace + the
/// 3-phase state machine, renders both children in a `ZStack`, and
/// flips the phase via `withAnimation(.timingCurve(0.52, 0, 0.12, 1,
/// duration: 0.82))` — which is the exact curve the handoff names.
///
/// **The state machine:**
/// - `.splash` — initial cold-launch state. Splash visible on top;
///   onboarding (via `RootGate`) mounted underneath but invisible.
/// - `.transitioning` — fired when the splash's existing
///   `splashDuration` timer completes. Logo's
///   `matchedGeometryEffect` resolves to its onboarding frame over
///   0.82s; splash chrome (wordmark, tagline, loader, glow) fades
///   out over ~0.35s; onboarding content fades in with staggered
///   delays driven by the same `phase` change. At t+0.82s the
///   haptic fires on logo landing.
/// - `.onboarding` — splash chrome fully unmounted. Onboarding is
///   the only interactive surface. `RootGate`'s reactive
///   `@Query` continues to handle the wallet/no-wallet route.
/// **2026-06-09 v4 — rebuilt from scratch.** The user reported
/// repeatedly seeing the wallet home flash between splash and lock
/// even after the v2 (lock-mount-during-transitioning) and v3
/// (scale motion) fixes. Their direction was unambiguous:
/// *"build it from scratch ... make real & native, not custom."*
///
/// **What changed.** The prior `AppRoot` mounted EVERYTHING in a
/// `ZStack` at all times — `RootGate`, lock, splash, privacy mask —
/// then used `if`/`zIndex` to control which was visible. That's
/// the kind of "custom" architecture the user named: the wallet
/// home was always alive underneath every other surface, which
/// means every off-by-a-frame timing bug in SwiftUI's transition
/// pipeline could let it peek through.
///
/// The v4 architecture was the single-root pattern: **exactly one of
/// splash / lock / home mounted at any given time, picked by
/// SwiftUI's `if` / `else if` / `else`.** That eliminated the
/// "wallet home flashes between splash and lock" race — but it
/// created a worse one (2026-06-13 user reports): every lock
/// REPLACED the content tree, so unlocking rebuilt `RootGate` from
/// scratch — every `NavigationStack` reset, every presented
/// `fullScreenCover` (the import flow!) dismissed. A paste-
/// permission prompt with the "Immediately" timer dumped the user
/// from the recovery-phrase entry back to the main screen.
///
/// **v5 (2026-06-13) — lock + privacy mask move to a detached
/// overlay `UIWindow`.** The content branch (`splash` ⟷ `RootGate`)
/// is the ONLY thing this view mounts; it is never unmounted by a
/// lock. `AppLockView` + `PrivacyMaskView` render in their own
/// `UIWindow` (`LockOverlayRoot`) layered above the main window.
/// Why a window and not a ZStack layer: sheets and fullScreenCovers
/// present ABOVE the root view's ZStack — a ZStack-layer lock would
/// be invisible behind the import/create covers, and the app-switcher
/// snapshot would leak whatever the cover showed. The overlay window
/// covers everything, and the content tree (including presentations)
/// survives untouched underneath. Unlock = the overlay fades out;
/// nothing else changes.
///
/// **No flash risk either way:** `AppLockView` owns an opaque
/// background, mounts instantly (no insertion transition) beneath
/// the privacy mask, and stays transparent until the splash
/// finishes — so neither the splash nor the home can peek through.
///
/// **Phase machine stays one bool**: `isShowingSplash`. The 3-state
/// `AppPhase` enum (.splash / .transitioning / .onboarding) is kept
/// ONLY for the environment value that descendant surfaces still
/// read — populated from `isShowingSplash ? .splash : .onboarding`.
///
/// **MatchedGeometryEffect dropped** (v4 decision, unchanged). The
/// splash still renders its full animation; the onboarding logo just
/// fades in at its destination position with a smooth spring.
private struct AppRoot: View {
    /// Kept for `SplashView`'s constructor signature. The matched
    /// geometry pairing it powered (with `OnboardingView`'s logo)
    /// is no longer in use; the splash logo just animates within
    /// the splash surface.
    @Namespace private var logoNamespace

    /// The one source of truth for "are we still on the splash."
    /// Flipped false by `SplashView`'s `onSplashComplete` callback
    /// once the splash's internal animations finish.
    @State private var isShowingSplash: Bool = true

    @Environment(\.autoLockController) private var lockController

    /// The detached overlay window hosting `PrivacyMaskView` +
    /// `AppLockView` above the main window (see the type doc for why
    /// this is a window, not a ZStack layer). Created once, on first
    /// appear, and kept for the app's lifetime. Always visible —
    /// `LockOverlayRoot` renders nothing (fully transparent) when
    /// there's nothing to show; touch passthrough is handled by
    /// toggling `isUserInteractionEnabled` in `syncLockOverlay()`.
    @State private var lockOverlayWindow: UIWindow?

    /// `true` whenever the lock surface is interactive on screen —
    /// the overlay window must swallow touches exactly then, and
    /// pass them through to the content window otherwise.
    private var isLockSurfaceVisible: Bool {
        !isShowingSplash && lockController.isLocked
    }

    var body: some View {
        ZStack {
            // Content root: splash, then `RootGate` — and nothing
            // else, ever. The lock no longer replaces this tree; it
            // overlays it from the detached window, so every
            // NavigationStack, sheet, and fullScreenCover survives a
            // lock/unlock cycle (2026-06-13 fix).
            activeSurface
        }
        // `.smooth(duration: 0.55)` spring on the splash → content
        // crossfade. SwiftUI crossfades the if/else branches via the
        // default `.opacity` transition; the spring controls timing.
        .animation(.smooth(duration: 0.55), value: isShowingSplash)
        // Publish the simplified phase so descendant surfaces
        // still see `.splash` / `.onboarding` as before. The
        // `.transitioning` middle state is gone.
        .environment(\.appPhase, isShowingSplash ? .splash : .onboarding)
        .onAppear {
            mountLockOverlayWindowIfNeeded()
        }
        .onChange(of: isLockSurfaceVisible) { _, visible in
            syncLockOverlay(lockVisible: visible)
        }
    }

    @ViewBuilder
    private var activeSurface: some View {
        if isShowingSplash {
            SplashView(
                logoNamespace: logoNamespace,
                phase: .splash,
                onSplashComplete: {
                    // **2026-06-10 handoff signature.** Splash →
                    // home is the irisSettle moment (per the
                    // handoff: "Logo lands in onboarding (splash
                    // hand-off)"). Fires the soft-tick → medium-tap
                    // pattern, gated by UniHapticEngine for both
                    // AppStorage opt-out and Reduce Motion.
                    UniHapticEngine.shared.play(.signature(.irisSettle))
                    isShowingSplash = false
                    // Let the lock overlay take over: on a locked
                    // cold launch `AppLockView` becomes visible the
                    // instant the splash hands off (opaque, no
                    // fade-in — so the splash → home crossfade
                    // running underneath can never peek through).
                    lockController.isSplashActive = false
                }
            )
            .transition(.opacity)
        } else {
            RootGate(logoNamespace: logoNamespace, phase: .onboarding)
                .transition(.opacity)
        }
    }

    // MARK: - Lock overlay window plumbing

    /// Creates the overlay window on the app's `UIWindowScene`. The
    /// window hosts `LockOverlayRoot` with the same environment the
    /// main window gets: the shared lock controller, the SwiftData
    /// container (`AppLockView` captures a biometric snapshot after a
    /// successful unlock), and `.uniAppEnvironment()` per Rule #12 §B
    /// item 5 (a detached `UIWindow` is a presentation surface).
    private func mountLockOverlayWindowIfNeeded() {
        guard lockOverlayWindow == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else { return }

        let host = UIHostingController(
            rootView: LockOverlayRoot()
                .environment(\.autoLockController, lockController)
                .modelContainer(ApertureDatabase.shared.container)
                .uniAppEnvironment()
        )
        // The hosting view must be transparent — `UIHostingController`
        // defaults to an opaque `systemBackground` that would black
        // out the whole app underneath.
        host.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        // Above the main window AND above anything presented inside
        // it (sheets, covers, alerts all live in the main window's
        // presentation hierarchy — window *level* outranks them all).
        window.windowLevel = .alert + 1
        window.isHidden = false
        window.isUserInteractionEnabled = isLockSurfaceVisible
        lockOverlayWindow = window
    }

    /// Touch routing for the always-mounted overlay window. iOS skips
    /// windows with `isUserInteractionEnabled == false` during
    /// hit-testing, so when nothing is locked the transparent overlay
    /// is invisible to touches and the content window behaves exactly
    /// as if the overlay didn't exist.
    private func syncLockOverlay(lockVisible: Bool) {
        lockOverlayWindow?.isUserInteractionEnabled = lockVisible
        guard lockVisible, let scene = lockOverlayWindow?.windowScene else { return }
        // Drop any active text focus in the content window the moment
        // the lock lands. The keyboard lives in its own system window
        // ABOVE the overlay; leaving a field focused would keep the
        // keyboard floating over the lock and let key taps reach a
        // hidden input while locked.
        for contentWindow in scene.windows where contentWindow !== lockOverlayWindow {
            contentWindow.endEditing(true)
        }
    }
}

// MARK: - Lock overlay root

/// Root view of the detached lock overlay window. Two layers, both
/// optional, both above EVERYTHING in the main window (including
/// presented sheets and fullScreenCovers — the reason this lives in
/// its own window at all):
///
/// 1. **`AppLockView`** — mounted while `AutoLockController.isLocked`.
///    Inserts instantly (it lands beneath the privacy mask on a
///    background-return, and stays transparent until the splash hands
///    off on a locked cold launch); fades out over the standard
///    0.55s smooth spring on unlock, revealing the untouched content
///    tree underneath.
/// 2. **`PrivacyMaskView`** — the task-switcher snapshot shield.
///    Mounted whenever the scene isn't `.active` (mirrored through
///    `AutoLockController.isSceneActive`, since `\.scenePhase` does
///    not propagate into a hand-mounted `UIHostingController`), the
///    user has a PIN, and the mask preference is on. Showing the mask
///    on `.inactive` is deliberate and correct — the snapshot is taken
///    from that state; it's the LOCK that must wait for `.background`
///    (see `AutoLockController.handleScenePhaseChange`).
private struct LockOverlayRoot: View {
    @Environment(\.autoLockController) private var lockController

    /// Live PIN-enabled flag — reactive so enabling / disabling the
    /// PIN in Settings flips the mask gate immediately.
    @AppStorage(PinCodePreference.pinEnabledKey)
    private var pinEnabled: Bool = PinCodePreference.defaultValue

    /// User preference — Settings → Preferences → "Privacy mask".
    /// Default ON. When OFF, the privacy mask never mounts, and the
    /// scene's last-active frame becomes the task-switcher snapshot
    /// — explicit opt-out the user can flip in Settings.
    @AppStorage(PrivacyMaskPreference.storageKey)
    private var privacyMaskEnabled: Bool = PrivacyMaskPreference.defaultValue

    /// `true` whenever the privacy mask should be on screen — any
    /// time the scene isn't fully active AND the user has PIN
    /// protection enabled AND they haven't disabled the privacy mask
    /// in Settings. Suppressed during the splash: there's nothing
    /// sensitive to shield yet, and a launch-time `.inactive` beat
    /// would otherwise flash the mask over the splash animation.
    private var isMaskVisible: Bool {
        pinEnabled && privacyMaskEnabled
            && !lockController.isSceneActive
            && !lockController.isSplashActive
    }

    var body: some View {
        ZStack {
            if lockController.isLocked {
                AppLockView()
                    // Invisible while the splash plays — a locked cold
                    // launch shows the full splash first, then the
                    // lock snaps in opaque at the handoff beat (no
                    // crossfade shimmer of the home underneath).
                    .opacity(lockController.isSplashActive ? 0 : 1)
                    // Insert instantly; fade ONLY on unlock. An
                    // animated insertion would let the content shine
                    // through a half-opaque lock for half a second.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }

            // Privacy mask — top layer, scene-phase gated.
            //
            // **2026-06-09 — `.opacity` transition.** The mask fades
            // out as the scene becomes active, revealing whatever is
            // underneath — `AppLockView` when a real background
            // period exceeded the auto-lock threshold. The user reads
            // a smooth privacy → PIN navigation instead of an instant
            // cut. Insertion stays `.opacity` symmetric so the mask
            // fades IN on backgrounding too (no harsh snap).
            if isMaskVisible {
                PrivacyMaskView()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        // Unlock fade — same 0.55s smooth spring the splash → content
        // crossfade uses, so the lock's exit reads as one system.
        .animation(.smooth(duration: 0.55), value: lockController.isLocked)
        // Privacy mask fade — slightly tighter (0.35s vs 0.55s) so
        // the privacy → PIN handoff feels prompt without being abrupt.
        .animation(.easeInOut(duration: 0.35), value: isMaskVisible)
    }
}

// MARK: - AppPhase

/// Three-state machine for the splash → onboarding orchestration.
/// Consumed by `AppRoot`, `SplashView`, and the onboarding
/// composition to drive matchedGeometryEffect + staggered fades.
///
/// Also published into the SwiftUI environment as `\.appPhase` so
/// returning-user surfaces (`WalletHomeView`) can suppress UI that
/// would otherwise race the splash to the screen — the
/// `AppLockView` `.fullScreenCover` is the canonical example:
/// without gating, it promotes itself to the window level and
/// renders above the splash before the splash's animation
/// completes (user report 2026-06-07).
enum AppPhase: Equatable {
    /// Initial cold-launch state. Splash is the active surface.
    case splash
    /// Logo flying to onboarding frame; splash chrome fading;
    /// onboarding content staggering in. Lasts ~0.82s.
    case transitioning
    /// Splash unmounted; onboarding (or wallet home) fully
    /// interactive. The post-splash steady state.
    case onboarding
}

// MARK: - Environment plumbing

/// Environment key carrying the live `AppPhase` from `AppRoot` to
/// every descendant view. Default `.onboarding` so previews and
/// any non-`AppRoot` host (test harnesses, isolated `#Preview`
/// blocks) behave as if the splash has already finished — they
/// would otherwise inherit a `.splash` default and inadvertently
/// suppress every phase-gated surface.
private struct AppPhaseEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppPhase = .onboarding
}

extension EnvironmentValues {
    var appPhase: AppPhase {
        get { self[AppPhaseEnvironmentKey.self] }
        set { self[AppPhaseEnvironmentKey.self] = newValue }
    }
}

// `RootGate` itself lives in `Features/Wallet/WalletHomeView.swift`
// where it is the closest sibling of `WalletHomeView` (the gate's
// secondary branch) and `OnboardingView` (the gate's primary
// branch). The gate's signature now accepts `logoNamespace + phase`
// so `AppRoot` can plumb both through.
