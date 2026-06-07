import SwiftUI
import SwiftData

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
    /// 3. Biometric enrollment drift check (reads the snapshot from step 2).
    init() {
        // 1) Locale-driven currency seed (Rule #16 — the user's iPhone
        //    configuration is the wallet's first impression).
        CurrencyPreference.bootstrapIfNeeded()

        // 2) SwiftData container — synchronous open. `shared` is a
        //    `static let`; first access constructs the container and
        //    opens the SQLite file. `bootstrap()` then writes the
        //    singleton AppMetadata + BiometricEnrollment rows on first
        //    install (idempotent on subsequent launches).
        ApertureDatabase.shared.bootstrap()

        // 3) Biometric drift detection per user direction 2026-06-06.
        //    If the user changed their Face ID enrollment in iOS
        //    Settings since their last successful Aperture biometric
        //    authentication, flips `biometricEnabled` to `false` and
        //    sets `requiresBiometricReenrollment` so the next
        //    biometric-gated surface knows to re-prompt.
        BiometricEnrollmentTracker.checkForDrift(in: ApertureDatabase.shared.container)
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
private struct AppRoot: View {
    @Namespace private var logoNamespace
    @State private var phase: AppPhase = .splash
    @State private var hasLanded: Bool = false
    @State private var hasPrepared: Bool = false

    var body: some View {
        ZStack {
            // Mount RootGate from frame 1 so its layout settles
            // silently behind the splash. The staggered fade-in is
            // driven by `phase != .splash` — every non-logo
            // onboarding element starts at opacity 0 + 16pt offset,
            // and reveals when the parent flips out of `.splash`.
            RootGate(logoNamespace: logoNamespace, phase: phase)

            if phase != .onboarding {
                SplashView(
                    logoNamespace: logoNamespace,
                    phase: phase,
                    onSplashComplete: startTransition
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // Single medium-impact haptic at logo landing. Routed
        // through `UniHaptic.contextualImpact(.commit)` per Rule
        // #10 — `.commit` significance maps internally to
        // `.impact(weight: .medium, intensity: 1.0)`, which is the
        // exact `UIImpactFeedbackGenerator(style: .medium)` weight
        // the handoff names. The `UIImpactFeedbackGenerator.prepare()`
        // call inside `startTransition` primes the engine to
        // minimize landing latency.
        .uniHaptic(.contextualImpact(.commit), trigger: hasLanded)
    }

    /// Fired when the splash's `splashDuration` (2.6s, hand-coded
    /// per the prior splash spec) elapses. Primes the haptic
    /// generator, animates the phase to `.transitioning` (which
    /// drives the matchedGeometryEffect resolution + onboarding
    /// content fade-in stagger), schedules the haptic-landing flip
    /// at +0.82s (= the logo animation duration), and at +1.10s
    /// unmounts the splash chrome.
    private func startTransition() {
        // Prepare the haptic engine for the imminent impact. Done
        // once per transition; `.sensoryFeedback` doesn't need this
        // prep but the handoff explicitly names it for parity with
        // teams shipping UIKit, and it's a no-op when not needed.
        if !hasPrepared {
            UIImpactFeedbackGenerator(style: .medium).prepare()
            hasPrepared = true
        }

        // 0.82s logo move + content stagger. The matchedGeometryEffect
        // on the logo resolves to the onboarding frame; every
        // staggered onboarding element reads `phase` and animates
        // its own opacity + offset with its specific delay.
        withAnimation(.timingCurve(0.52, 0, 0.12, 1, duration: 0.82)) {
            phase = .transitioning
        }

        // Fire the haptic the moment the 0.82s logo animation
        // completes. SwiftUI's `withAnimation` has no completion
        // callback — but `.sensoryFeedback(_:trigger:)` reacts to
        // the flipped state on the next render pass. The 0.82s
        // timer + the flag match the animation duration exactly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) {
            hasLanded = true
        }

        // Brief buffer past the logo landing so any in-flight
        // animation completes cleanly, then unmount the splash
        // chrome entirely. `phase = .onboarding` removes
        // `SplashView` from the hierarchy via the `if` above.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.10) {
            withAnimation(.easeInOut(duration: 0.25)) {
                phase = .onboarding
            }
        }
    }
}

// MARK: - AppPhase

/// Three-state machine for the splash → onboarding orchestration.
/// Consumed by `AppRoot`, `SplashView`, and the onboarding
/// composition to drive matchedGeometryEffect + staggered fades.
enum AppPhase: Equatable {
    /// Initial cold-launch state. Splash is the active surface.
    case splash
    /// Logo flying to onboarding frame; splash chrome fading;
    /// onboarding content staggering in. Lasts ~0.82s.
    case transitioning
    /// Splash unmounted; onboarding fully interactive.
    case onboarding
}

// `RootGate` itself lives in `Features/Wallet/WalletHomeView.swift`
// where it is the closest sibling of `WalletHomeView` (the gate's
// secondary branch) and `OnboardingView` (the gate's primary
// branch). The gate's signature now accepts `logoNamespace + phase`
// so `AppRoot` can plumb both through.
