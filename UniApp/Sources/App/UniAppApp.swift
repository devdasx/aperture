import SwiftUI
import SwiftData

@main
struct UniAppApp: App {
    /// Gates the splash → onboarding transition. Lives at the app root so
    /// the splash runs **once per cold launch**. Background → foreground
    /// returns do NOT replay it (that's an iOS system-level transition,
    /// not a fresh launch — replaying would be noisy and breaks the "first
    /// breath" intent of the splash).
    @State private var hasFinishedSplash: Bool = false

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
            Group {
                if hasFinishedSplash {
                    // RootGate reads the wallet count reactively via
                    // `@Query`; routes to `WalletHomeView` if the user
                    // has at least one persisted wallet, otherwise to
                    // `OnboardingView`. When the create / import flows
                    // insert a `WalletRecord`, the gate flips
                    // automatically — no explicit handoff needed from
                    // the flows.
                    RootGate()
                } else {
                    SplashView(onComplete: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            hasFinishedSplash = true
                        }
                    })
                }
            }
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
