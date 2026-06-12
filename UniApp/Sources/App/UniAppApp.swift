import SwiftUI
import SwiftData
import TipKit

@main
struct UniAppApp: App {
    /// Shared auto-lock controller. Observes `ScenePhase` and flips
    /// `isLocked` after the configured idle threshold. Cold-launch
    /// initializes locked iff PIN is enabled. The wallet-home reads
    /// the controller via `@Environment(\.autoLockController)` and
    /// presents `AppLockView` as a `.fullScreenCover` over the entire
    /// UI when locked.
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
/// The v4 architecture is the apple-native single-root pattern
/// every banking app on the App Store uses: **exactly one of
/// splash / lock / home is mounted at any given time, picked by
/// SwiftUI's `if` / `else if` / `else`.** The wallet home isn't in
/// the view tree at all while the lock is visible. There is no
/// race because there is no view to flash.
///
/// SwiftUI's `.animation(_:value:)` on the wrapping container
/// crossfades the switch between branches — Apple's documented
/// pattern for state-driven UI swaps. Same primitive Apple Wallet,
/// Mail's "Mailboxes ↔ Account picker", and Settings' biometric
/// re-auth sheet all use.
///
/// **Phase machine simplified to one bool**: `isShowingSplash`.
/// The 3-state `AppPhase` enum (.splash / .transitioning /
/// .onboarding) is kept ONLY for the environment value that
/// descendant surfaces still read — populated from
/// `isShowingSplash ? .splash : .onboarding`. The `.transitioning`
/// middle state is gone because the if/else swap doesn't need it.
///
/// **MatchedGeometryEffect dropped.** The fancy splash→onboarding
/// logo morph was the reason the prior code had to mount both
/// views simultaneously. Per the user direction (*"not custom"*),
/// that's the trade — a clean state machine over a polished
/// element transition. The splash still renders its full
/// animation; the onboarding logo just fades in at its destination
/// position with a smooth spring instead of materializing from
/// the splash logo's frame.
///
/// **Privacy mask retained** as a separate overlay at the top of
/// the ZStack — its job (hide wallet content from the iOS task
/// switcher snapshot when scene is inactive) is orthogonal to
/// which screen is currently active.
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
    @Environment(\.scenePhase) private var scenePhase

    /// Live PIN-enabled flag. `@AppStorage` (2026-06-10) so the view
    /// re-evaluates reactively when the user enables / disables their
    /// PIN in Settings — the previous bare `UserDefaults` computed
    /// property only re-read on unrelated body invalidations, leaving
    /// the privacy-mask gate stale until something else redrew.
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
    /// protection enabled AND they haven't disabled the privacy
    /// mask in Settings.
    private var shouldShowPrivacyMask: Bool {
        pinEnabled && privacyMaskEnabled && scenePhase != .active
    }

    var body: some View {
        ZStack {
            // Single-active-surface root. Exactly one of splash /
            // lock / home is mounted. SwiftUI's
            // `.animation(_:value:)` below crossfades when the
            // discriminating state flips.
            activeSurface

            // Privacy mask — separate top layer, scene-phase
            // gated. Covers everything when scene goes inactive.
            //
            // **2026-06-09 — `.opacity` transition replaces
            // `.identity`.** Per user direction: *"it should
            // navigate also from this screen to pin code screen"*.
            // The mask now fades out as the scene becomes active,
            // revealing whatever `activeSurface` resolved to
            // underneath — which is `AppLockView` when
            // `isLocked == true` (set by `AutoLockController` while
            // the scene was inactive). The user reads a smooth
            // privacy → PIN navigation instead of an instant cut.
            // Insertion stays `.opacity` symmetric so the mask
            // fades IN on background too (no harsh snap).
            if shouldShowPrivacyMask {
                PrivacyMaskView()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        // 2026-06-09 v4 — `.smooth(duration: 0.55)` spring on each
        // state-discriminator. SwiftUI crossfades the if/else
        // branches via the default `.opacity` transition; the
        // spring controls the timing. Splash → lock / home: one
        // value-driven animation. Lock → home: another.
        .animation(.smooth(duration: 0.55), value: isShowingSplash)
        .animation(.smooth(duration: 0.55), value: lockController.isLocked)
        // Privacy mask fade duration — slightly tighter than the
        // splash/lock springs (0.35s vs 0.55s) so the privacy → PIN
        // handoff feels prompt without being abrupt.
        .animation(.easeInOut(duration: 0.35), value: shouldShowPrivacyMask)
        // Publish the simplified phase so descendant surfaces
        // still see `.splash` / `.onboarding` as before. The
        // `.transitioning` middle state is gone.
        .environment(\.appPhase, isShowingSplash ? .splash : .onboarding)
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
                }
            )
            .transition(.opacity)
        } else if lockController.isLocked {
            AppLockView()
                .uniAppEnvironment()
                .transition(.opacity)
        } else {
            RootGate(logoNamespace: logoNamespace, phase: .onboarding)
                .transition(.opacity)
        }
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
