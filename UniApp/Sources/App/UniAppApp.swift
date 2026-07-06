import SwiftUI
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
    /// renders its first frame — the wallet screen's database reads
    /// resolve against an already-open SQLite store, biometric drift
    /// has already been checked, and the device's natural currency is
    /// already seeded into GRDB. This is what makes "zero
    /// latency on open" honest rather than aspirational.
    ///
    /// **Order matters:**
    /// 1. Preference bootstrap (Locale-driven currency seed).
    /// 2. SQLite database open + row bootstrap.
    ///
    /// The biometric enrollment drift check is intentionally NOT here
    /// (2026-06-10): it performs blocking biometric LocalAuthentication
    /// I/O, and running it synchronously in `init()` stalled the first
    /// frame. It now runs from the root view's `.task` — after the
    /// first frame is on screen, before any biometric-gated surface
    /// can realistically be reached.
    init() {
        let appInitStart = Date()
        Self.diagnostic(.info, "App init started")

        // 0) Fresh-install guard. iOS Keychain items survive app
        //    deletion by default; without this call a user who
        //    deletes Aperture and re-installs would see their old
        //    legacy wallet/security compatibility items come back — which
        //    breaks the Rule #16 §A.5 contract ("your wallet only
        //    lives on this iPhone"). The guard checks for a local
        //    GRDB store file; if it's missing we delete every legacy Keychain item under
        //    our known service identifiers. Runs BEFORE every other
        //    bootstrap call so legacy compatibility state is known-empty on
        //    first launch after install.
        let freshInstallStart = Date()
        FreshInstallGuard.purgeKeychainIfFreshInstall()
        Self.diagnostic(.debug, "Fresh-install guard finished", start: freshInstallStart)

        // 0.5) Last-screen restoration resolve (2026-06-13). Reads the
        //    "user left the app at T" stamp written on every real
        //    `.background` entry (see `AutoLockController`). Away for
        //    < 2 minutes → the persisted tab + NavigationStack paths
        //    are left in place and the restorable views consume them
        //    at init; ≥ 2 minutes → paths cleared and the selected tab
        //    reset to the wallet tab, so the user starts at the main
        //    screen. Must run before `WindowGroup` constructs the
        //    first view tree — `SettingsView` / `WalletHomeView` read
        //    the persisted paths in their `init`s.
        let restorationStart = Date()
        ScreenRestoration.resolveOnLaunch()
        Self.diagnostic(.debug, "Screen restoration resolved", start: restorationStart)

        // 1) Locale-driven currency seed (Rule #16 — the user's iPhone
        //    configuration is the wallet's first impression).
        let currencyStart = Date()
        CurrencyPreference.bootstrapIfNeeded()
        Self.diagnostic(.debug, "Currency preference bootstrapped", start: currencyStart)

        // 2) SQLite database — synchronous open. `shared` is a
        //    `static let`; first access opens the SQLite file.
        let databaseStart = Date()
        AppDatabase.shared.bootstrap()
        Self.diagnostic(.debug, "Database bootstrap requested", start: databaseStart)

        Self.diagnostic(.info, "App init finished", start: appInitStart)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .uniAppEnvironment()
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
                // `App.init()` because the check can perform blocking
                // LocalAuthentication work (2026-06-10).
                .task {
                    let startupTaskStart = Date()
                    Self.diagnostic(.info, "Root startup task started")
                    await TokenPricingEngine.shared.configure(database: AppDatabase.shared)
                    BiometricEnrollmentTracker.checkForDrift(database: AppDatabase.shared)
                    Self.diagnostic(.debug, "Biometric drift check finished")
                    // Data fetching is disabled for some chains (2026-06-21 —
                    // EVM + Bitcoin family + Tron) — clear any balances /
                    // history / UTXOs persisted before the cutover. One-shot,
                    // off the first frame, self-gated.
                    await Task.detached(priority: .utility) {
                        await DisabledChainDataPurge.runIfNeeded(database: AppDatabase.shared)
                    }.value
                    await PendingTransactionMonitor.shared.kick(database: AppDatabase.shared)
                    Self.diagnostic(.info, "Root startup task finished", start: startupTaskStart)
                }
        }
        // The app fills the screen natively on iPad (full-screen) and the
        // Mac "Designed for iPad" window resizes freely — we do NOT pin a
        // content size or a phone-shaped default size: `.windowResizability
        // (.contentSize)` + a 440-wide `.defaultSize` locked the iPad/Mac
        // window to a blown-up-iPhone column instead of the full canvas
        // (2026-06-16 fix). The "real iPad app" sizing is handled in the
        // content layer instead — `.sidebarAdaptable` nav at regular width
        // and a centered max-width column cap on the wallet surface — so the
        // window itself is free to fill the display. `UIApplicationSupports
        // MultipleScenes` stays `false` (the lock-overlay UIWindow assumes a
        // single scene).
    }

    private static func diagnostic(
        _ level: DiagnosticsLogLevel,
        _ message: String,
        start: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        var metadata = metadata
        if let start {
            metadata["elapsedMs"] = DiagnosticsLogStore.elapsedMilliseconds(since: start)
        }
        DiagnosticsLogStore.shared.record(
            level,
            category: "launch",
            message: message,
            metadata: metadata
        )
    }
}

// MARK: - AppRoot

/// Root composition that orchestrates the splash → onboarding
/// shared-element logo transition per the 2026-06-07
/// `design_handoff_splash_to_onboarding/` spec.
///
/// **Why this view exists.** The previous architecture had
/// `UniAppApp` replace `SplashView` with `RootGate` via a `hasFinishedSplash`
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
///   GRDB observation continues to handle the wallet/no-wallet route.
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
/// **v5 (2026-06-13) — the lock moves to a detached overlay
/// `UIWindow`.** The content branch (`splash` ⟷ `RootGate`)
/// is the ONLY thing this view mounts; it is never unmounted by a
/// lock. `AppLockView` renders in its own `UIWindow`
/// (`LockOverlayRoot`) layered above the main window.
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

    /// Language code feeding the Rule #12 §G direction-only rebuild
    /// key — extended on 2026-06-13 from sheet contents to the WHOLE
    /// content tree. See `rootDirectionKey`.
    @GRDBStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

    @Environment(\.autoLockController) private var lockController

    /// Drives the lock overlay's scene-phase handling (see the
    /// `onChange(of: scenePhase)` above).
    @Environment(\.scenePhase) private var scenePhase

    /// The detached overlay window hosting `AppLockView` above the main
    /// window (see the type doc for why
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

    /// Rule #12 §G direction-only rebuild key, applied to the WHOLE
    /// content tree (2026-06-13). The app root binds
    /// `\.layoutDirection` live via `.uniAppEnvironment()`, but every
    /// UIKit-backed host inside (`NavigationStack` bars, `List`s, the
    /// `TabView`) latches its `semanticContentAttribute` at creation —
    /// the exact phenomenon Rule #12 §F documents for sheets. Without
    /// a rebuild, switching Arabic → English left the app MIRRORED
    /// (English text right-aligned, chevrons on the wrong side) until
    /// a restart. Keying `RootGate` on the resolved direction tears
    /// the content tree down and rebuilds it the instant the user
    /// crosses the LTR ↔ RTL boundary — live, no app restart, per the
    /// user's 2026-06-13 direction ("it should rebuild the whole app
    /// in real way"). Same-direction language changes (en → es) keep
    /// the same key and propagate reactively, preserving navigation
    /// state — Rule #12 §G's reasoning, applied at the root.
    ///
    /// **Why the key sits on `RootGate`, not on `AppRoot` itself.**
    /// `AppRoot`'s own `@State` must survive the flip: re-keying
    /// `AppRoot` would replay the splash (`isShowingSplash` resets)
    /// and orphan + duplicate the detached lock-overlay `UIWindow`
    /// (its handle lives in `lockOverlayWindow`). The user-visible
    /// app IS `RootGate`'s subtree; that is what rebuilds.
    ///
    /// **Where the user lands after the flip.** The selected tab
    /// survives (`@GRDBStorage`), and the wallet-home / Settings
    /// navigation paths are re-consumed from `ScreenRestoration`'s
    /// continuous mirror — so the Choose-language screen survives its
    /// own direction flip and re-renders correctly, instantly, in the
    /// new direction. Presented sheets and covers are dismissed by
    /// the rebuild (their presenters die) — acceptable for a
    /// deliberate global language change.
    private var rootDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
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
            syncLockOverlay(lockVisible: isLockSurfaceVisible)
        }
        .onChange(of: isLockSurfaceVisible) { _, visible in
            syncLockOverlay(lockVisible: visible)
        }
        // App-wide Reset Aperture (design_handoff_reset) — presented HERE, at
        // the app root above `RootGate`, NOT from the Settings tab. That's what
        // lets the erasing→factory-fresh morph survive the wipe: once the wipe
        // empties the wallets, `RootGate` replaces `MainTabView` with onboarding
        // underneath, but this cover stays on top showing the morph until the
        // user taps "Get Started", which dismisses it onto the fresh onboarding.
        .fullScreenCover(isPresented: Binding(
            get: { ResetFlowGate.shared.isPresenting },
            set: { ResetFlowGate.shared.isPresenting = $0 }
        )) {
            ResetApertureFlow(onClose: { ResetFlowGate.shared.isPresenting = false })
                .id(rootDirectionKey)
                .uniAppEnvironment()
        }
    }

    @ViewBuilder
    private var activeSurface: some View {
        if isShowingSplash {
            SplashView(
                logoNamespace: logoNamespace,
                phase: .splash,
                onSplashComplete: {
                    // Do not start Core Haptics during cold launch. iOS can
                    // still be attaching audio/keyboard services at this
                    // point, and booting a CHHapticEngine here produces
                    // AudioConverterService console noise on real devices and
                    // simulators. User-initiated haptics stay lazy.
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
                // Direction-keyed identity (Rule #12 §G at the root —
                // see `rootDirectionKey`'s doc). The key only changes
                // on an LTR ↔ RTL flip, so the rebuild never fires for
                // theme or same-direction language changes. The replacement
                // is instant: the `.animation` above is keyed on
                // `isShowingSplash`, which doesn't change here.
                .id(rootDirectionKey)
                .transition(.opacity)
        }
    }

    // MARK: - Lock overlay window plumbing

    /// Creates the overlay window on the app's `UIWindowScene`. The
    /// window hosts `LockOverlayRoot` with the same environment the
    /// main window gets: the shared lock controller and
    /// `.uniAppEnvironment()` per Rule #12 §B
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
        guard let overlayWindow = lockOverlayWindow,
              let scene = overlayWindow.windowScene
        else { return }

        overlayWindow.isUserInteractionEnabled = lockVisible

        if lockVisible {
            // The native keyboard can only attach to a first responder
            // inside the key window. The lock surface is hosted in this
            // detached overlay window, so it must become key while the
            // passcode UI is interactive.
            if !overlayWindow.isKeyWindow {
                overlayWindow.makeKeyAndVisible()
            }
            // Drop any active text focus in the content window the moment
            // the lock lands. The keyboard lives in its own system window
            // ABOVE the overlay; leaving a field focused would keep the
            // keyboard floating over the lock and let key taps reach a
            // hidden input while locked.
            for contentWindow in scene.windows where contentWindow !== overlayWindow {
                contentWindow.endEditing(true)
            }
        } else {
            overlayWindow.endEditing(true)
            if overlayWindow.isKeyWindow {
                let contentWindow = scene.windows.first {
                    $0 !== overlayWindow &&
                    !$0.isHidden &&
                    $0.windowLevel == .normal
                }
                contentWindow?.makeKey()
            }
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
private struct LockOverlayRoot: View {
    @Environment(\.autoLockController) private var lockController

    /// Rule #12 §G direction key for the overlay window's content.
    /// The detached `UIHostingController` receives locale + direction
    /// reactively through the `.uniAppEnvironment()` applied at mount
    /// (its `@GRDBStorage` reads invalidate inside the host like
    /// anywhere else), and the lock surfaces are pure SwiftUI — but
    /// the host's own `semanticContentAttribute` latches at creation
    /// like every UIKit host, so the content is re-keyed on an LTR ↔
    /// RTL flip for the same reason the main tree is (see
    /// `AppRoot.rootDirectionKey`). Zero UX cost: language can only
    /// change while unlocked, when this renders nothing.
    @GRDBStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

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
        }
        // Direction-keyed identity for the overlay content — see the
        // `languageCode` property doc. Flips only on LTR ↔ RTL.
        .id(LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr")
        // Unlock fade — same 0.55s smooth spring the splash → content
        // crossfade uses, so the lock's exit reads as one system.
        .animation(.smooth(duration: 0.55), value: lockController.isLocked)
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
